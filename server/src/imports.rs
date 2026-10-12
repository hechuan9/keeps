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
    extract::{DefaultBodyLimit, Path, Query, State},
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
    #[serde(default)]
    matched: bool,
    #[serde(default)]
    publication_pending: bool,
    #[serde(default)]
    digest_stamp: Option<DigestStamp>,
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
    #[serde(default)]
    finish_requested: bool,
    #[serde(default)]
    finish_error: Option<String>,
    job_id: Option<String>,
    #[serde(default)]
    group_jobs: BTreeMap<String, String>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
struct DigestStamp {
    size: u64,
    device: u64,
    inode: u64,
    mtime: i64,
    mtime_ns: i64,
    ctime: i64,
    ctime_ns: i64,
}
impl DigestStamp {
    fn read(path: &FsPath) -> Result<Self> {
        use std::os::unix::fs::MetadataExt;
        let metadata = std::fs::symlink_metadata(path)?;
        ensure!(metadata.is_file(), "digest source is not a regular file");
        Ok(Self {
            size: metadata.len(),
            device: metadata.dev(),
            inode: metadata.ino(),
            mtime: metadata.mtime(),
            mtime_ns: metadata.mtime_nsec(),
            ctime: metadata.ctime(),
            ctime_ns: metadata.ctime_nsec(),
        })
    }
}
fn save_digest(
    db: &rusqlite::Connection,
    library: &str,
    path: &FsPath,
    hash: &str,
    stamp: &DigestStamp,
) -> Result<()> {
    db.execute("INSERT INTO import_file_digests(library_id,path,sha256,stamp) VALUES(?,?,?,?) ON CONFLICT(library_id,path) DO UPDATE SET sha256=excluded.sha256,stamp=excluded.stamp",
        params![library,path.to_string_lossy(),hash,serde_json::to_string(stamp)?])?;
    Ok(())
}
// Ctime and inode also invalidate edits that preserve file size and modification time.
pub(crate) fn file_digest(jobs: &Jobs, library: &str, path: &FsPath) -> Result<String> {
    let before = DigestStamp::read(path)?;
    let cached: Option<(String, String)> = jobs
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT sha256,stamp FROM import_file_digests WHERE library_id=? AND path=?",
            params![library, path.to_string_lossy()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    if let Some((hash, stamp)) = cached
        && serde_json::from_str::<DigestStamp>(&stamp)? == before
    {
        return Ok(hash);
    }
    let hash = crate::media::sha256_file(path)?;
    ensure!(
        DigestStamp::read(path)? == before,
        "file changed while computing content digest"
    );
    save_digest(&jobs.db.lock().unwrap(), library, path, &hash, &before)?;
    Ok(hash)
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
    let db = jobs.db.lock().unwrap();
    if let Some(batch) = existing_batch(&db, library, &input, &destination)? {
        return Ok(batch);
    }
    let reservations = reserved_batches(&db)?;
    drop(db);
    let mut files = Vec::new();
    for (parent, groups) in directories {
        let directory = destination.join(&parent);
        for mut file in plan_files(
            &reservations,
            &directory,
            &groups,
            false,
            &BTreeMap::new(),
            None,
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
        finish_requested: false,
        finish_error: None,
        job_id: None,
        group_jobs: BTreeMap::new(),
    };
    save(&jobs.db.lock().unwrap(), library, &batch)?;
    Ok(batch)
}
type SourceGroups = BTreeMap<String, Vec<(InputFile, String, String)>>;
fn reserved_batches(db: &rusqlite::Connection) -> Result<Vec<Batch>> {
    let mut stmt = db.prepare("SELECT manifest FROM imports")?;
    stmt.query_map([], |row| row.get::<_, String>(0))?
        .map(|raw| Ok(serde_json::from_str(&raw?)?))
        .collect()
}
fn plan_files(
    batches: &[Batch],
    destination: &FsPath,
    groups: &SourceGroups,
    deduplicate: bool,
    existing_groups: &ExistingGroups,
    matching_batch: Option<&str>,
) -> Result<Vec<File>> {
    let mut reserved: HashSet<String> = if destination.exists() {
        std::fs::read_dir(destination)?
            .map(|e| e.map(|e| e.file_name().to_string_lossy().to_lowercase()))
            .collect::<std::io::Result<_>>()?
    } else {
        HashSet::new()
    };
    let source_ids: HashSet<_> = groups
        .values()
        .flatten()
        .map(|(file, _, _)| file.id.as_str())
        .collect();
    let mut pending_names = HashSet::new();
    for batch in batches {
        for file in &batch.files {
            if matching_batch == Some(batch.id.as_str())
                && source_ids.contains(file.input.id.as_str())
            {
                continue;
            }
            let path = FsPath::new(&batch.target_path).join(&file.file_name);
            if path.parent() == Some(destination) {
                let name = path
                    .file_name()
                    .context("reserved filename")?
                    .to_string_lossy()
                    .to_lowercase();
                if !file.published {
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
                destination,
                entries,
                &suffixes,
                &pending_names,
                &reserved,
                existing_groups,
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
                        matched: true,
                        publication_pending: !skipped,
                        digest_stamp: None,
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
                    matched: false,
                    publication_pending: true,
                    digest_stamp: None,
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
                if Some(crate::media::sha256_file(&path)?) != input.sha256 {
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
            "/libraries/{library}/imports/{batch}/files/{file}/match",
            post(match_handler),
        )
        .route(
            "/libraries/{library}/imports/{batch}/files/{file}",
            put(upload).layer(DefaultBodyLimit::disable()),
        )
        .route(
            "/libraries/{library}/imports/{batch}/finish",
            post(finish).get(finish_status),
        )
        .route(
            "/libraries/{library}/imports/{batch}/heartbeat",
            post(compute_heartbeat),
        )
}
async fn prepare_handler(
    State(state): State<Arc<AppState>>,
    Path(library): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    let batch = tokio::task::spawn_blocking(move || -> Result<Batch> {
        let _guard = state.jobs.import_mutation.lock().unwrap();
        let input: Prepare = serde_json::from_value(body.clone())?;
        let batch = prepare(&state.jobs, &library, input)?;
        if let Some(worker) = body["workerID"].as_str() {
            reserve_compute(&state, &library, &batch, worker)?;
        }
        resume_pipeline(&state, &library, &batch.id)?;
        load(&state.jobs.db.lock().unwrap(), &library, &batch.id)
    })
    .await
    .map_err(anyhow::Error::from)??;
    Ok(Json(
        serde_json::to_value(batch).map_err(anyhow::Error::from)?,
    ))
}
#[derive(Deserialize)]
struct MatchGroup {
    files: Vec<InputFile>,
}

// Match one complete photo, keeping its original and sidecars together.
fn match_group(
    jobs: &Jobs,
    library: &str,
    id: &str,
    file_id: &str,
    mut inputs: Vec<InputFile>,
) -> Result<Batch> {
    let _directory_guard = jobs.directory_mutation.read().unwrap();
    crate::directory_move::ensure_reconciled(jobs)?;
    let mut batch = load(&jobs.db.lock().unwrap(), library, id)?;
    ensure!(
        batch.deduplicate,
        invalid("deduplication is not enabled for this batch")
    );
    let file_id = uuid(file_id)?;
    let selected = batch
        .files
        .iter()
        .find(|file| file.input.id == file_id)
        .ok_or_else(|| invalid("file not found"))?;
    let key = group(&selected.input)?.0;
    let indices = batch
        .files
        .iter()
        .enumerate()
        .filter_map(|(index, file)| {
            (group(&file.input)
                .map(|value| value.0 == key)
                .unwrap_or(false))
            .then_some(index)
        })
        .collect::<Vec<_>>();
    for input in &mut inputs {
        input.id = uuid(&input.id)?;
    }
    ensure!(
        inputs.len() == indices.len(),
        invalid("match requires the complete photo group")
    );
    let mut ids = HashSet::new();
    for input in &inputs {
        let original = indices
            .iter()
            .map(|index| &batch.files[*index])
            .find(|file| file.input.id == input.id)
            .ok_or_else(|| invalid("file belongs to another photo group"))?;
        ensure!(
            ids.insert(&input.id)
                && input.relative_path == original.input.relative_path
                && input.size == original.input.size,
            conflict("match manifest differs from prepared source")
        );
        ensure!(
            input
                .sha256
                .as_ref()
                .is_some_and(|digest| digest.len() == 64
                    && digest
                        .bytes()
                        .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())),
            invalid("match requires SHA256 for every file")
        );
        ensure!(
            original
                .input
                .sha256
                .as_ref()
                .is_none_or(|digest| Some(digest) == input.sha256.as_ref()),
            conflict("source digest changed")
        );
        if original.matched {
            ensure!(
                original.received_sha256 == input.sha256,
                conflict("source digest changed after matching")
            );
        }
    }
    if indices
        .iter()
        .all(|index| batch.files[*index].matched || batch.files[*index].uploaded)
    {
        batch.files = indices
            .iter()
            .map(|index| batch.files[*index].clone())
            .collect();
        return Ok(batch);
    }
    ensure!(
        indices.iter().all(|index| !batch.files[*index].uploaded),
        conflict("cannot rematch a partially uploaded photo")
    );
    let destination = target(jobs, library, &batch.target_path)?;
    let parent = if batch.preserve_structure {
        FsPath::new(&inputs[0].relative_path)
            .parent()
            .unwrap_or(FsPath::new(""))
    } else {
        FsPath::new("")
    };
    let directory = import_directory(&destination, parent, false)?;
    let mut entries = Vec::new();
    for input in &inputs {
        let (_, stem, suffix) = group(input)?;
        entries.push((input.clone(), stem, suffix));
    }
    let groups = BTreeMap::from([(key, entries)]);
    let existing = if directory.exists() {
        existing_groups(&directory)?
    } else {
        BTreeMap::new()
    };
    let reservations = reserved_batches(&jobs.db.lock().unwrap())?;
    let planned = plan_files(
        &reservations,
        &directory,
        &groups,
        true,
        &existing,
        Some(&batch.id),
    )?;
    let db = jobs.db.lock().unwrap();
    // Uploads of other groups may have advanced while destination files were read.
    batch = load(&db, library, id)?;
    let mut result = Vec::new();
    for mut file in planned {
        let index = batch
            .files
            .iter()
            .position(|entry| entry.input.id == file.input.id)
            .context("import file disappeared")?;
        file.received_sha256 = file.input.sha256.clone();
        file.input = batch.files[index].input.clone();
        file.file_name = parent.join(&file.file_name).to_string_lossy().into_owned();
        file.matched = true;
        batch.files[index] = file.clone();
        result.push(file);
    }
    save(&db, library, &batch)?;
    batch.files = result;
    Ok(batch)
}

async fn match_handler(
    State(state): State<Arc<AppState>>,
    Path((library, id, file)): Path<(String, String, String)>,
    Json(body): Json<MatchGroup>,
) -> Result<Json<Value>, ApiError> {
    let batch = tokio::task::spawn_blocking(move || -> Result<Batch> {
        let _guard = state.jobs.import_mutation.lock().unwrap();
        let batch = match_group(&state.jobs, &library, &id, &file, body.files)?;
        let worker: Option<String> = state.store.lock()?.query_row(
            "SELECT worker_id FROM import_compute_leases WHERE library_id=? AND batch_id=? LIMIT 1",
            params![library, batch.id], |row| row.get(0)).optional()?;
        if let Some(worker) = worker {
            reserve_compute(&state, &library, &batch, &worker)?;
        }
        Ok(batch)
    })
    .await
    .map_err(anyhow::Error::from)??;
    Ok(Json(
        serde_json::to_value(batch).map_err(anyhow::Error::from)?,
    ))
}

fn resume_pipeline(state: &AppState, library: &str, id: &str) -> Result<()> {
    let batch = load(&state.jobs.db.lock().unwrap(), library, id)?;
    let mut replacements = BTreeMap::new();
    for (group, job_id) in &batch.group_jobs {
        if let Some(job) = state
            .jobs
            .job(job_id)?
            .filter(|job| job.status == "failed" || job.status == "cancelled" || job.failed > 0)
        {
            let retry = state
                .jobs
                .enqueue_manual_file(&job.folder_id, FsPath::new(&job.path))?;
            replacements.insert(group.clone(), retry.id);
        }
    }
    let paths: Vec<_> = batch
        .files
        .iter()
        .map(|f| {
            FsPath::new(&batch.target_path)
                .join(&f.file_name)
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    state.store.lock()?.execute("UPDATE media_cache SET status=CASE WHEN status='failed' THEN 'pending' ELSE status END,attempts=CASE WHEN status='failed' THEN 0 ELSE attempts END,available_at=0,last_error=NULL,browse_attempts=0,browse_available_at=0,browse_last_error=NULL WHERE library_id=?1 AND asset_id IN (SELECT p.asset_id FROM json_each(?2) wanted CROSS JOIN catalog_paths p ON p.library_id=?1 AND p.path=wanted.value) AND (status='failed' OR browse_attempts>=4)",params![library,serde_json::to_string(&paths)?])?;
    let db = state.jobs.db.lock().unwrap();
    let mut current = load(&db, library, id)?;
    if let Some((group, _)) = batch
        .group_jobs
        .iter()
        .find(|(_, job)| Some(*job) == current.job_id.as_ref())
        && let Some(retry) = replacements.get(group)
    {
        current.job_id = Some(retry.clone());
    }
    current.group_jobs.extend(replacements);
    current.finish_error = None;
    save(&db, library, &current)?;
    Ok(())
}

fn reserve_compute(state: &AppState, library: &str, batch: &Batch, worker: &str) -> Result<()> {
    ensure!(
        !worker.is_empty() && worker.len() <= 128,
        invalid("invalid workerID")
    );
    let mut db = state.store.lock()?;
    let tx = db.transaction()?;
    for file in &batch.files {
        let path = FsPath::new(&batch.target_path)
            .join(&file.file_name)
            .to_string_lossy()
            .into_owned();
        let owner: Option<String> = tx.query_row("SELECT worker_id FROM import_compute_leases WHERE library_id=? AND batch_id=? AND path=?",params![library,batch.id,path], |r|r.get(0)).optional()?;
        ensure!(
            owner.as_deref().is_none_or(|owner| owner == worker),
            conflict("import compute owner changed")
        );
        tx.execute("INSERT INTO import_compute_leases VALUES(?,?,?,?,unixepoch()+3600) ON CONFLICT(library_id,batch_id,path) DO UPDATE SET expires_at=excluded.expires_at",params![library,batch.id,path,worker])?;
    }
    tx.commit()?;
    Ok(())
}
async fn compute_heartbeat(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(
        tokio::task::spawn_blocking(move || -> Result<Value> {
            let batch = load(&state.jobs.db.lock().unwrap(), &library, &id)?;
            let worker = body["workerID"]
                .as_str()
                .ok_or_else(|| invalid("workerID required"))?;
            reserve_compute(&state, &library, &batch, worker)?;
            Ok(json!({"leaseSeconds":3600}))
        })
        .await
        .map_err(anyhow::Error::from)??,
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
        ensure!(
            !batch.deduplicate || file.matched || file.uploaded || file.input.sha256.is_some(),
            conflict("match the photo group before uploading")
        );
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
            .received_sha256
            .as_ref()
            .or(file.input.sha256.as_ref())
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
        drop(temporary);
        item.digest_stamp = Some(DigestStamp::read(&output)?);
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
#[derive(Default, Deserialize)]
struct FinishQuery {
    #[serde(default, rename = "async")]
    asynchronous: bool,
}

fn status(jobs: &Jobs, library: &str, id: &str) -> Result<Value> {
    let batch = load(&jobs.db.lock().unwrap(), library, id)?;
    let status = if batch.finished {
        "finished"
    } else if batch.finish_error.is_some() {
        "failed"
    } else if batch.finish_requested {
        "publishing"
    } else {
        "uploading"
    };
    let job = batch
        .job_id
        .as_deref()
        .map(|id| jobs.job(id))
        .transpose()?
        .flatten();
    Ok(json!({"id": batch.id, "status": status,
        "completedFiles": batch.files.iter().filter(|file| file.published).count(),
        "totalFiles": batch.files.len(), "error": batch.finish_error, "job": job}))
}

fn pipeline_status(state: &AppState, library: &str, id: &str) -> Result<Value> {
    let mut response = status(&state.jobs, library, id)?;
    let batch = load(&state.jobs.db.lock().unwrap(), library, id)?;
    let db = state.store.read()?;
    let paths: Vec<String> = batch
        .files
        .iter()
        .filter(|f| {
            FsPath::new(&f.file_name)
                .extension()
                .is_none_or(|e| !e.eq_ignore_ascii_case("xmp"))
        })
        .map(|f| {
            FsPath::new(&batch.target_path)
                .join(&f.file_name)
                .to_string_lossy()
                .into_owned()
        })
        .collect();
    let mut photo_groups: BTreeMap<_, Vec<&String>> = BTreeMap::new();
    for path in &paths {
        let file = FsPath::new(path);
        photo_groups
            .entry((file.parent(), destination_stem(path)))
            .or_default()
            .push(path);
    }
    let mut ready_assets = HashSet::new();
    let mut media_error: Option<String> = None;
    let paths_json = serde_json::to_string(&paths)?;
    let indexed_assets = db.prepare("SELECT p.path,p.asset_id FROM json_each(?2) wanted CROSS JOIN catalog_paths p ON p.library_id=?1 AND p.path=wanted.value")?.query_map(params![library,paths_json],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?)))?.collect::<rusqlite::Result<BTreeMap<_,_>>>()?;
    let indexed = indexed_assets.len();
    let assets: HashSet<_> = indexed_assets.values().collect();
    for asset in &assets {
        let media: Option<(String,Option<String>,bool)> = db.query_row("SELECT c.status,coalesce(CASE WHEN c.status='failed' THEN c.last_error END,CASE WHEN c.browse_attempts>=4 THEN c.browse_last_error END),coalesce(c.status='ready' AND c.spec=?3 AND c.source_hash=coalesce(d.content_hash,a.content_hash) AND c.thumbnail IS NOT NULL AND c.browse_thumbnail IS NOT NULL AND json_extract(c.browse_thumbnail,'$.sourceThumbnailVersion')=json_extract(c.thumbnail,'$.version') AND json_extract(c.browse_thumbnail,'$.spec')=?4,0) FROM media_cache c JOIN catalog_assets a ON a.library_id=c.library_id AND a.id=c.asset_id LEFT JOIN catalog_defaults d ON d.library_id=a.library_id AND d.asset_id=a.id WHERE c.library_id=?1 AND c.asset_id=?2",params![library,asset,crate::cache_pipeline::spec()?,crate::browse_cache::SPEC],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
        if let Some((status, error, complete)) = media {
            if complete {
                ready_assets.insert(*asset);
            }
            if status == "failed" || error.is_some() {
                media_error = error;
            }
        }
    }
    drop(db);
    response["publicationComplete"] = json!(batch.finished);
    response["indexedFiles"] = json!(
        photo_groups
            .values()
            .filter(|group| group.iter().all(|path| indexed_assets.contains_key(*path)))
            .count()
    );
    response["indexTotal"] = json!(photo_groups.len());
    response["thumbnailTotal"] = json!(photo_groups.len());
    response["thumbnailCompleted"] = json!(
        photo_groups
            .values()
            .filter(|group| group.iter().all(|path| indexed_assets
                .get(*path)
                .is_some_and(|asset| ready_assets.contains(asset))))
            .count()
    );
    let mut job_ids: HashSet<_> = batch.group_jobs.values().cloned().collect();
    job_ids.extend(batch.job_id.clone());
    let jobs = job_ids
        .iter()
        .map(|id| state.jobs.job(id))
        .collect::<Result<Vec<_>>>()?;
    if let Some(job) = jobs
        .iter()
        .flatten()
        .find(|j| j.status == "failed" || j.status == "cancelled" || j.failed > 0)
    {
        response["status"] = json!("failed");
        response["error"] = json!(job.error.as_deref().unwrap_or("index task cancelled"));

        return Ok(response);
    }
    if let Some(error) = &media_error {
        response["status"] = json!("failed");
        response["error"] = json!(error);
        return Ok(response);
    }
    if batch.finished {
        if indexed < paths.len()
            || jobs
                .iter()
                .any(|j| j.as_ref().is_none_or(|j| j.status != "completed"))
        {
            response["status"] = json!("indexing");
        } else if let Some(error) = media_error {
            response["status"] = json!("failed");
            response["error"] = json!(error);
        } else if ready_assets.len() < assets.len() {
            response["status"] = json!("thumbnails");
        } else {
            response["status"] = json!("finished");
        }
    }
    Ok(response)
}
async fn finish_status(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    Ok(Json(
        tokio::task::spawn_blocking(move || pipeline_status(&state, &library, &id))
            .await
            .map_err(anyhow::Error::from)??,
    ))
}

async fn finish(
    State(state): State<Arc<AppState>>,
    Path((library, id)): Path<(String, String)>,
    Query(query): Query<FinishQuery>,
) -> Result<Json<Value>, ApiError> {
    let retry_state = state.clone();
    let retry_library = library.clone();
    let retry_id = id.clone();
    tokio::task::spawn_blocking(move || -> Result<()> {
        if pipeline_status(&retry_state,&retry_library,&retry_id)?["status"] != "failed" { return Ok(()); }
        let mut batch = load(&retry_state.jobs.db.lock().unwrap(),&retry_library,&retry_id)?;
        if !batch.finished { return Ok(()); }
        let destination = FsPath::new(&batch.target_path);
        let folder = retry_state.jobs.folders()?.into_iter().filter(|f|f.active && f.library_id==retry_library && destination.starts_with(&f.path)).max_by_key(|f|f.path.len()).context("import folder no longer tracked")?;
        let job = if batch.preserve_structure { retry_state.jobs.enqueue_reconcile_scope(&folder.id,destination)? } else { retry_state.jobs.enqueue_manual_directory(&folder.id,destination)? };
        batch.job_id=Some(job.id);
        batch.group_jobs.clear();
        save(&retry_state.jobs.db.lock().unwrap(),&retry_library,&batch)?;
        let paths: Vec<_> = batch.files.iter().map(|f|destination.join(&f.file_name).to_string_lossy().into_owned()).collect();
        retry_state.store.lock()?.execute("UPDATE media_cache SET status=CASE WHEN status='failed' THEN 'pending' ELSE status END,attempts=CASE WHEN status='failed' THEN 0 ELSE attempts END,available_at=0,last_error=NULL,browse_attempts=0,browse_available_at=0,browse_last_error=NULL WHERE library_id=?1 AND asset_id IN (SELECT p.asset_id FROM json_each(?2) wanted CROSS JOIN catalog_paths p ON p.library_id=?1 AND p.path=wanted.value)",params![retry_library,serde_json::to_string(&paths)?])?;
        Ok(())
    }).await.map_err(anyhow::Error::from)??;
    let (jobs, lib, batch_id) = (state.jobs.clone(), library.clone(), id.clone());
    tokio::task::spawn_blocking(move || -> Result<()> {
        let db = jobs.db.lock().unwrap();
        let mut batch = load(&db, &lib, &batch_id)?;
        ensure!(
            batch.files.iter().all(|file| file.uploaded),
            conflict("upload all files before finishing import")
        );
        if !batch.finished && (!batch.finish_requested || batch.finish_error.is_some()) {
            batch.finish_requested = true;
            batch.finish_error = None;
            save(&db, &lib, &batch)?;
        }
        Ok(())
    })
    .await
    .map_err(anyhow::Error::from)??;
    if query.asynchronous {
        return finish_status(State(state), Path((library, id))).await;
    }
    Ok(Json(
        tokio::task::spawn_blocking(move || {
            let _guard = state.jobs.import_mutation.lock().unwrap();
            execute_finish(&state.jobs, &library, &id, None)
        })
        .await
        .map_err(anyhow::Error::from)??,
    ))
}

pub fn run(jobs: Arc<Jobs>, stop: Arc<std::sync::atomic::AtomicBool>) -> Result<()> {
    use std::sync::atomic::Ordering;
    while !stop.load(Ordering::Relaxed) {
        let pending = {
            let db = jobs.db.lock().unwrap();
            let mut query = db.prepare("SELECT library_id,id FROM imports WHERE json_extract(manifest,'$.finished')=0 AND EXISTS(SELECT 1 FROM json_each(manifest,'$.files') WHERE json_extract(value,'$.uploaded')=1) AND json_extract(manifest,'$.finishError') IS NULL")?;
            query
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        for (library, id) in pending {
            if stop.load(Ordering::Relaxed) {
                return Ok(());
            }
            let _guard = jobs.import_mutation.lock().unwrap();
            let current = load(&jobs.db.lock().unwrap(), &library, &id)?;
            if current.finished || current.finish_error.is_some() {
                continue;
            }
            if let Err(error) = execute_finish(&jobs, &library, &id, Some(&stop)) {
                tracing::error!(batch = %id, error = %format!("{error:#}"), "Import publishing failed");
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
    Ok(())
}

fn execute_finish(
    jobs: &Jobs,
    library: &str,
    id: &str,
    stop: Option<&std::sync::atomic::AtomicBool>,
) -> Result<Value> {
    let result = finish_batch(jobs, library, id, stop);
    if let Err(error) = &result {
        let db = jobs.db.lock().unwrap();
        let mut batch = load(&db, library, id)?;
        batch.finish_error = Some(format!("{error:#}"));
        save(&db, library, &batch).with_context(|| format!("persist import failure: {error:#}"))?;
    }
    result
}

fn publish_checkpoint(
    jobs: &Jobs,
    library: &str,
    batch: &Batch,
    staged: &mut Vec<(std::path::PathBuf, std::path::PathBuf)>,
) -> Result<()> {
    if staged.is_empty() {
        return Ok(());
    }
    // Persist directory entries before recording publication, amortizing each
    // directory flush across the checkpoint rather than flushing every file.
    let parents: HashSet<_> = staged.iter().map(|(_, parent)| parent).collect();
    for parent in parents {
        std::fs::File::open(parent)?.sync_all()?;
    }
    let db = jobs.db.lock().unwrap();
    let mut latest = load(&db, library, &batch.id)?;
    for file in &mut latest.files {
        if batch
            .files
            .iter()
            .any(|saved| saved.input.id == file.input.id && saved.published)
        {
            let saved = batch
                .files
                .iter()
                .find(|saved| saved.input.id == file.input.id)
                .unwrap();
            file.published = true;
            file.digest_stamp = saved.digest_stamp.clone();
        }
    }
    save(&db, library, &latest)?;
    drop(db);
    // Retain the staging inode until the publication checkpoint is durable, so a
    // restart can distinguish our own hard link from an unrelated late collision.
    let mut files = Vec::new();
    for (path, _) in staged.iter() {
        let file = latest
            .files
            .iter()
            .find(|file| {
                staging(FsPath::new(&latest.target_path), &latest.id, &file.input.id) == *path
            })
            .context("publication file missing")?;
        files.push(file);
    }
    finalize_publications(jobs, library, &latest, &files)?;
    staged.clear();
    Ok(())
}

fn finalize_publications(jobs: &Jobs, library: &str, batch: &Batch, files: &[&File]) -> Result<()> {
    let mut receipts = Vec::new();
    for file in files {
        let destination = FsPath::new(&batch.target_path).join(&file.file_name);
        let staged = staging(FsPath::new(&batch.target_path), &batch.id, &file.input.id);
        let unchanged = file.publication_pending
            && file.digest_stamp.as_ref() == Some(&DigestStamp::read(&destination)?);
        if staged.try_exists()? {
            std::fs::remove_file(staged).context("remove completed import staging link")?;
        }
        receipts.push((
            file,
            destination.clone(),
            unchanged,
            DigestStamp::read(&destination)?,
        ));
    }
    let mut db = jobs.db.lock().unwrap();
    let tx = db.transaction()?;
    let mut latest = load(&tx, library, &batch.id)?;
    for (file, destination, unchanged, stamp) in receipts {
        if unchanged && let Some(hash) = &file.received_sha256 {
            save_digest(&tx, library, &destination, hash, &stamp)?;
        }
        latest
            .files
            .iter_mut()
            .find(|entry| entry.input.id == file.input.id)
            .context("import file missing")?
            .publication_pending = false;
    }
    save(&tx, library, &latest)?;
    tx.commit()?;
    Ok(())
}

fn finish_batch(
    jobs: &Jobs,
    library: &str,
    id: &str,
    stop: Option<&std::sync::atomic::AtomicBool>,
) -> Result<Value> {
    let _directory_guard = jobs.directory_mutation.read().unwrap();
    crate::directory_move::ensure_reconciled(jobs)?;
    let batch = load(&jobs.db.lock().unwrap(), library, id)?;
    if let Some(job_id) = batch.job_id {
        return Ok(json!({"job":jobs.job(&job_id)?}));
    }
    let destination = target(jobs, library, &batch.target_path)?;
    let mut groups: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for (index, file) in batch.files.iter().enumerate() {
        let path = FsPath::new(&file.file_name);
        let key = format!(
            "{}/{}",
            path.parent().context("import parent")?.display(),
            destination_stem(&file.file_name)
        );
        groups.entry(key).or_default().push(index);
    }
    let eligible: HashSet<usize> = groups
        .iter()
        .filter(|(key, indices)| {
            !batch.group_jobs.contains_key(*key) && indices.iter().all(|i| batch.files[*i].uploaded)
        })
        .flat_map(|(_, indices)| indices)
        .copied()
        .collect();
    let folder = jobs
        .folders()?
        .into_iter()
        .find(|f| f.active && f.library_id == library && destination.starts_with(&f.path))
        .context("tracked import folder disappeared")?;
    for (_, item) in batch
        .files
        .iter()
        .enumerate()
        .filter(|(i, _)| eligible.contains(i))
    {
        import_directory(
            &destination,
            FsPath::new(&item.file_name)
                .parent()
                .context("import parent")?,
            false,
        )?;
    }
    for item in batch
        .files
        .iter()
        .enumerate()
        .filter(|(i, item)| eligible.contains(i) && item.skipped)
        .map(|(_, item)| item)
    {
        let path = destination.join(&item.file_name);
        let metadata = std::fs::symlink_metadata(&path)
            .map_err(|error| conflict(format!("deduplicated file is unavailable: {error:#}")))?;
        ensure!(
            metadata.is_file()
                && metadata.len() == item.input.size
                && Some(crate::media::sha256_file(&path)?) == item.received_sha256,
            conflict("deduplicated file changed before import finished")
        );
    }
    {
        let mut current = load(&jobs.db.lock().unwrap(), library, id)?;
        // Discover a late collision before exposing any sidecar from this batch.
        for item in current
            .files
            .iter()
            .enumerate()
            .filter(|(i, item)| eligible.contains(i) && !item.published)
            .map(|(_, item)| item)
        {
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
        let mut order: Vec<usize> = eligible.iter().copied().collect();
        order.sort_by_key(|i| {
            !current.files[*i]
                .file_name
                .to_ascii_lowercase()
                .ends_with(".xmp")
        });
        // Sidecars must exist before any original becomes visible to the scanner.
        let mut checkpoint = Vec::new();
        for index in order {
            if stop.is_some_and(|stop| stop.load(std::sync::atomic::Ordering::Relaxed)) {
                publish_checkpoint(jobs, library, &current, &mut checkpoint)?;
                return Ok(json!({"status": "publishing"}));
            }
            if current.files[index].published {
                if current.files[index].publication_pending {
                    finalize_publications(jobs, library, &current, &[&current.files[index]])?;
                }
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
            let verified = match &item.digest_stamp {
                Some(stamp) => DigestStamp::read(&staged)? == *stamp,
                None => false,
            };
            match std::fs::hard_link(&staged, &output) {
                Ok(()) => (),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    ensure!(
                        same_file(&staged, &output)?,
                        conflict("destination appeared after prepare; existing file was preserved")
                    );
                }
                Err(e) => {
                    return Err(e).context("publish imported original without overwriting");
                }
            }
            current.files[index].digest_stamp = if verified {
                Some(DigestStamp::read(&output)?)
            } else {
                None
            };
            current.files[index].published = true;
            checkpoint.push((staged, parent));
            if checkpoint.len() == 32 {
                publish_checkpoint(jobs, library, &current, &mut checkpoint)?;
            }
        }
        publish_checkpoint(jobs, library, &current, &mut checkpoint)?;
    }
    for (key, indices) in groups {
        if !indices.iter().all(|i| eligible.contains(i)) || batch.group_jobs.contains_key(&key) {
            continue;
        }
        let original = indices
            .iter()
            .map(|i| &batch.files[*i])
            .find(|f| !f.file_name.to_ascii_lowercase().ends_with(".xmp"))
            .or_else(|| indices.first().map(|i| &batch.files[*i]));
        if let Some(original) = original {
            let job =
                jobs.enqueue_manual_file(&folder.id, &destination.join(&original.file_name))?;
            let db = jobs.db.lock().unwrap();
            let mut current = load(&db, library, id)?;
            current.group_jobs.insert(key, job.id);
            save(&db, library, &current)?;
        }
    }
    let db = jobs.db.lock().unwrap();
    let mut batch = load(&db, library, id)?;
    if batch.finish_requested && batch.files.iter().all(|f| f.published) {
        batch.finished = true;
        batch.job_id = batch.group_jobs.values().next_back().cloned();
        save(&db, library, &batch)?;
    }
    let job_id = batch.job_id.clone();
    drop(db);
    Ok(
        json!({"status": if batch.finished { "finished" } else { "uploading" }, "job":job_id.map(|id|jobs.job(&id)).transpose()?.flatten()}),
    )
}

fn staging(destination: &FsPath, batch: &str, file: &str) -> std::path::PathBuf {
    destination.join(format!(".keeps-import-{batch}-{file}"))
}

pub(crate) fn group_pending_publication(
    jobs: &Jobs,
    library: &str,
    paths: &[std::path::PathBuf],
) -> Result<bool> {
    let manifests = {
        let db = jobs.db.lock().unwrap();
        let mut query = db.prepare("SELECT manifest FROM imports WHERE library_id=? AND json_extract(manifest,'$.finished')=0")?;
        query
            .query_map([library], |row| row.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    let groups: HashSet<_> = paths
        .iter()
        .filter_map(|path| {
            Some((
                path.parent()?.to_owned(),
                destination_stem(path.file_name()?.to_str()?),
            ))
        })
        .collect();
    for manifest in manifests {
        let batch: Batch =
            serde_json::from_str(&manifest).context("read pending import manifest")?;
        for file in batch
            .files
            .iter()
            .filter(|file| !file.published || file.publication_pending)
        {
            let path = FsPath::new(&batch.target_path).join(&file.file_name);
            if groups.contains(&(
                path.parent().context("import parent")?.to_owned(),
                destination_stem(&file.file_name),
            )) {
                return Ok(true);
            }
        }
    }
    Ok(false)
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
    fn digest_receipt_invalidates_same_size_edit_with_preserved_mtime() {
        let dir = tempfile::tempdir().unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), dir.path()).unwrap();
        let path = dir.path().join("image.CR3");
        std::fs::write(&path, b"original").unwrap();
        let original_time = std::fs::metadata(&path).unwrap().modified().unwrap();
        let first = file_digest(&jobs, "lib", &path).unwrap();
        assert_eq!(file_digest(&jobs, "lib", &path).unwrap(), first);
        std::thread::sleep(std::time::Duration::from_millis(10));
        std::fs::write(&path, b"modified").unwrap();
        std::fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_modified(original_time))
            .unwrap();
        let second = file_digest(&jobs, "lib", &path).unwrap();
        assert_ne!(first, second);
        assert_eq!(second, crate::media::sha256_file(&path).unwrap());
    }

    #[test]
    fn publication_preserves_verified_upload_digest_after_staging_unlink() {
        let dir = tempfile::tempdir().unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), dir.path()).unwrap();
        jobs.add_folder("lib", ".").unwrap();
        let mut batch = prepare(
            &jobs,
            "lib",
            structure_input(jobs.root(), &["image.CR3"], false),
        )
        .unwrap();
        let staged = staging(jobs.root(), &batch.id, &batch.files[0].input.id);
        std::fs::write(&staged, b"original").unwrap();
        let hash = crate::media::sha256_file(&staged).unwrap();
        batch.files[0].uploaded = true;
        batch.files[0].received_sha256 = Some(hash.clone());
        batch.files[0].digest_stamp = Some(DigestStamp::read(&staged).unwrap());
        save(&jobs.db.lock().unwrap(), "lib", &batch).unwrap();
        finish_batch(&jobs, "lib", &batch.id, None).unwrap();
        let destination = jobs.root().join("image.CR3");
        assert!(!staged.exists());
        let stamp: String = jobs
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT stamp FROM import_file_digests WHERE library_id='lib' AND path=?",
                [destination.to_str().unwrap()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_str::<DigestStamp>(&stamp).unwrap(),
            DigestStamp::read(&destination).unwrap()
        );
        assert_eq!(file_digest(&jobs, "lib", &destination).unwrap(), hash);
        assert!(!group_pending_publication(&jobs, "lib", &[destination]).unwrap());
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
        assert!(
            batch
                .files
                .iter()
                .all(|file| !file.skipped && !file.matched)
        );
        match_group(
            &jobs,
            "lib",
            &batch.id,
            &input.files[0].id,
            input.files[..2].to_vec(),
        )
        .unwrap();
        match_group(
            &jobs,
            "lib",
            &batch.id,
            &input.files[2].id,
            input.files[2..].to_vec(),
        )
        .unwrap();
        let batch = load(&jobs.db.lock().unwrap(), "lib", &batch.id).unwrap();
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

    #[test]
    fn pipeline_completion_waits_for_index_and_both_thumbnail_sizes() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let originals = dir.path().join("photos");
        std::fs::create_dir(&originals)?;
        let keeps = dir.path().join("keeps");
        let state = AppState {
            previews: Arc::new(crate::previews::PreviewStorage::new(
                &keeps,
                Some(&originals),
                "http://localhost",
                "test",
            )?),
            store: Arc::new(crate::store::Store::open(
                &keeps.join("db/control.sqlite"),
                true,
            )?),
            jobs: Arc::new(Jobs::open(&keeps.join("db/jobs.sqlite"), &originals)?),
            access_token: String::new(),
            library_id: "lib".into(),
            original_root_names: Default::default(),
        };
        state.jobs.add_folder("lib", ".")?;
        let mut batch = prepare(
            &state.jobs,
            "lib",
            structure_input(
                state.jobs.root(),
                &["photo.jpg", "photo.CR3", "photo.jpg.xmp", "second.jpg"],
                false,
            ),
        )?;
        let pending = pipeline_status(&state, "lib", &batch.id)?;
        assert_eq!(pending["indexedFiles"], 0);
        assert_eq!(pending["indexTotal"], 2);
        assert_eq!(pending["thumbnailTotal"], 2);
        assert_eq!(pending["thumbnailCompleted"], 0);
        batch.finished = true;
        save(&state.jobs.db.lock().unwrap(), "lib", &batch)?;
        assert_eq!(
            pipeline_status(&state, "lib", &batch.id)?["status"],
            "indexing"
        );
        state.store.lock()?.execute("INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES('lib','asset','{}','hash','fp','2024-01-01','photo.jpg',0,'none',NULL,0)",[])?;
        state.store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib',?,'asset','hash','jpeg_original')",
            [state.jobs.root().join("photo.jpg").to_str().unwrap()],
        )?;
        assert_eq!(
            pipeline_status(&state, "lib", &batch.id)?["indexedFiles"],
            0
        );
        state.store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib',?,'asset','hash','raw_original')",
            [state.jobs.root().join("photo.CR3").to_str().unwrap()],
        )?;
        let first = pipeline_status(&state, "lib", &batch.id)?;
        assert_eq!(first["indexedFiles"], 1);
        assert_eq!(first["indexTotal"], 2);
        assert_eq!(first["thumbnailTotal"], 2);
        assert_eq!(first["thumbnailCompleted"], 0);
        state.store.lock()?.execute("INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES('lib','second','{}','hash2','fp2','2024-01-01','second.jpg',0,'none',NULL,0)",[])?;
        state.store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib',?,'second','hash2','jpeg_original')",
            [state.jobs.root().join("second.jpg").to_str().unwrap()],
        )?;
        state.store.reconcile_cache()?;
        assert_eq!(
            pipeline_status(&state, "lib", &batch.id)?["status"],
            "thumbnails"
        );
        state.store.lock()?.execute(
            "UPDATE media_cache SET status='ready',thumbnail=?",
            [json!({"version":"preview"}).to_string()],
        )?;
        assert_eq!(
            pipeline_status(&state, "lib", &batch.id)?["status"],
            "thumbnails"
        );
        state.store.lock()?.execute(
            "UPDATE media_cache SET browse_thumbnail=?",
            [
                json!({"sourceThumbnailVersion":"preview","spec":crate::browse_cache::SPEC})
                    .to_string(),
            ],
        )?;
        let complete = pipeline_status(&state, "lib", &batch.id)?;
        assert_eq!(complete["status"], "finished");
        assert_eq!(complete["indexedFiles"], 2);
        assert_eq!(complete["indexTotal"], 2);
        assert_eq!(complete["thumbnailCompleted"], 2);
        assert_eq!(complete["thumbnailTotal"], 2);
        state.store.lock()?.execute("UPDATE media_cache SET browse_thumbnail=NULL,browse_attempts=4,browse_last_error='encoder failed'",[])?;
        let failed = pipeline_status(&state, "lib", &batch.id)?;
        assert_eq!(failed["status"], "failed");
        assert_eq!(failed["error"], "encoder failed");
        Ok(())
    }
    #[tokio::test]
    async fn structure_finish_publishes_nested_files_and_enqueues_group_jobs() {
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
        assert!(finish_batch(&state.jobs, "lib", &batch.id, None).is_err());
        std::fs::remove_file(root.join("card")).unwrap();
        assert!(!dir.path().join("day").exists());
        let Json(submitted) = finish(
            State(state.clone()),
            Path(("lib".into(), batch.id.clone())),
            Query(FinishQuery { asynchronous: true }),
        )
        .await
        .ok()
        .unwrap();
        assert_eq!(submitted["status"], "publishing");
        assert_eq!(submitted["completedFiles"], 0);
        let Json(progress) =
            finish_status(State(state.clone()), Path(("lib".into(), batch.id.clone())))
                .await
                .ok()
                .unwrap();
        assert_eq!(progress, submitted);
        assert!(!root.join("card").exists());
        // Model both crash windows: a hard link before checkpoint, and a durable
        // checkpoint whose staging link has not yet been cleaned up.
        let mut checkpointed = load(&state.jobs.db.lock().unwrap(), "lib", &batch.id).unwrap();
        for (index, file) in checkpointed.files.iter_mut().take(2).enumerate() {
            let output = root.join(&file.file_name);
            std::fs::create_dir_all(output.parent().unwrap()).unwrap();
            std::fs::hard_link(staging(&root, &batch.id, &file.input.id), output).unwrap();
            file.published = index == 0;
        }
        save(&state.jobs.db.lock().unwrap(), "lib", &checkpointed).unwrap();
        let rewritten = root.join("metadata-rewrite.tmp");
        std::fs::write(&rewritten, b"original").unwrap();
        std::fs::rename(&rewritten, root.join(&checkpointed.files[0].file_name)).unwrap();
        assert!(
            !same_file(
                &staging(&root, &batch.id, &checkpointed.files[0].input.id),
                &root.join(&checkpointed.files[0].file_name)
            )
            .unwrap()
        );
        let recovered = Arc::new(Jobs::open(&keeps.join("db/jobs.sqlite"), &root).unwrap());
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let worker = std::thread::spawn({
            let (jobs, stop) = (recovered.clone(), stop.clone());
            move || run(jobs, stop)
        });
        let started = std::time::Instant::now();
        let result = loop {
            let result = status(&recovered, "lib", &batch.id).unwrap();
            if result["status"] == "finished" {
                break result;
            }
            assert_ne!(result["status"], "failed", "{result}");
            assert!(started.elapsed() < std::time::Duration::from_secs(5));
            std::thread::sleep(std::time::Duration::from_millis(10));
        };
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        worker.join().unwrap().unwrap();
        assert_eq!(result["completedFiles"], 3);
        assert_eq!(result["job"]["scopeKind"], "file");
        for file in &batch.files {
            assert!(!staging(&root, &batch.id, &file.input.id).exists());
        }
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
    fn complete_groups_publish_before_batch_seal_and_resume_without_overwriting_uploads() {
        let dir = tempfile::tempdir().unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), dir.path()).unwrap();
        jobs.add_folder("lib", ".").unwrap();
        let mut batch = prepare(
            &jobs,
            "lib",
            structure_input(
                jobs.root(),
                &["first.CR3", "first.CR3.xmp", "second.CR3"],
                false,
            ),
        )
        .unwrap();
        for file in &mut batch.files {
            if file.input.relative_path == "first.CR3" {
                std::fs::write(staging(jobs.root(), &batch.id, &file.input.id), b"original")
                    .unwrap();
                file.uploaded = true;
            }
        }
        save(&jobs.db.lock().unwrap(), "lib", &batch).unwrap();
        finish_batch(&jobs, "lib", &batch.id, None).unwrap();
        assert!(!jobs.root().join("first.CR3").exists());
        assert!(jobs.jobs(100).unwrap().is_empty());
        for file in &mut batch.files {
            if file.input.relative_path.ends_with("xmp") {
                std::fs::write(staging(jobs.root(), &batch.id, &file.input.id), b"original")
                    .unwrap();
                file.uploaded = true;
            }
        }
        save(&jobs.db.lock().unwrap(), "lib", &batch).unwrap();
        finish_batch(&jobs, "lib", &batch.id, None).unwrap();
        let published = load(&jobs.db.lock().unwrap(), "lib", &batch.id).unwrap();
        assert!(!published.finished && !published.finish_requested);
        assert_eq!(published.files.iter().filter(|f| f.published).count(), 2);
        assert_eq!(published.group_jobs.len(), 1);
        assert!(jobs.root().join("first.CR3.xmp").exists());
        assert!(!jobs.root().join("second.CR3").exists());
        assert!(
            !group_pending_publication(&jobs, "lib", &[jobs.root().join("first.CR3")]).unwrap()
        );
        assert!(
            group_pending_publication(&jobs, "lib", &[jobs.root().join("second.CR3")]).unwrap()
        );
        finish_batch(&jobs, "lib", &batch.id, None).unwrap();
        assert_eq!(jobs.jobs(100).unwrap().len(), 1);
        // A publication snapshot must not erase a concurrent upload or seal.
        let mut latest = published.clone();
        latest.finish_requested = true;
        let second = latest
            .files
            .iter_mut()
            .find(|f| f.input.relative_path == "second.CR3")
            .unwrap();
        second.uploaded = true;
        second.received_sha256 = Some("concurrent-upload".into());
        save(&jobs.db.lock().unwrap(), "lib", &latest).unwrap();
        let first = published.files.iter().find(|f| f.published).unwrap();
        let staged = staging(jobs.root(), &batch.id, &first.input.id);
        std::fs::hard_link(jobs.root().join(&first.file_name), &staged).unwrap();
        publish_checkpoint(
            &jobs,
            "lib",
            &published,
            &mut vec![(staged, jobs.root().to_owned())],
        )
        .unwrap();
        let merged = load(&jobs.db.lock().unwrap(), "lib", &batch.id).unwrap();
        assert!(merged.finish_requested);
        assert!(
            merged
                .files
                .iter()
                .any(|f| f.received_sha256.as_deref() == Some("concurrent-upload"))
        );
    }

    #[tokio::test]
    async fn prepare_resume_requeues_failed_early_group_and_clears_publication_failure() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("photos");
        std::fs::create_dir(&root).unwrap();
        let keeps = dir.path().join("keeps");
        let state = Arc::new(AppState {
            store: Arc::new(
                crate::store::Store::open(&keeps.join("db/control_plane.sqlite"), true).unwrap(),
            ),
            previews: Arc::new(
                crate::previews::PreviewStorage::new(
                    &keeps,
                    Some(&root),
                    "http://localhost",
                    "test-preview-key-01234567890123456789",
                )
                .unwrap(),
            ),
            jobs: Arc::new(Jobs::open(&keeps.join("db/jobs.sqlite"), &root).unwrap()),
            access_token: String::new(),
            library_id: "lib".into(),
            original_root_names: Default::default(),
        });
        state.jobs.add_folder("lib", ".").unwrap();
        let input = structure_input(state.jobs.root(), &["first.CR3", "second.CR3"], false);
        let mut batch = prepare(&state.jobs, "lib", input.clone()).unwrap();
        let first = batch
            .files
            .iter_mut()
            .find(|f| f.input.relative_path == "first.CR3")
            .unwrap();
        std::fs::write(staging(&root, &batch.id, &first.input.id), b"original").unwrap();
        first.uploaded = true;
        save(&state.jobs.db.lock().unwrap(), "lib", &batch).unwrap();
        finish_batch(&state.jobs, "lib", &batch.id, None).unwrap();
        let mut batch = load(&state.jobs.db.lock().unwrap(), "lib", &batch.id).unwrap();
        let old_job = batch.group_jobs.values().next().unwrap().clone();
        state.jobs.db.lock().unwrap().execute("UPDATE jobs SET status='failed',failed=1,error='synthetic index failure' WHERE id=?",[&old_job]).unwrap();
        assert_eq!(
            pipeline_status(&state, "lib", &batch.id).unwrap()["status"],
            "failed"
        );
        batch.finish_error = Some("synthetic publication failure".into());
        save(&state.jobs.db.lock().unwrap(), "lib", &batch).unwrap();
        let _ = prepare_handler(
            State(state.clone()),
            Path("lib".into()),
            Json(serde_json::to_value(input).unwrap()),
        )
        .await
        .ok()
        .unwrap();
        let resumed = load(&state.jobs.db.lock().unwrap(), "lib", &batch.id).unwrap();
        assert!(resumed.finish_error.is_none());
        assert!(!resumed.finished);
        assert_ne!(resumed.group_jobs.values().next().unwrap(), &old_job);
        assert_eq!(
            pipeline_status(&state, "lib", &batch.id).unwrap()["status"],
            "uploading"
        );
        assert_eq!(resumed.files.iter().filter(|f| f.uploaded).count(), 1);
    }

    #[test]
    fn failed_directory_flush_preserves_staging_and_unpublished_checkpoint() {
        let dir = tempfile::tempdir().unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), dir.path()).unwrap();
        jobs.add_folder("lib", ".").unwrap();
        let mut batch = prepare(
            &jobs,
            "lib",
            structure_input(jobs.root(), &["image.CR3"], false),
        )
        .unwrap();
        let staged = staging(jobs.root(), &batch.id, &batch.files[0].input.id);
        std::fs::write(&staged, b"original").unwrap();
        batch.files[0].published = true;
        let mut checkpoint = vec![(staged.clone(), dir.path().join("missing-directory"))];
        assert!(publish_checkpoint(&jobs, "lib", &batch, &mut checkpoint).is_err());
        assert!(staged.is_file());
        assert_eq!(checkpoint.len(), 1);
        assert!(
            !load(&jobs.db.lock().unwrap(), "lib", &batch.id)
                .unwrap()
                .files[0]
                .published
        );
    }

    #[test]
    fn large_finish_checkpoints_release_database_and_repeated_finish_reuses_job() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("photos");
        std::fs::create_dir(&root).unwrap();
        let jobs = Arc::new(Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap());
        jobs.add_folder("lib", ".").unwrap();
        let names: Vec<_> = (0..256).map(|index| format!("image-{index}.CR3")).collect();
        let paths: Vec<_> = names.iter().map(String::as_str).collect();
        let mut batch = prepare(&jobs, "lib", structure_input(jobs.root(), &paths, false)).unwrap();
        for file in &mut batch.files {
            std::fs::write(staging(&root, &batch.id, &file.input.id), b"original").unwrap();
            file.uploaded = true;
        }
        batch.finish_requested = true;
        save(&jobs.db.lock().unwrap(), "lib", &batch).unwrap();
        let stopping = std::sync::atomic::AtomicBool::new(true);
        assert_eq!(
            finish_batch(&jobs, "lib", &batch.id, Some(&stopping)).unwrap()["status"],
            "publishing"
        );
        assert!(
            !load(&jobs.db.lock().unwrap(), "lib", &batch.id)
                .unwrap()
                .finished
        );
        assert!(jobs.jobs(100).unwrap().is_empty());
        let worker = std::thread::spawn({
            let (jobs, id) = (jobs.clone(), batch.id.clone());
            move || finish_batch(&jobs, "lib", &id, None).unwrap()
        });
        let mut observed_checkpoint = false;
        while !worker.is_finished() {
            let current = load(&jobs.db.lock().unwrap(), "lib", &batch.id).unwrap();
            let published = current.files.iter().filter(|file| file.published).count();
            if (32..256).contains(&published) {
                observed_checkpoint = true;
                assert!(!current.finished);
            }
            std::thread::yield_now();
        }
        let result = worker.join().unwrap();
        assert!(
            observed_checkpoint,
            "database must remain accessible between publication checkpoints"
        );
        let repeated = finish_batch(&jobs, "lib", &batch.id, None).unwrap();
        assert_eq!(result["job"]["id"], repeated["job"]["id"]);
        assert_eq!(jobs.jobs(1000).unwrap().len(), 256);
        assert!(
            batch
                .files
                .iter()
                .all(|file| root.join(&file.file_name).is_file())
        );
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
    fn matching_is_incremental_scoped_and_rejects_partial_groups() {
        let dir = tempfile::tempdir().unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), dir.path()).unwrap();
        jobs.add_folder("lib", ".").unwrap();
        std::fs::create_dir(dir.path().join("target")).unwrap();
        std::fs::write(dir.path().join("elsewhere.CR3"), b"original").unwrap();
        std::fs::write(dir.path().join("target/first.CR3"), b"original").unwrap();
        let mut input = structure_input(
            &jobs.root().join("target"),
            &["first.CR3", "first.xmp", "second.CR3"],
            true,
        );
        input.preserve_structure = false;
        for file in &mut input.files {
            file.sha256 = None;
        }
        let initial = prepare(&jobs, "lib", input.clone()).unwrap();
        assert!(
            initial
                .files
                .iter()
                .all(|file| !file.matched && !file.uploaded)
        );
        let mut matching = input.files[..2].to_vec();
        for file in &mut matching {
            file.sha256 = Some(format!("{:x}", Sha256::digest(b"original")));
        }
        assert!(
            match_group(
                &jobs,
                "lib",
                &initial.id,
                &matching[0].id,
                matching[..1].to_vec()
            )
            .is_err()
        );
        let matched =
            match_group(&jobs, "lib", &initial.id, &matching[0].id, matching.clone()).unwrap();
        assert_eq!(matched.files.len(), 2);
        assert!(matched.files[0].skipped);
        assert!(!matched.files[1].skipped);
        let resumed = prepare(&jobs, "lib", input.clone()).unwrap();
        assert!(!resumed.files[2].matched);
        matching[0].sha256 = Some("0".repeat(64));
        assert!(match_group(&jobs, "lib", &initial.id, &input.files[0].id, matching).is_err());
        // The next photo sees destination changes made after batch creation.
        std::fs::write(dir.path().join("target/late.CR3"), b"latefile").unwrap();
        let mut second = input.files[2].clone();
        second.sha256 = Some(format!("{:x}", Sha256::digest(b"latefile")));
        let result =
            match_group(&jobs, "lib", &initial.id, &second.id, vec![second.clone()]).unwrap();
        assert_eq!(result.files[0].file_name, "late.CR3");
        assert!(result.files[0].skipped);
        // Another destination must not use identical files outside that directory.
        std::fs::create_dir(dir.path().join("empty")).unwrap();
        let mut other = structure_input(&jobs.root().join("empty"), &["new.CR3"], true);
        other.preserve_structure = false;
        let prepared = prepare(&jobs, "lib", other.clone()).unwrap();
        let result = match_group(
            &jobs,
            "lib",
            &prepared.id,
            &other.files[0].id,
            other.files.clone(),
        )
        .unwrap();
        assert!(!result.files[0].skipped);
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
            let mut batch = prepare(&jobs, "lib", input.clone()).unwrap();
            assert!(batch.files.iter().all(|file| !file.skipped));
            if enabled {
                batch = match_group(
                    &jobs,
                    "lib",
                    &batch.id,
                    &input.files[0].id,
                    input.files.clone(),
                )
                .unwrap();
                let resumed = match_group(
                    &jobs,
                    "lib",
                    &batch.id,
                    &input.files[0].id,
                    input.files.clone(),
                )
                .unwrap();
                assert_eq!(resumed.files[0].file_name, batch.files[0].file_name);
            }
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
