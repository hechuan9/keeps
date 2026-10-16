//! Immutable offline exports: a point-in-time client catalog and its available small images.
use crate::{
    api::{ApiError, AppState},
    store::StoreError,
};
use anyhow::{Context, Result, ensure};
use axum::{
    Json, Router,
    extract::{Path, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path as FsPath, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use uuid::Uuid;

const RETENTION_SECONDS: i64 = 48 * 60 * 60;
const CLIENT_SCHEMA: &str = "CREATE TABLE assets(id TEXT PRIMARY KEY,snapshot TEXT NOT NULL,sort_time TEXT NOT NULL,filename TEXT NOT NULL,camera TEXT NOT NULL,rating INTEGER NOT NULL,flag TEXT NOT NULL,color TEXT,trashed INTEGER NOT NULL);
CREATE INDEX assets_sort ON assets(trashed,sort_time DESC,id);
CREATE TABLE paths(asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,path TEXT NOT NULL,PRIMARY KEY(asset_id,path));
CREATE INDEX paths_path ON paths(path,asset_id);
CREATE TABLE seen(id TEXT PRIMARY KEY); CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE hidden(path TEXT PRIMARY KEY); CREATE TABLE navigation(path TEXT PRIMARY KEY,snapshot TEXT NOT NULL);";

#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct Status {
    id: String,
    state: String,
    phase: String,
    completed: i64,
    total: i64,
    revision: Option<i64>,
    byte_count: Option<i64>,
    sha256: Option<String>,
    error: Option<String>,
    #[serde(default)]
    created_at: i64,
    #[serde(default = "yes")]
    include_thumbnails: bool,
    #[serde(default)]
    request: SyncRequest,
    #[serde(default)]
    from_revision: Option<i64>,
    #[serde(default)]
    generation: Option<String>,
    #[serde(skip)]
    last_progress_save: Option<Instant>,
}
fn yes() -> bool {
    true
}
#[derive(Clone, Default, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyncRequest {
    #[serde(rename = "replicaID")]
    replica_id: Option<Uuid>,
    generation: Option<Uuid>,
    since_revision: Option<i64>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BuildRequest {
    #[serde(flatten)]
    sync: SyncRequest,
    #[serde(default = "yes")]
    include_thumbnails: bool,
}
struct Manager {
    app: Arc<AppState>,
    root: PathBuf,
    initialized: Mutex<bool>,
}

pub fn router(app: Arc<AppState>) -> Router<Arc<AppState>> {
    let manager = Arc::new(Manager {
        root: app
            .previews
            .keeps_root()
            .join("tmp/offline-rebuild")
            .join(format!("{:x}", Sha256::digest(app.library_id.as_bytes()))),
        app,
        initialized: Mutex::new(false),
    });
    Router::new()
        .route("/libraries/{library}/replicas/{replica}/ack", post(ack))
        .route("/libraries/{library}/offline-rebuild", post(start))
        .route("/libraries/{library}/offline-rebuild/{id}", get(status))
        .route(
            "/libraries/{library}/offline-rebuild/{id}/download",
            get(download),
        )
        .with_state(manager)
}
fn missing() -> anyhow::Error {
    StoreError {
        status: 404,
        code: "offline_rebuild_not_found".into(),
        message: "offline rebuild not found".into(),
    }
    .into()
}
impl Manager {
    fn directory(&self, id: &str) -> Result<PathBuf> {
        let id = Uuid::parse_str(id).map_err(|_| missing())?;
        Ok(self.root.join(id.to_string()))
    }
    fn save(&self, status: &Status) -> Result<()> {
        let dir = self.directory(&status.id)?;
        fs::create_dir_all(&dir)?;
        let mut temporary = tempfile::NamedTempFile::new_in(&dir)?;
        serde_json::to_writer(&mut temporary, status)?;
        temporary.as_file().sync_all()?;
        temporary.persist(dir.join("status.json"))?;
        Ok(())
    }
    fn load(&self, id: &str) -> Result<Status> {
        let path = self.directory(id)?.join("status.json");
        if !path.is_file() {
            return Err(missing());
        }
        Ok(serde_json::from_reader(fs::File::open(path)?)?)
    }
    fn initialize(&self, initialized: &mut bool) -> Result<()> {
        if *initialized {
            return Ok(());
        }
        fs::create_dir_all(&self.root)?;
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if Uuid::parse_str(&name).is_err() {
                continue;
            }
            if !entry.path().join("status.json").is_file() {
                fs::remove_dir_all(entry.path()).context("remove unpublished offline export")?;
                continue;
            }
            let mut status = self.load(&name)?;
            if status.state == "building" {
                status.state = "failed".into();
                status.error = Some(
                    "Server restarted before offline rebuild completed; request a new rebuild"
                        .into(),
                );
                self.save(&status)?;
                for artifact in fs::read_dir(entry.path())? {
                    let artifact = artifact?;
                    if artifact.file_name() == "status.json" {
                        continue;
                    }
                    if artifact.file_type()?.is_dir() {
                        fs::remove_dir_all(artifact.path())?;
                    } else {
                        fs::remove_file(artifact.path())?;
                    }
                }
            }
        }
        *initialized = true;
        Ok(())
    }
    #[cfg(test)]
    fn begin(self: &Arc<Self>, include_thumbnails: bool) -> Result<Status> {
        self.begin_request(include_thumbnails, SyncRequest::default())
    }
    fn begin_request(
        self: &Arc<Self>,
        include_thumbnails: bool,
        request: SyncRequest,
    ) -> Result<Status> {
        let mut initialized = self
            .initialized
            .lock()
            .map_err(|_| anyhow::anyhow!("offline rebuild mutex poisoned"))?;
        self.initialize(&mut initialized)?;
        let mut previous = Vec::new();
        let mut building = 0;
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if Uuid::parse_str(&name).is_err() {
                continue;
            }
            let status = self.load(&name)?;
            if status.state == "building" {
                building += 1;
                if status.include_thumbnails == include_thumbnails && status.request == request {
                    return Ok(status);
                }
                if request.replica_id.is_some() && status.request.replica_id == request.replica_id {
                    return Err(StoreError {
                        status: 409,
                        code: "replica_sync_in_progress".into(),
                        message: "replica already has an unfinished sync package".into(),
                    }
                    .into());
                }
                continue;
            }
            if chrono::Utc::now().timestamp() - status.created_at > RETENTION_SECONDS {
                fs::remove_dir_all(entry.path()).context("remove expired offline export")?;
            } else if status.request.replica_id == request.replica_id {
                previous.push((status.created_at, entry.path()));
            }
        }
        previous.sort();
        let obsolete = previous.len().saturating_sub(1);
        for (_, path) in previous.into_iter().take(obsolete) {
            fs::remove_dir_all(path).context("remove superseded offline export")?;
        }
        if building >= 4 {
            return Err(StoreError {
                status: 409,
                code: "sync_capacity_busy".into(),
                message: "four sync packages are already building".into(),
            }
            .into());
        }
        let status = Status {
            id: Uuid::new_v4().to_string(),
            state: "building".into(),
            phase: "snapshot".into(),
            completed: 0,
            total: 1,
            revision: None,
            byte_count: None,
            sha256: None,
            error: None,
            created_at: chrono::Utc::now().timestamp(),
            include_thumbnails,
            request,
            from_revision: None,
            generation: None,
            last_progress_save: None,
        };
        self.save(&status)?;
        let manager = self.clone();
        let mut work = status.clone();
        crate::background::spawn("offline-rebuild", move || {
            if let Err(error) = manager.build(&mut work) {
                tracing::error!(error=?error, id=%work.id,"offline rebuild failed");
                work.state = "failed".into();
                work.error = Some(format!("{error:#}"));
                if let Err(error) = manager.save(&work) {
                    tracing::error!(error=?error,"persist failed offline rebuild");
                }
            }
            Ok(())
        })?;
        Ok(status)
    }
    fn remove_acknowledged_packages(&self, replica: Uuid, revision: i64) -> Result<()> {
        let _guard = self
            .initialized
            .lock()
            .map_err(|_| anyhow::anyhow!("offline rebuild mutex poisoned"))?;
        if !self.root.exists() {
            return Ok(());
        }
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if Uuid::parse_str(&name).is_err() {
                continue;
            }
            let status = self.load(&name)?;
            if status.request.replica_id == Some(replica)
                && status.state != "building"
                && status.revision.is_some_and(|r| r <= revision)
            {
                fs::remove_dir_all(entry.path()).context("remove acknowledged sync package")?;
            }
        }
        Ok(())
    }
    fn read_status(&self, id: &str) -> Result<Status> {
        let mut initialized = self
            .initialized
            .lock()
            .map_err(|_| anyhow::anyhow!("offline rebuild mutex poisoned"))?;
        self.initialize(&mut initialized)?;
        let status = self.load(id)?;
        if status.request.replica_id.is_some() && status.state == "ready" {
            let db = self.app.store.read()?;
            let current = crate::replicas::state(&db, &self.app.library_id)?.map(|s| s.0);
            if current != status.generation {
                return Err(StoreError {
                    status: 410,
                    code: "replica_rebuild_required".into(),
                    message: "sync package belongs to an obsolete library generation".into(),
                }
                .into());
            }
        }
        Ok(status)
    }
    fn progress(&self, status: &mut Status, phase: &str, completed: i64, total: i64) -> Result<()> {
        let phase_changed = status.phase != phase;
        status.phase = phase.into();
        status.completed = completed;
        status.total = total;
        if phase_changed
            || completed >= total
            || status
                .last_progress_save
                .is_none_or(|last| last.elapsed() >= Duration::from_secs(1))
        {
            self.save(status)?;
            status.last_progress_save = Some(Instant::now());
        }
        Ok(())
    }
    fn build(&self, status: &mut Status) -> Result<()> {
        let dir = self.directory(&status.id)?;
        let work = tempfile::tempdir_in(&dir)?;
        let source_path = {
            let mut db = self.app.store.lock()?;
            let tx = db.transaction()?;
            crate::replicas::initialize(&tx, &self.app.library_id)?;
            crate::replicas::prune(&tx, &self.app.library_id, chrono::Utc::now().timestamp())?;
            tx.commit()?;
            PathBuf::from(db.path().context("catalog must be a file")?)
        };
        let source = Connection::open_with_flags(source_path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        source.busy_timeout(Duration::from_secs(30))?;
        let navigation_guard = self
            .app
            .jobs
            .directory_mutation
            .read()
            .map_err(|_| anyhow::anyhow!("directory mutation lock poisoned"))?;
        crate::directory_move::ensure_reconciled(&self.app.jobs)?;
        crate::directory_trash::ensure_reconciled(&self.app.jobs)?;
        let revision = pin_read_snapshot(&source, &self.app.library_id)?;
        drop(navigation_guard);
        let generation = crate::replicas::state(&source, &self.app.library_id)?
            .context("sync state")?
            .0;
        status.generation = Some(generation.clone());
        status.from_revision = match (
            &status.request.replica_id,
            &status.request.generation,
            status.request.since_revision,
        ) {
            (Some(replica), Some(generation), Some(since))
                if crate::replicas::can_delta(
                    &source,
                    &self.app.library_id,
                    &replica.to_string(),
                    &generation.to_string(),
                    since,
                    chrono::Utc::now().timestamp(),
                )? =>
            {
                Some(since)
            }
            _ => None,
        };
        if status.from_revision.is_some() {
            status.include_thumbnails = false;
        }
        let mut frozen = if status.from_revision.is_none() {
            Some(Connection::open(work.path().join("source.sqlite"))?)
        } else {
            None
        };
        if let Some(frozen) = frozen.as_mut() {
            let backup = rusqlite::backup::Backup::new(&source, frozen)?;
            loop {
                let step = backup.step(2048)?;
                let progress = backup.progress();
                self.progress(
                    status,
                    "snapshot",
                    i64::from(progress.pagecount - progress.remaining),
                    i64::from(progress.pagecount),
                )?;
                match step {
                    rusqlite::backup::StepResult::Done => break,
                    rusqlite::backup::StepResult::More => (),
                    _ => anyhow::bail!("snapshot backup could not continue: {step:?}"),
                }
            }
        }
        if frozen.is_some() {
            source.execute_batch("ROLLBACK")?;
        }
        let export = frozen.as_ref().unwrap_or(&source);
        let lib = &self.app.library_id;
        status.revision = Some(revision);
        let total:i64=export.query_row("SELECT count(*) FROM catalog_assets a WHERE library_id=? AND EXISTS(SELECT 1 FROM catalog_paths p WHERE p.library_id=a.library_id AND p.asset_id=a.id)",[lib],|r|r.get(0))?;
        self.progress(status, "catalog", 0, total)?;
        let mut target = Connection::open(work.path().join("catalog.sqlite"))?;
        target.execute_batch(CLIENT_SCHEMA)?;
        let thumbnails = self.catalog(export, &mut target, status)?;
        let mut manifest = json!({"formatVersion":1,"libraryID":lib,"revision":revision,"assetCount":total,"thumbnailCount":total,"missingThumbnailCount":total,"browseThumbnailCount":total,"missingBrowseThumbnailCount":total});
        if status.request.replica_id.is_some() {
            manifest["formatVersion"] = json!(2);
            manifest["mode"] = json!(if status.from_revision.is_some() {
                "delta"
            } else {
                "snapshot"
            });
            manifest["generation"] = json!(generation);
            manifest["fromRevision"] = json!(status.from_revision);
        }
        drop(target);
        drop(frozen);
        if !source.is_autocommit() {
            source.execute_batch("ROLLBACK")?;
        }
        drop(source);
        let archive_total = fs::metadata(work.path().join("catalog.sqlite"))?.len()
            + thumbnails
                .iter()
                .filter_map(|(_, _, path)| fs::metadata(path).ok().map(|meta| meta.len()))
                .sum::<u64>();
        self.progress(status, "archive", 0, archive_total as i64)?;
        let archive = fs::File::create(work.path().join("library.tar"))?;
        let mut tar = tar::Builder::new(archive);
        // Reserve enough JSON space for either count, then fill in the actual packed count.
        let manifest_size = serde_json::to_vec(&manifest)?.len();
        append_bytes(&mut tar, "manifest.json", &vec![b' '; manifest_size])?;
        let mut packed = 0;
        let mut last_report = 0;
        let mut report = |count: usize| -> std::io::Result<()> {
            packed += count as u64;
            if packed - last_report >= 8 * 1024 * 1024 || packed == archive_total {
                self.progress(status, "archive", packed as i64, archive_total as i64)
                    .map_err(std::io::Error::other)?;
                last_report = packed;
            }
            Ok(())
        };
        append_file(
            &mut tar,
            "catalog.sqlite",
            &work.path().join("catalog.sqlite"),
            &mut report,
        )?;
        let mut thumbnail_count = 0;
        let mut browse_count = 0;
        for (directory, id, path) in &thumbnails {
            if append_optional_image(&mut tar, directory, id, path, &mut report)? {
                if *directory == "thumbnails" {
                    thumbnail_count += 1;
                } else {
                    browse_count += 1;
                }
            }
        }
        let mut archive = tar.into_inner()?;
        manifest["thumbnailCount"] = json!(thumbnail_count);
        manifest["missingThumbnailCount"] = json!(total - thumbnail_count);
        manifest["browseThumbnailCount"] = json!(browse_count);
        manifest["missingBrowseThumbnailCount"] = json!(total - browse_count);
        let mut bytes = serde_json::to_vec(&manifest)?;
        ensure!(
            bytes.len() <= manifest_size,
            "manifest exceeds reserved space"
        );
        bytes.resize(manifest_size, b' ');
        archive.seek(SeekFrom::Start(512))?;
        archive.write_all(&bytes)?;
        archive.sync_all()?;
        let mut file = fs::File::open(work.path().join("library.tar"))?;
        let length = file.metadata()?.len();
        let mut hash = Sha256::new();
        let mut buffer = vec![0; 1024 * 1024];
        self.progress(status, "verifying", 0, length as i64)?;
        let mut read = 0;
        loop {
            let count = file.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            hash.update(&buffer[..count]);
            read += count;
            if read % (32 * 1024 * 1024) < count {
                self.progress(status, "verifying", read as i64, length as i64)?;
            }
        }
        status.sha256 = Some(format!("{:x}", hash.finalize()));
        status.byte_count = Some(length as i64);
        fs::rename(work.path().join("library.tar"), dir.join("library.tar"))?;
        if let Some(replica) = &status.request.replica_id {
            let mut db = self.app.store.lock()?;
            let tx = db.transaction()?;
            crate::replicas::delivered(
                &tx,
                lib,
                &replica.to_string(),
                &generation,
                revision,
                chrono::Utc::now().timestamp(),
            )?;
            tx.commit()?;
        }
        status.state = "ready".into();
        self.progress(status, "ready", length as i64, length as i64)?;
        Ok(())
    }
    fn catalog(
        &self,
        source: &Connection,
        target: &mut Connection,
        status: &mut Status,
    ) -> Result<Vec<(&'static str, String, PathBuf)>> {
        let lib = &self.app.library_id;
        let tx = target.transaction()?;
        let mut paths = source.prepare(
            // ORDER BY otherwise makes SQLite scan every path in the library for each asset.
            "SELECT path FROM catalog_paths INDEXED BY catalog_paths_asset WHERE library_id=? AND asset_id=? ORDER BY path",
        )?;
        let mut thumbnails = Vec::new();
        let selection = if status.from_revision.is_some() {
            "a.id IN (SELECT asset_id FROM catalog_sync_assets WHERE library_id=?1 AND revision>?4 AND deleted=0)"
        } else {
            "?4 IS NULL"
        };
        let mut statement=source.prepare(&format!("SELECT a.id,a.snapshot,coalesce(e.thumbnail,c.thumbnail),coalesce(e.standard,c.standard),coalesce(e.browse,CASE WHEN c.browse_source_version=json_extract(c.thumbnail,'$.version') AND c.browse_spec=?3 AND json_extract(c.browse_thumbnail,'$.sourceThumbnailVersion')=c.browse_source_version AND json_extract(c.browse_thumbnail,'$.spec')=c.browse_spec THEN c.browse_thumbnail END),a.negative_hash FROM catalog_assets a LEFT JOIN photo_edits e ON e.library_id=a.library_id AND e.asset_id=a.id LEFT JOIN catalog_defaults d ON d.library_id=a.library_id AND d.asset_id=a.id LEFT JOIN media_cache c ON c.library_id=a.library_id AND c.asset_id=a.id AND c.status='ready' AND c.source_hash=coalesce(d.content_hash,a.content_hash) AND c.spec=?2 WHERE a.library_id=?1 AND EXISTS(SELECT 1 FROM catalog_paths p WHERE p.library_id=a.library_id AND p.asset_id=a.id) AND {selection} ORDER BY a.id"))?;
        let rows = statement.query_map(
            params![
                lib,
                crate::cache_pipeline::spec()?,
                crate::browse_cache::SPEC,
                status.from_revision
            ],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, Option<String>>(5)?,
                ))
            },
        )?;
        for (index, row) in rows.enumerate() {
            let (id, snapshot, thumbnail, standard, browse, negative) = row?;
            let mut asset: Value = serde_json::from_str(&snapshot)?;
            let upper = Uuid::parse_str(&id)?.to_string().to_uppercase();
            let asset_paths = paths
                .query_map(params![lib, id], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            asset["id"] = json!(upper);
            asset["paths"] = json!(asset_paths);
            asset["negativeContentHash"] = json!(negative);
            asset["preview"] = Value::Null;
            asset["thumbnail"] = Value::Null;
            asset["browseThumbnail"] = Value::Null;
            asset["standard"] = Value::Null;
            if let Some(thumbnail) = thumbnail {
                let thumbnail: Value = serde_json::from_str(&thumbnail)?;
                let path = self.app.previews.object_path(&thumbnail["objectRef"])?;
                asset["thumbnail"] = json!({"downloadURL":self.app.previews.download_url(&thumbnail["objectRef"])?,"width":thumbnail["width"],"height":thumbnail["height"],"version":thumbnail["version"]});
                if status.include_thumbnails {
                    thumbnails.push(("thumbnails", upper.clone(), path));
                }
            }
            if let Some(browse) = browse {
                let browse: Value = serde_json::from_str(&browse)?;
                asset["browseThumbnail"] = json!({"downloadURL":self.app.previews.download_url(&browse["objectRef"])?,"width":browse["width"],"height":browse["height"],"version":browse["version"]});
                if status.include_thumbnails {
                    thumbnails.push((
                        "browse-thumbnails",
                        upper.clone(),
                        self.app.previews.object_path(&browse["objectRef"])?,
                    ));
                }
            }
            if let Some(standard) = standard {
                asset["standard"] = crate::api::standard_descriptor(
                    &self.app,
                    lib,
                    &id,
                    &serde_json::from_str(&standard)?,
                )?;
            }
            tx.prepare_cached("INSERT INTO assets VALUES(?,?,?,?,?,?,?,?,?)")?
                .execute(params![
                    upper,
                    serde_json::to_string(&asset)?,
                    asset["captureTime"]
                        .as_str()
                        .or(asset["createdAt"].as_str())
                        .unwrap_or(""),
                    asset["originalFilename"].as_str().unwrap_or(""),
                    asset["cameraModel"].as_str().unwrap_or(""),
                    asset["rating"].as_i64().unwrap_or(0),
                    asset["flagState"].as_str().unwrap_or("unflagged"),
                    asset["colorLabel"].as_str(),
                    asset["trashed"].as_bool().unwrap_or(false)
                ])?;
            for path in asset_paths {
                tx.prepare_cached("INSERT INTO paths VALUES(?,?)")?
                    .execute(params![upper, path])?;
            }
            if index % 100 == 0 {
                self.progress(status, "catalog", index as i64 + 1, status.total)?;
            }
        }
        let mut statement =
            source.prepare("SELECT path FROM catalog_hidden_directories WHERE library_id=?")?;
        for path in statement.query_map([lib], |r| r.get::<_, String>(0))? {
            tx.execute("INSERT INTO hidden VALUES(?)", [path?])?;
        }
        self.progress(status, "navigation", 0, 1)?;
        let mut pages = source.prepare(
            "SELECT path,page_json FROM catalog_sync_navigation WHERE library_id=? ORDER BY path",
        )?;
        let mut root_seen = false;
        for page in pages.query_map([lib], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })? {
            let (path, page) = page?;
            root_seen |= path.is_empty();
            let mut navigation: Value = serde_json::from_str(&page)?;
            for child in navigation["directories"]
                .as_array_mut()
                .context("navigation directories")?
            {
                let child_path = child["path"].as_str().context("directory path")?.to_owned();
                if let Some(name) = self.app.original_root_names.get(FsPath::new(&child_path)) {
                    child["name"] = json!(name);
                }
                let root = child_path.trim_end_matches('/');
                let (direct,count):(i64,i64)=source.query_row("SELECT count(DISTINCT CASE WHEN instr(substr(p.path,length(?2)+1),'/')=0 THEN p.asset_id END),count(DISTINCT p.asset_id) FROM catalog_paths p JOIN catalog_assets a ON a.library_id=p.library_id AND a.id=p.asset_id WHERE p.library_id=?1 AND p.path>=?2 AND p.path<?3 AND a.trashed=0",params![lib,format!("{root}/"),format!("{root}0")],|r|Ok((r.get(0)?,r.get(1)?)))?;
                child["directPhotoCount"] = json!(direct);
                child["photoCount"] = json!(count);
            }
            tx.execute(
                "INSERT INTO navigation VALUES(?,?)",
                params![path, navigation.to_string()],
            )?;
        }
        ensure!(root_seen, "mobile navigation projection is not initialized");
        tx.execute(
            "INSERT INTO metadata VALUES('revision',?)",
            [status.revision.context("snapshot revision")?.to_string()],
        )?;
        if let Some(generation) = &status.generation {
            tx.execute("INSERT INTO metadata VALUES('generation',?)", [generation])?;
        }
        if let Some(since) = status.from_revision {
            tx.execute(
                "INSERT INTO metadata VALUES('from_revision',?)",
                [since.to_string()],
            )?;
            tx.execute_batch("CREATE TABLE deleted_assets(id TEXT PRIMARY KEY)")?;
            let mut deleted=source.prepare("SELECT asset_id FROM catalog_sync_assets WHERE library_id=? AND revision>? AND deleted=1")?;
            for id in deleted.query_map(params![lib, since], |r| r.get::<_, String>(0))? {
                tx.execute(
                    "INSERT INTO deleted_assets VALUES(?)",
                    [Uuid::parse_str(&id?)?.to_string().to_uppercase()],
                )?;
            }
        }
        tx.commit()?;
        Ok(thumbnails)
    }
}
fn pin_read_snapshot(source: &Connection, library: &str) -> Result<i64> {
    source.execute_batch("BEGIN DEFERRED")?;
    // BEGIN alone does not acquire a read snapshot; an actual read pins the WAL view
    // so independent NAS writers cannot restart subsequent incremental backup steps.
    Ok(source.query_row(
        "SELECT coalesce((SELECT revision FROM catalog_version_revision WHERE library_id=?1),0)",
        [library],
        |row| row.get(0),
    )?)
}

fn append_bytes<W: Write>(tar: &mut tar::Builder<W>, name: &str, bytes: &[u8]) -> Result<()> {
    let mut header = tar::Header::new_ustar();
    header.set_size(bytes.len() as u64);
    header.set_mode(0o600);
    header.set_cksum();
    tar.append_data(&mut header, name, bytes)?;
    Ok(())
}
fn append_optional_image<W: Write, F: FnMut(usize) -> std::io::Result<()>>(
    tar: &mut tar::Builder<W>,
    directory: &str,
    id: &str,
    path: &FsPath,
    report: &mut F,
) -> Result<bool> {
    // Finish reading before writing a tar header: a vanished or unreadable cache
    // must not leave a partial archive entry or invalidate the required catalog.
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) => {
            tracing::warn!(path = %path.display(), error = ?error, "Skipping unavailable offline thumbnail");
            return Ok(false);
        }
    };
    append_bytes(tar, &format!("{directory}/{id}.image"), &bytes)?;
    report(bytes.len())?;
    Ok(true)
}

struct ProgressReader<'a, F: FnMut(usize) -> std::io::Result<()>> {
    file: fs::File,
    report: &'a mut F,
}
impl<F: FnMut(usize) -> std::io::Result<()>> Read for ProgressReader<'_, F> {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let count = self.file.read(buffer)?;
        (self.report)(count)?;
        Ok(count)
    }
}
fn append_file<W: Write, F: FnMut(usize) -> std::io::Result<()>>(
    tar: &mut tar::Builder<W>,
    name: &str,
    path: &FsPath,
    report: &mut F,
) -> Result<()> {
    let file = fs::File::open(path)?;
    let mut header = tar::Header::new_ustar();
    header.set_size(file.metadata()?.len());
    header.set_mode(0o600);
    header.set_cksum();
    tar.append_data(&mut header, name, ProgressReader { file, report })?;
    Ok(())
}
#[derive(Deserialize)]
struct Acknowledgement {
    generation: Uuid,
    revision: i64,
}
async fn ack(
    State(manager): State<Arc<Manager>>,
    Path((_library, replica)): Path<(String, Uuid)>,
    Json(request): Json<Acknowledgement>,
) -> Result<Response, ApiError> {
    tokio::task::spawn_blocking(move || -> Result<()> {
        let mut db = manager.app.store.lock()?;
        let tx = db.transaction()?;
        crate::replicas::acknowledge(
            &tx,
            &manager.app.library_id,
            &replica.to_string(),
            &request.generation.to_string(),
            request.revision,
            chrono::Utc::now().timestamp(),
        )?;
        tx.commit()?;
        drop(db);
        manager.remove_acknowledged_packages(replica, request.revision)?;
        Ok(())
    })
    .await
    .map_err(anyhow::Error::from)??;
    Ok(StatusCode::NO_CONTENT.into_response())
}
async fn start(
    State(manager): State<Arc<Manager>>,
    Json(request): Json<BuildRequest>,
) -> Result<Response, ApiError> {
    Ok(Json(
        tokio::task::spawn_blocking(move || {
            manager.begin_request(request.include_thumbnails, request.sync)
        })
        .await
        .map_err(anyhow::Error::from)??,
    )
    .into_response())
}
async fn status(
    State(manager): State<Arc<Manager>>,
    Path((_library, id)): Path<(String, String)>,
) -> Result<Response, ApiError> {
    Ok(Json(
        tokio::task::spawn_blocking(move || manager.read_status(&id))
            .await
            .map_err(anyhow::Error::from)??,
    )
    .into_response())
}
pub(crate) fn range(value: &str, length: u64) -> Result<(u64, u64)> {
    let value = value.strip_prefix("bytes=").context("invalid range unit")?;
    let (start, end) = value.split_once('-').context("invalid range")?;
    ensure!(!value.contains(','), "multiple ranges unsupported");
    let (start, end) = if start.is_empty() {
        let suffix: u64 = end.parse()?;
        ensure!(suffix > 0, "empty suffix");
        (length.saturating_sub(suffix), length.saturating_sub(1))
    } else {
        (
            start.parse()?,
            if end.is_empty() {
                length.saturating_sub(1)
            } else {
                end.parse::<u64>()?.min(length.saturating_sub(1))
            },
        )
    };
    ensure!(
        length > 0 && start < length && end >= start,
        "unsatisfiable range"
    );
    Ok((start, end))
}
async fn download(
    State(manager): State<Arc<Manager>>,
    Path((_library, id)): Path<(String, String)>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let status = manager.read_status(&id)?;
    if status.state != "ready" {
        return Err(anyhow::Error::from(StoreError {
            status: 409,
            code: "offline_rebuild_not_ready".into(),
            message: "offline rebuild is not ready".into(),
        })
        .into());
    }
    let mut file = tokio::fs::File::open(manager.directory(&id)?.join("library.tar"))
        .await
        .map_err(anyhow::Error::from)?;
    let length = file.metadata().await.map_err(anyhow::Error::from)?.len();
    let etag = format!(
        "\"{}\"",
        status.sha256.context("ready export missing hash")?
    );
    let requested = headers.get(header::RANGE).filter(|_| {
        headers
            .get(header::IF_RANGE)
            .is_none_or(|value| value.to_str().ok() == Some(etag.as_str()))
    });
    let selected = if let Some(value) = requested {
        match value
            .to_str()
            .ok()
            .and_then(|value| range(value, length).ok())
        {
            Some(range) => Some(range),
            None => {
                return Ok((
                    StatusCode::RANGE_NOT_SATISFIABLE,
                    [
                        (header::CONTENT_RANGE, format!("bytes */{length}")),
                        (header::ETAG, etag),
                    ],
                )
                    .into_response());
            }
        }
    } else {
        None
    };
    let (start, end) = selected.unwrap_or((0, length.saturating_sub(1)));
    let count = end - start + 1;
    file.seek(std::io::SeekFrom::Start(start))
        .await
        .map_err(anyhow::Error::from)?;
    let mut response =
        axum::body::Body::from_stream(tokio_util::io::ReaderStream::new(file.take(count)))
            .into_response();
    *response.status_mut() = if selected.is_some() {
        StatusCode::PARTIAL_CONTENT
    } else {
        StatusCode::OK
    };
    let headers = response.headers_mut();
    for (key, value) in [
        (header::CONTENT_TYPE, "application/x-tar".into()),
        (header::ACCEPT_RANGES, "bytes".into()),
        (header::CONTENT_LENGTH, count.to_string()),
        (header::ETAG, etag),
    ] {
        headers.insert(key, value.parse().map_err(anyhow::Error::from)?);
    }
    if selected.is_some() {
        headers.insert(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{length}")
                .parse()
                .map_err(anyhow::Error::from)?,
        );
    }
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{body::Body, http::Request};
    use http_body_util::BodyExt;
    use tower::ServiceExt;
    fn fixture(root: &FsPath) -> Arc<AppState> {
        let originals = root.join("originals");
        fs::create_dir(&originals).unwrap();
        let keeps = root.join("keeps");
        Arc::new(AppState {
            store: Arc::new(
                crate::store::Store::open(&keeps.join("db/catalog.sqlite"), true).unwrap(),
            ),
            previews: Arc::new(
                crate::previews::PreviewStorage::new(
                    &keeps,
                    Some(&originals),
                    "http://localhost",
                    "test-signing-key",
                )
                .unwrap(),
            ),
            jobs: Arc::new(
                crate::jobs::Jobs::open(&keeps.join("db/jobs.sqlite"), &originals).unwrap(),
            ),
            access_token: "test-token".into(),
            library_id: "photos".into(),
            original_root_names: Default::default(),
        })
    }
    fn seed(app: &AppState, root: &FsPath, name: &str) -> String {
        let path = root.join("originals").canonicalize().unwrap().join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, b"original must remain").unwrap();
        app.store.ingest_original("photos",path.to_str().unwrap(),&json!({"contentHash":name,"sizeBytes":20,"role":"jpeg_original"}),&json!({"captureTime":"2024-01-01T00:00:00Z","cameraMake":"Canon","cameraModel":"R3","lensModel":"50mm","originalFilename":name,"contentFingerprint":name,"metadataFingerprint":name,"rating":2,"flagState":"picked","tags":[],"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"})).unwrap()
    }
    fn manager(app: Arc<AppState>) -> Manager {
        crate::sync_navigation::refresh(&app.store, &app.jobs, &app.library_id).unwrap();
        Manager {
            root: app
                .previews
                .keeps_root()
                .join("tmp/offline-rebuild")
                .join(format!("{:x}", Sha256::digest(app.library_id.as_bytes()))),
            app,
            initialized: Mutex::new(false),
        }
    }
    fn fresh() -> Status {
        Status {
            id: Uuid::new_v4().to_string(),
            state: "building".into(),
            phase: "snapshot".into(),
            completed: 0,
            total: 1,
            revision: None,
            byte_count: None,
            sha256: None,
            error: None,
            created_at: chrono::Utc::now().timestamp(),
            include_thumbnails: true,
            request: SyncRequest::default(),
            from_revision: None,
            generation: None,
            last_progress_save: None,
        }
    }
    fn unpack_catalog(
        manager: &Manager,
        status: &Status,
        target: &FsPath,
    ) -> Result<(Value, Connection)> {
        fs::create_dir_all(target)?;
        tar::Archive::new(fs::File::open(
            manager.directory(&status.id)?.join("library.tar"),
        )?)
        .unpack(target)?;
        let manifest = serde_json::from_reader(fs::File::open(target.join("manifest.json"))?)?;
        Ok((manifest, Connection::open(target.join("catalog.sqlite"))?))
    }

    #[test]
    fn delta_replaces_merged_assets_paths_and_rules_and_matches_full_snapshot() -> Result<()> {
        let root = tempfile::tempdir()?;
        let app = fixture(root.path());
        app.jobs.add_folder(
            "photos",
            root.path()
                .join("originals")
                .canonicalize()?
                .to_str()
                .unwrap(),
        )?;
        let retained = seed(&app, root.path(), "B0014325.HEIC");
        let removed = seed(&app, root.path(), "other.3FR");
        let unchanged = seed(&app, root.path(), "unchanged.jpg");
        let manager = manager(app.clone());
        let replica = Uuid::new_v4();
        let mut initial = fresh();
        initial.request.replica_id = Some(replica);
        initial.include_thumbnails = false;
        manager.save(&initial)?;
        manager.build(&mut initial)?;
        let (first, mut local) = unpack_catalog(&manager, &initial, &root.path().join("initial"))?;
        assert_eq!(first["mode"], "snapshot");
        let generation = initial.generation.clone().unwrap();
        let since = initial.revision.unwrap();
        {
            let mut db = app.store.lock()?;
            let tx = db.transaction()?;
            crate::replicas::acknowledge(
                &tx,
                "photos",
                &replica.to_string(),
                &generation,
                since,
                chrono::Utc::now().timestamp(),
            )?;
            tx.execute(
                "UPDATE catalog_paths SET asset_id=? WHERE asset_id=?",
                params![retained, removed],
            )?;
            tx.execute("DELETE FROM catalog_assets WHERE id=?", [&removed])?;
            crate::revisions::flush(&tx)?;
            tx.commit()?;
        }
        app.store
            .patch_asset("photos", &retained, &json!({"rating":5}))?;
        app.store.set_hidden_directory(
            "photos",
            root.path()
                .join("originals")
                .canonicalize()?
                .to_str()
                .unwrap(),
            true,
        )?;
        let mut delta = fresh();
        delta.request = SyncRequest {
            replica_id: Some(replica),
            generation: Some(Uuid::parse_str(&generation)?),
            since_revision: Some(since),
        };
        manager.save(&delta)?;
        manager.build(&mut delta)?;
        let (manifest, delta_db) = unpack_catalog(&manager, &delta, &root.path().join("delta"))?;
        assert_eq!(manifest["mode"], "delta");
        assert_eq!(manifest["assetCount"], 2);
        assert_eq!(manifest["thumbnailCount"], 0);
        assert_eq!(manifest["missingThumbnailCount"], 2);
        assert_eq!(manifest["fromRevision"], since);
        assert_eq!(
            delta_db.query_row("SELECT id FROM deleted_assets", [], |r| r
                .get::<_, String>(0))?,
            removed.to_uppercase()
        );
        // Hiding a directory updates all affected assets, including the previously unchanged one.
        assert_eq!(
            delta_db.query_row(
                "SELECT count(*) FROM assets WHERE id=?",
                [unchanged.to_uppercase()],
                |r| r.get::<_, i64>(0)
            )?,
            1
        );
        local.execute(
            "ATTACH DATABASE ? AS delta",
            [root.path().join("delta/catalog.sqlite").to_str().unwrap()],
        )?;
        {
            let tx = local.transaction()?;
            tx.execute_batch("DELETE FROM paths WHERE asset_id IN (SELECT id FROM delta.assets UNION SELECT id FROM delta.deleted_assets); DELETE FROM assets WHERE id IN (SELECT id FROM delta.deleted_assets); INSERT OR REPLACE INTO assets SELECT * FROM delta.assets; INSERT INTO paths SELECT * FROM delta.paths; DELETE FROM hidden; INSERT INTO hidden SELECT * FROM delta.hidden; DELETE FROM navigation; INSERT INTO navigation SELECT * FROM delta.navigation; INSERT OR REPLACE INTO metadata SELECT * FROM delta.metadata WHERE key<>'from_revision';")?;
            tx.commit()?;
        }
        let mut full = fresh();
        full.request.replica_id = Some(Uuid::new_v4());
        full.include_thumbnails = false;
        manager.save(&full)?;
        manager.build(&mut full)?;
        let (_, full_db) = unpack_catalog(&manager, &full, &root.path().join("full"))?;
        if let Ok(output) = std::env::var("KEEPS_SYNC_TEST_EXPORT") {
            fs::create_dir_all(&output)?;
            for (name, status) in [("initial", &initial), ("delta", &delta), ("full", &full)] {
                fs::copy(
                    manager.directory(&status.id)?.join("library.tar"),
                    FsPath::new(&output).join(format!("{name}.tar")),
                )?;
            }
        }
        for (table, columns, order) in [
            (
                "assets",
                "id,snapshot,sort_time,filename,camera,rating,flag,color,trashed",
                "id",
            ),
            ("paths", "asset_id,path", "asset_id,path"),
            ("hidden", "path", "path"),
            ("navigation", "path,snapshot", "path"),
            ("metadata", "key,value", "key"),
        ] {
            let query = format!(
                "SELECT json_group_array(json_array({columns})) FROM (SELECT * FROM {table} ORDER BY {order})"
            );
            let expected: String = full_db.query_row(&query, [], |r| r.get(0))?;
            let actual: String = local.query_row(&query, [], |r| r.get(0))?;
            assert_eq!(actual, expected, "table {table}");
        }
        assert_eq!(
            local.query_row(
                "SELECT count(*) FROM paths WHERE asset_id=?",
                [retained.to_uppercase()],
                |r| r.get::<_, i64>(0)
            )?,
            2
        );
        let mut db = app.store.lock()?;
        let tx = db.transaction()?;
        crate::replicas::acknowledge(
            &tx,
            "photos",
            &replica.to_string(),
            &generation,
            delta.revision.unwrap(),
            chrono::Utc::now().timestamp(),
        )?;
        tx.commit()?;
        drop(db);
        manager.remove_acknowledged_packages(replica, delta.revision.unwrap())?;
        assert!(!manager.directory(&initial.id)?.exists());
        assert!(!manager.directory(&delta.id)?.exists());
        assert!(manager.directory(&full.id)?.exists());
        Ok(())
    }

    #[test]
    fn superseded_packages_are_bounded_and_parallel_builds_have_a_limit() -> Result<()> {
        let root = tempfile::tempdir()?;
        let app = fixture(root.path());
        let manager = Arc::new(manager(app));
        {
            let mut initialized = manager.initialized.lock().unwrap();
            manager.initialize(&mut initialized)?;
        }
        let replica = Uuid::new_v4();
        let mut previous = Vec::new();
        for i in 0..3 {
            let mut status = fresh();
            status.request.replica_id = Some(replica);
            status.state = "ready".into();
            status.created_at += i;
            manager.save(&status)?;
            previous.push(status);
        }
        for _ in 0..4 {
            let mut status = fresh();
            status.request.replica_id = Some(Uuid::new_v4());
            manager.save(&status)?;
        }
        let error = manager
            .begin_request(
                false,
                SyncRequest {
                    replica_id: Some(replica),
                    ..Default::default()
                },
            )
            .unwrap_err();
        assert_eq!(
            error.downcast_ref::<StoreError>().unwrap().code,
            "sync_capacity_busy"
        );
        assert_eq!(
            previous
                .iter()
                .filter(|s| manager.directory(&s.id).unwrap().exists())
                .count(),
            1
        );
        Ok(())
    }

    #[tokio::test]
    async fn acknowledgements_are_idempotent_and_invalid_progress_requires_rebuild() -> Result<()> {
        let root = tempfile::tempdir()?;
        let app = fixture(root.path());
        seed(&app, root.path(), "photo.jpg");
        let manager = manager(app.clone());
        let replica = Uuid::new_v4();
        let mut status = fresh();
        status.request.replica_id = Some(replica);
        status.include_thumbnails = false;
        manager.save(&status)?;
        manager.build(&mut status)?;
        let generation = status.generation.clone().unwrap();
        let revision = status.revision.unwrap();
        let router = crate::api::router(app.clone());
        for (target, value, expected) in [
            (replica, revision + 1, StatusCode::CONFLICT),
            (Uuid::new_v4(), revision, StatusCode::CONFLICT),
            (replica, revision, StatusCode::NO_CONTENT),
            (replica, revision, StatusCode::NO_CONTENT),
        ] {
            let response = router
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri(format!("/libraries/photos/replicas/{target}/ack"))
                        .header("Authorization", "Bearer test-token")
                        .header("Content-Type", "application/json")
                        .body(Body::from(
                            json!({"generation":generation,"revision":value}).to_string(),
                        ))?,
                )
                .await?;
            assert_eq!(response.status(), expected);
            if expected == StatusCode::CONFLICT {
                let body: Value =
                    serde_json::from_slice(&response.into_body().collect().await?.to_bytes())?;
                assert_eq!(body["detail"]["code"], "replica_rebuild_required");
            }
        }
        assert!(!manager.directory(&status.id)?.exists());
        let mut old = fresh();
        old.request.replica_id = Some(replica);
        manager.save(&old)?;
        manager.build(&mut old)?;
        app.store.lock()?.execute(
            "UPDATE catalog_sync_state SET generation=?",
            [Uuid::new_v4().to_string()],
        )?;
        let error = manager.read_status(&old.id).unwrap_err();
        assert_eq!(error.downcast_ref::<StoreError>().unwrap().status, 410);
        Ok(())
    }

    #[test]
    fn unavailable_optional_thumbnails_do_not_leave_partial_tar_entries() -> Result<()> {
        let root = tempfile::tempdir()?;
        let good = root.path().join("good.image");
        fs::write(&good, b"available thumbnail")?;
        let vanished = root.path().join("vanished.image");
        fs::write(&vanished, b"removed after catalog selection")?;
        fs::remove_file(&vanished)?;
        let unreadable = root.path().join("unreadable.image");
        fs::create_dir(&unreadable)?;
        let mut tar = tar::Builder::new(Vec::new());
        let mut reported = 0;
        let mut report = |count| {
            reported += count;
            Ok(())
        };
        assert!(!append_optional_image(
            &mut tar,
            "thumbnails",
            "missing",
            &vanished,
            &mut report
        )?);
        assert!(!append_optional_image(
            &mut tar,
            "thumbnails",
            "unreadable",
            &unreadable,
            &mut report
        )?);
        assert!(append_optional_image(
            &mut tar,
            "thumbnails",
            "good",
            &good,
            &mut report
        )?);
        let bytes = tar.into_inner()?;
        let mut archive = tar::Archive::new(&bytes[..]);
        let mut entries = archive.entries()?;
        let mut entry = entries.next().unwrap()?;
        assert_eq!(entry.path()?.to_str(), Some("thumbnails/good.image"));
        let mut content = Vec::new();
        entry.read_to_end(&mut content)?;
        assert_eq!(content, b"available thumbnail");
        assert_eq!(reported, content.len());
        assert!(entries.next().is_none());
        Ok(())
    }

    #[test]
    fn optional_thumbnail_archive_write_errors_still_fail() -> Result<()> {
        struct BrokenWriter;
        impl Write for BrokenWriter {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::other("archive disk full"))
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let root = tempfile::tempdir()?;
        let good = root.path().join("good.image");
        fs::write(&good, b"available thumbnail")?;
        let mut tar = tar::Builder::new(BrokenWriter);
        assert!(
            append_optional_image(&mut tar, "thumbnails", "good", &good, &mut |_| Ok(())).is_err()
        );
        Ok(())
    }

    #[test]
    fn bundle_has_client_schema_hidden_trash_and_only_current_available_thumbnail() -> Result<()> {
        let root = tempfile::tempdir()?;
        let app = fixture(root.path());
        app.jobs.add_folder(
            "photos",
            root.path()
                .join("originals")
                .canonicalize()?
                .to_str()
                .unwrap(),
        )?;
        let first = seed(&app, root.path(), "hidden/one.jpg");
        let second = seed(&app, root.path(), "two.jpg");
        let third = seed(&app, root.path(), "three.jpg");
        app.store.set_hidden_directory(
            "photos",
            root.path()
                .join("originals/hidden")
                .canonicalize()?
                .to_str()
                .unwrap(),
            true,
        )?;
        app.store.set_trashed("photos", &second, true)?;
        let image = root.path().join("image.heic");
        use base64::Engine;
        let png=base64::engine::general_purpose::STANDARD.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6SAAAAABJRU5ErkJggg==")?;
        fs::write(&image, png)?;
        let object =
            app.previews
                .put_generated_role("photos", &first, "image-v1", &image, "thumbnail")?;
        let descriptor = json!({"objectRef":object,"width":512,"height":400,"version":"image-v1"});
        let browse_object =
            app.previews
                .put_generated_role("photos", &first, "browse-v1", &image, "browse")?;
        let browse_descriptor = json!({"objectRef":browse_object,"width":64,"height":50,"version":"browse-v1","sourceThumbnailVersion":"image-v1","spec":crate::browse_cache::SPEC});
        app.store.reconcile_cache()?;
        {
            let db = app.store.lock()?;
            db.execute(
                "UPDATE media_cache SET status='ready',thumbnail=?,standard=? WHERE asset_id=?",
                params![
                    descriptor.to_string(),
                    json!({"deferred":true}).to_string(),
                    first
                ],
            )?;
            db.execute("UPDATE media_cache SET browse_thumbnail=?,browse_source_version='image-v1',browse_spec=? WHERE asset_id=?",params![browse_descriptor.to_string(),crate::browse_cache::SPEC,first])?;
            db.execute("UPDATE media_cache SET status='ready',source_hash='obsolete',thumbnail=?,standard=? WHERE asset_id=?",params![descriptor.to_string(),json!({"deferred":true}).to_string(),third])?;
            let missing = app.previews.put_generated_role(
                "photos",
                &second,
                "missing-v1",
                &image,
                "thumbnail",
            )?;
            fs::remove_file(app.previews.object_path(&missing)?)?;
            db.execute(
                "UPDATE media_cache SET status='ready',thumbnail=? WHERE asset_id=?",
                params![
                    json!({"objectRef":missing,"width":512,"height":400,"version":"missing-v1"})
                        .to_string(),
                    second
                ],
            )?;
        }
        {
            let db = app.store.lock()?;
            // A matching browse spec cannot make an obsolete preview or source current.
            for id in [&second, &third] {
                db.execute("UPDATE media_cache SET browse_thumbnail=?,browse_source_version='image-v1',browse_spec=? WHERE asset_id=?",params![browse_descriptor.to_string(),crate::browse_cache::SPEC,id])?;
            }
        }
        let manager = manager(app.clone());
        let expected = app.store.library_revision("photos")?["revision"]
            .as_i64()
            .unwrap();
        let mut status = fresh();
        manager.save(&status)?;
        manager.build(&mut status)?;
        assert_eq!(status.state, "ready");
        assert_eq!(status.revision, Some(expected));
        let bytes = fs::read(manager.directory(&status.id)?.join("library.tar"))?;
        assert_eq!(status.sha256, Some(format!("{:x}", Sha256::digest(&bytes))));
        let mut archive = tar::Archive::new(&bytes[..]);
        let mut entries = archive.entries()?;
        let mut entry = entries.next().unwrap()?;
        assert_eq!(entry.path()?.to_str(), Some("manifest.json"));
        assert_eq!(entry.header().as_bytes()[257..263], *b"ustar\0");
        let mut manifest = String::new();
        entry.read_to_string(&mut manifest)?;
        let manifest: Value = serde_json::from_str(&manifest)?;
        assert_eq!(manifest["assetCount"], 3);
        assert_eq!(manifest["thumbnailCount"], 1);
        assert_eq!(manifest["missingThumbnailCount"], 2);
        assert_eq!(manifest["browseThumbnailCount"], 1);
        assert_eq!(manifest["missingBrowseThumbnailCount"], 2);
        if let Ok(output) = std::env::var("KEEPS_OFFLINE_TEST_EXPORT") {
            fs::create_dir_all(&output)?;
            fs::write(FsPath::new(&output).join("fixture.tar"), &bytes)?;
            fs::write(
                FsPath::new(&output).join("manifest.json"),
                serde_json::to_vec_pretty(&manifest)?,
            )?;
            fs::write(
                FsPath::new(&output).join("status.json"),
                serde_json::to_vec_pretty(&status)?,
            )?;
        }
        let mut entry = entries.next().unwrap()?;
        assert_eq!(entry.path()?.to_str(), Some("catalog.sqlite"));
        entry.unpack(root.path().join("client.sqlite"))?;
        let db = Connection::open(root.path().join("client.sqlite"))?;
        assert_eq!(
            db.query_row("SELECT count(*) FROM assets", [], |r| r.get::<_, i64>(0))?,
            3
        );
        assert_eq!(
            db.query_row("SELECT count(*) FROM assets WHERE trashed=1", [], |r| r
                .get::<_, i64>(0))?,
            1
        );
        assert_eq!(
            db.query_row("SELECT count(*) FROM hidden", [], |r| r.get::<_, i64>(0))?,
            1
        );
        assert_eq!(
            db.query_row("SELECT value FROM metadata WHERE key='revision'", [], |r| r
                .get::<_, String>(0))?,
            expected.to_string()
        );
        assert_eq!(
            db.query_row("SELECT count(*) FROM navigation WHERE path=''", [], |r| r
                .get::<_, i64>(
                0
            ))?,
            1
        );
        let entry = entries.next().unwrap()?;
        assert_eq!(
            entry.path()?.to_string_lossy(),
            format!("thumbnails/{}.image", first.to_uppercase())
        );
        let entry = entries.next().unwrap()?;
        assert_eq!(
            entry.path()?.to_string_lossy(),
            format!("browse-thumbnails/{}.image", first.to_uppercase())
        );
        assert!(entries.next().is_none());
        assert_eq!(
            fs::read(root.path().join("originals/hidden/one.jpg"))?,
            b"original must remain"
        );
        app.store
            .patch_asset("photos", &first, &json!({"rating":5}))?;
        assert_eq!(
            db.query_row(
                "SELECT rating FROM assets WHERE id=?",
                [first.to_uppercase()],
                |r| r.get::<_, i64>(0)
            )?,
            2
        );
        Ok(())
    }
    #[test]
    fn bundle_uses_client_rendered_edit_images_and_negative() -> Result<()> {
        let root = tempfile::tempdir()?;
        let app = fixture(root.path());
        let id = seed(&app, root.path(), "edited.jpg");
        app.store.initialize_negative("photos", &id)?;
        let hash = app.store.edit_state("photos", &id)?["negativeContentHash"]
            .as_str()
            .unwrap()
            .to_owned();
        let image = root.path().join("edited.heic");
        fs::write(&image, b"edited image bytes")?;
        let object =
            app.previews
                .put_generated_role("photos", &id, "edit-version", &image, "thumbnail")?;
        let descriptor =
            json!({"objectRef":object,"width":64,"height":48,"version":"edit-version"});
        app.store.lock()?.execute(
            "INSERT INTO photo_edits VALUES('photos',?,?,1,'test','test',?,?,?,NULL)",
            params![
                id,
                hash,
                descriptor.to_string(),
                descriptor.to_string(),
                descriptor.to_string()
            ],
        )?;
        let manager = manager(app);
        let mut status = fresh();
        manager.save(&status)?;
        manager.build(&mut status)?;
        let bytes = fs::read(manager.directory(&status.id)?.join("library.tar"))?;
        let mut archive = tar::Archive::new(&bytes[..]);
        let mut images = 0;
        for entry in archive.entries()? {
            let mut entry = entry?;
            let name = entry.path()?.to_string_lossy().to_string();
            if name == "catalog.sqlite" {
                entry.unpack(root.path().join("edited-client.sqlite"))?;
            }
            if name.starts_with("thumbnails/") || name.starts_with("browse-thumbnails/") {
                let mut bytes = Vec::new();
                entry.read_to_end(&mut bytes)?;
                assert_eq!(bytes, b"edited image bytes");
                images += 1;
            }
        }
        assert_eq!(images, 2);
        let db = Connection::open(root.path().join("edited-client.sqlite"))?;
        let snapshot: String = db.query_row(
            "SELECT snapshot FROM assets WHERE id=?",
            [id.to_uppercase()],
            |r| r.get(0),
        )?;
        let asset: Value = serde_json::from_str(&snapshot)?;
        for role in ["thumbnail", "standard", "browseThumbnail"] {
            assert_eq!(asset[role]["version"], "edit-version");
        }
        assert_eq!(asset["negativeContentHash"], hash);
        Ok(())
    }
    #[test]
    fn pinned_snapshot_stays_consistent_during_independent_writer_commits() -> Result<()> {
        let root = tempfile::tempdir()?;
        let path = root.path().join("source.sqlite");
        let setup = Connection::open(&path)?;
        setup.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE catalog_version_revision(library_id TEXT PRIMARY KEY,revision INTEGER); INSERT INTO catalog_version_revision VALUES('photos',7); CREATE TABLE samples(id INTEGER PRIMARY KEY, label TEXT, bytes BLOB);")?;
        for id in 0..64 {
            setup.execute(
                "INSERT INTO samples VALUES(?,'original',zeroblob(8192))",
                [id],
            )?;
        }
        drop(setup);
        let source = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        assert_eq!(pin_read_snapshot(&source, "photos")?, 7);
        let (request_tx, request_rx) = std::sync::mpsc::channel::<()>();
        let (ack_tx, ack_rx) = std::sync::mpsc::channel();
        let writer = std::thread::spawn(move || -> Result<()> {
            let mut writer = Connection::open(path)?;
            while request_rx.recv().is_ok() {
                let tx = writer.transaction()?;
                tx.execute(
                    "UPDATE catalog_version_revision SET revision=revision+1",
                    [],
                )?;
                tx.execute("UPDATE samples SET label='changed' WHERE id=0", [])?;
                tx.execute(
                    "INSERT INTO samples(label,bytes) VALUES('new',zeroblob(8192))",
                    [],
                )?;
                tx.commit()?;
                ack_tx.send(())?;
            }
            Ok(())
        });
        // A commit before the first backup step must also be outside the pinned view.
        request_tx.send(())?;
        ack_rx.recv()?;
        let mut target = Connection::open(root.path().join("target.sqlite"))?;
        let mut previous = 0;
        let mut steps = 0;
        {
            let backup = rusqlite::backup::Backup::new(&source, &mut target)?;
            loop {
                let step = backup.step(8)?;
                let progress = backup.progress();
                let completed = progress.pagecount - progress.remaining;
                assert!(
                    completed > previous,
                    "backup restarted: {previous} -> {completed}"
                );
                previous = completed;
                steps += 1;
                if step == rusqlite::backup::StepResult::Done {
                    break;
                }
                assert_eq!(step, rusqlite::backup::StepResult::More);
                request_tx.send(())?;
                ack_rx.recv()?;
            }
        }
        drop(request_tx);
        writer.join().expect("writer thread")?;
        assert!(steps > 1);
        assert_eq!(
            target.query_row("SELECT revision FROM catalog_version_revision", [], |r| r
                .get::<_, i64>(
                0
            ))?,
            7
        );
        assert_eq!(
            target.query_row("SELECT count(*) FROM samples", [], |r| r.get::<_, i64>(0))?,
            64
        );
        assert_eq!(
            target.query_row("SELECT label FROM samples WHERE id=0", [], |r| r
                .get::<_, String>(0))?,
            "original"
        );
        source.execute_batch("ROLLBACK")?;
        assert!(
            source.query_row("SELECT revision FROM catalog_version_revision", [], |r| r
                .get::<_, i64>(
                0
            ))? > 7
        );
        Ok(())
    }

    #[test]
    fn interrupted_export_becomes_failed_and_new_id_is_required() -> Result<()> {
        let root = tempfile::tempdir()?;
        let manager = manager(fixture(root.path()));
        let status = fresh();
        manager.save(&status)?;
        let found = manager.read_status(&status.id)?;
        assert_eq!(found.state, "failed");
        assert!(found.error.unwrap().contains("restarted"));
        Ok(())
    }
    #[tokio::test]
    async fn download_auth_ranges_and_immutable_etag() -> Result<()> {
        let root = tempfile::tempdir()?;
        let app = fixture(root.path());
        seed(&app, root.path(), "photo.jpg");
        let manager = manager(app.clone());
        let mut state = fresh();
        manager.save(&state)?;
        manager.build(&mut state)?;
        crate::sync_navigation::refresh(&app.store, &app.jobs, &app.library_id)?;
        let app = crate::api::router(app);
        let path = format!("/libraries/photos/offline-rebuild/{}/download", state.id);
        let response = app
            .clone()
            .oneshot(Request::builder().uri(&path).body(Body::empty())?)
            .await?;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(path.replace("/photos/", "/other/"))
                    .header("Authorization", "Bearer test-token")
                    .body(Body::empty())?,
            )
            .await?;
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(&path)
                    .header("Authorization", "Bearer test-token")
                    .header("Range", "bytes=0-511")
                    .body(Body::empty())?,
            )
            .await?;
        assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(response.headers()[header::CONTENT_LENGTH], "512");
        assert_eq!(
            response.headers()[header::ETAG],
            format!("\"{}\"", state.sha256.unwrap())
        );
        assert_eq!(response.into_body().collect().await?.to_bytes().len(), 512);
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(&path)
                    .header("Authorization", "Bearer test-token")
                    .header("Range", "bytes=99999999-")
                    .body(Body::empty())?,
            )
            .await?;
        assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(&path)
                    .header("Authorization", "Bearer test-token")
                    .header("Range", "bytes=0-10")
                    .header("If-Range", "\"obsolete\"")
                    .body(Body::empty())?,
            )
            .await?;
        assert_eq!(response.status(), StatusCode::OK);
        Ok(())
    }
    #[tokio::test]
    async fn post_builds_and_poll_returns_ready_status() -> Result<()> {
        let root = tempfile::tempdir()?;
        let app = fixture(root.path());
        seed(&app, root.path(), "photo.jpg");
        crate::sync_navigation::refresh(&app.store, &app.jobs, &app.library_id)?;
        let app = crate::api::router(app);
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/libraries/photos/offline-rebuild")
                    .header("Authorization", "Bearer test-token")
                    .header("Content-Type", "application/json")
                    .body(Body::from("{\"includeThumbnails\":false}"))?,
            )
            .await?;
        assert_eq!(response.status(), StatusCode::OK);
        let state: Status =
            serde_json::from_slice(&response.into_body().collect().await?.to_bytes())?;
        assert!(!state.include_thumbnails);
        let mut ready = false;
        for _ in 0..200 {
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(format!("/libraries/photos/offline-rebuild/{}", state.id))
                        .header("Authorization", "Bearer test-token")
                        .body(Body::empty())?,
                )
                .await?;
            assert_eq!(response.status(), StatusCode::OK);
            let status: Status =
                serde_json::from_slice(&response.into_body().collect().await?.to_bytes())?;
            assert_ne!(status.state, "failed", "{:?}", status.error);
            if status.state == "ready" {
                ready = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(ready);
        Ok(())
    }
    #[tokio::test]
    async fn in_flight_reuse_distinguishes_thumbnail_option() -> Result<()> {
        let root = tempfile::tempdir()?;
        let manager = Arc::new(manager(fixture(root.path())));
        *manager.initialized.lock().unwrap() = true;
        let building = fresh();
        manager.save(&building)?;
        assert_eq!(manager.begin(true)?.id, building.id);
        let other = manager.begin(false)?;
        assert_ne!(other.id, building.id);
        for _ in 0..200 {
            if manager.read_status(&other.id)?.state != "building" {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        anyhow::bail!("export did not complete")
    }
    #[test]
    fn ranges_are_bounded_and_support_suffix_and_resume() {
        assert_eq!(range("bytes=10-", 100).unwrap(), (10, 99));
        assert_eq!(range("bytes=-10", 100).unwrap(), (90, 99));
        assert_eq!(range("bytes=0-200", 100).unwrap(), (0, 99));
        assert!(range("bytes=0-1,3-4", 100).is_err());
        assert!(range("bytes=100-", 100).is_err());
        assert!(range("bytes=-0", 100).is_err());
    }
}
