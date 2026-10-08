//! Explicit, copy-only imports. A complete verified file is published without replacement.
use crate::{
    api::{ApiError, AppState},
    jobs::Jobs,
    store::StoreError,
};
use anyhow::{Context, Result, ensure};
use axum::{
    Json, Router,
    body::Body,
    extract::{DefaultBodyLimit, Path, State},
    routing::{post, put},
};
use http_body_util::BodyExt;
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    path::{Component, Path as FsPath},
    sync::Arc,
};
use tokio::io::AsyncWriteExt;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct InputFile {
    pub id: String,
    pub relative_path: String,
    pub size: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Prepare {
    pub id: String,
    pub target_path: String,
    #[serde(default)]
    pub deduplicate: bool,
    #[serde(default)]
    pub preserve_structure: bool,
    pub files: Vec<InputFile>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct File {
    #[serde(flatten)]
    input: InputFile,
    file_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    received_sha256: Option<String>,
    #[serde(default)]
    skipped: bool,
    uploaded: bool,
    published: bool,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Batch {
    id: String,
    target_path: String,
    #[serde(default)]
    deduplicate: bool,
    #[serde(default)]
    preserve_structure: bool,
    files: Vec<File>,
    finished: bool,
    job_id: Option<String>,
}
fn invalid(message: impl Into<String>) -> anyhow::Error {
    StoreError {
        status: 422,
        code: "invalid_import".into(),
        message: message.into(),
    }
    .into()
}
fn conflict(message: impl Into<String>) -> anyhow::Error {
    StoreError {
        status: 409,
        code: "import_conflict".into(),
        message: message.into(),
    }
    .into()
}
fn uuid(value: &str) -> Result<String> {
    uuid::Uuid::parse_str(value)
        .map(|v| v.to_string())
        .map_err(|_| invalid("invalid UUID"))
}
fn load(db: &rusqlite::Connection, library: &str, id: &str) -> Result<Batch> {
    let id = uuid(id)?;
    let raw: Option<String> = db
        .query_row(
            "SELECT manifest FROM imports WHERE id=? AND library_id=?",
            params![id, library],
            |r| r.get(0),
        )
        .optional()?;
    serde_json::from_str(&raw.ok_or_else(|| invalid("import batch not found"))?)
        .context("read import manifest")
}
fn save(db: &rusqlite::Connection, library: &str, batch: &Batch) -> Result<()> {
    db.execute("INSERT INTO imports(id,library_id,manifest) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET manifest=excluded.manifest", params![batch.id,library,serde_json::to_string(batch)?])?;
    Ok(())
}
fn target(jobs: &Jobs, library: &str, path: &str) -> Result<std::path::PathBuf> {
    let path = jobs
        .validate_path(FsPath::new(path))
        .map_err(|e| invalid(format!("{e:#}")))?;
    ensure!(
        jobs.folders()?
            .iter()
            .any(|f| f.active && f.library_id == library && path.starts_with(&f.path)),
        invalid("target must be inside an active tracked folder")
    );
    Ok(path)
}
// Both IMG.xmp and IMG.RAW.xmp follow the same source stem as IMG.RAW.
fn group(file: &InputFile) -> Result<(String, String, String)> {
    let path = FsPath::new(&file.relative_path);
    ensure!(
        !path.is_absolute() && path.components().all(|c| matches!(c, Component::Normal(_))),
        invalid("source path must be relative without dot components")
    );
    ensure!(
        !file.relative_path.contains('\\') && !file.relative_path.contains('\0'),
        invalid("invalid source path")
    );
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .context("source filename")?;
    ensure!(
        !name.starts_with('.'),
        invalid("hidden files cannot be imported")
    );
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    ensure!(
        crate::media::is_raw(path)
            || ["jpg", "jpeg", "heif", "heic", "hif", "xmp"].contains(&ext.as_str()),
        invalid("only RAW, JPEG, HEIF and associated XMP are supported")
    );
    let mut stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .context("source stem")?;
    if ext == "xmp" {
        let p = FsPath::new(stem);
        if crate::media::is_raw(p)
            || p.extension().and_then(|e| e.to_str()).is_some_and(|e| {
                ["jpg", "jpeg", "heif", "heic", "hif"].contains(&e.to_ascii_lowercase().as_str())
            })
        {
            stem = p
                .file_stem()
                .and_then(|s| s.to_str())
                .context("sidecar stem")?;
        }
    }
    ensure!(!stem.is_empty(), invalid("empty filename stem"));
    let key = path
        .parent()
        .unwrap_or(FsPath::new(""))
        .join(stem.to_lowercase())
        .to_string_lossy()
        .to_string();
    Ok((key, stem.to_owned(), name[stem.len()..].to_owned()))
}
fn existing_batch(
    db: &rusqlite::Connection,
    library: &str,
    input: &Prepare,
    destination: &FsPath,
) -> Result<Option<Batch>> {
    let existing: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM imports WHERE id=?)",
        [&input.id],
        |r| r.get(0),
    )?;
    if existing {
        let batch = load(db, library, &input.id)?;
        let original: Vec<_> = batch.files.iter().map(|f| f.input.clone()).collect();
        let mut actual = input.files.clone();
        let mut original = original;
        original.sort_by(|a, b| a.id.cmp(&b.id));
        actual.sort_by(|a, b| a.id.cmp(&b.id));
        ensure!(
            batch.target_path == destination.to_string_lossy()
                && batch.deduplicate == input.deduplicate
                && batch.preserve_structure == input.preserve_structure
                && original == actual,
            conflict("batch ID already belongs to another manifest")
        );
        return Ok(Some(batch));
    }
    Ok(None)
}
fn prepare(jobs: &Jobs, library: &str, mut input: Prepare) -> Result<Batch> {
    let _guard = jobs.directory_mutation.read().unwrap();
    crate::directory_move::ensure_reconciled(jobs)?;
    ensure!(
        uuid::Uuid::parse_str(&input.id).is_ok(),
        invalid("invalid batch UUID")
    );
    ensure!(
        !input.files.is_empty() && input.files.len() <= 10000,
        invalid("batch must contain 1 to 10000 files")
    );
    input.id = uuid(&input.id)?;
    for file in &mut input.files {
        file.id = uuid(&file.id)?;
    }
    let destination = target(jobs, library, &input.target_path)?;
    let mut groups: BTreeMap<String, Vec<(InputFile, String, String)>> = BTreeMap::new();
    let mut ids = HashSet::new();
    let mut paths = HashSet::new();
    for file in &input.files {
        ensure!(
            uuid::Uuid::parse_str(&file.id).is_ok()
                && ids.insert(&file.id)
                && paths.insert(&file.relative_path),
            invalid("file IDs and source paths must be unique")
        );
        ensure!(
            file.size > 0
                && file.size <= 8 * 1024 * 1024 * 1024
                && file.sha256.as_ref().is_none_or(|digest| {
                    digest.len() == 64
                        && digest
                            .bytes()
                            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
                }),
            invalid("invalid size or SHA256")
        );
        ensure!(
            !input.deduplicate || file.sha256.is_some(),
            invalid("deduplication requires SHA256 for every file")
        );
        let (key, stem, suffix) = group(file)?;
        groups
            .entry(key)
            .or_default()
            .push((file.clone(), stem, suffix));
    }
    if let Some(batch) = existing_batch(&jobs.db.lock().unwrap(), library, &input, &destination)? {
        return Ok(batch);
    }
    let mut directories: BTreeMap<std::path::PathBuf, SourceGroups> = BTreeMap::new();
    for (key, entries) in groups {
        let parent = if input.preserve_structure {
            FsPath::new(&entries[0].0.relative_path)
                .parent()
                .unwrap_or(FsPath::new(""))
        } else {
            FsPath::new("")
        };
        import_directory(&destination, parent, false)?;
        directories
            .entry(parent.to_path_buf())
            .or_default()
            .insert(key, entries);
    }
    let mut planned_directories = Vec::new();
    for (parent, groups) in directories {
        let existing =
            hash_existing_groups(&destination.join(&parent), &groups, input.deduplicate)?;
        planned_directories.push((parent, groups, existing));
    }
    let db = jobs.db.lock().unwrap();
    if let Some(batch) = existing_batch(&db, library, &input, &destination)? {
        return Ok(batch);
    }
    let mut files = Vec::new();
    for (parent, groups, (existing_groups, existing_hashes)) in planned_directories {
        let directory = destination.join(&parent);
        for mut file in plan_files(
            &db,
            &directory,
            &groups,
            input.deduplicate,
            &existing_groups,
            &existing_hashes,
        )? {
            file.file_name = parent.join(&file.file_name).to_string_lossy().into_owned();
            files.push(file);
        }
    }
    let batch = Batch {
        id: input.id,
        target_path: destination.to_string_lossy().to_string(),
        deduplicate: input.deduplicate,
        preserve_structure: input.preserve_structure,
        files,
        finished: false,
        job_id: None,
    };
    save(&db, library, &batch)?;
    Ok(batch)
}
type SourceGroups = BTreeMap<String, Vec<(InputFile, String, String)>>;
fn hash_existing_groups(
    destination: &FsPath,
    groups: &SourceGroups,
    deduplicate: bool,
) -> Result<(ExistingGroups, BTreeMap<String, String>)> {
    let existing_groups = if deduplicate && destination.exists() {
        existing_groups(destination)?
    } else {
        BTreeMap::new()
    };
    let mut existing_hashes = BTreeMap::new();
    if deduplicate {
        let candidates: HashSet<_> = groups
            .values()
            .flatten()
            .map(|(file, _, suffix)| (suffix.to_lowercase(), file.size))
            .collect();
        for existing in existing_groups.values() {
            for (suffix, (name, _)) in existing {
                let path = destination.join(name);
                let metadata = std::fs::symlink_metadata(&path)?;
                if metadata.is_file() && candidates.contains(&(suffix.clone(), metadata.len())) {
                    existing_hashes.insert(name.clone(), crate::media::sha256_file(&path)?);
                }
            }
        }
    }
    Ok((existing_groups, existing_hashes))
}
fn plan_files(
    db: &rusqlite::Connection,
    destination: &FsPath,
    groups: &SourceGroups,
    deduplicate: bool,
    existing_groups: &ExistingGroups,
    existing_hashes: &BTreeMap<String, String>,
) -> Result<Vec<File>> {
    let mut reserved: HashSet<String> = if destination.exists() {
        std::fs::read_dir(destination)?
            .map(|e| e.map(|e| e.file_name().to_string_lossy().to_lowercase()))
            .collect::<std::io::Result<_>>()?
    } else {
        HashSet::new()
    };
    let mut pending_names = HashSet::new();
    let mut stmt = db.prepare("SELECT manifest FROM imports")?;
    for raw in stmt.query_map([], |r| r.get::<_, String>(0))? {
        let batch: Batch = serde_json::from_str(&raw?)?;
        for file in batch.files {
            let path = FsPath::new(&batch.target_path).join(&file.file_name);
            if path.parent() == Some(destination) {
                let name = path
                    .file_name()
                    .context("reserved filename")?
                    .to_string_lossy()
                    .to_lowercase();
                if !batch.finished {
                    pending_names.insert(name.clone());
                }
                reserved.insert(name);
            }
        }
    }
    let mut occupied_stems: HashSet<String> =
        reserved.iter().map(|name| destination_stem(name)).collect();
    let mut files = Vec::new();
    for entries in groups.values() {
        ensure!(
            entries
                .iter()
                .any(|e| !e.2.to_ascii_lowercase().ends_with(".xmp")),
            invalid("XMP must accompany a RAW, JPEG or HEIF file with the same source stem")
        );
        let stem = &entries
            .iter()
            .find(|e| !e.2.to_ascii_lowercase().ends_with(".xmp"))
            .context("photo group is empty")?
            .1;
        let mut suffixes = Vec::new();
        for (_, _, suffix) in entries {
            if suffix.eq_ignore_ascii_case(".xmp") {
                suffixes.push(".xmp".to_owned());
            } else if suffix.to_ascii_lowercase().ends_with(".xmp") {
                let source_extension = &suffix[..suffix.len() - 4];
                let matching = entries
                    .iter()
                    .find(|e| e.2.eq_ignore_ascii_case(source_extension))
                    .ok_or_else(|| invalid("appended XMP must accompany its matching original"))?;
                suffixes.push(format!("{}.xmp", matching.2));
            } else {
                suffixes.push(suffix.clone());
            }
        }
        if deduplicate {
            ensure!(
                suffixes
                    .iter()
                    .map(|suffix| suffix.to_lowercase())
                    .collect::<HashSet<_>>()
                    .len()
                    == suffixes.len(),
                invalid("case-insensitive duplicate filenames within source group")
            );
            if let Some(matches) = matching_existing_group(
                &destination,
                entries,
                &suffixes,
                &pending_names,
                &reserved,
                existing_groups,
                existing_hashes,
            )? {
                for ((input, _, _), (name, skipped)) in entries.iter().zip(matches) {
                    reserved.insert(name.to_lowercase());
                    pending_names.insert(name.to_lowercase());
                    occupied_stems.insert(destination_stem(&name));
                    files.push(File {
                        input: input.clone(),
                        file_name: name,
                        received_sha256: if skipped { input.sha256.clone() } else { None },
                        skipped,
                        uploaded: skipped,
                        published: skipped,
                    });
                }
                continue;
            }
        }
        let mut number = 0;
        loop {
            let names: Vec<_> = suffixes
                .iter()
                .map(|suffix| {
                    if number == 0 {
                        format!("{stem}{suffix}")
                    } else {
                        format!("{stem} ({number}){suffix}")
                    }
                })
                .collect();
            let unique: HashSet<_> = names.iter().map(|n| n.to_lowercase()).collect();
            ensure!(
                unique.len() == names.len(),
                invalid("case-insensitive duplicate filenames within source group")
            );
            ensure!(
                names.iter().all(|n| n.len() <= 255),
                invalid("destination filename exceeds 255 bytes")
            );
            if occupied_stems.contains(&destination_stem(&names[0]))
                || names.iter().any(|n| reserved.contains(&n.to_lowercase()))
            {
                number += 1;
                continue;
            }
            occupied_stems.insert(destination_stem(&names[0]));
            for ((input, _, _), name) in entries.iter().zip(names) {
                reserved.insert(name.to_lowercase());
                pending_names.insert(name.to_lowercase());
                files.push(File {
                    input: input.clone(),
                    file_name: name,
                    received_sha256: None,
                    skipped: false,
                    uploaded: false,
                    published: false,
                });
            }
            break;
        }
    }
    Ok(files)
}

// Walk each ancestor without following symlinks, including when a directory was
// added after prepare. Excluded scanner directories cannot contain imports.
fn import_directory(root: &FsPath, relative: &FsPath, create: bool) -> Result<std::path::PathBuf> {
    let mut path = root.to_path_buf();
    for component in relative.components() {
        let Component::Normal(name) = component else {
            return Err(invalid(
                "destination directory must be relative without dot components",
            ));
        };
        let name_text = name.to_string_lossy();
        ensure!(
            !name_text.starts_with('.')
                && !name_text.eq_ignore_ascii_case("@eaDir")
                && !name_text.eq_ignore_ascii_case("#recycle")
                && name_text.len() <= 255,
            invalid("excluded or invalid destination directory")
        );
        path.push(name);
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) => ensure!(
                metadata.is_dir() && !metadata.file_type().is_symlink(),
                conflict("destination parent must be a directory without symlinks")
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                if create {
                    match std::fs::create_dir(&path) {
                        Ok(()) => {
                            std::fs::File::open(path.parent().context("destination parent")?)?
                                .sync_all()?
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                            let metadata = std::fs::symlink_metadata(&path)?;
                            ensure!(
                                metadata.is_dir() && !metadata.file_type().is_symlink(),
                                conflict("destination parent must be a directory without symlinks")
                            );
                        }
                        Err(error) => return Err(error).context("create import directory"),
                    }
                }
            }
            Err(error) => return Err(error).context("inspect import directory"),
        }
    }
    Ok(path)
}

type ExistingGroups = BTreeMap<String, BTreeMap<String, (String, String)>>;
fn existing_groups(destination: &FsPath) -> Result<ExistingGroups> {
    let mut groups: BTreeMap<String, BTreeMap<String, (String, String)>> = BTreeMap::new();
    for entry in std::fs::read_dir(destination)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if !entry.file_type()?.is_file() {
            continue;
        }
        let input = InputFile {
            id: String::new(),
            relative_path: name.clone(),
            size: 0,
            sha256: None,
        };
        if let Ok((key, stem, suffix)) = group(&input) {
            groups
                .entry(key)
                .or_default()
                .insert(suffix.to_lowercase(), (name, stem));
        }
    }
    Ok(groups)
}
// A whole source group follows an existing original only when every overlapping
// companion agrees, so a differing sidecar can never attach to the wrong original.
fn matching_existing_group(
    destination: &FsPath,
    entries: &[(InputFile, String, String)],
    suffixes: &[String],
    pending_names: &HashSet<String>,
    occupied: &HashSet<String>,
    groups: &ExistingGroups,
    hashes: &BTreeMap<String, String>,
) -> Result<Option<Vec<(String, bool)>>> {
    for existing in groups.values() {
        let mut anchor = None;
        let mut matches = true;
        for ((input, _, _), suffix) in entries.iter().zip(suffixes) {
            if let Some((name, stem)) = existing.get(&suffix.to_lowercase()) {
                let path = destination.join(name);
                if pending_names.contains(&name.to_lowercase())
                    || std::fs::metadata(&path)?.len() != input.size
                {
                    matches = false;
                    break;
                }
                if hashes.get(name) != input.sha256.as_ref() {
                    matches = false;
                    break;
                }
                if !suffix.to_ascii_lowercase().ends_with(".xmp") {
                    anchor = Some(stem.clone());
                }
            }
        }
        if !matches {
            continue;
        }
        let Some(stem) = anchor else {
            continue;
        };
        let mut result = Vec::new();
        for suffix in suffixes {
            if let Some((name, _)) = existing.get(&suffix.to_lowercase()) {
                result.push((name.clone(), true));
            } else {
                let name = suffix
                    .strip_suffix(".xmp")
                    .and_then(|original_suffix| existing.get(&original_suffix.to_lowercase()))
                    .map(|(name, _)| format!("{name}.xmp"))
                    .unwrap_or_else(|| format!("{stem}{suffix}"));
                if occupied.contains(&name.to_lowercase())
                    || pending_names.contains(&name.to_lowercase())
                    || name.len() > 255
                {
                    matches = false;
                    break;
                }
                result.push((name, false));
            }
        }
        if matches {
            return Ok(Some(result));
        }
    }
    Ok(None)
}

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route(
            "/libraries/{library}/imports",
            post(prepare_handler).layer(DefaultBodyLimit::max(8 * 1024 * 1024)),
        )
        .route(
            "/libraries/{library}/imports/{batch}/files/{file}",
            put(upload).layer(DefaultBodyLimit::disable()),
        )
        .route("/libraries/{library}/imports/{batch}/finish", post(finish))
}
async fn prepare_handler(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(input): Json<Prepare>,
) -> Result<Json<Value>, ApiError> {
    let batch = tokio::task::spawn_blocking(move || prepare(&state.jobs, &library, input))
        .await
        .map_err(anyhow::Error::from)??;
    Ok(Json(
        serde_json::to_value(batch).map_err(anyhow::Error::from)?,
    ))
}
async fn upload(
    State(state): State<Arc<AppState>>,
    Path((library, id, file_id)): Path<(String, String, String)>,
    mut body: Body,
) -> Result<Json<Value>, ApiError> {
    let id = uuid(&id)?;
    let file_id = uuid(&file_id)?;
    let jobs = state.jobs.clone();
    let lib = library.clone();
    let batch_id = id.clone();
    let fid = file_id.clone();
    let (batch, file, destination) = tokio::task::spawn_blocking(move || -> Result<_> {
        let batch = load(&jobs.db.lock().unwrap(), &lib, &batch_id)?;
        let file = batch
            .files
            .iter()
            .find(|f| f.input.id == fid)
            .cloned()
            .ok_or_else(|| invalid("file not found"))?;
        let destination = target(&jobs, &lib, &batch.target_path)?;
        Ok((batch, file, destination))
    })
    .await
    .map_err(anyhow::Error::from)??;
    if file.uploaded {
        return Ok(Json(json!({"uploaded":true})));
    }
    let temporary = tempfile::Builder::new()
        .prefix(".keeps-import-")
        .tempfile_in(&destination)
        .map_err(anyhow::Error::from)?;
    let mut writer = tokio::fs::File::from_std(temporary.reopen().map_err(anyhow::Error::from)?);
    let mut size = 0u64;
    let mut hash = Sha256::new();
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(anyhow::Error::from)?;
        if let Ok(bytes) = frame.into_data() {
            size += bytes.len() as u64;
            ensure_upload_size(size, file.input.size)?;
            writer
                .write_all(&bytes)
                .await
                .map_err(anyhow::Error::from)?;
            hash.update(&bytes);
        }
    }
    let received_sha256 = format!("{:x}", hash.finalize());
    if size != file.input.size
        || file
            .input
            .sha256
            .as_ref()
            .is_some_and(|expected| expected != &received_sha256)
    {
        return Err(invalid("uploaded size or SHA256 does not match manifest").into());
    }
    writer.sync_all().await.map_err(anyhow::Error::from)?;
    drop(writer);
    tokio::task::spawn_blocking(move || -> Result<()> {
        let destination = target(&state.jobs, &library, &batch.target_path)?;
        let db = state.jobs.db.lock().unwrap();
        let mut current = load(&db, &library, &id)?;
        let current_id = current.id.clone();
        let item = current
            .files
            .iter_mut()
            .find(|f| f.input.id == file_id)
            .context("import file disappeared")?;
        if item.uploaded {
            return Ok(());
        }
        let output = staging(&destination, &current_id, &item.input.id);
        match std::fs::hard_link(temporary.path(), &output) {
            Ok(()) => (),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                let metadata = std::fs::symlink_metadata(&output)?;
                ensure!(
                    metadata.is_file()
                        && !metadata.file_type().is_symlink()
                        && metadata.len() == item.input.size
                        && item
                            .received_sha256
                            .as_ref()
                            .is_none_or(|digest| digest == &received_sha256)
                        && crate::media::sha256_file(&output)?
                            == item.received_sha256.as_deref().unwrap_or(&received_sha256),
                    conflict("destination appeared after prepare; existing file was preserved")
                );
            }
            Err(e) => return Err(e).context("publish imported original without overwriting"),
        }
        std::fs::File::open(&destination)?.sync_all()?;
        item.received_sha256 = Some(received_sha256);
        item.uploaded = true;
        save(&db, &library, &current)?;
        Ok(())
    })
    .await
    .map_err(anyhow::Error::from)??;
    Ok(Json(json!({"uploaded":true})))
}
fn ensure_upload_size(size: u64, expected: u64) -> Result<(), ApiError> {
    if size > expected {
        Err(invalid("upload exceeds declared size").into())
    } else {
        Ok(())
    }
}
async fn finish(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    let result = tokio::task::spawn_blocking(move || -> Result<Value> {
        let _directory_guard = state.jobs.directory_mutation.read().unwrap();
        crate::directory_move::ensure_reconciled(&state.jobs)?;
        let batch = load(&state.jobs.db.lock().unwrap(), &library, &id)?;
        if let Some(job_id) = batch.job_id {
            return Ok(json!({"job":state.jobs.job(&job_id)?}));
        }
        let destination = target(&state.jobs, &library, &batch.target_path)?;
        ensure!(
            batch.files.iter().all(|f| f.uploaded),
            conflict("upload all files before finishing import")
        );
        let folder = state
            .jobs
            .folders()?
            .into_iter()
            .find(|f| f.active && f.library_id == library && destination.starts_with(&f.path))
            .context("tracked import folder disappeared")?;
        for item in &batch.files {
            import_directory(
                &destination,
                FsPath::new(&item.file_name)
                    .parent()
                    .context("import parent")?,
                false,
            )?;
        }
        for item in batch.files.iter().filter(|item| item.skipped) {
            let path = destination.join(&item.file_name);
            let metadata = std::fs::symlink_metadata(&path).map_err(|error| {
                conflict(format!("deduplicated file is unavailable: {error:#}"))
            })?;
            ensure!(
                metadata.is_file()
                    && metadata.len() == item.input.size
                    && Some(crate::media::sha256_file(&path)?) == item.received_sha256,
                conflict("deduplicated file changed before import finished")
            );
        }
        {
            let db = state.jobs.db.lock().unwrap();
            let mut current = load(&db, &library, &id)?;
            // Discover a late collision before exposing any sidecar from this batch.
            for item in current.files.iter().filter(|item| !item.published) {
                let output = destination.join(&item.file_name);
                match std::fs::symlink_metadata(&output) {
                    Ok(_) => ensure!(
                        same_file(&staging(&destination, &current.id, &item.input.id), &output)?,
                        conflict("destination appeared after prepare; existing file was preserved")
                    ),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
                    Err(error) => return Err(error).context("inspect import destination"),
                }
            }
            let mut order: Vec<usize> = (0..current.files.len()).collect();
            order.sort_by_key(|i| {
                !current.files[*i]
                    .file_name
                    .to_ascii_lowercase()
                    .ends_with(".xmp")
            });
            // Sidecars must exist before any original becomes visible to the scanner.
            for index in order {
                if current.files[index].published {
                    continue;
                }
                let item = &current.files[index];
                let staged = staging(&destination, &current.id, &item.input.id);
                let parent = import_directory(
                    &destination,
                    FsPath::new(&item.file_name)
                        .parent()
                        .context("import parent")?,
                    true,
                )?;
                let output = destination.join(&item.file_name);
                match std::fs::hard_link(&staged, &output) {
                    Ok(()) => (),
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                        ensure!(
                            same_file(&staged, &output)?,
                            conflict(
                                "destination appeared after prepare; existing file was preserved"
                            )
                        );
                    }
                    Err(e) => {
                        return Err(e).context("publish imported original without overwriting");
                    }
                }
                std::fs::File::open(&parent)?.sync_all()?;
                current.files[index].published = true;
                save(&db, &library, &current)?;
                std::fs::remove_file(staged).context("remove completed import staging link")?;
            }
        }
        let job = if batch.preserve_structure {
            state
                .jobs
                .enqueue_reconcile_scope(&folder.id, &destination)?
        } else {
            state
                .jobs
                .enqueue_manual_directory(&folder.id, &destination)?
        };
        let db = state.jobs.db.lock().unwrap();
        let mut batch = load(&db, &library, &id)?;
        batch.finished = true;
        batch.job_id = Some(job.id.clone());
        save(&db, &library, &batch)?;
        Ok(json!({"job":job}))
    })
    .await
    .map_err(anyhow::Error::from)??;
    Ok(Json(result))
}

fn staging(destination: &FsPath, batch: &str, file: &str) -> std::path::PathBuf {
    destination.join(format!(".keeps-import-{batch}-{file}"))
}

fn destination_stem(name: &str) -> String {
    let path = FsPath::new(name);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or(name);
    if path
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("xmp"))
        && crate::media::is_photo(FsPath::new(stem))
    {
        FsPath::new(stem)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or(stem)
            .to_lowercase()
    } else {
        stem.to_lowercase()
    }
}

fn same_file(first: &FsPath, second: &FsPath) -> Result<bool> {
    use std::os::unix::fs::MetadataExt;
    let a = std::fs::symlink_metadata(first)?;
    let b = std::fs::symlink_metadata(second)?;
    Ok(a.is_file() && b.is_file() && a.dev() == b.dev() && a.ino() == b.ino())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn structure_input(root: &FsPath, paths: &[&str], deduplicate: bool) -> Prepare {
        Prepare {
            id: uuid::Uuid::new_v4().to_string(),
            target_path: root.to_string_lossy().into_owned(),
            deduplicate,
            preserve_structure: true,
            files: paths
                .iter()
                .map(|path| InputFile {
                    id: uuid::Uuid::new_v4().to_string(),
                    relative_path: (*path).into(),
                    size: 8,
                    sha256: Some(format!("{:x}", Sha256::digest(b"original"))),
                })
                .collect(),
        }
    }

    #[test]
    fn structure_preserves_directories_and_scopes_deduplication_and_reservations() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("photos");
        std::fs::create_dir_all(root.join("card/day")).unwrap();
        std::fs::write(root.join("IMG.CR3"), b"original").unwrap();
        std::fs::write(root.join("card/day/IMG.CR3"), b"original").unwrap();
        let db = dir.path().join("jobs.sqlite");
        let jobs = Jobs::open(&db, &root).unwrap();
        jobs.add_folder("lib", ".").unwrap();
        let input = structure_input(
            jobs.root(),
            &["card/day/IMG.CR3", "card/day/IMG.CR3.xmp", "other/IMG.CR3"],
            true,
        );
        let batch = prepare(&jobs, "lib", input.clone()).unwrap();
        assert_eq!(
            batch
                .files
                .iter()
                .map(|f| (f.file_name.as_str(), f.skipped))
                .collect::<Vec<_>>(),
            vec![
                ("card/day/IMG.CR3", true),
                ("card/day/IMG.CR3.xmp", false),
                ("other/IMG.CR3", false)
            ]
        );
        assert!(!root.join("other").exists());
        let mut changed = input.clone();
        changed.preserve_structure = false;
        assert!(
            prepare(&jobs, "lib", changed)
                .unwrap_err()
                .to_string()
                .contains("another manifest")
        );
        drop(jobs);
        let jobs = Jobs::open(&db, &root).unwrap();
        let resumed = prepare(&jobs, "lib", input).unwrap();
        assert!(resumed.preserve_structure);
        assert_eq!(resumed.files[1].file_name, "card/day/IMG.CR3.xmp");
        let next = prepare(
            &jobs,
            "lib",
            structure_input(jobs.root(), &["card/day/IMG.CR3", "other/IMG.CR3"], false),
        )
        .unwrap();
        assert_eq!(
            next.files
                .iter()
                .map(|f| f.file_name.as_str())
                .collect::<Vec<_>>(),
            vec!["card/day/IMG (1).CR3", "other/IMG (1).CR3"]
        );
        let mut direct = structure_input(&jobs.root().join("card/day"), &["IMG.CR3"], false);
        direct.preserve_structure = false;
        assert_eq!(
            prepare(&jobs, "lib", direct).unwrap().files[0].file_name,
            "IMG (2).CR3"
        );
    }

    #[test]
    fn structure_rejects_symlink_and_excluded_parents() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("photos");
        std::fs::create_dir(&root).unwrap();
        std::os::unix::fs::symlink(dir.path(), root.join("escape")).unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap();
        jobs.add_folder("lib", ".").unwrap();
        for path in [
            "escape/nested/IMG.CR3",
            "../IMG.CR3",
            ".hidden/IMG.CR3",
            "@eaDir/IMG.CR3",
            "#recycle/IMG.CR3",
        ] {
            assert!(
                prepare(&jobs, "lib", structure_input(jobs.root(), &[path], false)).is_err(),
                "{path}"
            );
        }
        let legacy: Prepare = serde_json::from_value(
            json!({"id":uuid::Uuid::new_v4().to_string(), "targetPath":root, "files":[]}),
        )
        .unwrap();
        assert!(!legacy.preserve_structure);
    }

    #[tokio::test]
    async fn structure_finish_publishes_nested_files_and_enqueues_recursive_scan() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("photos");
        std::fs::create_dir(&root).unwrap();
        let keeps = dir.path().join("keeps");
        let previews = crate::previews::PreviewStorage::new(
            &keeps,
            Some(&root),
            "http://localhost",
            "test-preview-key-01234567890123456789",
        )
        .unwrap();
        let state = Arc::new(AppState {
            store: Arc::new(
                crate::store::Store::open(&keeps.join("db/control_plane.sqlite"), true).unwrap(),
            ),
            previews: Arc::new(previews),
            jobs: Arc::new(Jobs::open(&keeps.join("db/jobs.sqlite"), &root).unwrap()),
            access_token: String::new(),
            library_id: "lib".into(),
            original_root_names: Default::default(),
        });
        state.jobs.add_folder("lib", ".").unwrap();
        let batch = prepare(
            &state.jobs,
            "lib",
            structure_input(
                state.jobs.root(),
                &["card/day/IMG.CR3", "card/day/IMG.CR3.xmp", "other/IMG.CR3"],
                false,
            ),
        )
        .unwrap();
        for file in &batch.files {
            assert!(
                upload(
                    State(state.clone()),
                    Path(("lib".into(), batch.id.clone(), file.input.id.clone())),
                    Body::from("original")
                )
                .await
                .is_ok()
            );
        }
        assert!(!root.join("card").exists());
        std::os::unix::fs::symlink(dir.path(), root.join("card")).unwrap();
        assert!(
            finish(State(state.clone()), Path(("lib".into(), batch.id.clone())))
                .await
                .is_err()
        );
        std::fs::remove_file(root.join("card")).unwrap();
        assert!(!dir.path().join("day").exists());
        let result = finish(State(state.clone()), Path(("lib".into(), batch.id.clone()))).await;
        assert!(result.is_ok());
        let Json(result) = result.ok().unwrap();
        assert_eq!(result["job"]["scopeKind"], "recursive");
        for file in &batch.files {
            assert_eq!(
                std::fs::read(root.join(&file.file_name)).unwrap(),
                b"original"
            );
        }
        let resumed = load(&state.jobs.db.lock().unwrap(), "lib", &batch.id).unwrap();
        assert!(resumed.finished && resumed.files.iter().all(|f| f.published));
    }

    #[test]
    fn sidecar_case_matches_original_destination() {
        let dir = tempfile::tempdir().unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), dir.path()).unwrap();
        jobs.add_folder("lib", ".").unwrap();
        let files = ["folder/img.XMP", "folder/IMG.cr3", "folder/img.CR3.XmP"]
            .iter()
            .map(|p| InputFile {
                id: uuid::Uuid::new_v4().to_string(),
                relative_path: p.to_string(),
                size: 1,
                sha256: Some("a".repeat(64)),
            })
            .collect();
        let batch = prepare(
            &jobs,
            "lib",
            Prepare {
                id: uuid::Uuid::new_v4().to_string(),
                target_path: jobs.root().to_str().unwrap().into(),
                deduplicate: false,
                preserve_structure: false,
                files,
            },
        )
        .unwrap();
        assert_eq!(
            batch
                .files
                .iter()
                .map(|f| f.file_name.as_str())
                .collect::<Vec<_>>(),
            vec!["IMG.xmp", "IMG.cr3", "IMG.cr3.xmp"]
        );
    }
    #[test]
    fn jpeg_import_keeps_sidecars_together_on_name_collision() {
        for extension in ["JPG", "JpEg"] {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().join("photos");
            std::fs::create_dir(&root).unwrap();
            let original = root.join(format!("IMG.{extension}"));
            std::fs::write(&original, b"existing").unwrap();
            let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap();
            jobs.add_folder("lib", ".").unwrap();
            let paths = [
                format!("deep/nested/IMG.{extension}"),
                "deep/nested/img.XMP".into(),
                format!("deep/nested/img.{}.XmP", extension.to_lowercase()),
            ];
            let batch = prepare(
                &jobs,
                "lib",
                Prepare {
                    id: uuid::Uuid::new_v4().to_string(),
                    target_path: jobs.root().to_str().unwrap().into(),
                    deduplicate: false,
                    preserve_structure: false,
                    files: paths
                        .iter()
                        .map(|path| InputFile {
                            id: uuid::Uuid::new_v4().to_string(),
                            relative_path: path.clone(),
                            size: 1,
                            sha256: None,
                        })
                        .collect(),
                },
            )
            .unwrap();
            assert_eq!(
                batch
                    .files
                    .iter()
                    .map(|f| f.file_name.clone())
                    .collect::<Vec<_>>(),
                vec![
                    format!("IMG (1).{extension}"),
                    "IMG (1).xmp".into(),
                    format!("IMG (1).{extension}.xmp"),
                ]
            );
            assert_eq!(std::fs::read(original).unwrap(), b"existing");
        }
    }
    #[test]
    fn reservations_survive_restart_and_avoid_other_extensions() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("photos");
        std::fs::create_dir(&root).unwrap();
        std::fs::write(root.join("IMG.CR3"), b"existing").unwrap();
        let db = dir.path().join("jobs.sqlite");
        let jobs = Jobs::open(&db, &root).unwrap();
        jobs.add_folder("lib", ".").unwrap();
        let input = Prepare {
            id: uuid::Uuid::new_v4().to_string(),
            target_path: jobs.root().to_str().unwrap().into(),
            deduplicate: false,
            preserve_structure: false,
            files: vec![InputFile {
                id: uuid::Uuid::new_v4().to_string(),
                relative_path: "card/IMG.HEIC".into(),
                size: 1,
                sha256: Some("a".repeat(64)),
            }],
        };
        let batch = prepare(&jobs, "lib", input.clone()).unwrap();
        assert_eq!(batch.files[0].file_name, "IMG (1).HEIC");
        drop(jobs);
        let jobs = Jobs::open(&db, &root).unwrap();
        let resumed = prepare(&jobs, "lib", input.clone()).unwrap();
        assert_eq!(resumed.files[0].file_name, batch.files[0].file_name);
        let mut other = input;
        other.id = uuid::Uuid::new_v4().to_string();
        assert_eq!(
            prepare(&jobs, "lib", other).unwrap().files[0].file_name,
            "IMG (2).HEIC"
        );
    }
    #[test]
    fn optional_deduplication_keeps_groups_together_and_preserves_sidecars() {
        use sha2::{Digest, Sha256};
        for (enabled, existing_sidecar, include_heif, expected, skipped) in [
            (false, None, false, "IMG (1).CR3", vec![false]),
            (true, None, false, "IMG.CR3", vec![true]),
            (
                true,
                Some(b"sidecar".as_slice()),
                true,
                "IMG.CR3",
                vec![true, false, true],
            ),
            (true, None, true, "IMG.CR3", vec![true, false, false]),
            (
                true,
                Some(b"changed".as_slice()),
                true,
                "IMG (1).CR3",
                vec![false, false, false],
            ),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().join("photos");
            std::fs::create_dir(&root).unwrap();
            std::fs::write(root.join("IMG.CR3"), b"original").unwrap();
            if let Some(data) = existing_sidecar {
                std::fs::write(root.join("IMG.xmp"), data).unwrap();
            }
            let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap();
            jobs.add_folder("lib", ".").unwrap();
            let mut contents = vec![("IMG.CR3", b"original".as_slice())];
            if include_heif {
                contents.extend([
                    ("IMG.heic", b"heif".as_slice()),
                    ("IMG.xmp", b"sidecar".as_slice()),
                ]);
            }
            let files = contents
                .iter()
                .map(|(name, data)| InputFile {
                    id: uuid::Uuid::new_v4().to_string(),
                    relative_path: format!("card/{name}"),
                    size: data.len() as u64,
                    sha256: enabled.then(|| format!("{:x}", Sha256::digest(data))),
                })
                .collect();
            let input = Prepare {
                id: uuid::Uuid::new_v4().to_string(),
                target_path: jobs.root().to_string_lossy().into(),
                deduplicate: enabled,
                preserve_structure: false,
                files,
            };
            let batch = prepare(&jobs, "lib", input.clone()).unwrap();
            assert_eq!(batch.files[0].file_name, expected);
            assert_eq!(
                batch
                    .files
                    .iter()
                    .map(|file| file.skipped)
                    .collect::<Vec<_>>(),
                skipped
            );
            assert_eq!(
                prepare(&jobs, "lib", input).unwrap().files[0].file_name,
                expected
            );
            assert_eq!(std::fs::read(root.join("IMG.CR3")).unwrap(), b"original");
            if let Some(data) = existing_sidecar {
                assert_eq!(std::fs::read(root.join("IMG.xmp")).unwrap(), data);
            }
        }
    }
    #[test]
    fn deduplication_rejects_duplicate_suffixes_before_assigning_existing_file() {
        use sha2::{Digest, Sha256};
        let dir = tempfile::tempdir().unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), dir.path()).unwrap();
        jobs.add_folder("lib", ".").unwrap();
        std::fs::write(dir.path().join("IMG.CR3"), b"original").unwrap();
        let files = ["card/IMG.CR3", "card/img.cr3"]
            .iter()
            .map(|name| InputFile {
                id: uuid::Uuid::new_v4().to_string(),
                relative_path: (*name).into(),
                size: 8,
                sha256: Some(format!("{:x}", Sha256::digest(b"original"))),
            })
            .collect();
        let error = prepare(
            &jobs,
            "lib",
            Prepare {
                id: uuid::Uuid::new_v4().to_string(),
                target_path: jobs.root().to_string_lossy().into(),
                deduplicate: true,
                preserve_structure: false,
                files,
            },
        )
        .unwrap_err();
        assert!(
            error.to_string().contains("duplicate filenames"),
            "{error:#}"
        );
    }
}
