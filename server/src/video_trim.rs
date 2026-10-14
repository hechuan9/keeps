//! Durable NAS video edits: publish a new file before recycling the source asset.
use crate::{
    api::{ApiError, AppState},
    jobs::Jobs,
    store::{Store, StoreError},
};
use anyhow::{Context, Result, ensure};
use axum::{
    Json, Router,
    extract::{Path as ApiPath, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub id: String,
    pub content_hash: String,
    pub start_seconds: f64,
    pub end_seconds: f64,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    pub id: String,
    #[serde(rename = "assetID")]
    pub asset_id: String,
    pub content_hash: String,
    pub start_seconds: f64,
    pub end_seconds: f64,
    pub status: String,
    pub error: Option<String>,
    #[serde(rename = "newAssetID")]
    pub new_asset_id: Option<String>,
    pub output_path: Option<String>,
}
#[derive(Clone, Deserialize, Serialize)]
struct Record {
    task: Task,
    library: String,
    source: PathBuf,
    folder_id: String,
    output_hash: Option<String>,
    index_job: Option<String>,
    identity: String,
}
fn error(status: u16, message: impl Into<String>) -> anyhow::Error {
    StoreError {
        status,
        code: "video_trim_failed".into(),
        message: message.into(),
    }
    .into()
}
pub(crate) fn initialize(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS video_trims(id TEXT PRIMARY KEY,library_id TEXT NOT NULL,asset_id TEXT NOT NULL,status TEXT NOT NULL,record TEXT NOT NULL,created_at INTEGER NOT NULL DEFAULT(unixepoch())); CREATE UNIQUE INDEX IF NOT EXISTS video_trim_active_asset ON video_trims(library_id,asset_id) WHERE status IN ('pending','processing','indexing');")?;
    Ok(())
}
fn load(jobs: &Jobs, id: &str) -> Result<Option<Record>> {
    let text: Option<String> = jobs
        .db
        .lock()?
        .query_row("SELECT record FROM video_trims WHERE id=?", [id], |r| {
            r.get(0)
        })
        .optional()?;
    text.map(|s| serde_json::from_str(&s).map_err(Into::into))
        .transpose()
}
fn save(jobs: &Jobs, record: &Record) -> Result<()> {
    jobs.db.lock()?.execute(
        "UPDATE video_trims SET status=?,record=? WHERE id=?",
        params![
            record.task.status,
            serde_json::to_string(record)?,
            record.task.id
        ],
    )?;
    Ok(())
}
fn validate(request: &Request) -> Result<()> {
    if Uuid::parse_str(&request.id).is_err()
        || request.content_hash.len() != 64
        || !request
            .content_hash
            .bytes()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
    {
        return Err(error(400, "invalid trim request ID or content hash"));
    }
    if !request.start_seconds.is_finite()
        || !request.end_seconds.is_finite()
        || request.start_seconds < 0.0
        || request.end_seconds <= request.start_seconds
    {
        return Err(error(
            400,
            "trim range must be finite with 0 <= start < end",
        ));
    }
    Ok(())
}
fn source(
    store: &Store,
    jobs: &Jobs,
    library: &str,
    asset: &str,
    hash: &str,
) -> Result<(PathBuf, String)> {
    let versions = store.versions(library, asset)?;
    let version = versions["items"]
        .as_array()
        .and_then(|items| {
            items
                .iter()
                .find(|v| v["contentHash"] == hash && v["available"] == true)
        })
        .ok_or_else(|| error(409, "video version is unavailable"))?;
    let folders = jobs.folders()?;
    for location in version["paths"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|p| p["available"] == true)
    {
        let Some(path) = location["path"].as_str() else {
            continue;
        };
        if !crate::media::is_video(Path::new(path)) {
            continue;
        }
        let Some(folder) = folders
            .iter()
            .find(|f| f.active && f.library_id == library && Path::new(path).starts_with(&f.path))
        else {
            continue;
        };
        let Some(file) = jobs.file_state(&folder.id, path)? else {
            continue;
        };
        if file.asset_id == asset && file.version == hash && file.error.is_none() {
            let metadata = fs::symlink_metadata(path)?;
            ensure!(
                metadata.is_file() && !metadata.file_type().is_symlink(),
                "video source must be a regular file"
            );
            jobs.validate_path(Path::new(path).parent().context("source has no parent")?)?;
            ensure!(
                metadata.len() == file.size as u64
                    && metadata
                        .modified()?
                        .duration_since(std::time::UNIX_EPOCH)?
                        .as_nanos()
                        == file.mtime_ns as u128,
                "video source changed; refresh inventory"
            );
            return Ok((path.into(), folder.id.clone()));
        }
    }
    Err(error(
        409,
        "tracked video source unavailable; refresh inventory",
    ))
}
fn validate_source(jobs: &Jobs, path: &Path, hash: &str) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        metadata.is_file() && !metadata.file_type().is_symlink(),
        "video source must be a regular file"
    );
    jobs.validate_path(path.parent().context("video has no parent")?)?;
    ensure!(
        crate::media::sha256_file(path)? == hash,
        "video source changed; refresh inventory"
    );
    Ok(())
}
fn duration(path: &Path) -> Result<f64> {
    let output = crate::media::run(
        Command::new("ffprobe")
            .args([
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=duration:format=duration",
                "-of",
                "json",
            ])
            .arg(path),
    )?;
    let value: Value = serde_json::from_slice(&output)?;
    ensure!(
        value["streams"].as_array().is_some_and(|a| !a.is_empty()),
        "file contains no video stream"
    );
    let parse = |v: &Value| {
        v.as_str()
            .and_then(|s| s.parse::<f64>().ok())
            .filter(|n| n.is_finite() && *n > 0.0)
    };
    parse(&value["format"]["duration"])
        .or_else(|| parse(&value["streams"][0]["duration"]))
        .context("video duration is unavailable")
}
fn enqueue(
    store: &Store,
    jobs: &Jobs,
    library: &str,
    asset: &str,
    mut request: Request,
) -> Result<Task> {
    validate(&request)?;
    request.id = Uuid::parse_str(&request.id)?.to_string();
    if let Some(record) = load(jobs, &request.id)? {
        if record.library == library
            && record.task.asset_id == asset
            && record.task.content_hash == request.content_hash
            && record.task.start_seconds == request.start_seconds
            && record.task.end_seconds == request.end_seconds
        {
            return Ok(record.task);
        }
        return Err(error(
            409,
            "trim request ID already has different parameters",
        ));
    }
    let _guard = jobs
        .directory_mutation
        .read()
        .map_err(|_| error(500, "directory mutation lock poisoned"))?;
    crate::directory_move::ensure_reconciled(jobs)?;
    ensure!(
        store.asset(library, asset)?["trashed"] != true,
        "cannot trim a recycled asset"
    );
    let (source, folder_id) = source(store, jobs, library, asset, &request.content_hash)?;
    if request.end_seconds > duration(&source)? {
        return Err(error(400, "trim end exceeds video duration"));
    }
    let stem = source
        .file_stem()
        .context("video filename missing")?
        .to_string_lossy();
    // A fresh filename and embedded identity prevent accidental grouping with the source.
    let output = source.with_file_name(format!(
        "{}-trim-{}.mp4",
        stem.chars().take(100).collect::<String>(),
        Uuid::new_v4()
    ));
    let record = Record {
        task: Task {
            id: request.id,
            asset_id: asset.into(),
            content_hash: request.content_hash,
            start_seconds: request.start_seconds,
            end_seconds: request.end_seconds,
            status: "pending".into(),
            error: None,
            new_asset_id: None,
            output_path: Some(output.to_str().context("output path must be UTF-8")?.into()),
        },
        library: library.into(),
        source,
        folder_id,
        output_hash: None,
        index_job: None,
        identity: Uuid::new_v4().to_string(),
    };
    let result = jobs.db.lock()?.execute(
        "INSERT INTO video_trims(id,library_id,asset_id,status,record) VALUES(?,?,?,?,?)",
        params![
            record.task.id,
            library,
            asset,
            record.task.status,
            serde_json::to_string(&record)?
        ],
    );
    if let Err(e) = result {
        if let Some(prior) = load(jobs, &record.task.id)?
            && prior.library == library
            && prior.task.asset_id == asset
            && prior.task.content_hash == record.task.content_hash
            && prior.task.start_seconds == record.task.start_seconds
            && prior.task.end_seconds == record.task.end_seconds
        {
            return Ok(prior.task);
        }
        if matches!(&e,rusqlite::Error::SqliteFailure(code,_) if code.code==rusqlite::ErrorCode::ConstraintViolation)
        {
            return Err(error(
                409,
                "this asset already has an active trim or this request ID is in use",
            ));
        }
        return Err(e.into());
    }
    Ok(record.task)
}

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route(
            "/libraries/{library}/assets/{asset}/video-trims",
            post(create),
        )
        .route(
            "/libraries/{library}/assets/{asset}/video-trims/{id}",
            get(fetch),
        )
}
async fn create(
    State(state): State<Arc<AppState>>,
    ApiPath((library, asset)): ApiPath<(String, String)>,
    Json(body): Json<Request>,
) -> Result<Response, ApiError> {
    crate::api::require_library(&state, &library)?;
    let asset = crate::api::asset_id(&asset)?;
    let task =
        crate::api::blocking(move || enqueue(&state.store, &state.jobs, &library, &asset, body))
            .await?;
    Ok((StatusCode::ACCEPTED, Json(task)).into_response())
}
async fn fetch(
    State(state): State<Arc<AppState>>,
    ApiPath((library, asset, id)): ApiPath<(String, String, String)>,
) -> Result<Response, ApiError> {
    crate::api::require_library(&state, &library)?;
    let asset = crate::api::asset_id(&asset)?;
    let id = Uuid::parse_str(&id)
        .map_err(|_| error(400, "invalid trim UUID"))?
        .to_string();
    let task = crate::api::blocking(move || {
        load(&state.jobs, &id)?
            .filter(|r| r.library == library && r.task.asset_id == asset)
            .map(|r| r.task)
            .ok_or_else(|| error(404, "video trim not found"))
    })
    .await?;
    Ok(Json(task).into_response())
}

fn encode(record: &Record, target: &Path, stop: &AtomicBool) -> Result<bool> {
    if stop.load(Ordering::Relaxed) {
        return Ok(false);
    }
    let stderr = tempfile::tempfile()?;
    let mut command = Command::new("ffmpeg");
    command
        .args(["-nostdin", "-v", "error", "-y", "-threads", "1", "-ss"])
        .arg(record.task.start_seconds.to_string())
        .arg("-i")
        .arg(&record.source)
        .arg("-t")
        .arg((record.task.end_seconds - record.task.start_seconds).to_string())
        .args([
            "-map",
            "0:v:0",
            "-map",
            "0:a?",
            "-map_metadata",
            "0",
            "-map_chapters",
            "-1",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-vf",
            "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-threads",
            "1",
            "-filter_threads",
            "1",
            "-movflags",
            "+faststart",
            "-f",
            "mp4",
        ])
        .arg(target)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(stderr.try_clone()?);
    let mut child = command.spawn().context("start video trim encoder")?;
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            use std::io::{Read, Seek};
            let mut stderr = stderr;
            stderr.rewind()?;
            let mut detail = String::new();
            stderr.read_to_string(&mut detail)?;
            ensure!(
                status.success(),
                "video trim encoder failed: {status}: {detail}"
            );
            return Ok(true);
        }
        if stop.load(Ordering::Relaxed) || started.elapsed() > Duration::from_secs(24 * 3600) {
            child.kill().context("stop video trim encoder")?;
            child.wait()?;
            if stop.load(Ordering::Relaxed) {
                return Ok(false);
            }
            anyhow::bail!("video trim exceeded 24-hour encoding limit");
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}
fn prepare(store: &Store, jobs: &Jobs, record: &mut Record, stop: &AtomicBool) -> Result<bool> {
    let _guard = jobs
        .directory_mutation
        .read()
        .map_err(|_| error(500, "directory mutation lock poisoned"))?;
    crate::directory_move::ensure_reconciled(jobs)?;
    let _source_guard = store
        .source_mutation
        .read()
        .map_err(|_| error(500, "source mutation lock poisoned"))?;
    let output = PathBuf::from(
        record
            .task
            .output_path
            .as_ref()
            .context("missing output path")?,
    );
    validate_source(jobs, &record.source, &record.task.content_hash)?;
    ensure!(
        store.asset(&record.library, &record.task.asset_id)?["trashed"] != true,
        "source was recycled before trim completed"
    );
    if output.try_exists()? {
        ensure!(
            record.output_hash.as_ref().is_some_and(
                |h| crate::media::sha256_file(&output).is_ok_and(|actual| actual == *h)
            ),
            "trim output path already exists with different content"
        );
    } else {
        record.task.status = "processing".into();
        save(jobs, record)?;
        let scratch = tempfile::Builder::new()
            .prefix(".keeps-trim-")
            .tempdir_in(record.source.parent().context("source has no parent")?)?;
        let temporary = scratch.path().join("trim.mp4");
        if !encode(record, &temporary, stop)? {
            return Ok(false);
        }
        let actual = duration(&temporary)?;
        ensure!(
            (actual - (record.task.end_seconds - record.task.start_seconds)).abs() < 0.25,
            "encoded video duration does not match requested trim"
        );
        crate::identity::generated(&temporary, &record.identity)?;
        validate_source(jobs, &record.source, &record.task.content_hash)?;
        record.output_hash = Some(crate::media::sha256_file(&temporary)?);
        fs::File::open(&temporary)?.sync_all()?;
        save(jobs, record)?;
        // Linking fails on collisions; publication never overwrites an existing original.
        fs::hard_link(&temporary, &output).context("publish trimmed video without overwriting")?;
        fs::File::open(output.parent().context("output has no parent")?)?.sync_all()?;
    }
    record.task.status = "indexing".into();
    let job = jobs.enqueue_operation_file(&record.folder_id, &output, 0)?;
    record.index_job = Some(job.id);
    save(jobs, record)?;
    Ok(true)
}
fn indexed(store: &Store, jobs: &Jobs, record: &mut Record) -> Result<bool> {
    let output = record
        .task
        .output_path
        .as_ref()
        .context("missing output path")?;
    let file = jobs.file_state(&record.folder_id, output)?;
    if let Some(file) = file.filter(|f| {
        f.error.is_none()
            && record.output_hash.as_ref() == Some(&f.version)
            && !f.asset_id.is_empty()
    }) {
        ensure!(
            file.asset_id != record.task.asset_id,
            "trim incorrectly grouped with original asset"
        );
        ensure!(
            store.asset(&record.library, &file.asset_id)?["trashed"] != true,
            "trimmed asset is recycled"
        );
        ensure!(
            store.original_is_online(&record.library, output, &file.version)?,
            "trimmed output is not indexed online"
        );
        record.task.new_asset_id = Some(file.asset_id);
        return Ok(true);
    }
    if let Some(job) = record
        .index_job
        .as_ref()
        .map(|id| jobs.job(id))
        .transpose()?
        .flatten()
    {
        ensure!(
            job.status != "failed",
            "trim indexing failed: {}",
            job.error.unwrap_or_default()
        );
        if job.status == "completed" {
            record.index_job = Some(
                jobs.enqueue_operation_file(&record.folder_id, Path::new(output), 0)?
                    .id,
            );
            save(jobs, record)?;
        }
    } else {
        anyhow::bail!("trim indexing job disappeared");
    }
    Ok(false)
}
pub fn run(jobs: Arc<Jobs>, store: Arc<Store>, stop: Arc<AtomicBool>) -> Result<()> {
    while !stop.load(Ordering::Relaxed) {
        let records=jobs.db.lock()?.prepare("SELECT record FROM video_trims WHERE status IN ('pending','processing','indexing') ORDER BY created_at,rowid")?.query_map([],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
        for text in records {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            let mut record: Record = serde_json::from_str(&text)?;
            let result = (|| -> Result<bool> {
                if record.task.status != "indexing" && !prepare(&store, &jobs, &mut record, &stop)?
                {
                    return Ok(false);
                }
                indexed(&store, &jobs, &mut record)
            })();
            match result {
                Ok(true) => {
                    let _guard = jobs
                        .directory_mutation
                        .read()
                        .map_err(|_| error(500, "directory mutation lock poisoned"))?;
                    let validation = (|| -> Result<()> {
                        validate_source(&jobs, &record.source, &record.task.content_hash)?;
                        let output = Path::new(
                            record
                                .task
                                .output_path
                                .as_ref()
                                .context("missing output path")?,
                        );
                        validate_source(
                            &jobs,
                            output,
                            record.output_hash.as_ref().context("missing output hash")?,
                        )?;
                        Ok(())
                    })();
                    if let Err(e) = validation {
                        tracing::error!(id=%record.task.id,error=?e,"video trim final validation failed");
                        record.task.status = "failed".into();
                        record.task.error = Some(format!("{e:#}"));
                        save(&jobs, &record)?;
                        continue;
                    }
                    // Persist completion only after catalog commit. A restart safely repeats this idempotent operation.
                    store.set_trashed(&record.library, &record.task.asset_id, true)?;
                    record.task.status = "completed".into();
                    save(&jobs, &record)?;
                }
                Ok(false) => {}
                Err(e) => {
                    tracing::error!(id=%record.task.id,error=?e,"video trim failed");
                    record.task.status = "failed".into();
                    record.task.error = Some(format!("{e:#}"));
                    save(&jobs, &record)?;
                }
            }
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn fixture() -> Result<(tempfile::TempDir, Arc<Store>, Arc<Jobs>)> {
        let dir = tempfile::tempdir()?;
        let root = dir.path().join("originals");
        fs::create_dir(&root)?;
        let store = Arc::new(Store::open(&dir.path().join("catalog.sqlite"), true)?);
        let jobs = Arc::new(Jobs::open(&dir.path().join("jobs.sqlite"), &root)?);
        jobs.add_folder("photos", ".")?;
        Ok((dir, store, jobs))
    }
    fn ingest(
        store: &Store,
        jobs: &Jobs,
        path: &Path,
        identity: Option<&str>,
    ) -> Result<(String, String)> {
        let hash = crate::media::sha256_file(path)?;
        let mut snapshot = json!({"captureTime":"2024-01-01T00:00:00Z","originalFilename":path.file_name().unwrap().to_str().unwrap(),"contentFingerprint":hash,"metadataFingerprint":path.display().to_string(),"rating":0,"flagState":"unflagged","tags":[],"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"});
        if let Some(identity) = identity {
            snapshot["originalDocumentID"] = json!(identity);
        }
        let metadata = fs::metadata(path)?;
        let id = store.ingest_original(
            "photos",
            path.to_str().unwrap(),
            &json!({"contentHash":hash,"sizeBytes":metadata.len(),"role":"jpeg_original"}),
            &snapshot,
        )?;
        jobs.record_file(
            &jobs.folders()?[0].id,
            path.to_str().unwrap(),
            metadata.len() as i64,
            metadata
                .modified()?
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos() as i64,
            &id,
            &hash,
            None,
        )?;
        Ok((id, hash))
    }
    fn request(hash: &str) -> Request {
        Request {
            id: Uuid::new_v4().to_string(),
            content_hash: hash.into(),
            start_seconds: 0.4,
            end_seconds: 1.4,
        }
    }
    #[test]
    fn invalid_ranges_and_ids_are_rejected() {
        let good = request(&"a".repeat(64));
        assert!(validate(&good).is_ok());
        for (start, end) in [
            (-1.0, 1.0),
            (1.0, 1.0),
            (2.0, 1.0),
            (f64::NAN, 2.0),
            (0.0, f64::INFINITY),
        ] {
            let mut bad = good.clone();
            bad.start_seconds = start;
            bad.end_seconds = end;
            assert!(validate(&bad).is_err());
        }
        let mut bad = good;
        bad.id = "../escape".into();
        assert!(validate(&bad).is_err());
    }
    #[test]
    fn completed_retry_precedes_source_validation_and_survives_restart() -> Result<()> {
        let (dir, store, jobs) = fixture()?;
        let request = request(&"a".repeat(64));
        let record = Record {
            task: Task {
                id: request.id.clone(),
                asset_id: Uuid::new_v4().to_string(),
                content_hash: request.content_hash.clone(),
                start_seconds: request.start_seconds,
                end_seconds: request.end_seconds,
                status: "completed".into(),
                error: None,
                new_asset_id: Some(Uuid::new_v4().to_string()),
                output_path: Some("/already-saved.mp4".into()),
            },
            library: "photos".into(),
            source: "/unavailable.mp4".into(),
            folder_id: "folder".into(),
            output_hash: None,
            index_job: None,
            identity: Uuid::new_v4().to_string(),
        };
        jobs.db.lock()?.execute(
            "INSERT INTO video_trims(id,library_id,asset_id,status,record) VALUES(?,?,?,?,?)",
            params![
                record.task.id,
                record.library,
                record.task.asset_id,
                record.task.status,
                serde_json::to_string(&record)?
            ],
        )?;
        drop(jobs);
        let jobs = Jobs::open(
            &dir.path().join("jobs.sqlite"),
            &dir.path().join("originals"),
        )?;
        let mut uppercase = request.clone();
        uppercase.id = uppercase.id.to_uppercase();
        assert_eq!(
            enqueue(&store, &jobs, "photos", &record.task.asset_id, uppercase)?.status,
            "completed"
        );
        let mut changed = request;
        changed.end_seconds = 2.0;
        assert_eq!(
            enqueue(&store, &jobs, "photos", &record.task.asset_id, changed)
                .unwrap_err()
                .downcast_ref::<StoreError>()
                .unwrap()
                .status,
            409
        );
        Ok(())
    }
    #[test]
    #[ignore = "requires ffmpeg, ffprobe, exiftool and NAS media command wrappers"]
    fn actual_trim_preserves_source_and_audio_and_recovers_publication() -> Result<()> {
        let (_dir, store, jobs) = fixture()?;
        let source = jobs.root().join("source.mp4");
        let output = Command::new("ffmpeg")
            .args([
                "-nostdin",
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                "testsrc2=size=160x120:rate=30:duration=2",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:duration=2",
                "-c:v",
                "libx264",
                "-c:a",
                "aac",
                "-shortest",
            ])
            .arg(&source)
            .output()?;
        ensure!(
            output.status.success(),
            "fixture encoder failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let (asset, hash) = ingest(&store, &jobs, &source, None)?;
        let mut invalid = request(&hash);
        invalid.end_seconds = 3.0;
        assert_eq!(
            enqueue(&store, &jobs, "photos", &asset, invalid)
                .unwrap_err()
                .downcast_ref::<StoreError>()
                .unwrap()
                .status,
            400
        );
        let body = request(&hash);
        let task = enqueue(&store, &jobs, "photos", &asset, body.clone())?;
        assert_eq!(task.status, "pending");
        assert_eq!(
            enqueue(&store, &jobs, "photos", &asset, body.clone())?.id,
            task.id
        );
        assert!(enqueue(&store, &jobs, "photos", &asset, request(&hash)).is_err());
        let mut record = load(&jobs, &task.id)?.unwrap();
        assert!(!prepare(
            &store,
            &jobs,
            &mut record,
            &AtomicBool::new(true)
        )?);
        assert_eq!(load(&jobs, &task.id)?.unwrap().task.status, "processing");
        assert!(!Path::new(record.task.output_path.as_ref().unwrap()).exists());
        let stop = AtomicBool::new(false);
        assert!(prepare(&store, &jobs, &mut record, &stop)?);
        assert_eq!(store.asset("photos", &asset)?["trashed"], false);
        assert_eq!(crate::media::sha256_file(&source)?, hash);
        let target = PathBuf::from(record.task.output_path.as_ref().unwrap());
        assert!((duration(&target)? - 1.0).abs() < 0.1);
        let probe = Command::new("ffprobe")
            .args([
                "-v",
                "error",
                "-select_streams",
                "a:0",
                "-show_entries",
                "stream=codec_name",
                "-of",
                "csv=p=0",
            ])
            .arg(&target)
            .output()?;
        assert!(String::from_utf8_lossy(&probe.stdout).contains("aac"));
        assert_eq!(
            crate::identity::read(&target)?,
            Some(record.identity.clone())
        );
        let bytes = fs::read(&target)?;
        // Re-enter after publication but before indexing was persisted: no second output or overwrite.
        record.task.status = "processing".into();
        save(&jobs, &record)?;
        assert!(prepare(&store, &jobs, &mut record, &stop)?);
        assert_eq!(fs::read(&target)?, bytes);
        let (new_asset, _) = ingest(&store, &jobs, &target, Some(&record.identity))?;
        assert_ne!(new_asset, asset);
        assert!(indexed(&store, &jobs, &mut record)?);
        let running = Arc::new(AtomicBool::new(false));
        let worker = std::thread::spawn({
            let (jobs, store, stop) = (jobs.clone(), store.clone(), running.clone());
            move || run(jobs, store, stop)
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        while load(&jobs, &task.id)?.unwrap().task.status != "completed"
            && Instant::now() < deadline
        {
            std::thread::sleep(Duration::from_millis(50));
        }
        running.store(true, Ordering::Relaxed);
        worker.join().unwrap()?;
        assert_eq!(load(&jobs, &task.id)?.unwrap().task.status, "completed");
        assert_eq!(store.asset("photos", &asset)?["trashed"], true);
        assert_eq!(store.asset("photos", &new_asset)?["trashed"], false);
        assert_eq!(crate::media::sha256_file(&source)?, hash);
        assert_eq!(
            enqueue(&store, &jobs, "photos", &asset, body)?.status,
            "completed"
        );
        Ok(())
    }
    #[test]
    fn output_collision_and_source_change_never_recycle_source() -> Result<()> {
        let (_dir, store, jobs) = fixture()?;
        let source = jobs.root().join("source.mp4");
        fs::write(&source, b"source bytes")?;
        let (asset, hash) = ingest(&store, &jobs, &source, None)?;
        let output = jobs.root().join("existing.mp4");
        fs::write(&output, b"existing file")?;
        let mut record = Record {
            task: Task {
                id: Uuid::new_v4().to_string(),
                asset_id: asset.clone(),
                content_hash: hash.clone(),
                start_seconds: 0.0,
                end_seconds: 1.0,
                status: "processing".into(),
                error: None,
                new_asset_id: None,
                output_path: Some(output.to_str().unwrap().into()),
            },
            library: "photos".into(),
            source: source.clone(),
            folder_id: jobs.folders()?[0].id.clone(),
            output_hash: None,
            index_job: None,
            identity: Uuid::new_v4().to_string(),
        };
        assert!(prepare(&store, &jobs, &mut record, &AtomicBool::new(false)).is_err());
        assert_eq!(fs::read(&output)?, b"existing file");
        assert_eq!(store.asset("photos", &asset)?["trashed"], false);
        assert_eq!(crate::media::sha256_file(&source)?, hash);
        fs::write(&source, b"changed original")?;
        assert!(prepare(&store, &jobs, &mut record, &AtomicBool::new(false)).is_err());
        assert_eq!(store.asset("photos", &asset)?["trashed"], false);
        Ok(())
    }
}
