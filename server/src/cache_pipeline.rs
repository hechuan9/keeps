use crate::{
    jobs::Jobs,
    media::{self, MediaProcessor},
    previews::PreviewStorage,
    store::Store,
};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::{fs, path::Path};

pub fn thumbnail_quality() -> Result<u8> {
    static QUALITY: std::sync::OnceLock<Result<u8, String>> = std::sync::OnceLock::new();
    QUALITY
        .get_or_init(|| {
            let text = std::env::var("KEEPS_THUMBNAIL_QUALITY").unwrap_or_else(|_| "50".into());
            let value = text
                .parse::<u8>()
                .map_err(|_| "KEEPS_THUMBNAIL_QUALITY must be 1..100".to_string())?;
            if !(1..=100).contains(&value) {
                return Err("KEEPS_THUMBNAIL_QUALITY must be 1..100".into());
            }
            Ok(value)
        })
        .clone()
        .map_err(anyhow::Error::msg)
}
pub fn spec() -> Result<String> {
    Ok(format!("thumbnail-heic-512-q{}-v1", thumbnail_quality()?))
}
pub fn local_encoding_enabled() -> Result<bool> {
    static ENABLED: std::sync::OnceLock<Result<bool, String>> = std::sync::OnceLock::new();
    ENABLED
        .get_or_init(
            || match std::env::var("KEEPS_LOCAL_CACHE_ENCODING_ENABLED").as_deref() {
                Ok("1") | Ok("true") | Err(_) => Ok(true),
                Ok("0") | Ok("false") => Ok(false),
                _ => Err("KEEPS_LOCAL_CACHE_ENCODING_ENABLED must be 0 or 1".into()),
            },
        )
        .clone()
        .map_err(anyhow::Error::msg)
}
pub const BATCH: usize = 20;
const MAX_ATTEMPTS: i64 = 1;

/// Preserve a terminal failure without overwriting a newer source attempt.
/// Returns whether the failed attempt still owns the current cache source.
pub(crate) fn record_failure(
    db: &Connection,
    lib: &str,
    id: &str,
    expected_hash: &str,
    error: &str,
) -> Result<bool> {
    let current: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM media_cache WHERE library_id=? AND asset_id=? AND source_hash=? AND status='processing')",
        params![lib,id,expected_hash], |r| r.get(0),
    )?;
    if !current {
        return Ok(false);
    }
    let target: Option<String> = db.query_row(
        "SELECT coalesce(d.content_hash,a.content_hash) FROM catalog_assets a LEFT JOIN catalog_defaults d ON d.library_id=a.library_id AND d.asset_id=a.id WHERE a.library_id=?1 AND a.id=?2 AND a.trashed=0 AND EXISTS(SELECT 1 FROM catalog_paths p WHERE p.library_id=a.library_id AND p.asset_id=a.id AND p.content_hash=coalesce(d.content_hash,a.content_hash) AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path))",
        params![lib,id], |r| r.get(0),
    ).optional()?;
    match target {
        None => {
            db.execute("UPDATE media_cache SET status='cancelled',last_error=NULL,available_at=0,updated_at=unixepoch() WHERE library_id=? AND asset_id=?",params![lib,id])?;
            tracing::info!(
                library_id = lib,
                asset_id = id,
                source_hash = expected_hash,
                error,
                reason = "asset has no eligible indexed source",
                "Obsolete media task cancelled"
            );
            Ok(false)
        }
        Some(hash) if hash != expected_hash => {
            db.execute("UPDATE media_cache SET source_hash=?,spec=?,status='failed',attempts=0,available_at=0,last_error=?,updated_at=unixepoch() WHERE library_id=? AND asset_id=?",params![hash,spec()?,error,lib,id])?;
            tracing::info!(
                library_id = lib,
                asset_id = id,
                source_hash = expected_hash,
                new_hash = hash,
                error,
                "Media task stopped after source change"
            );
            Ok(false)
        }
        Some(_) => {
            db.execute("UPDATE media_cache SET status='failed',last_error=?,available_at=0,updated_at=unixepoch() WHERE library_id=? AND asset_id=?",params![error,lib,id])?;
            Ok(true)
        }
    }
}

pub fn migrate(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS photos(library_id TEXT NOT NULL,id TEXT NOT NULL,snapshot TEXT NOT NULL,PRIMARY KEY(library_id,id));
CREATE TABLE IF NOT EXISTS videos(library_id TEXT NOT NULL,id TEXT NOT NULL,snapshot TEXT NOT NULL,PRIMARY KEY(library_id,id));
CREATE TABLE IF NOT EXISTS directories(library_id TEXT NOT NULL,path TEXT NOT NULL,parent_path TEXT,PRIMARY KEY(library_id,path));
INSERT OR IGNORE INTO photos SELECT library_id,id,snapshot FROM catalog_assets WHERE lower(filename) NOT GLOB '*.mov' AND lower(filename) NOT GLOB '*.mp4' AND lower(filename) NOT GLOB '*.m4v' AND lower(filename) NOT GLOB '*.avi' AND lower(filename) NOT GLOB '*.mkv' AND lower(filename) NOT GLOB '*.mts' AND lower(filename) NOT GLOB '*.m2ts';
INSERT OR IGNORE INTO videos SELECT library_id,id,snapshot FROM catalog_assets WHERE NOT EXISTS(SELECT 1 FROM photos WHERE photos.library_id=catalog_assets.library_id AND photos.id=catalog_assets.id);
INSERT OR IGNORE INTO directories SELECT library_id,path,parent_path FROM catalog_directory_revisions;
CREATE TRIGGER IF NOT EXISTS photos_insert AFTER INSERT ON catalog_assets BEGIN
INSERT OR IGNORE INTO photos SELECT NEW.library_id,NEW.id,NEW.snapshot WHERE lower(NEW.filename) NOT GLOB '*.mov' AND lower(NEW.filename) NOT GLOB '*.mp4' AND lower(NEW.filename) NOT GLOB '*.m4v' AND lower(NEW.filename) NOT GLOB '*.avi' AND lower(NEW.filename) NOT GLOB '*.mkv' AND lower(NEW.filename) NOT GLOB '*.mts' AND lower(NEW.filename) NOT GLOB '*.m2ts';
INSERT OR IGNORE INTO videos SELECT NEW.library_id,NEW.id,NEW.snapshot WHERE NOT EXISTS(SELECT 1 FROM photos WHERE library_id=NEW.library_id AND id=NEW.id); END;
CREATE TRIGGER IF NOT EXISTS photos_update AFTER UPDATE ON catalog_assets BEGIN UPDATE photos SET snapshot=NEW.snapshot WHERE library_id=NEW.library_id AND id=NEW.id; UPDATE videos SET snapshot=NEW.snapshot WHERE library_id=NEW.library_id AND id=NEW.id; END;
CREATE TRIGGER IF NOT EXISTS directories_insert AFTER INSERT ON catalog_directory_revisions BEGIN INSERT OR IGNORE INTO directories VALUES(NEW.library_id,NEW.path,NEW.parent_path); END;
CREATE TABLE IF NOT EXISTS media_cache(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,source_hash TEXT NOT NULL,spec TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'pending',attempts INTEGER NOT NULL DEFAULT 0,available_at INTEGER NOT NULL DEFAULT 0,last_error TEXT,thumbnail TEXT,standard TEXT,updated_at INTEGER NOT NULL DEFAULT 0,audited_at INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(library_id,asset_id));
CREATE INDEX IF NOT EXISTS media_cache_claim ON media_cache(status,available_at,updated_at);
CREATE INDEX IF NOT EXISTS media_cache_audit ON media_cache(status,audited_at);
CREATE TABLE IF NOT EXISTS cache_runtime(id INTEGER PRIMARY KEY CHECK(id=1),next_batch_at INTEGER NOT NULL DEFAULT 0,last_batch_count INTEGER NOT NULL DEFAULT 0,last_batch_at INTEGER,last_error TEXT,free_bytes INTEGER);
INSERT OR IGNORE INTO cache_runtime(id) VALUES(1);")?;
    crate::browse_cache::migrate(db)?;
    crate::remote_worker::migrate(db)?;
    crate::cache_gc::migrate(db)?;
    Ok(())
}

pub fn migrate_published_state(db: &Connection) -> Result<()> {
    let columns: Vec<String> = db
        .prepare("PRAGMA table_info(media_cache)")?
        .query_map([], |r| r.get(1))?
        .collect::<rusqlite::Result<_>>()?;
    for name in ["published_source_hash", "published_spec"] {
        if !columns.iter().any(|column| column == name) {
            db.execute_batch(&format!("ALTER TABLE media_cache ADD COLUMN {name} TEXT"))?;
        }
    }
    db.execute("UPDATE media_cache SET published_source_hash=source_hash,published_spec=spec WHERE status='ready' AND published_source_hash IS NULL", [])?;
    db.execute_batch("CREATE TRIGGER IF NOT EXISTS media_cache_published_update AFTER UPDATE OF thumbnail,status ON media_cache WHEN NEW.status='ready' BEGIN UPDATE media_cache SET published_source_hash=NEW.source_hash,published_spec=NEW.spec WHERE library_id=NEW.library_id AND asset_id=NEW.asset_id; END;
CREATE TRIGGER IF NOT EXISTS media_cache_published_insert AFTER INSERT ON media_cache WHEN NEW.status='ready' BEGIN UPDATE media_cache SET published_source_hash=NEW.source_hash,published_spec=NEW.spec WHERE library_id=NEW.library_id AND asset_id=NEW.asset_id; END;")?;
    Ok(())
}

impl Store {
    pub fn record_directory(&self, library: &str, path: &Path) -> Result<()> {
        let parent = path.parent().and_then(Path::to_str);
        self.lock()?.execute(
            "INSERT OR IGNORE INTO directories(library_id,path,parent_path) VALUES(?,?,?)",
            params![
                library,
                path.to_str().context("directory path must be UTF-8")?,
                parent
            ],
        )?;
        Ok(())
    }
    pub fn reconcile_cache(&self) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        tx.execute("INSERT INTO media_cache(library_id,asset_id,source_hash,spec) SELECT a.library_id,a.id,coalesce(d.content_hash,a.content_hash),? FROM catalog_assets a LEFT JOIN catalog_defaults d ON a.library_id=d.library_id AND a.id=d.asset_id WHERE a.trashed=0 ON CONFLICT(library_id,asset_id) DO UPDATE SET source_hash=excluded.source_hash,spec=excluded.spec,status='pending',attempts=0,available_at=0,last_error=NULL WHERE media_cache.source_hash!=excluded.source_hash OR media_cache.spec!=excluded.spec OR (media_cache.status='cancelled' AND EXISTS(SELECT 1 FROM catalog_paths p WHERE p.library_id=excluded.library_id AND p.asset_id=excluded.asset_id AND p.content_hash=excluded.source_hash AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path)))", [spec()?])?;
        tx.execute("UPDATE media_cache SET status='pending',attempts=0,available_at=0,last_error=NULL WHERE status='ready' AND json_extract(thumbnail,'$.version') NOT LIKE 'video-v3:%' AND EXISTS (SELECT 1 FROM catalog_assets a WHERE a.library_id=media_cache.library_id AND a.id=media_cache.asset_id AND (lower(a.filename) GLOB '*.mov' OR lower(a.filename) GLOB '*.mp4' OR lower(a.filename) GLOB '*.m4v' OR lower(a.filename) GLOB '*.avi' OR lower(a.filename) GLOB '*.mkv' OR lower(a.filename) GLOB '*.mts' OR lower(a.filename) GLOB '*.m2ts'))", [])?;
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(())
    }
    pub fn recover_cache(&self) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        tx.execute(
            "UPDATE media_cache SET status='failed',last_error='服务已重启，媒体处理已中断，请人工重试' WHERE status='processing' AND NOT EXISTS(SELECT 1 FROM remote_cache_tasks r WHERE r.library_id=media_cache.library_id AND r.asset_id=media_cache.asset_id AND r.completed=0 AND r.expires_at>unixepoch())",
            [],
        )?;
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(())
    }
    pub fn cache_status(&self, library: &str) -> Result<Value> {
        let mut connection = self.read()?;
        let db = connection.transaction()?;
        let mut counts = json!({"pending":0,"processing":0,"ready":0,"failed":0});
        let mut q = db.prepare(
            "SELECT status,count(*) FROM media_cache WHERE library_id=? AND EXISTS(SELECT 1 FROM catalog_assets a WHERE a.library_id=media_cache.library_id AND a.id=media_cache.asset_id AND a.trashed=0) GROUP BY status",
        )?;
        for item in q.query_map([library], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
        })? {
            let (state, count) = item?;
            counts[state] = json!(count);
        }
        let mut q=db.prepare("SELECT asset_id,last_error,attempts,available_at FROM media_cache WHERE library_id=? AND EXISTS(SELECT 1 FROM catalog_assets a WHERE a.library_id=media_cache.library_id AND a.id=media_cache.asset_id AND a.trashed=0) AND last_error IS NOT NULL ORDER BY updated_at DESC LIMIT 20")?;
        let errors=q.query_map([library], |r| Ok(json!({"assetID":r.get::<_,String>(0)?,"error":r.get::<_,String>(1)?,"attempts":r.get::<_,i64>(2)?,"retryAt":r.get::<_,i64>(3)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let last: Option<i64> = db.query_row(
            "SELECT max(updated_at) FROM media_cache WHERE library_id=? AND status='ready' AND EXISTS(SELECT 1 FROM catalog_assets a WHERE a.library_id=media_cache.library_id AND a.id=media_cache.asset_id AND a.trashed=0)",
            [library],
            |r| r.get(0),
        )?;
        let inventory: i64 = db.query_row(
            "SELECT count(*) FROM catalog_assets WHERE library_id=? AND trashed=0",
            [library],
            |r| r.get(0),
        )?;
        let eligible: i64 = db.query_row(
            "SELECT count(*) FROM media_cache WHERE library_id=? AND EXISTS(SELECT 1 FROM catalog_assets a WHERE a.library_id=media_cache.library_id AND a.id=media_cache.asset_id AND a.trashed=0)",
            [library],
            |r| r.get(0),
        )?;
        let runtime=db.query_row("SELECT next_batch_at,last_batch_count,last_batch_at,last_error,free_bytes FROM cache_runtime WHERE id=1",[],|r| Ok(json!({"nextBatchAt":r.get::<_,i64>(0)?,"lastBatchCount":r.get::<_,i64>(1)?,"lastBatchAt":r.get::<_,Option<i64>>(2)?,"lastError":r.get::<_,Option<String>>(3)?,"freeBytes":r.get::<_,Option<i64>>(4)?})))?;
        Ok(
            json!({"enabled":true,"localEncodingEnabled":local_encoding_enabled()?,"browse":crate::browse_cache::status(&db,library)?,"gc":crate::cache_gc::status(&db,library)?,"runtime":runtime,"totalAssets":inventory,"eligibleAssets":eligible,"pendingInventory":inventory-eligible,"counts":counts,"spec":spec()?,"batchLimit":1,"concurrency":1,"encoderThreads":1,"restSeconds":0,"maxAttempts":MAX_ATTEMPTS,"lastSuccessAt":last,"errors":errors}),
        )
    }
    pub fn rebuild_cache(&self, library: &str) -> Result<usize> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let changed = tx.execute("UPDATE media_cache SET status='pending',attempts=0,available_at=0,last_error=NULL WHERE rowid IN (SELECT rowid FROM media_cache WHERE library_id=? AND status='ready' ORDER BY updated_at LIMIT 20)",[library])?;
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(changed)
    }
    pub fn retry_cache(&self, library: &str) -> Result<usize> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        tx.execute("UPDATE media_cache SET browse_attempts=0,browse_available_at=0,browse_last_error=NULL WHERE library_id=? AND browse_last_error IS NOT NULL",[library])?;
        let changed = tx.execute("UPDATE media_cache SET status='pending',attempts=0,available_at=0,last_error=NULL,updated_at=0 WHERE rowid IN (SELECT rowid FROM media_cache WHERE library_id=? AND status IN ('pending','failed') AND last_error IS NOT NULL ORDER BY updated_at LIMIT 20)",[library])?;
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(changed)
    }
    pub fn cache_descriptors(&self, library: &str, asset: &str) -> Result<Option<(Value, Value)>> {
        let media = self.media_snapshot(library, asset)?;
        if media["thumbnail"].is_null() {
            return Ok(None);
        }
        Ok(Some((
            media["thumbnail"].clone(),
            media["standard"].clone(),
        )))
    }

    #[cfg(test)]
    fn claim_cache(&self) -> Result<Option<(String, String, String)>> {
        let _source = self
            .source_mutation
            .read()
            .map_err(|_| anyhow::anyhow!("source mutation lock poisoned"))?;
        let mut db = self.lock()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        crate::remote_worker::expire(&tx)?;
        let row=tx.query_row("SELECT library_id,asset_id,source_hash FROM media_cache WHERE status='pending' AND available_at<=unixepoch() AND EXISTS(SELECT 1 FROM catalog_assets a WHERE a.library_id=media_cache.library_id AND a.id=media_cache.asset_id AND a.trashed=0) AND NOT EXISTS(SELECT 1 FROM catalog_paths p JOIN import_compute_leases l ON l.library_id=p.library_id AND l.path=p.path WHERE p.library_id=media_cache.library_id AND p.asset_id=media_cache.asset_id AND l.expires_at>unixepoch()) ORDER BY updated_at,asset_id LIMIT 1",[],|r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?))).optional()?;
        if let Some((lib, id, _)) = &row {
            tx.execute("UPDATE media_cache SET status='processing',attempts=attempts+1,updated_at=unixepoch() WHERE library_id=? AND asset_id=?",params![lib,id])?;
        }
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(row)
    }
    pub(crate) fn defer_cache_for_scan(&self, jobs: &Jobs, lib: &str, id: &str) -> Result<bool> {
        let _source = self
            .source_mutation
            .read()
            .map_err(|_| anyhow::anyhow!("source mutation lock poisoned"))?;
        let paths = {
            let db = self.lock()?;
            let mut query = db.prepare("SELECT path FROM catalog_paths p WHERE p.library_id=? AND p.asset_id=? AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path)")?;
            query
                .query_map(params![lib, id], |row| row.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        for path in paths {
            if jobs.directory_scan_pending(lib, Path::new(&path))? {
                self.defer_cache_for_path_sync(lib, id)?;
                return Ok(true);
            }
        }
        Ok(false)
    }
    pub(crate) fn defer_cache_for_path_sync(&self, lib: &str, id: &str) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        tx.execute("UPDATE media_cache SET status='pending',attempts=MAX(attempts-1,0),available_at=unixepoch()+30 WHERE library_id=? AND asset_id=? AND status='processing'",params![lib,id])?;
        tx.execute("UPDATE remote_cache_tasks SET completed=-1 WHERE library_id=? AND asset_id=? AND completed=0",params![lib,id])?;
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(())
    }
    pub(crate) fn cache_failed(
        &self,
        lib: &str,
        id: &str,
        hash: &str,
        error: &str,
    ) -> Result<bool> {
        let mut db = self.lock()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let failed = record_failure(&tx, lib, id, hash, error)?;
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(failed)
    }
    pub(crate) fn cache_publish(
        &self,
        lib: &str,
        id: &str,
        hash: &str,
        thumbnail: &Value,
        standard: &Value,
    ) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let previous: Option<String> = tx
            .query_row(
                "SELECT thumbnail FROM media_cache WHERE library_id=? AND asset_id=?",
                params![lib, id],
                |r| r.get(0),
            )
            .optional()?
            .flatten();
        let changed=tx.execute("UPDATE media_cache SET status='ready',thumbnail=?,standard=?,last_error=NULL,updated_at=unixepoch() WHERE library_id=? AND asset_id=? AND source_hash=? AND spec=? AND status<>'cancelled' AND EXISTS(SELECT 1 FROM catalog_assets a LEFT JOIN catalog_defaults d ON a.library_id=d.library_id AND a.id=d.asset_id WHERE a.library_id=? AND a.id=? AND coalesce(d.content_hash,a.content_hash)=?)",params![thumbnail.to_string(),standard.to_string(),lib,id,hash,spec()?,lib,id,hash])?;
        if changed == 0 {
            tx.execute(
                "UPDATE media_cache SET status='pending' WHERE library_id=? AND asset_id=? AND source_hash=? AND status='processing'",
                params![lib, id, hash],
            )?;
        } else {
            tx.execute("UPDATE remote_cache_tasks SET completed=1 WHERE library_id=? AND asset_id=? AND source_hash=? AND completed=0",params![lib,id,hash])?;
            if let Some(previous) = previous {
                let previous: Value = serde_json::from_str(&previous)?;
                crate::cache_gc::enqueue(
                    &tx,
                    lib,
                    id,
                    &previous["objectRef"],
                    &thumbnail["objectRef"],
                    chrono::Utc::now().timestamp(),
                )?;
            }
            crate::cache_gc::switch_preview(
                &tx,
                lib,
                id,
                thumbnail,
                chrono::Utc::now().timestamp(),
            )?;
            tx.execute("INSERT OR IGNORE INTO catalog_revision_dirty(library_id,kind,key) VALUES(?,'asset',?)",params![lib,id])?;
        }
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(())
    }
    fn asset_cache_current(&self, previews: &PreviewStorage, lib: &str, id: &str) -> Result<bool> {
        let descriptors: Option<(String, String, String)> = self.lock()?.query_row(
            "SELECT c.thumbnail,c.standard,a.filename FROM media_cache c JOIN catalog_assets a ON a.library_id=c.library_id AND a.id=c.asset_id LEFT JOIN catalog_defaults d ON d.library_id=a.library_id AND d.asset_id=a.id WHERE c.library_id=?1 AND c.asset_id=?2 AND c.published_source_hash=coalesce(d.content_hash,a.content_hash) AND c.published_spec=?3 AND c.thumbnail IS NOT NULL AND c.standard IS NOT NULL",
            params![lib, id, spec()?], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        ).optional()?;
        let Some((thumbnail, standard, filename)) = descriptors else {
            return Ok(false);
        };
        let thumbnail: Value = serde_json::from_str(&thumbnail)?;
        let standard: Value = serde_json::from_str(&standard)?;
        if media::is_video(Path::new(&filename))
            && !thumbnail["version"]
                .as_str()
                .is_some_and(|v| v.starts_with("video-v3:"))
        {
            return Ok(false);
        }
        Ok(previews.contains(&thumbnail["objectRef"])? && standard_current(&standard)?)
    }
}

/// Explicit cache operations are finite manual jobs, never background priority changes.
pub fn queue_manual(store: &Store, jobs: &Jobs, library: &str, rebuild: bool) -> Result<usize> {
    let paths = {
        let db = store.lock()?;
        let mut q=db.prepare("SELECT (SELECT p.path FROM catalog_paths p WHERE p.library_id=c.library_id AND p.asset_id=c.asset_id AND p.content_hash=c.source_hash ORDER BY p.path LIMIT 1) FROM media_cache c WHERE c.library_id=?1 AND ((?2=1 AND c.status='ready') OR (?2=0 AND c.status IN ('pending','failed') AND c.last_error IS NOT NULL)) ORDER BY c.updated_at LIMIT 20")?;
        q.query_map(params![library, rebuild], |r| r.get::<_, Option<String>>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    let folders = jobs.folders()?;
    let targets = paths
        .into_iter()
        .map(|p| {
            let path = p.context("cannot retry a photo without an indexed source path")?;
            let folder = folders
                .iter()
                .filter(|f| {
                    f.active && f.library_id == library && Path::new(&path).starts_with(&f.path)
                })
                .max_by_key(|f| f.path.len())
                .context("photo has no active source folder")?;
            Ok((folder.id.clone(), path))
        })
        .collect::<Result<Vec<_>>>()?;
    let mut queued = std::collections::HashSet::new();
    for (folder, path) in targets {
        let job = if rebuild {
            jobs.enqueue_manual_media_rebuild(&folder, Path::new(&path))?
        } else {
            jobs.enqueue_manual_file(&folder, Path::new(&path))?
        };
        store.note_revision_activity(library, &job.id, &job.path)?;
        queued.insert(job.id);
    }
    Ok(queued.len())
}

/// Finish media preparation inside the same non-preemptible indexed photo unit.
pub fn process_asset(
    store: &Store,
    jobs: &Jobs,
    previews: &PreviewStorage,
    lib: &str,
    id: &str,
) -> Result<()> {
    process_asset_with_override(store, jobs, previews, lib, id, false).map(|_| ())
}

pub fn process_asset_with_override(
    store: &Store,
    jobs: &Jobs,
    previews: &PreviewStorage,
    lib: &str,
    id: &str,
    override_media: bool,
) -> Result<bool> {
    let selected: Option<(String, String)> = {
        let _source = store
            .source_mutation
            .read()
            .map_err(|_| anyhow::anyhow!("source mutation lock poisoned"))?;
        let mut db = store.lock()?;
        let tx = db.transaction()?;
        tx.execute("INSERT INTO media_cache(library_id,asset_id,source_hash,spec) SELECT a.library_id,a.id,coalesce(d.content_hash,a.content_hash),?3 FROM catalog_assets a LEFT JOIN catalog_defaults d ON d.library_id=a.library_id AND d.asset_id=a.id WHERE a.library_id=?1 AND a.id=?2 AND a.trashed=0 ON CONFLICT(library_id,asset_id) DO UPDATE SET source_hash=excluded.source_hash,spec=excluded.spec,status='pending',attempts=0,available_at=0,last_error=NULL WHERE media_cache.source_hash!=excluded.source_hash OR media_cache.spec!=excluded.spec OR (media_cache.status='cancelled' AND EXISTS(SELECT 1 FROM catalog_paths p WHERE p.library_id=excluded.library_id AND p.asset_id=excluded.asset_id AND p.content_hash=excluded.source_hash AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path)))",params![lib,id,spec()?])?;
        let reserved: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM catalog_paths p JOIN import_compute_leases l ON l.library_id=p.library_id AND l.path=p.path WHERE p.library_id=? AND p.asset_id=? AND l.expires_at>unixepoch())",params![lib,id],|r|r.get(0))?;
        if reserved {
            crate::revisions::flush(&tx)?;
            tx.commit()?;
            return Ok(false);
        }
        let row: Option<(String, String)> = tx
            .query_row(
                "SELECT source_hash,status FROM media_cache WHERE library_id=? AND asset_id=?",
                params![lib, id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        row
    };
    let Some((hash, status)) = selected else {
        return Ok(false);
    };
    if status == "cancelled" {
        return Ok(false);
    }
    ensure!(status != "processing", "photo media is already processing");
    if !override_media && store.asset_cache_current(previews, lib, id)? {
        prepare_asset_cache(store, lib, id, &hash, true)?;
        return crate::browse_cache::process_asset(store, previews, lib, id);
    }
    prepare_asset_cache(store, lib, id, &hash, false)?;
    let result = (|| {
        ensure!(
            local_encoding_enabled()?,
            "local photo encoding is disabled"
        );
        ensure!(
            previews.free_bytes()? >= 2 * 1024 * 1024 * 1024,
            "cache disk has less than 2 GiB free"
        );
        generate(store, jobs, previews, lib, id, &hash, override_media)
    })();
    if let Err(error) = &result {
        store.cache_failed(lib, id, &hash, &format!("{error:#}"))?;
    }
    store.lock()?.execute("UPDATE cache_runtime SET last_batch_count=1,last_batch_at=unixepoch(),next_batch_at=0 WHERE id=1",[])?;
    let generated = result?;
    let browse_generated =
        crate::browse_cache::process_asset_with_override(store, previews, lib, id, override_media)?;
    Ok(generated || browse_generated)
}

fn prepare_asset_cache(store: &Store, lib: &str, id: &str, hash: &str, reuse: bool) -> Result<()> {
    let mut db = store.lock()?;
    let tx = db.transaction()?;
    let changed = tx.execute(
        "UPDATE media_cache SET status=CASE WHEN ?5 THEN 'ready' ELSE 'processing' END,attempts=attempts+CASE WHEN ?5 THEN 0 ELSE 1 END,last_error=NULL WHERE library_id=?1 AND asset_id=?2 AND source_hash=?3 AND spec=?4 AND status NOT IN ('processing','cancelled') AND (NOT ?5 OR (published_source_hash=?3 AND published_spec=?4)) AND EXISTS(SELECT 1 FROM catalog_assets a LEFT JOIN catalog_defaults d ON d.library_id=a.library_id AND d.asset_id=a.id WHERE a.library_id=?1 AND a.id=?2 AND a.trashed=0 AND coalesce(d.content_hash,a.content_hash)=?3)",
        params![lib, id, hash, spec()?, reuse],
    )?;
    ensure!(
        changed == 1,
        "photo media source or processing state changed before execution"
    );
    crate::revisions::flush(&tx)?;
    tx.commit()?;
    Ok(())
}

fn generate(
    store: &Store,
    jobs: &Jobs,
    previews: &PreviewStorage,
    lib: &str,
    id: &str,
    hash: &str,
    override_media: bool,
) -> Result<bool> {
    let selected = if let Some(selected) = store.default_version(lib, id)? {
        selected
    } else {
        store.lock()?.query_row("SELECT content_hash,path FROM catalog_paths p WHERE library_id=? AND asset_id=? AND content_hash=? AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path) ORDER BY path LIMIT 1",params![lib,id,hash],|r| Ok(crate::versions::DefaultVersion {content_hash:r.get(0)?,path:r.get(1)?})).optional()?.context("no indexed source path available")?
    };
    ensure!(
        selected.content_hash == hash,
        "selected source changed before processing"
    );
    let source = Path::new(&selected.path);
    if !source.try_exists()? && jobs.path_sync_pending(lib, source)? {
        store.defer_cache_for_path_sync(lib, id)?;
        return Ok(false);
    }
    jobs.validate_path(source.parent().context("source parent missing")?)?;
    ensure!(
        !fs::symlink_metadata(source)?.file_type().is_symlink(),
        "source symlink forbidden"
    );
    ensure!(
        crate::imports::file_digest(jobs, lib, source)? == hash,
        "source content differs from indexed version"
    );
    let standard_source =
        select_standard_source_with_override(store, lib, id, &selected, override_media)?;
    let standard_input = Path::new(&standard_source.path);
    jobs.validate_path(
        standard_input
            .parent()
            .context("standard source parent missing")?,
    )?;
    ensure!(
        !fs::symlink_metadata(standard_input)?
            .file_type()
            .is_symlink(),
        "standard source symlink forbidden"
    );
    ensure!(
        crate::imports::file_digest(jobs, lib, standard_input)? == standard_source.content_hash,
        "standard source content differs from indexed version"
    );
    let metadata = MediaProcessor::new().extract(standard_input)?;
    let extension = standard_input
        .extension()
        .and_then(|v| v.to_str())
        .unwrap_or("")
        .to_lowercase();
    let (standard_path, standard_hash, width, height) = if !media::is_raw(standard_input)
        || extension == "3fr"
    {
        (
            standard_input.to_path_buf(),
            standard_source.content_hash.clone(),
            metadata.width,
            metadata.height,
        )
    } else {
        let root = standard_input
            .parent()
            .context("standard source parent missing")?;
        ensure!(
            free_bytes(root)? >= 2 * 1024 * 1024 * 1024,
            "standard photo disk has less than 2 GiB free"
        );
        let target = store.generated_standard_target_with_override(
            lib,
            id,
            standard_input,
            &standard_source.content_hash,
            override_media,
        )?;
        if !target.exists() {
            let scratch = tempfile::tempdir_in(root)?;
            let staged = scratch.path().join("standard.heic");
            ensure!(
                metadata.width > 0 && metadata.height > 0,
                "source dimensions missing for standard photo generation"
            );
            let generated_standard = MediaProcessor::new().generate_standard(
                standard_input,
                &staged,
                u32::try_from(metadata.width.max(metadata.height))?,
            )?;
            MediaProcessor::new().preserve_standard_metadata(standard_input, &staged)?;
            ensure!(
                crate::imports::file_digest(jobs, lib, standard_input)?
                    == standard_source.content_hash,
                "standard input changed during generation"
            );
            crate::identity::generated(&staged, &store.root_id(lib, id)?)?;
            store.publish_generated_standard(
                lib,
                id,
                &standard_source.content_hash,
                &staged,
                &target,
                (
                    i64::from(generated_standard.width),
                    i64::from(generated_standard.height),
                ),
            )?;
        }
        ensure!(
            store.generated_standard_matches(lib, id, &target)?,
            "existing standard photo is not registered to this asset; refusing to adopt or replace it"
        );
        let m = MediaProcessor::new().extract(&target)?;
        (
            target.clone(),
            media::sha256_file(&target)?,
            m.width,
            m.height,
        )
    };
    let scratch = tempfile::tempdir()?;
    let target = scratch.path().join("thumbnail.heic");
    let generated = MediaProcessor::new().generate_image_quality(
        &standard_path,
        &target,
        512,
        thumbnail_quality()?,
    )?;
    ensure!(
        crate::imports::file_digest(jobs, lib, source)? == hash,
        "source changed during generation"
    );
    ensure!(
        crate::imports::file_digest(jobs, lib, standard_input)? == standard_source.content_hash,
        "standard input changed during generation"
    );
    let object = previews.put_generated_role(lib, id, &generated.sha256, &target, "thumbnail")?;
    let thumbnail = json!({"objectRef":object,"width":generated.width,"height":generated.height,"version":format!("{}{}:{}",if media::is_video(standard_input) { "video-v3:" } else { "" },spec()?,generated.sha256),"sizeBytes":generated.size_bytes});
    let standard = json!({"path":standard_path,"width":width,"height":height,"version":standard_hash,"sizeBytes":fs::metadata(&standard_path)?.len(),"mtimeNs":file_mtime(&standard_path)?,"deferred":extension == "3fr"});
    store.cache_publish(lib, id, hash, &thumbnail, &standard)?;
    tracing::info!(asset_id=%id,bytes=generated.size_bytes,"NAS thumbnail ready");
    Ok(true)
}

pub fn free_bytes(path: &Path) -> Result<i64> {
    let output = std::process::Command::new("df")
        .arg("-Pk")
        .arg(path)
        .output()
        .context("read filesystem free space")?;
    ensure!(
        output.status.success(),
        "df failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let output = String::from_utf8(output.stdout)?;
    let line = output.lines().last().context("df returned no filesystem")?;
    let available = line
        .split_whitespace()
        .nth(3)
        .context("df missing available space")?
        .parse::<i64>()?;
    Ok(available * 1024)
}

pub fn file_mtime(path: &Path) -> Result<String> {
    Ok(fs::metadata(path)?
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)?
        .as_nanos()
        .to_string())
}

pub fn standard_current(standard: &Value) -> Result<bool> {
    let path = Path::new(standard["path"].as_str().context("standard path missing")?);
    match fs::metadata(path) {
        Ok(info) => Ok(info.is_file()
            && Some(info.len()) == standard["sizeBytes"].as_u64()
            && Some(file_mtime(path)?.as_str()) == standard["mtimeNs"].as_str()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error.into()),
    }
}

pub(crate) fn select_standard_source(
    store: &Store,
    library: &str,
    asset: &str,
    selected: &crate::versions::DefaultVersion,
) -> Result<crate::versions::DefaultVersion> {
    select_standard_source_with_override(store, library, asset, selected, false)
}

fn select_standard_source_with_override(
    store: &Store,
    library: &str,
    asset: &str,
    selected: &crate::versions::DefaultVersion,
    override_media: bool,
) -> Result<crate::versions::DefaultVersion> {
    if !media::is_raw(Path::new(&selected.path)) {
        return Ok(selected.clone());
    }
    let db = store.lock()?;
    let mut q=db.prepare("SELECT content_hash,path FROM catalog_paths p WHERE library_id=? AND asset_id=? AND role='jpeg_original' AND (?3=0 OR NOT EXISTS(SELECT 1 FROM catalog_versions v WHERE v.library_id=p.library_id AND v.asset_id=p.asset_id AND v.content_hash=p.content_hash AND json_extract(v.evidence,'$.generatedFrom') IS NOT NULL)) AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path) ORDER BY path")?;
    let rows = q.query_map(params![library, asset, override_media], |r| {
        Ok(crate::versions::DefaultVersion {
            content_hash: r.get(0)?,
            path: r.get(1)?,
        })
    })?;
    for row in rows {
        let row = row?;
        let path = Path::new(&row.path);
        let extension = path
            .extension()
            .and_then(|v| v.to_str())
            .unwrap_or("")
            .to_lowercase();
        if ["jpg", "jpeg", "heic", "heif", "hif"].contains(&extension.as_str()) && path.is_file() {
            return Ok(row);
        }
    }
    Ok(selected.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reconcile_requeues_only_old_video_thumbnails() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        for (id, filename, version) in [
            ("old-video", "clip.MP4", "thumbnail-heic-512-q50-v1:old"),
            (
                "green-video",
                "green.mp4",
                "video-v2:thumbnail-heic-512-q50-v1:green",
            ),
            (
                "new-video",
                "clip.mov",
                "video-v3:thumbnail-heic-512-q50-v1:new",
            ),
            ("photo", "still.jpg", "thumbnail-heic-512-q50-v1:photo"),
        ] {
            store.lock()?.execute("INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES('lib',?1,'{}',?1,?1,'2024-01-01',?2,0,'unflagged',NULL,0)",params![id,filename])?;
            store.reconcile_cache()?;
            store.lock()?.execute(
                "UPDATE media_cache SET status='ready',thumbnail=?2 WHERE asset_id=?1",
                params![id, json!({"version":version}).to_string()],
            )?;
        }
        store.reconcile_cache()?;
        let db = store.lock()?;
        let mut q = db.prepare("SELECT asset_id,status FROM media_cache ORDER BY asset_id")?;
        let rows = q
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        assert_eq!(
            rows,
            [
                ("green-video".into(), "pending".into()),
                ("new-video".into(), "ready".into()),
                ("old-video".into(), "pending".into()),
                ("photo".into(), "ready".into())
            ]
        );
        Ok(())
    }
    fn seed(store: &Store, n: usize) -> Result<()> {
        for index in 0..n {
            let id = format!("00000000-0000-0000-0000-{index:012}");
            store.lock()?.execute("INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES('lib',?,?,?,'fingerprint','2024-01-01','photo.jpg',3,'picked',NULL,0)",params![id,json!({"id":id,"rating":3,"tags":["keep"]}).to_string(),format!("hash{index}")])?;
        }
        Ok(())
    }
    #[test]
    fn revoking_ready_cache_publishes_immediately_and_noop_rebuild_keeps_version() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        seed(&store, 1)?;
        store.reconcile_cache()?;
        {
            let mut db = store.lock()?;
            let tx = db.transaction()?;
            tx.execute(
                "UPDATE media_cache SET status='ready',thumbnail='{}',standard='{}'",
                [],
            )?;
            crate::revisions::flush(&tx)?;
            tx.commit()?;
        }
        let before = store.library_revision("lib")?["revision"].as_i64().unwrap();
        assert_eq!(store.rebuild_cache("lib")?, 1);
        let after = store.library_revision("lib")?["revision"].as_i64().unwrap();
        assert_eq!(after, before + 1);
        assert_eq!(store.rebuild_cache("lib")?, 0);
        assert_eq!(store.library_revision("lib")?["revision"], after);
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT count(*) FROM catalog_revision_dirty", [], |r| r
                    .get::<_, i64>(0))?,
            0
        );
        Ok(())
    }

    #[test]
    fn import_compute_lease_blocks_nas_claim_and_direct_encoding_until_expiry() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let jobs = Jobs::open(&dir.path().join("jobs"), dir.path())?;
        seed(&store, 1)?;
        store.reconcile_cache()?;
        let id = "00000000-0000-0000-0000-000000000000";
        let path = dir.path().join("photo.jpg").to_string_lossy().into_owned();
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib',?,?,'hash0','jpeg_original')",
            params![path, id],
        )?;
        store.lock()?.execute(
            "INSERT INTO import_compute_leases VALUES('lib','batch',?,'mac',unixepoch()+3600)",
            [&path],
        )?;
        assert!(store.claim_cache()?.is_none());
        let previews = PreviewStorage::new(
            &dir.path().join("previews"),
            None,
            "http://localhost",
            "test-key",
        )?;
        process_asset(&store, &jobs, &previews, "lib", id)?;
        let attempts: i64 =
            store
                .lock()?
                .query_row("SELECT attempts FROM media_cache", [], |r| r.get(0))?;
        assert_eq!(attempts, 0);
        store.lock()?.execute(
            "UPDATE import_compute_leases SET expires_at=unixepoch()-1",
            [],
        )?;
        assert!(store.claim_cache()?.is_some());
        Ok(())
    }
    #[test]
    fn obsolete_generation_error_still_fails_the_parent_task() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let jobs = Jobs::open(&dir.path().join("jobs"), dir.path())?;
        seed(&store, 1)?;
        let previews = PreviewStorage::new(
            &dir.path().join("previews"),
            None,
            "http://localhost",
            "test-key",
        )?;
        let result = process_asset(
            &store,
            &jobs,
            &previews,
            "lib",
            "00000000-0000-0000-0000-000000000000",
        );
        assert!(result.is_err());
        assert_eq!(store.cache_status("lib")?["counts"]["cancelled"], 1);
        Ok(())
    }

    #[test]
    fn obsolete_failure_stays_cancelled_until_source_is_reindexed() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let jobs = Jobs::open(&dir.path().join("jobs"), dir.path())?;
        seed(&store, 1)?;
        store.reconcile_cache()?;
        let (lib, id, hash) = store.claim_cache()?.unwrap();
        assert!(!store.cache_failed(&lib, &id, &hash, "no indexed source path")?);
        store.reconcile_cache()?;
        assert!(store.claim_cache()?.is_none());
        let status = crate::tasks::status(&store, &jobs, &lib)?;
        assert_eq!(status["automatic"]["remainingPhotos"], 0);
        assert_eq!(status["automatic"]["failedPhotos"], 0);
        store.cache_publish(&lib, &id, &hash, &json!({}), &json!({}))?;
        assert_eq!(store.cache_status(&lib)?["counts"]["cancelled"], 1);
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib','/photos/restored.jpg',?,?,'jpeg_original')",
            params![id, hash],
        )?;
        store.reconcile_cache()?;
        assert_eq!(store.claim_cache()?.unwrap().2, hash);
        Ok(())
    }

    #[test]
    fn failure_stops_changed_source_until_explicit_retry() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        seed(&store, 1)?;
        store.reconcile_cache()?;
        let (lib, id, old) = store.claim_cache()?.unwrap();
        store
            .lock()?
            .execute("UPDATE catalog_assets SET content_hash='new'", [])?;
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib','/photos/current.jpg',?,'new','jpeg_original')",
            [&id],
        )?;
        assert!(!store.cache_failed(&lib, &id, &old, "old generation failed")?);
        let row: (String, String, i64, Option<String>) = store.lock()?.query_row(
            "SELECT source_hash,status,attempts,last_error FROM media_cache",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )?;
        assert_eq!(
            row,
            (
                "new".into(),
                "failed".into(),
                0,
                Some("old generation failed".into())
            )
        );
        assert!(store.claim_cache()?.is_none());
        store.retry_cache(&lib)?;
        store.claim_cache()?.unwrap();
        assert!(!store.cache_failed(&lib, &id, &old, "late old failure")?);
        assert!(store.cache_failed(&lib, &id, "new", "permission denied: full cause chain")?);
        assert_eq!(
            store.cache_status(&lib)?["errors"][0]["error"],
            "permission denied: full cause chain"
        );
        Ok(())
    }

    #[test]
    fn scan_gate_keeps_other_photos_in_same_directory_claimable() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let originals = dir.path().join("photos");
        fs::create_dir_all(&originals)?;
        let jobs = Jobs::open(&dir.path().join("jobs"), &originals)?;
        let folder = jobs.add_folder("lib", ".")?;
        let originals = jobs.root().to_path_buf();
        seed(&store, 2)?;
        for (index, path) in [originals.join("a.3fr"), originals.join("b.heic")]
            .iter()
            .enumerate()
        {
            store.lock()?.execute(
                "INSERT INTO catalog_paths VALUES('lib',?,?,?,'jpeg_original')",
                params![
                    path.to_str().unwrap(),
                    format!("00000000-0000-0000-0000-{index:012}"),
                    format!("hash{index}")
                ],
            )?;
        }
        jobs.enqueue_file_change(&folder.id, &originals.join("a.heic"), 0)?;
        store.reconcile_cache()?;
        let (lib, id, _) = store.claim_cache()?.unwrap();
        assert!(store.defer_cache_for_scan(&jobs, &lib, &id)?);
        let state: (String, i64, bool) = store.lock()?.query_row(
            "SELECT status,attempts,available_at>unixepoch() FROM media_cache WHERE asset_id=?",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?;
        assert_eq!(state, ("pending".into(), 0, true));
        let (lib, other, _) = store.claim_cache()?.unwrap();
        assert_ne!(id, other);
        assert!(!store.defer_cache_for_scan(&jobs, &lib, &other)?);
        Ok(())
    }
    #[test]
    fn legacy_assets_without_versions_are_queued_and_identity_is_preserved() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        seed(&store, 23)?;
        store.reconcile_cache()?;
        store.reconcile_cache()?;
        let status = store.cache_status("lib")?;
        assert_eq!(status["totalAssets"], 23);
        assert_eq!(status["counts"]["pending"], 23);
        assert_eq!(status["pendingInventory"], 0);
        assert_eq!(
            store.lock()?.query_row(
                "SELECT count(*) FROM photos WHERE json_extract(snapshot,'$.rating')=3",
                [],
                |r| r.get::<_, i64>(0)
            )?,
            23
        );
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT count(*) FROM videos", [], |r| r.get::<_, i64>(0))?,
            0
        );
        Ok(())
    }
    #[test]
    fn trashed_assets_preserve_cache_history_and_leave_inventory() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        seed(&store, 2)?;
        store.reconcile_cache()?;
        store.lock()?.execute("UPDATE catalog_assets SET trashed=1 WHERE id=(SELECT id FROM catalog_assets ORDER BY id LIMIT 1)", [])?;
        store.reconcile_cache()?;
        let status = store.cache_status("lib")?;
        assert_eq!(status["totalAssets"], 1);
        assert_eq!(status["eligibleAssets"], 1);
        assert_eq!(status["counts"]["pending"], 1);
        assert!(store.claim_cache()?.is_some());
        assert!(store.claim_cache()?.is_none());
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT count(*) FROM media_cache", [], |r| r
                    .get::<_, i64>(0))?,
            2
        );
        store.lock()?.execute("DELETE FROM media_cache WHERE asset_id IN (SELECT id FROM catalog_assets WHERE trashed=1)", [])?;
        store.reconcile_cache()?;
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT count(*) FROM media_cache", [], |r| r
                    .get::<_, i64>(0))?,
            1
        );
        Ok(())
    }
    #[test]
    fn recovery_and_first_failure_require_manual_retry() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let db = dir.path().join("db");
        let store = Store::open(&db, true)?;
        seed(&store, 1)?;
        store.reconcile_cache()?;
        let (lib, id, hash) = store.claim_cache()?.unwrap();
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib','/photos/live.jpg',?,?,'jpeg_original')",
            params![id, hash],
        )?;
        drop(store);
        let store = Store::open(&db, false)?;
        store.recover_cache()?;
        assert_eq!(store.cache_status("lib")?["counts"]["failed"], 1);
        assert!(store.claim_cache()?.is_none());
        assert_eq!(store.retry_cache("lib")?, 1);
        store.claim_cache()?.unwrap();
        store.cache_failed(&lib, &id, &hash, "full error chain")?;
        assert_eq!(store.cache_status("lib")?["counts"]["failed"], 1);
        assert!(store.claim_cache()?.is_none());
        assert_eq!(store.retry_cache("lib")?, 1);
        store
            .lock()?
            .execute("UPDATE catalog_assets SET content_hash='new'", [])?;
        store.reconcile_cache()?;
        assert_eq!(store.claim_cache()?.unwrap().2, "new");
        Ok(())
    }
    #[test]
    fn new_spec_retires_previous_thumbnail_only_after_successful_publication() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        seed(&store, 1)?;
        store.reconcile_cache()?;
        let (library, id, hash) = store.claim_cache()?.unwrap();
        let previews = PreviewStorage::new(
            &dir.path().join("keeps"),
            None,
            "http://localhost",
            "test-key",
        )?;
        let source = dir.path().join("fixture");
        fs::write(&source, b"thumbnail")?;
        let old = previews.put_generated_role(&library, &id, "old", &source, "thumbnail")?;
        let new = previews.put_generated_role(&library, &id, "new", &source, "thumbnail")?;
        store.lock()?.execute(
            "UPDATE media_cache SET status='ready',thumbnail=?,spec='old-spec'",
            [json!({"objectRef":old}).to_string()],
        )?;
        store.reconcile_cache()?;
        assert_eq!(
            store.lock()?.query_row(
                "SELECT json_extract(thumbnail,'$.objectRef.key') FROM media_cache",
                [],
                |r| r.get::<_, String>(0)
            )?,
            old["key"].as_str().unwrap()
        );
        let thumbnail =
            json!({"objectRef":new,"version":"spec:new","width":512,"height":384,"sizeBytes":9});
        store.cache_publish(&library, &id, &hash, &thumbnail, &json!({}))?;
        assert!(previews.contains(&old)?);
        assert_eq!(store.collect_asset_cache_garbage(&previews, "lib", &id)?, 1);
        assert!(previews.contains(&new)?);
        Ok(())
    }
    #[test]
    fn explicit_retry_includes_pending_errors_but_not_ready_or_processing() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        seed(&store, 25)?;
        store.reconcile_cache()?;
        store.lock()?.execute("UPDATE media_cache SET last_error='timeout',attempts=1,available_at=9999999999,updated_at=123",[])?;
        store.lock()?.execute("UPDATE media_cache SET status='processing' WHERE asset_id='00000000-0000-0000-0000-000000000023'",[])?;
        store.lock()?.execute("UPDATE media_cache SET status='ready' WHERE asset_id='00000000-0000-0000-0000-000000000024'",[])?;
        assert_eq!(store.retry_cache("lib")?, 20);
        assert_eq!(store.lock()?.query_row("SELECT count(*) FROM media_cache WHERE status='pending' AND last_error IS NULL AND attempts=0 AND available_at=0 AND updated_at=0",[],|r|r.get::<_,i64>(0))?,20);
        assert_eq!(store.lock()?.query_row("SELECT count(*) FROM media_cache WHERE status IN ('processing','ready') AND last_error='timeout' AND attempts=1 AND updated_at=123",[],|r|r.get::<_,i64>(0))?,2);
        assert!(store.claim_cache()?.is_some());
        assert_eq!(store.retry_cache("lib")?, 3);
        assert_eq!(store.retry_cache("lib")?, 0);
        Ok(())
    }
    #[test]
    fn confirmed_raw_jpeg_pair_reuses_standard_and_raw_only_keeps_raw() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        seed(&store, 1)?;
        let id = "00000000-0000-0000-0000-000000000000";
        let raw = dir.path().join("different-name.arw");
        fs::write(&raw, b"raw")?;
        let selected = crate::versions::DefaultVersion {
            content_hash: "rawhash".into(),
            path: raw.to_str().unwrap().into(),
        };
        assert_eq!(
            select_standard_source(&store, "lib", id, &selected)?.content_hash,
            "rawhash"
        );
        let jpeg = dir.path().join("confirmed.jpg");
        fs::write(&jpeg, b"jpeg")?;
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES('lib',?,?,'jpeghash','jpeg_original')",
            params![jpeg.to_str(), id],
        )?;
        assert_eq!(
            select_standard_source(&store, "lib", id, &selected)?.content_hash,
            "jpeghash"
        );
        store.lock()?.execute(
            "INSERT INTO catalog_versions(library_id,asset_id,content_hash,width,height,priority,evidence) VALUES('lib',?,'jpeghash',512,384,1,?)",
            params![id, json!({"generatedFrom":"rawhash"}).to_string()],
        )?;
        assert_eq!(
            select_standard_source_with_override(&store, "lib", id, &selected, true)?.content_hash,
            "rawhash"
        );
        store.lock()?.execute(
            "INSERT INTO catalog_defaults VALUES('lib',?,'rawhash',1)",
            [id],
        )?;
        assert_eq!(
            select_standard_source(&store, "lib", id, &selected)?.content_hash,
            "jpeghash"
        );
        store.lock()?.execute("INSERT INTO catalog_deprecated_files VALUES('lib',?,'retained.jpg','content_hash','duplicate')", [jpeg.to_str()])?;
        assert_eq!(
            select_standard_source(&store, "lib", id, &selected)?.content_hash,
            "rawhash"
        );
        Ok(())
    }
    #[test]
    fn manual_cache_validation_detects_changed_stat_without_background_queueing() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        seed(&store, 1)?;
        store.reconcile_cache()?;
        let (_, id, _) = store.claim_cache()?.unwrap();
        let previews = PreviewStorage::new(
            &dir.path().join("keeps"),
            None,
            "http://localhost",
            "test-key",
        )?;
        let source = dir.path().join("source.jpg");
        fs::write(&source, b"bytes")?;
        let object = previews.put_generated_role("lib", &id, "thumb", &source, "thumbnail")?;
        let standard = json!({"path":source,"sizeBytes":5,"mtimeNs":file_mtime(&source)?});
        store.lock()?.execute(
            "UPDATE media_cache SET status='ready',thumbnail=?,standard=?,updated_at=123",
            params![
                json!({"objectRef":object}).to_string(),
                standard.to_string()
            ],
        )?;
        assert!(store.asset_cache_current(&previews, "lib", &id)?);
        assert_eq!(store.cache_status("lib")?["lastSuccessAt"], 123);
        std::thread::sleep(std::time::Duration::from_millis(5));
        fs::write(&source, b"bytes")?;
        assert!(!store.asset_cache_current(&previews, "lib", &id)?);
        assert_eq!(store.cache_status("lib")?["counts"]["ready"], 1);
        assert_eq!(fs::read(source)?, b"bytes");
        Ok(())
    }
    #[test]
    fn normal_retry_reuses_published_media_but_override_attempts_generation() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let jobs = Jobs::open(&dir.path().join("jobs"), dir.path())?;
        seed(&store, 1)?;
        store.reconcile_cache()?;
        let id = "00000000-0000-0000-0000-000000000000";
        let previews = PreviewStorage::new(
            &dir.path().join("keeps"),
            None,
            "http://localhost",
            "test-key",
        )?;
        let source = dir.path().join("source.jpg");
        fs::write(&source, b"bytes")?;
        let object = previews.put_generated_role("lib", id, "thumb", &source, "thumbnail")?;
        let thumbnail =
            json!({"objectRef":object,"version":"current","width":512,"height":384,"sizeBytes":5});
        let standard = json!({"path":source,"sizeBytes":5,"mtimeNs":file_mtime(&source)?,"width":512,"height":384,"version":"source"});
        store.cache_publish("lib", id, "hash0", &thumbnail, &standard)?;
        let browse = json!({"objectRef":object,"sourceThumbnailVersion":"current","spec":crate::browse_cache::SPEC,"version":"browse","width":64,"height":48,"sizeBytes":5});
        store.lock()?.execute(
            "UPDATE media_cache SET status='failed',last_error='interrupted',browse_thumbnail=?",
            [browse.to_string()],
        )?;
        assert!(!process_asset_with_override(
            &store, &jobs, &previews, "lib", id, false
        )?);
        assert_eq!(store.cache_status("lib")?["counts"]["ready"], 1);
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT attempts FROM media_cache", [], |r| r
                    .get::<_, i64>(0))?,
            0
        );
        assert!(process_asset_with_override(&store, &jobs, &previews, "lib", id, true).is_err());
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT thumbnail FROM media_cache", [], |r| r
                    .get::<_, String>(0))?,
            thumbnail.to_string()
        );
        assert_eq!(store.media_snapshot("lib", id)?["thumbnail"], thumbnail);
        assert_eq!(fs::read(&source)?, b"bytes");
        store
            .lock()?
            .execute("UPDATE catalog_assets SET content_hash='changed'", [])?;
        store.reconcile_cache()?;
        assert!(!store.asset_cache_current(&previews, "lib", id)?);
        Ok(())
    }

    #[test]
    fn cache_preparation_rejects_source_changes_without_relabeling_published_media() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        seed(&store, 1)?;
        store.reconcile_cache()?;
        let id = "00000000-0000-0000-0000-000000000000";
        store.cache_publish("lib", id, "hash0", &json!({"version":"old","width":512,"height":384,"sizeBytes":5,"objectRef":{"bucket":"keeps-previews","key":"libraries/lib/assets/asset/derivatives/thumbnail/old.heic"}}), &json!({}))?;
        store
            .lock()?
            .execute("UPDATE catalog_assets SET content_hash='changed'", [])?;
        for reuse in [false, true] {
            assert!(prepare_asset_cache(&store, "lib", id, "hash0", reuse).is_err());
        }
        store.reconcile_cache()?;
        for reuse in [false, true] {
            assert!(prepare_asset_cache(&store, "lib", id, "hash0", reuse).is_err());
        }
        assert!(prepare_asset_cache(&store, "lib", id, "changed", true).is_err());
        let retained: (String,String,String) = store.lock()?.query_row(
            "SELECT status,published_source_hash,json_extract(thumbnail,'$.version') FROM media_cache",
            [], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?)),
        )?;
        assert_eq!(retained, ("pending".into(), "hash0".into(), "old".into()));
        prepare_asset_cache(&store, "lib", id, "changed", false)?;
        assert!(prepare_asset_cache(&store, "lib", id, "changed", false).is_err());
        Ok(())
    }

    #[test]
    fn stale_source_cannot_publish_and_audit_does_not_fake_success() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        seed(&store, 1)?;
        store.reconcile_cache()?;
        let (lib, id, hash) = store.claim_cache()?.unwrap();
        store
            .lock()?
            .execute("UPDATE catalog_assets SET content_hash='new'", [])?;
        store.cache_publish(&lib, &id, &hash, &json!({}), &json!({}))?;
        assert!(store.cache_descriptors(&lib, &id)?.is_none());
        assert_eq!(store.cache_status("lib")?["counts"]["ready"], 0);
        Ok(())
    }
}
