//! Only displaced generated objects enter this queue. Originals and standard photos never do.
use crate::{previews::PreviewStorage, store::Store};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

pub const GRACE_SECONDS: i64 = 20 * 60;
const LIMIT: usize = 20;
const MAX_ATTEMPTS: i64 = 4;

pub fn enabled() -> Result<bool> {
    static ENABLED: std::sync::OnceLock<Result<bool, String>> = std::sync::OnceLock::new();
    ENABLED
        .get_or_init(
            || match std::env::var("KEEPS_CACHE_GC_ENABLED").as_deref() {
                Ok("1") | Ok("true") => Ok(true),
                Ok("0") | Ok("false") | Err(_) => Ok(false),
                _ => Err("KEEPS_CACHE_GC_ENABLED must be 0 or 1".into()),
            },
        )
        .clone()
        .map_err(anyhow::Error::msg)
}

pub fn migrate(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS media_cache_gc(library_id TEXT NOT NULL,bucket TEXT NOT NULL,object_key TEXT NOT NULL,not_before INTEGER NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,last_error TEXT,PRIMARY KEY(bucket,object_key));
CREATE INDEX IF NOT EXISTS media_cache_gc_due ON media_cache_gc(not_before,attempts);
CREATE INDEX IF NOT EXISTS media_cache_thumbnail_ref ON media_cache(json_extract(thumbnail,'$.objectRef.bucket'),json_extract(thumbnail,'$.objectRef.key'));
CREATE INDEX IF NOT EXISTS derivative_object_ref ON derivative_objects(object_bucket,object_key);")?;
    Ok(())
}

fn generated_key(object: &Value) -> Result<(&str, &str)> {
    let bucket = object["bucket"]
        .as_str()
        .context("cache object bucket missing")?;
    let key = object["key"].as_str().context("cache object key missing")?;
    let parts = key.split('/').collect::<Vec<_>>();
    let legacy_flat = key
        .strip_suffix("-1200.heic")
        .is_some_and(|hash| hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit()));
    let role_path = parts.len() == 7
        && parts[0] == "libraries"
        && parts[2] == "assets"
        && parts[4] == "derivatives"
        && (["preview", "thumbnail", "browse"].contains(&parts[5])
            || parts[5] == "standard" && parts[6].starts_with("edit-"))
        && parts[6].ends_with(".heic")
        && parts.iter().all(|part| {
            !part.is_empty() && ![".", ".."].contains(part) && !part.contains(['\\', '\0'])
        });
    ensure!(
        bucket == "keeps-previews" && (legacy_flat || role_path),
        "GC can only remove generated preview or thumbnail objects"
    );
    Ok((bucket, key))
}

pub fn enqueue(
    db: &Connection,
    library: &str,
    old: &Value,
    replacement: &Value,
    now: i64,
) -> Result<()> {
    if old.is_null() || old["bucket"] == replacement["bucket"] && old["key"] == replacement["key"] {
        return Ok(());
    }
    let (bucket, key) = generated_key(old)?;
    db.execute("INSERT INTO media_cache_gc(library_id,bucket,object_key,not_before) VALUES(?,?,?,?) ON CONFLICT(bucket,object_key) DO UPDATE SET not_before=max(media_cache_gc.not_before,excluded.not_before)",params![library,bucket,key,now+GRACE_SECONDS])?;
    Ok(())
}

/// Caller owns the source/spec validation and transaction so retirement cannot precede publication.
pub fn switch_preview(
    db: &Connection,
    library: &str,
    asset: &str,
    thumbnail: &Value,
    now: i64,
) -> Result<()> {
    generated_key(&thumbnail["objectRef"])?;
    let old: Option<String>=db.query_row("SELECT json_object('bucket',object_bucket,'key',object_key) FROM derivative_objects WHERE library_id=? AND asset_id=? AND role='preview'",params![library,asset],|r|r.get(0)).optional()?;
    let old = old
        .map(|s| serde_json::from_str::<Value>(&s))
        .transpose()?
        .unwrap_or(Value::Null);
    let new = &thumbnail["objectRef"];
    if old["bucket"] == new["bucket"] && old["key"] == new["key"] {
        return Ok(());
    }
    let hash = thumbnail["version"]
        .as_str()
        .context("thumbnail version missing")?
        .rsplit(':')
        .next()
        .context("thumbnail hash missing")?;
    let derivative = json!({"assetID":asset,"role":"preview","fileObject":{"contentHash":hash,"sizeBytes":thumbnail["sizeBytes"],"role":"preview"},"objectRef":new,"pixelSize":{"width":thumbnail["width"],"height":thumbnail["height"]}});
    crate::catalog::register_derivative(db, library, asset, &derivative)?;
    enqueue(db, library, &old, new, now)?;
    Ok(())
}

impl Store {
    pub fn retry_cache_garbage(&self, library: &str) -> Result<usize> {
        Ok(self.lock()?.execute("UPDATE media_cache_gc SET attempts=0,last_error=NULL,not_before=unixepoch()+1200 WHERE rowid IN(SELECT rowid FROM media_cache_gc WHERE library_id=? AND attempts>=4 ORDER BY not_before LIMIT 20)",[library])?)
    }
    pub fn switch_ready_previews(&self, previews: &PreviewStorage) -> Result<usize> {
        let rows = {
            let db = self.lock()?;
            let mut q=db.prepare("SELECT c.library_id,c.asset_id,c.thumbnail FROM media_cache c JOIN catalog_assets a ON a.library_id=c.library_id AND a.id=c.asset_id LEFT JOIN catalog_defaults d ON d.library_id=c.library_id AND d.asset_id=c.asset_id LEFT JOIN derivative_objects o ON o.library_id=c.library_id AND o.asset_id=c.asset_id AND o.role='preview' WHERE c.status='ready' AND c.spec=? AND c.source_hash=coalesce(d.content_hash,a.content_hash) AND (o.object_key IS NULL OR o.object_key!=json_extract(c.thumbnail,'$.objectRef.key') OR o.object_bucket!=json_extract(c.thumbnail,'$.objectRef.bucket')) LIMIT 20")?;
            q.query_map([crate::cache_pipeline::spec()?], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
        };
        let mut count = 0;
        for (library, asset, thumbnail) in rows {
            let thumbnail: Value = serde_json::from_str(&thumbnail)?;
            if previews.contains(&thumbnail["objectRef"])? {
                let mut db = self.lock()?;
                let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
                let current: Option<String> = tx.query_row("SELECT c.thumbnail FROM media_cache c JOIN catalog_assets a ON a.library_id=c.library_id AND a.id=c.asset_id LEFT JOIN catalog_defaults d ON d.library_id=c.library_id AND d.asset_id=c.asset_id WHERE c.library_id=? AND c.asset_id=? AND c.status='ready' AND c.spec=? AND c.source_hash=coalesce(d.content_hash,a.content_hash)", params![library,asset,crate::cache_pipeline::spec()?], |row| row.get(0)).optional()?;
                if current
                    .as_deref()
                    .map(serde_json::from_str::<Value>)
                    .transpose()?
                    .as_ref()
                    != Some(&thumbnail)
                {
                    continue;
                }
                switch_preview(
                    &tx,
                    &library,
                    &asset,
                    &thumbnail,
                    chrono::Utc::now().timestamp(),
                )?;
                crate::revisions::flush(&tx)?;
                tx.commit()?;
                count += 1;
            }
        }
        Ok(count)
    }
    pub fn collect_cache_garbage(&self, previews: &PreviewStorage, now: i64) -> Result<usize> {
        let rows = {
            let db = self.lock()?;
            let mut q=db.prepare("SELECT bucket,object_key,attempts FROM media_cache_gc WHERE not_before<=? AND attempts<? ORDER BY not_before LIMIT 20")?;
            q.query_map(params![now, MAX_ATTEMPTS], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
        };
        let mut deleted = 0;
        for (bucket, key, _) in rows.into_iter().take(LIMIT) {
            // One object is the atomic reference-check/delete unit, so foreground
            // requests can use the database between filesystem operations.
            let mut db = self.lock()?;
            let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let attempts: Option<i64> = tx.query_row("SELECT attempts FROM media_cache_gc WHERE bucket=? AND object_key=? AND not_before<=? AND attempts<?", params![bucket,key,now,MAX_ATTEMPTS], |row| row.get(0)).optional()?;
            let Some(attempts) = attempts else {
                continue;
            };
            let referenced: bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM derivative_objects WHERE object_bucket=?1 AND object_key=?2) OR EXISTS(SELECT 1 FROM media_cache WHERE json_extract(thumbnail,'$.objectRef.bucket')=?1 AND json_extract(thumbnail,'$.objectRef.key')=?2) OR EXISTS(SELECT 1 FROM media_cache WHERE json_extract(browse_thumbnail,'$.objectRef.bucket')=?1 AND json_extract(browse_thumbnail,'$.objectRef.key')=?2)",params![bucket,key],|r|r.get(0))?;
            let referenced = referenced || tx.query_row("SELECT EXISTS(SELECT 1 FROM photo_edits WHERE json_extract(standard,'$.objectRef.key')=?1 OR json_extract(thumbnail,'$.objectRef.key')=?1 OR json_extract(browse,'$.objectRef.key')=?1)", [&key], |r|r.get::<_,bool>(0))?;
            if referenced {
                tx.execute(
                    "UPDATE media_cache_gc SET not_before=? WHERE bucket=? AND object_key=?",
                    params![now + GRACE_SECONDS, bucket, key],
                )?;
                tx.commit()?;
                continue;
            }
            let object = json!({"bucket":bucket,"key":key});
            let result = generated_key(&object).and_then(|_| previews.delete(&object));
            match result {
                Ok(()) => {
                    tx.execute(
                        "DELETE FROM media_cache_gc WHERE bucket=? AND object_key=?",
                        params![bucket, key],
                    )?;
                    deleted += 1;
                }
                Err(error) => {
                    let error = format!("{error:#}");
                    tracing::error!(object_key=%key,error=%error,"NAS cache cleanup failed");
                    tx.execute("UPDATE media_cache_gc SET attempts=attempts+1,last_error=?,not_before=? WHERE bucket=? AND object_key=?",params![error,now+60*(attempts+1)*(attempts+1),bucket,key])?;
                }
            }
            tx.commit()?;
        }
        Ok(deleted)
    }
}

pub fn status(db: &Connection, library: &str) -> Result<Value> {
    let mut state=db.query_row("SELECT count(*) FILTER(WHERE attempts<4),count(*) FILTER(WHERE attempts>=4),min(not_before) FILTER(WHERE attempts<4) FROM media_cache_gc WHERE library_id=?",[library],|r|Ok(json!({"pending":r.get::<_,i64>(0)?,"failed":r.get::<_,i64>(1)?,"nextEligibleAt":r.get::<_,Option<i64>>(2)?})))?;
    state["enabled"] = json!(enabled()?);
    state["graceSeconds"] = json!(GRACE_SECONDS);
    state["batchLimit"] = json!(LIMIT);
    let mut q=db.prepare("SELECT object_key,last_error,attempts FROM media_cache_gc WHERE library_id=? AND last_error IS NOT NULL ORDER BY not_before DESC LIMIT 20")?;
    state["errors"]=json!(q.query_map([library],|r|Ok(json!({"key":r.get::<_,String>(0)?,"error":r.get::<_,String>(1)?,"attempts":r.get::<_,i64>(2)?})))?.collect::<rusqlite::Result<Vec<_>>>()?);
    Ok(state)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn setup() -> Result<(tempfile::TempDir, Store, PreviewStorage, String)> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("catalog"), true)?;
        let previews = PreviewStorage::new(
            &dir.path().join("keeps"),
            None,
            "http://localhost",
            "test-key",
        )?;
        let original = dir.path().join("original.jpg");
        std::fs::write(&original, b"original must remain unchanged")?;
        let snapshot = json!({"originalFilename":"original.jpg","contentFingerprint":"source","metadataFingerprint":"metadata","cameraMake":"test","cameraModel":"test","lensModel":"test","rating":3,"flagState":"picked","tags":["keep"],"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"});
        let id = store.ingest_original(
            "lib",
            original.to_str().unwrap(),
            &json!({"contentHash":"source","sizeBytes":30,"role":"jpeg_original"}),
            &snapshot,
        )?;
        store.reconcile_cache()?;
        Ok((dir, store, previews, id))
    }
    fn object(
        previews: &PreviewStorage,
        dir: &std::path::Path,
        id: &str,
        hash: &str,
        role: &str,
    ) -> Result<Value> {
        let input = dir.join(format!("{hash}.fixture"));
        std::fs::write(&input, hash.as_bytes())?;
        previews.put_generated_role("lib", id, hash, &input, role)
    }
    fn ready(store: &Store, id: &str, object: &Value, hash: &str) -> Result<Value> {
        let thumbnail = json!({"objectRef":object,"version":format!("spec:{hash}"),"width":512,"height":384,"sizeBytes":hash.len()});
        store.lock()?.execute(
            "UPDATE media_cache SET status='ready',thumbnail=?,standard='{}' WHERE asset_id=?",
            params![thumbnail.to_string(), id],
        )?;
        Ok(thumbnail)
    }
    fn legacy(store: &Store, id: &str, object: &Value, hash: &str) -> Result<()> {
        store.declare_generated_preview("lib",id,&json!({"assetID":id,"role":"preview","fileObject":{"contentHash":hash,"sizeBytes":hash.len(),"role":"preview"},"objectRef":object,"pixelSize":{"width":1200,"height":800}}))?;
        Ok(())
    }
    #[test]
    fn verified_flat_legacy_format_is_switched_and_reclaimed() -> Result<()> {
        let (dir, store, previews, id) = setup()?;
        let key = format!("{}-1200.heic", "a".repeat(64));
        let path = dir.path().join("keeps/previews").join(&key);
        std::fs::write(&path, b"legacy preview")?;
        let old = json!({"bucket":"keeps-previews","key":key});
        let new = object(&previews, dir.path(), &id, "new", "thumbnail")?;
        legacy(&store, &id, &old, "legacy-hash")?;
        ready(&store, &id, &new, "new")?;
        assert_eq!(store.switch_ready_previews(&previews)?, 1);
        let due = store
            .lock()?
            .query_row("SELECT not_before FROM media_cache_gc", [], |r| {
                r.get::<_, i64>(0)
            })?;
        assert_eq!(store.collect_cache_garbage(&previews, due - 1)?, 0);
        assert!(path.is_file());
        assert_eq!(store.collect_cache_garbage(&previews, due)?, 1);
        assert!(!path.exists());
        assert!(previews.contains(&new)?);
        for key in [
            "photo.heic".to_owned(),
            format!("{}-1200.heic", "a".repeat(63)),
            format!("{}-1200.heic", "g".repeat(64)),
            format!("{}-512.heic", "a".repeat(64)),
            format!("../{}-1200.heic", "a".repeat(64)),
            format!("{}-1200.heic.bak", "a".repeat(64)),
        ] {
            assert!(generated_key(&json!({"bucket":"keeps-previews","key":key})).is_err());
        }
        assert!(
            generated_key(
                &json!({"bucket":"originals","key":format!("{}-1200.heic","a".repeat(64))})
            )
            .is_err()
        );
        assert_eq!(
            std::fs::read(dir.path().join("original.jpg"))?,
            b"original must remain unchanged"
        );
        Ok(())
    }
    #[test]
    fn retirement_waits_twenty_minutes_survives_restart_and_preserves_originals() -> Result<()> {
        let (dir, store, previews, id) = setup()?;
        let old = object(&previews, dir.path(), &id, "old", "preview")?;
        let new = object(&previews, dir.path(), &id, "new", "thumbnail")?;
        legacy(&store, &id, &old, "old")?;
        ready(&store, &id, &new, "new")?;
        assert_eq!(store.switch_ready_previews(&previews)?, 1);
        assert_eq!(store.asset("lib", &id)?["_preview"]["objectRef"], new);
        let due = store
            .lock()?
            .query_row("SELECT not_before FROM media_cache_gc", [], |r| {
                r.get::<_, i64>(0)
            })?;
        assert!(due >= chrono::Utc::now().timestamp() + GRACE_SECONDS - 1);
        assert_eq!(store.collect_cache_garbage(&previews, due - 1)?, 0);
        assert!(previews.contains(&old)?);
        drop(store);
        let store = Store::open(&dir.path().join("catalog"), false)?;
        assert_eq!(store.collect_cache_garbage(&previews, due)?, 1);
        assert!(!previews.contains(&old)?);
        assert!(previews.contains(&new)?);
        assert_eq!(
            std::fs::read(dir.path().join("original.jpg"))?,
            b"original must remain unchanged"
        );
        assert_eq!(store.asset("lib", &id)?["rating"], 3);
        Ok(())
    }
    #[test]
    fn current_references_and_same_object_are_never_deleted() -> Result<()> {
        let (dir, store, previews, id) = setup()?;
        let same = object(&previews, dir.path(), &id, "same", "thumbnail")?;
        legacy(&store, &id, &same, "same")?;
        ready(&store, &id, &same, "same")?;
        assert_eq!(store.switch_ready_previews(&previews)?, 0);
        enqueue(&*store.lock()?, "lib", &same, &same, 0)?;
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT count(*) FROM media_cache_gc", [], |r| r
                    .get::<_, i64>(0))?,
            0
        );
        enqueue(&*store.lock()?, "lib", &same, &Value::Null, 0)?;
        assert_eq!(store.collect_cache_garbage(&previews, GRACE_SECONDS)?, 0);
        assert!(previews.contains(&same)?);
        store
            .lock()?
            .execute("DELETE FROM derivative_objects", [])?;
        assert_eq!(
            store.collect_cache_garbage(&previews, 2 * GRACE_SECONDS)?,
            0
        );
        assert!(previews.contains(&same)?);
        store
            .lock()?
            .execute("UPDATE media_cache SET thumbnail=NULL", [])?;
        assert_eq!(
            store.collect_cache_garbage(&previews, 3 * GRACE_SECONDS)?,
            1
        );
        Ok(())
    }
    #[test]
    fn gc_is_bounded_and_rejects_non_cache_paths_with_finite_retries() -> Result<()> {
        let (dir, store, previews, id) = setup()?;
        for i in 0..23 {
            let old = object(&previews, dir.path(), &id, &format!("old{i}"), "thumbnail")?;
            enqueue(&*store.lock()?, "lib", &old, &Value::Null, 0)?;
        }
        assert_eq!(store.collect_cache_garbage(&previews, GRACE_SECONDS)?, 20);
        assert_eq!(store.collect_cache_garbage(&previews, GRACE_SECONDS)?, 3);
        let invalid = json!({"bucket":"keeps-previews","key":"../original.jpg"});
        assert!(enqueue(&*store.lock()?, "lib", &invalid, &Value::Null, 0).is_err());
        store.lock()?.execute(
            "INSERT INTO media_cache_gc VALUES('lib','keeps-previews','../original.jpg',0,0,NULL)",
            [],
        )?;
        for i in 1..=5 {
            assert_eq!(store.collect_cache_garbage(&previews, i * 10000)?, 0);
        }
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT attempts FROM media_cache_gc", [], |r| r
                    .get::<_, i64>(0))?,
            4
        );
        assert_eq!(
            std::fs::read(dir.path().join("original.jpg"))?,
            b"original must remain unchanged"
        );
        Ok(())
    }
    #[test]
    fn stale_source_and_stale_spec_cannot_switch_legacy_reference() -> Result<()> {
        let (dir, store, previews, id) = setup()?;
        let old = object(&previews, dir.path(), &id, "old", "preview")?;
        let new = object(&previews, dir.path(), &id, "new", "thumbnail")?;
        legacy(&store, &id, &old, "old")?;
        ready(&store, &id, &new, "new")?;
        store
            .lock()?
            .execute("UPDATE media_cache SET spec='stale'", [])?;
        assert_eq!(store.switch_ready_previews(&previews)?, 0);
        store.lock()?.execute(
            "UPDATE media_cache SET spec=?,source_hash='stale'",
            [crate::cache_pipeline::spec()?],
        )?;
        assert_eq!(store.switch_ready_previews(&previews)?, 0);
        assert_eq!(store.asset("lib", &id)?["_preview"]["objectRef"], old);
        Ok(())
    }
}
