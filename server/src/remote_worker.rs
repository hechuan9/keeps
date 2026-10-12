use crate::{
    api::{ApiError, AppState},
    cache_pipeline as cache,
    media::{self, MediaProcessor},
    store::Store,
};
use anyhow::{Context, Result, ensure};
use axum::{
    Json, Router,
    body::Body,
    extract::{DefaultBodyLimit, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::{fs, path::PathBuf, sync::Arc};
const LEASE: i64 = 1800;
pub(crate) const IMPORT_LEASE: i64 = 300;

fn task_lease(db: &Connection, lib: &str, id: &str) -> Result<i64> {
    let imported: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM remote_cache_tasks r JOIN catalog_paths p ON p.library_id=r.library_id AND p.asset_id=r.asset_id JOIN import_compute_leases l ON l.library_id=p.library_id AND l.path=p.path AND l.worker_id=r.worker_id WHERE r.library_id=? AND r.id=?)", params![lib,id], |r|r.get(0))?;
    Ok(if imported { IMPORT_LEASE } else { LEASE })
}

static COMMIT: std::sync::Mutex<()> = std::sync::Mutex::new(());
pub fn migrate(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS import_compute_leases(library_id TEXT NOT NULL,batch_id TEXT NOT NULL,path TEXT NOT NULL,worker_id TEXT NOT NULL,expires_at INTEGER NOT NULL,PRIMARY KEY(library_id,batch_id,path)); CREATE INDEX IF NOT EXISTS import_compute_path ON import_compute_leases(library_id,path,expires_at); CREATE TABLE IF NOT EXISTS remote_cache_tasks(id TEXT PRIMARY KEY,library_id TEXT NOT NULL,asset_id TEXT NOT NULL,source_hash TEXT NOT NULL,input_hash TEXT NOT NULL,input_path TEXT NOT NULL,worker_id TEXT NOT NULL,expires_at INTEGER NOT NULL,completed INTEGER NOT NULL DEFAULT 0); CREATE INDEX IF NOT EXISTS remote_cache_expiry ON remote_cache_tasks(completed,expires_at);")?;
    Ok(())
}
pub fn expire(db: &Connection) -> Result<()> {
    let expired = db.prepare("SELECT id,library_id,asset_id,source_hash FROM remote_cache_tasks WHERE completed=0 AND expires_at<=unixepoch()")?
        .query_map([], |row| Ok((row.get::<_,String>(0)?,row.get::<_,String>(1)?,row.get::<_,String>(2)?,row.get::<_,String>(3)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (id, library, asset, hash) in expired {
        cache::record_failure(db, &library, &asset, &hash, "remote worker lease expired")?;
        db.execute(
            "UPDATE remote_cache_tasks SET completed=-1 WHERE id=? AND completed=0",
            [id],
        )?;
    }
    Ok(())
}
#[derive(Clone)]
struct Task {
    id: String,
    asset: String,
    hash: String,
    input_hash: String,
    path: PathBuf,
    completed: i64,
}
fn conflict() -> anyhow::Error {
    crate::store::StoreError {
        status: 409,
        code: "worker_lease_expired".into(),
        message: "worker lease expired or task changed".into(),
    }
    .into()
}
fn task(store: &Store, library: &str, id: &str) -> Result<Task> {
    let db = store.lock()?;
    let row=db.query_row("SELECT asset_id,source_hash,input_hash,input_path,completed,expires_at FROM remote_cache_tasks WHERE id=? AND library_id=?",params![id,library],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,r.get::<_,i64>(4)?,r.get::<_,i64>(5)?))).optional()?.ok_or_else(conflict)?;
    if row.4 != 1 && (row.4 != 0 || row.5 <= chrono::Utc::now().timestamp()) {
        return Err(conflict());
    }
    let state = if row.4 == 1 { "ready" } else { "processing" };
    let valid: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM media_cache WHERE library_id=? AND asset_id=? AND source_hash=? AND spec=? AND status=?)",
        params![library,row.0,row.1,cache::spec()?,state], |r|r.get(0))?;
    ensure!(valid, conflict());
    Ok(Task {
        id: id.into(),
        asset: row.0,
        hash: row.1,
        input_hash: row.2,
        path: row.3.into(),
        completed: row.4,
    })
}
fn scratch(state: &AppState, t: &Task) -> Result<PathBuf> {
    let root = PathBuf::from(state.store.lock()?.path().context("database path")?)
        .parent()
        .context("database parent")?
        .parent()
        .context("keeps root")?
        .join("tmp")
        .join("remote-worker")
        .join(&t.id);
    fs::create_dir_all(&root)?;
    Ok(root)
}
fn cleanup_expired(state: &AppState) -> Result<()> {
    let ids = {
        let db = state.store.lock()?;
        db.prepare("SELECT id FROM remote_cache_tasks WHERE completed=-1 LIMIT 20")?
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    for id in ids {
        let t = Task {
            id: id.clone(),
            asset: String::new(),
            hash: String::new(),
            input_hash: String::new(),
            path: PathBuf::new(),
            completed: -1,
        };
        fs::remove_dir_all(scratch(state, &t)?)?;
        state.store.lock()?.execute(
            "UPDATE remote_cache_tasks SET completed=-2 WHERE id=? AND completed=-1",
            [id],
        )?;
    }
    Ok(())
}
fn validate(state: &AppState, t: &Task) -> Result<()> {
    state
        .jobs
        .validate_path(t.path.parent().context("source parent")?)?;
    ensure!(
        !fs::symlink_metadata(&t.path)?.file_type().is_symlink(),
        "source symlink forbidden"
    );
    ensure!(
        media::sha256_file(&t.path)? == t.input_hash,
        "source changed"
    );
    Ok(())
}
fn needs_standard(t: &Task) -> bool {
    media::is_raw(&t.path) && !deferred(t)
}
fn deferred(t: &Task) -> bool {
    t.path
        .extension()
        .and_then(|v| v.to_str())
        .is_some_and(|v| v.eq_ignore_ascii_case("3fr"))
}
pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/libraries/{library}/worker/claim", post(claim))
        .route("/libraries/{library}/worker/tasks/{id}/source", get(source))
        .route(
            "/libraries/{library}/worker/tasks/{id}/heartbeat",
            post(heartbeat),
        )
        .route(
            "/libraries/{library}/worker/tasks/{id}/thumbnail",
            put(thumbnail).layer(DefaultBodyLimit::max(256 * 1024 * 1024)),
        )
        .route(
            "/libraries/{library}/worker/tasks/{id}/browse",
            put(browse).layer(DefaultBodyLimit::max(256 * 1024 * 1024)),
        )
        .route(
            "/libraries/{library}/worker/tasks/{id}/standard",
            put(standard).layer(DefaultBodyLimit::max(256 * 1024 * 1024)),
        )
        .route(
            "/libraries/{library}/worker/tasks/{id}/complete",
            post(complete),
        )
        .route("/libraries/{library}/worker/tasks/{id}/fail", post(fail))
}
async fn run<F>(f: F) -> Result<Json<Value>, ApiError>
where
    F: FnOnce() -> Result<Value> + Send + 'static,
{
    Ok(Json(
        tokio::task::spawn_blocking(f)
            .await
            .map_err(anyhow::Error::from)??,
    ))
}
async fn claim(
    State(s): State<Arc<AppState>>,
    Path(lib): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    run(move || {
        let enabled = std::env::var("KEEPS_REMOTE_WORKER_ENABLED").ok();
        claim_sync(&s, &lib, body, enabled.as_deref())
    })
    .await
}
#[cfg(test)]
fn claim_pending(
    store: &Store,
    lib: &str,
    worker: &str,
) -> Result<Option<(String, String, String)>> {
    claim_pending_scoped(store, lib, worker, None)
}
fn claim_pending_scoped(
    store: &Store,
    lib: &str,
    worker: &str,
    batch: Option<&str>,
) -> Result<Option<(String, String, String)>> {
    let _source = store
        .source_mutation
        .read()
        .map_err(|_| anyhow::anyhow!("source mutation lock poisoned"))?;
    let mut db = store.lock()?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    expire(&tx)?;
    let row = tx.query_row("SELECT asset_id,source_hash FROM media_cache WHERE library_id=? AND (status='pending' OR (?2 IS NOT NULL AND status='ready' AND (browse_thumbnail IS NULL OR json_extract(browse_thumbnail,'$.sourceThumbnailVersion') IS NOT json_extract(thumbnail,'$.version') OR json_extract(browse_thumbnail,'$.spec') IS NOT 'browse-heic-64-q50-v1'))) AND available_at<=unixepoch() AND EXISTS(SELECT 1 FROM catalog_assets a WHERE a.library_id=media_cache.library_id AND a.id=media_cache.asset_id AND a.trashed=0) AND (?2 IS NULL OR EXISTS(SELECT 1 FROM catalog_paths p JOIN import_compute_leases l ON l.library_id=p.library_id AND l.path=p.path WHERE p.library_id=media_cache.library_id AND p.asset_id=media_cache.asset_id AND l.batch_id=?2 AND l.worker_id=?3 AND l.expires_at>unixepoch())) AND (?2 IS NOT NULL OR NOT EXISTS(SELECT 1 FROM catalog_paths p JOIN import_compute_leases l ON l.library_id=p.library_id AND l.path=p.path WHERE p.library_id=media_cache.library_id AND p.asset_id=media_cache.asset_id AND l.expires_at>unixepoch())) LIMIT 1", params![lib,batch,worker], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))).optional()?;
    let Some((asset, hash)) = row else {
        tx.commit()?;
        return Ok(None);
    };
    let id = uuid::Uuid::new_v4().to_string();
    tx.execute("UPDATE media_cache SET status='processing',attempts=attempts+1,updated_at=unixepoch() WHERE library_id=? AND asset_id=?", params![lib, asset])?;
    tx.execute(
        "INSERT INTO remote_cache_tasks VALUES(?,?,?,?,?,'',?,unixepoch()+?,0)",
        params![
            id,
            lib,
            asset,
            hash,
            hash,
            worker,
            if batch.is_some() { IMPORT_LEASE } else { LEASE }
        ],
    )?;
    tx.commit()?;
    Ok(Some((id, asset, hash)))
}
fn remote_worker_enabled(value: Option<&str>) -> Result<bool> {
    match value {
        None | Some("0" | "false") => Ok(false),
        Some("1" | "true") => Ok(true),
        _ => anyhow::bail!("KEEPS_REMOTE_WORKER_ENABLED must be 0 or 1"),
    }
}
fn claim_sync(s: &AppState, lib: &str, body: Value, enabled: Option<&str>) -> Result<Value> {
    let batch_id = body["importID"]
        .as_str()
        .map(uuid::Uuid::parse_str)
        .transpose()?
        .map(|id| id.to_string());
    let batch = batch_id.as_deref();
    if batch.is_none() && !remote_worker_enabled(enabled)? {
        return Ok(json!({"task":null,"enabled":false}));
    }
    {
        let _guard = COMMIT
            .lock()
            .map_err(|_| anyhow::anyhow!("worker commit poisoned"))?;
        cleanup_expired(s)?;
    }
    let worker = body["workerID"].as_str().context("workerID required")?;
    ensure!(
        !worker.is_empty() && worker.len() <= 128,
        "invalid workerID"
    );
    ensure!(
        s.previews.free_bytes()? > 2 * 1024 * 1024 * 1024,
        "cache disk low"
    );
    let mut deferred_count = 0;
    let (id, asset, hash) = loop {
        if deferred_count >= crate::cache_pipeline::BATCH {
            return Ok(json!({"task":null}));
        }
        let Some(candidate) = claim_pending_scoped(&s.store, lib, worker, batch)? else {
            return Ok(json!({"task":null}));
        };
        if !s.store.defer_cache_for_scan(&s.jobs, lib, &candidate.1)? {
            break candidate;
        }
        deferred_count += 1;
    };
    let prepared = (|| -> Result<Option<Task>> {
        let selected = s.store.default_version(lib, &asset)?;
        let selected = match selected {
            Some(v) => v,
            None => s.store.lock()?.query_row(
                "SELECT content_hash,path FROM catalog_paths p WHERE library_id=? AND asset_id=? AND content_hash=? AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path) ORDER BY path LIMIT 1",
                params![lib,asset,hash], |r| Ok(crate::versions::DefaultVersion { content_hash:r.get(0)?, path:r.get(1)? })
            ).optional()?.context("no indexed source path")?,
        };
        ensure!(selected.content_hash == hash, "source changed");
        if !std::path::Path::new(&selected.path).try_exists()?
            && s.jobs
                .path_sync_pending(lib, std::path::Path::new(&selected.path))?
        {
            s.store.defer_cache_for_path_sync(lib, &asset)?;
            return Ok(None);
        }
        let input = cache::select_standard_source(&s.store, lib, &asset, &selected)?;
        s.store.lock()?.execute(
            "UPDATE remote_cache_tasks SET input_hash=?,input_path=? WHERE id=?",
            params![input.content_hash, input.path, id],
        )?;
        let t = task(&s.store, lib, &id)?;
        validate(s, &t)?;
        Ok(Some(t))
    })();
    match prepared {
        Ok(None) => Ok(json!({"task":null})),
        Ok(Some(t)) => Ok(json!({
        "task":{
        "taskID":t.id,"assetID":t.asset,"sourceHash":t.hash,"inputHash":t.input_hash,"filename":t.path.file_name().context("filename")?.to_str().context("filename utf8")?,"sizeBytes":fs::metadata(&t.path)?.len(),"mediaType":if media::is_video(&t.path) { "video" } else { "photo" },"generateStandard":needs_standard(&t),"generateBrowse":batch.is_some(),"deferred":deferred(&t),"thumbnailEdge":512,"thumbnailQuality":cache::thumbnail_quality()?,"leaseSeconds":if batch.is_some() { IMPORT_LEASE } else { LEASE }}
        }
        )),
        Err(e) => {
            fail_task(&s.store, lib, &id, &format!("{e:#}"))?;
            Err(e)
        }
    }
}
fn byte_range(value: &str, size: u64) -> Result<(u64, u64)> {
    ensure!(size > 0, "empty source");
    let (start, end) = value
        .strip_prefix("bytes=")
        .context("byte range required")?
        .split_once('-')
        .context("invalid byte range")?;
    if start.is_empty() {
        let suffix: u64 = end.parse()?;
        ensure!(suffix > 0, "empty suffix");
        return Ok((size.saturating_sub(suffix), size - 1));
    }
    let start: u64 = start.parse()?;
    let end = if end.is_empty() {
        size - 1
    } else {
        end.parse::<u64>()?.min(size - 1)
    };
    ensure!(start < size && end >= start, "range outside source");
    Ok((start, end))
}
async fn source(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let t = task(&s.store, &lib, &id)?;
    s.jobs
        .validate_path(t.path.parent().context("source parent")?)?;
    if fs::symlink_metadata(&t.path)
        .map_err(anyhow::Error::from)?
        .file_type()
        .is_symlink()
    {
        return Err(anyhow::anyhow!("source symlink forbidden").into());
    }
    let mut file = tokio::fs::File::open(&t.path)
        .await
        .map_err(anyhow::Error::from)?;
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let size = file.metadata().await.map_err(anyhow::Error::from)?.len();
    let range = headers.get("range").and_then(|v| v.to_str().ok());
    let selected = range.map(|v| byte_range(v, size)).transpose();
    let (start, end, partial) = match selected {
        Ok(Some((start, end))) => (start, end, true),
        Ok(None) if size > 0 => (0, size - 1, false),
        _ => {
            return Ok((
                StatusCode::RANGE_NOT_SATISFIABLE,
                [("content-range", format!("bytes */{size}"))],
            )
                .into_response());
        }
    };
    file.seek(std::io::SeekFrom::Start(start))
        .await
        .map_err(anyhow::Error::from)?;
    let length = end - start + 1;
    let mut response =
        Body::from_stream(tokio_util::io::ReaderStream::new(file.take(length))).into_response();
    *response.status_mut() = if partial {
        StatusCode::PARTIAL_CONTENT
    } else {
        StatusCode::OK
    };
    response
        .headers_mut()
        .insert("accept-ranges", "bytes".parse().unwrap());
    response
        .headers_mut()
        .insert("content-length", length.to_string().parse().unwrap());
    if partial {
        response.headers_mut().insert(
            "content-range",
            format!("bytes {start}-{end}/{size}").parse().unwrap(),
        );
    }
    Ok(response)
}
async fn heartbeat(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    run(move || {
        let t = task(&s.store, &lib, &id)?;
        let lease = task_lease(&*s.store.lock()?, &lib, &id)?;
        if t.completed == 0 {
            s.store.lock()?.execute(
                "UPDATE remote_cache_tasks SET expires_at=unixepoch()+? WHERE id=?",
                params![lease, id],
            )?;
        }
        Ok(json!({
        "ok":true,"leaseSeconds":lease}
        ))
    })
    .await
}
async fn upload(
    s: Arc<AppState>,
    lib: String,
    id: String,
    mut body: Body,
    role: &'static str,
) -> Result<Json<Value>, ApiError> {
    use http_body_util::BodyExt;
    use tokio::io::AsyncWriteExt;
    let t = task(&s.store, &lib, &id)?;
    if t.completed == 1 {
        return Ok(Json(json!({"ok":true})));
    }
    if role == "standard" && !needs_standard(&t) {
        return Err(anyhow::anyhow!("standard not requested").into());
    }
    let root = scratch(&s, &t)?;
    let file = tempfile::NamedTempFile::new_in(&root).map_err(anyhow::Error::from)?;
    let mut output = tokio::fs::File::from_std(file.reopen().map_err(anyhow::Error::from)?);
    let mut size = 0;
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(anyhow::Error::from)?;
        if let Ok(bytes) = frame.into_data() {
            size += bytes.len();
            if size > 256 * 1024 * 1024 {
                return Err(anyhow::anyhow!("upload exceeds 256 MiB").into());
            }
            output
                .write_all(&bytes)
                .await
                .map_err(anyhow::Error::from)?;
        }
    }
    output.flush().await.map_err(anyhow::Error::from)?;
    drop(output);
    run(move || {
        task(&s.store, &lib, &id)?;
        let mut header = [0u8; 12];
        use std::io::Read;
        fs::File::open(file.path())?.read_exact(&mut header)?;
        ensure!(
            &header[4..8] == b"ftyp"
                && [b"heic", b"heix", b"mif1"]
                    .iter()
                    .any(|brand| brand.as_slice() == &header[8..12]),
            "HEIC required"
        );
        file.persist(root.join(format!("{role}.heic")))
            .map_err(|e| e.error)?;
        Ok(json!({"ok":true}))
    })
    .await
}
async fn thumbnail(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    body: Body,
) -> Result<Json<Value>, ApiError> {
    upload(s, lib, id, body, "thumbnail").await
}
async fn browse(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    body: Body,
) -> Result<Json<Value>, ApiError> {
    upload(s, lib, id, body, "browse").await
}
async fn standard(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    body: Body,
) -> Result<Json<Value>, ApiError> {
    upload(s, lib, id, body, "standard").await
}
async fn complete(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    run(move || complete_sync(&s, &lib, &id)).await
}
fn complete_sync(s: &AppState, lib: &str, id: &str) -> Result<Value> {
    let _directory_guard = s.jobs.directory_mutation.read().unwrap();
    crate::directory_move::ensure_reconciled(&s.jobs)?;
    let _guard = COMMIT
        .lock()
        .map_err(|_| anyhow::anyhow!("worker commit poisoned"))?;
    let t = task(&s.store, lib, id)?;
    if t.completed == 1 {
        let root = scratch(s, &t)?;
        let browse = root.join("browse.heic");
        if browse.exists() {
            let thumbnail = s.store.media_snapshot(lib, &t.asset)?["thumbnail"].clone();
            let bm = MediaProcessor::new().extract(&browse)?;
            ensure!(
                bm.width > 0 && bm.height > 0 && bm.width <= 64 && bm.height <= 64,
                "invalid browse thumbnail"
            );
            let hash = media::sha256_file(&browse)?;
            let object = s
                .previews
                .put_generated_role(lib, &t.asset, &hash, &browse, "browse")?;
            let version = thumbnail["version"].as_str().context("thumbnail version")?;
            let descriptor = json!({"objectRef":object,"width":bm.width,"height":bm.height,"sizeBytes":fs::metadata(&browse)?.len(),"version":format!("{}:{}",crate::browse_cache::SPEC,hash),"spec":crate::browse_cache::SPEC,"sourceThumbnailVersion":version});
            crate::browse_cache::publish(&s.store, lib, &t.asset, &t.hash, version, &descriptor)?;
        }
        fs::remove_dir_all(root)?;
        return Ok(json!({"ok":true}));
    }
    {
        let db = s.store.lock()?;
        let lease = task_lease(&db, lib, id)?;
        db.execute(
            "UPDATE remote_cache_tasks SET expires_at=unixepoch()+? WHERE id=? AND completed=0",
            params![lease, id],
        )?;
    }
    ensure!(
        s.jobs.folders()?.iter().any(|folder| folder.active
            && folder.library_id == lib
            && t.path.starts_with(&folder.path)),
        "source directory is no longer tracked"
    );
    validate(s, &t)?;
    let root = scratch(s, &t)?;
    let thumb = root.join("thumbnail.heic");
    let tm = MediaProcessor::new().extract(&thumb)?;
    ensure!(
        tm.width > 0 && tm.height > 0 && tm.width <= 512 && tm.height <= 512,
        "invalid thumbnail"
    );
    let standard = if needs_standard(&t) {
        let target = s
            .store
            .generated_standard_target(lib, &t.asset, &t.path, &t.input_hash)?;
        if !target.exists() {
            ensure!(
                cache::free_bytes(t.path.parent().context("parent")?)? > 2 * 1024 * 1024 * 1024,
                "standard disk low"
            );
            let uploaded = root.join("standard.heic");
            let m = MediaProcessor::new().extract(&uploaded)?;
            ensure!(m.width > 0 && m.height > 0, "image dimensions missing");
            let original = MediaProcessor::new().extract(&t.path)?;
            ensure!(
                m.width.max(m.height) >= original.width.max(original.height) * 9 / 10
                    && m.width.min(m.height) >= original.width.min(original.height) * 9 / 10,
                "standard photo is smaller than source dimensions"
            );
            let staging = tempfile::tempdir_in(t.path.parent().context("parent")?)?;
            let staged = staging.path().join("standard.heic");
            fs::copy(&uploaded, &staged)?;
            crate::identity::generated(&staged, &s.store.root_id(lib, &t.asset)?)?;
            s.store.publish_generated_standard(
                lib,
                &t.asset,
                &t.input_hash,
                &staged,
                &target,
                (m.width, m.height),
            )?;
        }
        ensure!(
            s.store.generated_standard_matches(lib, &t.asset, &target)?,
            "existing standard is not owned by this asset"
        );
        target
    } else {
        t.path.clone()
    };
    let sm = MediaProcessor::new().extract(&standard)?;
    let hash = media::sha256_file(&thumb)?;
    let object = s
        .previews
        .put_generated_role(lib, &t.asset, &hash, &thumb, "thumbnail")?;
    let thumbnail_descriptor = json!({
        "objectRef": object, "width": tm.width, "height": tm.height,
        "version": format!("{}{}:{}",if media::is_video(&t.path) { "video-v3:" } else { "" },cache::spec()?,hash),
        "sizeBytes":fs::metadata(&thumb)?.len()
    });
    let standard_descriptor = json!({
        "path":standard,"width":sm.width,"height":sm.height,
        "version":media::sha256_file(&standard)?,"sizeBytes":fs::metadata(&standard)?.len(),
        "mtimeNs":cache::file_mtime(&standard)?,"deferred":deferred(&t)
    });
    let browse_path = root.join("browse.heic");
    let reserved: bool = s.store.lock()?.query_row(
        "SELECT EXISTS(SELECT 1 FROM import_compute_leases WHERE library_id=? AND path=?)",
        params![lib, t.path.to_string_lossy()],
        |r| r.get(0),
    )?;
    ensure!(
        !reserved || browse_path.exists(),
        "import browse thumbnail required"
    );
    let browse_descriptor = if browse_path.exists() {
        let bm = MediaProcessor::new().extract(&browse_path)?;
        ensure!(
            bm.width > 0 && bm.height > 0 && bm.width <= 64 && bm.height <= 64,
            "invalid browse thumbnail"
        );
        let bh = media::sha256_file(&browse_path)?;
        let object = s
            .previews
            .put_generated_role(lib, &t.asset, &bh, &browse_path, "browse")?;
        Some(
            json!({"objectRef":object,"width":bm.width,"height":bm.height,"sizeBytes":fs::metadata(&browse_path)?.len(),"version":format!("{}:{}",crate::browse_cache::SPEC,bh),"spec":crate::browse_cache::SPEC,"sourceThumbnailVersion":thumbnail_descriptor["version"]}),
        )
    } else {
        None
    };
    s.store.cache_publish(
        lib,
        &t.asset,
        &t.hash,
        &thumbnail_descriptor,
        &standard_descriptor,
    )?;
    ensure!(
        task(&s.store, lib, id)?.completed == 1,
        "source changed before publication"
    );
    if let Some(descriptor) = browse_descriptor {
        crate::browse_cache::publish(
            &s.store,
            lib,
            &t.asset,
            &t.hash,
            thumbnail_descriptor["version"]
                .as_str()
                .context("thumbnail version")?,
            &descriptor,
        )?;
    }
    fs::remove_dir_all(root)?;
    Ok(json!({"ok":true}))
}
fn fail_task(store: &Store, lib: &str, id: &str, error: &str) -> Result<()> {
    let mut db = store.lock()?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let source: Option<(String,String)> = tx.query_row("SELECT asset_id,source_hash FROM remote_cache_tasks WHERE id=? AND library_id=? AND completed=0 AND expires_at>unixepoch()", params![id,lib],|row| Ok((row.get(0)?,row.get(1)?))).optional()?;
    let (asset, hash) = source.ok_or_else(conflict)?;
    cache::record_failure(&tx, lib, &asset, &hash, error)?;
    tx.execute(
        "UPDATE remote_cache_tasks SET completed=-1 WHERE id=?",
        [id],
    )?;
    tx.commit()?;
    Ok(())
}
async fn fail(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, ApiError> {
    run(move || {
        let _guard = COMMIT
            .lock()
            .map_err(|_| anyhow::anyhow!("worker commit poisoned"))?;
        let t = task(&s.store, &lib, &id)?;
        if t.completed == 0 {
            let error = body["error"].as_str().context("error required")?;
            fail_task(&s.store, &lib, &id, error)?;
            let root = scratch(&s, &t)?;
            fs::remove_dir_all(root)?;
        }
        Ok(json!({"ok":true}))
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_io_allows_catalog_edits_but_cache_claim_waits_for_new_hash() -> Result<()> {
        use std::sync::{Arc, mpsc};
        use std::time::Duration;
        let dir = tempfile::tempdir()?;
        let store = Arc::new(Store::open(&dir.path().join("db"), true)?);
        let id = store.ingest_original("lib", "/photo.jpg",
            &json!({"contentHash":"old-hash","sizeBytes":8,"role":"jpeg_original"}),
            &json!({"contentFingerprint":"old-hash","metadataFingerprint":"fp","createdAt":"2024-01-01","originalFilename":"photo.jpg","rating":0,"flagState":"unflagged","tags":[]}))?;
        store.reconcile_cache()?;
        let (started_tx, started_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let identity = std::thread::spawn({
            let store = store.clone();
            move || {
                store.with_identity_update("lib", "/photo.jpg", "old-hash", || {
                    started_tx.send(())?;
                    release_rx.recv_timeout(Duration::from_secs(5))?;
                    Ok(Some(("new-hash".into(), 9, "2".into())))
                })
            }
        });
        started_rx.recv_timeout(Duration::from_secs(2))?;
        let (claimed_tx, claimed_rx) = mpsc::channel();
        let claim = std::thread::spawn({
            let store = store.clone();
            move || {
                claimed_tx
                    .send(claim_pending(&store, "lib", "test-worker"))
                    .unwrap();
            }
        });
        let (patched_tx, patched_rx) = mpsc::channel();
        let foreground = std::thread::spawn({
            let (store, id) = (store.clone(), id.clone());
            move || {
                let result = store
                    .patch_asset("lib", &id, &json!({"rating":5}))
                    .and_then(|_| store.asset("lib", &id));
                patched_tx.send(result).unwrap();
            }
        });
        let patched = patched_rx.recv_timeout(Duration::from_secs(2));
        let claim_blocked = matches!(
            claimed_rx.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        );
        release_tx.send(())?;
        assert!(identity.join().unwrap()?);
        foreground.join().unwrap();
        claim.join().unwrap();
        assert_eq!(patched??["rating"], 5);
        assert!(
            claim_blocked,
            "cache claim must wait while the source is changing"
        );
        let (_, asset, hash) = claimed_rx
            .recv_timeout(Duration::from_secs(2))??
            .context("cache claim")?;
        assert_eq!(asset, id);
        assert_eq!(hash, "new-hash");
        assert_eq!(store.asset("lib", &id)?["rating"], 5);
        Ok(())
    }

    #[test]
    fn remote_workers_require_explicit_enablement() -> Result<()> {
        for value in [None, Some("0"), Some("false")] {
            assert!(!remote_worker_enabled(value)?);
        }
        for value in [Some("1"), Some("true")] {
            assert!(remote_worker_enabled(value)?);
        }
        assert!(remote_worker_enabled(Some("yes")).is_err());
        Ok(())
    }
    #[test]
    fn single_byte_ranges_support_ffmpeg_seeking() -> Result<()> {
        assert_eq!(byte_range("bytes=0-99", 1000)?, (0, 99));
        assert_eq!(byte_range("bytes=800-", 1000)?, (800, 999));
        assert_eq!(byte_range("bytes=-100", 1000)?, (900, 999));
        assert_eq!(byte_range("bytes=900-2000", 1000)?, (900, 999));
        for invalid in ["bytes=1000-", "bytes=9-2", "bytes=0-1,5-6", "bytes=-0"] {
            assert!(byte_range(invalid, 1000).is_err());
        }
        Ok(())
    }
    fn setup() -> Result<(tempfile::TempDir, Store)> {
        let root = tempfile::tempdir()?;
        let store = Store::open(&root.path().join("db.sqlite"), true)?;
        store.lock()?.execute("INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES('lib','asset','{}','hash','fingerprint','2024-01-01','photo.jpg',0,'none',NULL,0)",[])?;
        store.reconcile_cache()?;
        store
            .lock()?
            .execute("UPDATE media_cache SET status='processing'", [])?;
        store.lock()?.execute("INSERT INTO remote_cache_tasks VALUES('task','lib','asset','hash','hash','/photo/test.jpg','worker',unixepoch()+1800,0)",[])?;
        Ok((root, store))
    }
    fn add_indexed_source(root: &std::path::Path, store: &Store) -> Result<()> {
        let source = root.join("photo.jpg");
        fs::write(&source, b"original")?;
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib',?,'asset','hash','jpeg_original')",
            [source.to_str().unwrap()],
        )?;
        Ok(())
    }
    fn pending_setup() -> Result<(tempfile::TempDir, Store)> {
        let (root, store) = setup()?;
        store
            .lock()?
            .execute("DELETE FROM remote_cache_tasks", [])?;
        store
            .lock()?
            .execute("UPDATE media_cache SET status='pending'", [])?;
        Ok((root, store))
    }
    #[test]
    fn schema_twelve_requires_explicit_migration_and_installs_import_leases() -> Result<()> {
        let root = tempfile::tempdir()?;
        let path = root.path().join("db.sqlite");
        let store = Store::open(&path, true)?;
        store.lock()?.execute("INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES('lib','asset','{}','hash','fp','2024-01-01','photo.jpg',0,'none',NULL,0)",[])?;
        store.reconcile_cache()?;
        store.lock()?.execute(
            "UPDATE media_cache SET status='ready',thumbnail=?",
            [json!({"version":"preserved"}).to_string()],
        )?;
        store
            .lock()?
            .execute_batch("DROP TABLE import_compute_leases; PRAGMA user_version=12;")?;
        drop(store);
        let error = Store::open(&path, false)
            .err()
            .context("old schema unexpectedly opened")?;
        assert!(format!("{error:#}").contains("database migration required"));
        let migrated = Store::open(&path, true)?;
        migrated.lock()?.prepare("SELECT library_id,batch_id,path,worker_id,expires_at FROM import_compute_leases LIMIT 0")?;
        let preserved: String=migrated.lock()?.query_row("SELECT json_extract(thumbnail,'$.version') FROM media_cache WHERE status='ready' AND asset_id='asset'",[],|r|r.get(0))?;
        assert_eq!(preserved, "preserved");
        drop(migrated);
        Store::open(&path, false)?;
        Ok(())
    }
    #[test]
    fn schema_thirteen_variants_preserve_edits_ai_state_and_import_leases() -> Result<()> {
        for imported_schema in [false, true] {
            let root = tempfile::tempdir()?;
            let path = root.path().join("db.sqlite");
            let store = Store::open(&path, true)?;
            store.lock()?.execute("INSERT INTO photo_edits VALUES('lib','asset','hash',1,'auto-v1','renderer-v1','{}','{}','{}',?)",[json!({"engine":"darktable","recipeJSON":"{}"}).to_string()])?;
            store.lock()?.execute("INSERT INTO photo_edit_requests VALUES('lib','asset','request','payload','response')",[])?;
            store.lock()?.execute(
                "INSERT INTO ai_editing_state VALUES('lib','settings',4,'settings-content')",
                [],
            )?;
            store.lock()?.execute(
                "INSERT INTO photo_edit_decisions VALUES('lib','asset','decision')",
                [],
            )?;
            if imported_schema {
                store.lock()?.execute_batch("ALTER TABLE photo_edits RENAME TO photo_edits_current; CREATE TABLE photo_edits(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,negative_hash TEXT NOT NULL,exposure_ev REAL NOT NULL,algorithm_version TEXT NOT NULL,renderer_version TEXT NOT NULL,standard TEXT NOT NULL,thumbnail TEXT NOT NULL,browse TEXT NOT NULL,PRIMARY KEY(library_id,asset_id)); INSERT INTO photo_edits SELECT library_id,asset_id,negative_hash,exposure_ev,algorithm_version,renderer_version,standard,thumbnail,browse FROM photo_edits_current; DROP TABLE photo_edits_current; DROP TABLE ai_editing_state; DROP TABLE photo_edit_decisions;")?;
                store.lock()?.execute("INSERT INTO import_compute_leases VALUES('lib','batch','/original/photo.jpg','mac',4000000000)",[])?;
            } else {
                store
                    .lock()?
                    .execute_batch("DROP TABLE import_compute_leases;")?;
            }
            store.lock()?.pragma_update(None, "user_version", 13)?;
            drop(store);
            let error = Store::open(&path, false)
                .err()
                .context("schema13 needs migration")?;
            assert!(format!("{error:#}").contains("database migration required"));
            let store = Store::open(&path, true)?;
            let db = store.lock()?;
            assert_eq!(
                db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))?,
                15
            );
            let edited: (f64, Option<String>) = db.query_row(
                "SELECT exposure_ev,recipe FROM photo_edits WHERE asset_id='asset'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            assert_eq!(edited.0, 1.0);
            assert_eq!(edited.1.is_some(), !imported_schema);
            assert_eq!(
                db.query_row("SELECT response FROM photo_edit_requests", [], |r| r
                    .get::<_, String>(0))?,
                "response"
            );
            if imported_schema {
                assert_eq!(
                    db.query_row("SELECT worker_id FROM import_compute_leases", [], |r| {
                        r.get::<_, String>(0)
                    })?,
                    "mac"
                );
            } else {
                assert_eq!(
                    db.query_row("SELECT content FROM ai_editing_state", [], |r| r
                        .get::<_, String>(0))?,
                    "settings-content"
                );
                assert_eq!(
                    db.query_row("SELECT metadata FROM photo_edit_decisions", [], |r| r
                        .get::<_, String>(0))?,
                    "decision"
                );
            }
            db.execute("UPDATE photo_edits SET exposure_ev=NULL,recipe='{}'", [])?;
            drop(db);
            drop(store);
            Store::open(&path, false)?;
        }
        Ok(())
    }
    #[test]
    fn import_claim_requires_live_owned_batch_and_excludes_global_workers() -> Result<()> {
        let (root, store) = pending_setup()?;
        add_indexed_source(root.path(), &store)?;
        store.lock()?.execute(
            "INSERT INTO import_compute_leases VALUES('lib','batch',?,'mac',unixepoch()+3600)",
            [root.path().join("photo.jpg").to_str().unwrap()],
        )?;
        assert!(claim_pending(&store, "lib", "other")?.is_none());
        assert!(claim_pending_scoped(&store, "lib", "mac", Some("other-batch"))?.is_none());
        assert!(claim_pending_scoped(&store, "lib", "other", Some("batch"))?.is_none());
        assert_eq!(
            claim_pending_scoped(&store, "lib", "mac", Some("batch"))?
                .unwrap()
                .1,
            "asset"
        );
        {
            let db = store.lock()?;
            let (id, remaining): (String, i64) = db.query_row(
                "SELECT id,expires_at-unixepoch() FROM remote_cache_tasks",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?;
            assert!((IMPORT_LEASE - 1..=IMPORT_LEASE).contains(&remaining));
            assert_eq!(task_lease(&db, "lib", &id)?, IMPORT_LEASE);
        }
        store
            .lock()?
            .execute("DELETE FROM remote_cache_tasks", [])?;
        store
            .lock()?
            .execute("UPDATE media_cache SET status='pending'", [])?;
        store.lock()?.execute(
            "UPDATE import_compute_leases SET expires_at=unixepoch()-1",
            [],
        )?;
        assert!(claim_pending_scoped(&store, "lib", "mac", Some("batch"))?.is_none());
        assert!(claim_pending(&store, "lib", "other")?.is_some());
        Ok(())
    }
    #[test]
    fn batch_claim_recovers_ready_preview_without_browse_after_worker_restart() -> Result<()> {
        let (root, store) = pending_setup()?;
        add_indexed_source(root.path(), &store)?;
        store.lock()?.execute(
            "INSERT INTO import_compute_leases VALUES('lib','batch',?,'mac',unixepoch()+3600)",
            [root.path().join("photo.jpg").to_str().unwrap()],
        )?;
        store.lock()?.execute(
            "UPDATE media_cache SET status='ready',thumbnail=?",
            [json!({"version":"preview"}).to_string()],
        )?;
        assert!(claim_pending(&store, "lib", "other")?.is_none());
        assert_eq!(
            claim_pending_scoped(&store, "lib", "mac", Some("batch"))?
                .unwrap()
                .1,
            "asset"
        );
        Ok(())
    }
    #[test]
    fn claims_skip_trashed_assets() -> Result<()> {
        let (_root, store) = pending_setup()?;
        store
            .lock()?
            .execute("UPDATE catalog_assets SET trashed=1", [])?;
        assert!(claim_pending(&store, "lib", "worker")?.is_none());
        Ok(())
    }
    #[test]
    fn directory_scan_keeps_ready_photo_remote_lease_until_that_photo_changes() -> Result<()> {
        let (root, store) = pending_setup()?;
        let originals = root.path().join("photos");
        fs::create_dir_all(&originals)?;
        let jobs = crate::jobs::Jobs::open(&root.path().join("jobs.sqlite"), &originals)?;
        let folder = jobs.add_folder("lib", ".")?;
        let source = jobs.root().join("photo.3fr");
        fs::write(&source, b"original")?;
        fs::write(jobs.root().join("other.3fr"), b"waiting for index")?;
        let info = fs::metadata(&source)?;
        jobs.record_file(
            &folder.id,
            source.to_str().unwrap(),
            info.len() as i64,
            info.modified()?
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos() as i64,
            "asset",
            "hash",
            None,
        )?;
        jobs.enqueue_directory_change(&folder.id, jobs.root(), 0)?;
        store.lock()?.execute("DELETE FROM catalog_paths", [])?;
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib',?,'asset','hash','raw_original')",
            [source.to_str().unwrap()],
        )?;
        let (_, asset, _) = claim_pending(&store, "lib", "worker")?.unwrap();
        assert!(!store.defer_cache_for_scan(&jobs, "lib", &asset)?);
        let remaining: i64 = store.lock()?.query_row(
            "SELECT count(*) FROM remote_cache_tasks WHERE completed=0",
            [],
            |r| r.get(0),
        )?;
        assert_eq!(remaining, 1);
        fs::write(source.with_extension("xmp"), b"new metadata")?;
        assert!(store.defer_cache_for_scan(&jobs, "lib", &asset)?);
        let remaining: i64 = store.lock()?.query_row(
            "SELECT count(*) FROM remote_cache_tasks WHERE completed=0",
            [],
            |r| r.get(0),
        )?;
        assert_eq!(remaining, 0);
        Ok(())
    }
    #[test]
    fn sibling_scan_revokes_remote_lease_before_encoding_existing_source() -> Result<()> {
        let (root, store) = pending_setup()?;
        let originals = root.path().join("photos");
        fs::create_dir_all(&originals)?;
        let source = originals.join("photo.3fr");
        fs::write(&source, b"original")?;
        let jobs = crate::jobs::Jobs::open(&root.path().join("jobs.sqlite"), &originals)?;
        let folder = jobs.add_folder("lib", ".")?;
        let originals = jobs.root().to_path_buf();
        let source = originals.join("photo.3fr");
        jobs.enqueue_file_change(&folder.id, &originals.join("photo.heic"), 0)?;
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib',?,'asset','hash','raw_original')",
            [source.to_str().unwrap()],
        )?;
        let (_, asset, _) = claim_pending(&store, "lib", "worker")?.unwrap();
        assert!(store.defer_cache_for_scan(&jobs, "lib", &asset)?);
        let remaining: i64 = store.lock()?.query_row(
            "SELECT count(*) FROM remote_cache_tasks WHERE completed=0",
            [],
            |r| r.get(0),
        )?;
        assert_eq!(remaining, 0);
        let attempts: i64 = store.lock()?.query_row(
            "SELECT attempts FROM media_cache WHERE asset_id='asset'",
            [],
            |r| r.get(0),
        )?;
        assert_eq!(attempts, 0);
        Ok(())
    }
    #[test]
    fn pending_path_sync_defers_missing_source_without_spending_attempts() -> Result<()> {
        let (root, store) = pending_setup()?;
        let originals = root.path().join("photos");
        fs::create_dir_all(originals.join("moved"))?;
        let jobs = crate::jobs::Jobs::open(&root.path().join("jobs.sqlite"), &originals)?;
        let folder = jobs.add_folder("lib", ".")?;
        let scope = jobs.root().join("moved");
        let missing = scope.join("photo.jpg");
        jobs.enqueue_path_change(&folder.id, &scope, 0)?;
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib',?,'asset','hash','jpeg_original')",
            [missing.to_str().unwrap()],
        )?;
        let state = AppState {
            previews: Arc::new(crate::previews::PreviewStorage::new(
                &root.path().join("keeps"),
                Some(&originals),
                "http://localhost",
                "test",
            )?),
            store: Arc::new(store),
            jobs: Arc::new(jobs),
            access_token: "test".into(),
            library_id: "lib".into(),
            original_root_names: Default::default(),
        };
        for disabled in [None, Some("0"), Some("false")] {
            assert_eq!(
                claim_sync(&state, "lib", json!({"workerID":"worker"}), disabled)?,
                json!({"task":null,"enabled":false})
            );
        }
        assert_eq!(
            state.store.lock()?.query_row(
                "SELECT status,attempts,available_at FROM media_cache WHERE asset_id='asset'",
                [],
                |r| Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?
                ))
            )?,
            ("pending".into(), 0, 0)
        );
        assert_eq!(
            state
                .store
                .lock()?
                .query_row("SELECT count(*) FROM remote_cache_tasks", [], |r| r
                    .get::<_, i64>(0))?,
            0
        );
        assert!(
            claim_sync(&state, "lib", json!({"workerID":"worker"}), Some("1"))?["task"].is_null()
        );
        let row = state.store.lock()?.query_row("SELECT status,attempts,last_error,available_at>unixepoch() FROM media_cache WHERE asset_id='asset'",[],|r|Ok((r.get::<_,String>(0)?,r.get::<_,i64>(1)?,r.get::<_,Option<String>>(2)?,r.get::<_,bool>(3)?)))?;
        assert_eq!(row, ("pending".into(), 0, None, true));
        assert_eq!(
            state.store.lock()?.query_row(
                "SELECT count(*) FROM remote_cache_tasks WHERE completed=0",
                [],
                |r| r.get::<_, i64>(0)
            )?,
            0
        );
        state.store.lock()?.execute("INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES('lib','other','{}','otherhash','fp','2024-01-01','other.jpg',0,'none',NULL,0)",[])?;
        state.store.reconcile_cache()?;
        assert_eq!(
            claim_pending(&state.store, "lib", "worker")?.unwrap().1,
            "other"
        );
        Ok(())
    }

    #[test]
    fn claims_skip_processing_and_not_yet_available_work() -> Result<()> {
        for change in ["status='processing'", "available_at=unixepoch()+60"] {
            let (_root, store) = pending_setup()?;
            store
                .lock()?
                .execute(&format!("UPDATE media_cache SET {change}"), [])?;
            assert!(claim_pending(&store, "lib", "worker")?.is_none());
            assert_eq!(
                store
                    .lock()?
                    .query_row("SELECT count(*) FROM remote_cache_tasks", [], |r| r
                        .get::<_, i64>(0))?,
                0
            );
        }
        Ok(())
    }
    #[test]
    fn concurrent_claims_lease_each_asset_once() -> Result<()> {
        let (_root, store) = pending_setup()?;
        for i in 0..24 {
            store.lock()?.execute("INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) SELECT library_id,?1,snapshot,?1,?1,sort_time,filename,rating,flag,color,trashed FROM catalog_assets WHERE id='asset'", [format!("asset-{i}")])?;
        }
        store.reconcile_cache()?;
        let store = Arc::new(store);
        let threads: Vec<_> = (0..4)
            .map(|_| {
                let store = store.clone();
                std::thread::spawn(move || -> Result<Vec<String>> {
                    let mut assets = Vec::new();
                    while let Some((_, asset, _)) = claim_pending(&store, "lib", "worker")? {
                        assets.push(asset);
                    }
                    Ok(assets)
                })
            })
            .collect();
        let mut assets = Vec::new();
        for thread in threads {
            assets.extend(thread.join().unwrap()?);
        }
        assert_eq!(assets.len(), 25);
        assets.sort();
        assets.dedup();
        assert_eq!(assets.len(), 25);
        Ok(())
    }
    #[test]
    fn startup_preserves_active_lease_and_expiry_requeues_once() -> Result<()> {
        let (_root, store) = setup()?;
        add_indexed_source(_root.path(), &store)?;
        store.recover_cache()?;
        assert!(task(&store, "lib", "task").is_ok());
        store
            .lock()?
            .execute("UPDATE remote_cache_tasks SET expires_at=0", [])?;
        assert!(task(&store, "lib", "task").is_err());
        expire(&*store.lock()?)?;
        assert_eq!(store.cache_status("lib")?["counts"]["pending"], 1);
        store
            .lock()?
            .execute("UPDATE media_cache SET status='processing'", [])?;
        expire(&*store.lock()?)?;
        assert_eq!(store.cache_status("lib")?["counts"]["processing"], 1);
        Ok(())
    }
    #[test]
    fn publish_commits_receipt_with_cache_and_retry_survives_expiry() -> Result<()> {
        let (_root, store) = setup()?;
        let thumbnail = json!({"objectRef":{"bucket":"keeps-previews","key":"lib/asset/thumbnail/hash.heic"},"width":10,"height":10});
        store.cache_publish("lib", "asset", "hash", &thumbnail, &json!({}))?;
        assert_eq!(task(&store, "lib", "task")?.completed, 1);
        store
            .lock()?
            .execute("UPDATE remote_cache_tasks SET expires_at=0", [])?;
        assert_eq!(task(&store, "lib", "task")?.completed, 1);
        assert_eq!(store.cache_status("lib")?["counts"]["ready"], 1);
        Ok(())
    }
    #[test]
    fn expired_fourth_attempt_is_failed_and_stale_failure_cannot_touch_replacement() -> Result<()> {
        let (_root, store) = setup()?;
        add_indexed_source(_root.path(), &store)?;
        store
            .lock()?
            .execute("UPDATE media_cache SET attempts=4", [])?;
        store
            .lock()?
            .execute("UPDATE remote_cache_tasks SET expires_at=0", [])?;
        expire(&*store.lock()?)?;
        assert_eq!(store.cache_status("lib")?["counts"]["failed"], 1);
        store
            .lock()?
            .execute("UPDATE media_cache SET status='processing'", [])?;
        assert!(fail_task(&store, "lib", "task", "late error").is_err());
        assert_eq!(store.cache_status("lib")?["counts"]["processing"], 1);
        Ok(())
    }
    #[test]
    fn stale_failure_and_expiry_preserve_replacement_cache() -> Result<()> {
        for expired in [false, true] {
            let (_root, store) = setup()?;
            store.lock()?.execute("UPDATE media_cache SET source_hash='replacement',status='processing',attempts=2,last_error='current error',available_at=123",[])?;
            if expired {
                store
                    .lock()?
                    .execute("UPDATE remote_cache_tasks SET expires_at=0", [])?;
                expire(&*store.lock()?)?;
            } else {
                fail_task(&store, "lib", "task", "stale error")?;
            }
            let row=store.lock()?.query_row("SELECT source_hash,status,attempts,last_error,available_at FROM media_cache WHERE asset_id='asset'",[],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,i64>(2)?,r.get::<_,String>(3)?,r.get::<_,i64>(4)?)))?;
            assert_eq!(
                row,
                (
                    "replacement".into(),
                    "processing".into(),
                    2,
                    "current error".into(),
                    123
                )
            );
            assert_eq!(
                store.lock()?.query_row(
                    "SELECT completed FROM remote_cache_tasks WHERE id='task'",
                    [],
                    |r| r.get::<_, i64>(0)
                )?,
                -1
            );
        }
        Ok(())
    }
    #[test]
    fn missing_indexed_source_ends_remote_failure_without_retry() -> Result<()> {
        for expired in [false, true] {
            let (_root, store) = setup()?;
            if expired {
                store
                    .lock()?
                    .execute("UPDATE remote_cache_tasks SET expires_at=0", [])?;
                expire(&*store.lock()?)?;
            } else {
                fail_task(&store, "lib", "task", "no indexed source")?;
            }
            assert_eq!(
                store.lock()?.query_row(
                    "SELECT status FROM media_cache WHERE asset_id='asset'",
                    [],
                    |r| r.get::<_, String>(0)
                )?,
                "cancelled"
            );
            assert!(claim_pending(&store, "lib", "worker")?.is_none());
        }
        Ok(())
    }
    #[test]
    fn replaced_source_rejects_old_lease() -> Result<()> {
        let (_root, store) = setup()?;
        store
            .lock()?
            .execute("UPDATE media_cache SET source_hash='other'", [])?;
        assert!(task(&store, "lib", "task").is_err());
        Ok(())
    }
}
