//! Only displaced generated objects enter this queue; original photo files are never eligible.
use crate::{previews::PreviewStorage, store::Store};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

pub fn migrate(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS media_cache_gc(library_id TEXT NOT NULL,bucket TEXT NOT NULL,object_key TEXT NOT NULL,not_before INTEGER NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,last_error TEXT,PRIMARY KEY(bucket,object_key));
CREATE INDEX IF NOT EXISTS media_cache_gc_due ON media_cache_gc(not_before,attempts);
CREATE INDEX IF NOT EXISTS media_cache_thumbnail_ref ON media_cache(json_extract(thumbnail,'$.objectRef.bucket'),json_extract(thumbnail,'$.objectRef.key'));
CREATE INDEX IF NOT EXISTS derivative_object_ref ON derivative_objects(object_bucket,object_key);")?;
    Ok(())
}

pub fn migrate_asset_ownership(db: &Connection) -> Result<()> {
    let columns = db
        .prepare("PRAGMA table_info(media_cache_gc)")?
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if !columns.iter().any(|column| column == "asset_id") {
        db.execute_batch("ALTER TABLE media_cache_gc ADD COLUMN asset_id TEXT;")?;
    }
    db.execute_batch(
        "CREATE INDEX IF NOT EXISTS media_cache_gc_asset ON media_cache_gc(library_id,asset_id);",
    )?;
    let rows = db
        .prepare("SELECT library_id,bucket,object_key FROM media_cache_gc WHERE asset_id IS NULL")?
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (library, bucket, key) in rows {
        let object = json!({"bucket":bucket,"key":key});
        let parts: Vec<_> = key.split('/').collect();
        if generated_key(&object).is_ok() && parts.len() == 7 && parts[1] == library {
            db.execute(
                "UPDATE media_cache_gc SET asset_id=?1 WHERE bucket=?2 AND object_key=?3",
                params![parts[3], bucket, key],
            )?;
        }
    }
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
    asset: &str,
    old: &Value,
    replacement: &Value,
    now: i64,
) -> Result<()> {
    if old.is_null() || old["bucket"] == replacement["bucket"] && old["key"] == replacement["key"] {
        return Ok(());
    }
    let (bucket, key) = generated_key(old)?;
    let parts: Vec<_> = key.split('/').collect();
    ensure!(
        parts.len() == 1 || parts[1] == library && parts[3] == asset,
        "retired cache object must belong to the operated asset"
    );
    db.execute("INSERT INTO media_cache_gc(library_id,asset_id,bucket,object_key,not_before) VALUES(?,?,?,?,?) ON CONFLICT(bucket,object_key) DO UPDATE SET asset_id=excluded.asset_id,not_before=excluded.not_before",params![library,asset,bucket,key,now])?;
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
    enqueue(db, library, asset, &old, new, now)?;
    Ok(())
}

impl Store {
    pub fn collect_asset_cache_garbage(
        &self,
        previews: &PreviewStorage,
        library: &str,
        asset: &str,
    ) -> Result<usize> {
        let rows = {
            let db = self.lock()?;
            let mut q=db.prepare("SELECT bucket,object_key FROM media_cache_gc WHERE library_id=? AND asset_id=? ORDER BY not_before")?;
            q.query_map(params![library, asset], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
        };
        let mut deleted = 0;
        for (bucket, key) in rows {
            // One object is the atomic reference-check/delete unit, so foreground
            // requests can use the database between filesystem operations.
            let mut db = self.lock()?;
            let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            let queued: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM media_cache_gc WHERE library_id=?1 AND asset_id=?2 AND bucket=?3 AND object_key=?4)", params![library,asset,bucket,key], |row| row.get(0))?;
            if !queued {
                continue;
            }
            let referenced: bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM derivative_objects WHERE object_bucket=?1 AND object_key=?2) OR EXISTS(SELECT 1 FROM media_cache WHERE json_extract(thumbnail,'$.objectRef.bucket')=?1 AND json_extract(thumbnail,'$.objectRef.key')=?2) OR EXISTS(SELECT 1 FROM media_cache WHERE json_extract(browse_thumbnail,'$.objectRef.bucket')=?1 AND json_extract(browse_thumbnail,'$.objectRef.key')=?2)",params![bucket,key],|r|r.get(0))?;
            let referenced = referenced || tx.query_row("SELECT EXISTS(SELECT 1 FROM photo_edits WHERE json_extract(standard,'$.objectRef.key')=?1 OR json_extract(thumbnail,'$.objectRef.key')=?1 OR json_extract(browse,'$.objectRef.key')=?1)", [&key], |r|r.get::<_,bool>(0))?;
            let referenced = referenced || tx.query_row("SELECT EXISTS(SELECT 1 FROM photo_edit_requests r,json_each(r.payload,'$.body.outputs') o WHERE json_extract(r.payload,'$.action')='commit' AND json_extract(o.value,'$.objectRef.bucket')=?1 AND json_extract(o.value,'$.objectRef.key')=?2)", params![bucket,key], |r|r.get::<_,bool>(0))?;
            if referenced {
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
                    let detail = format!("{error:#}");
                    tx.execute("UPDATE media_cache_gc SET attempts=attempts+1,last_error=? WHERE bucket=? AND object_key=?",params![detail,bucket,key])?;
                    tx.commit()?;
                    return Err(error)
                        .with_context(|| format!("清理照片 {asset} 的旧缓存失败: {key}"));
                }
            }
            tx.commit()?;
        }
        Ok(deleted)
    }
}

pub fn status(db: &Connection, library: &str) -> Result<Value> {
    let mut state=db.query_row("SELECT count(*) FILTER(WHERE last_error IS NULL),count(*) FILTER(WHERE last_error IS NOT NULL),NULL FROM media_cache_gc WHERE library_id=?",[library],|r|Ok(json!({"pending":r.get::<_,i64>(0)?,"failed":r.get::<_,i64>(1)?,"nextEligibleAt":r.get::<_,Option<i64>>(2)?})))?;
    state["enabled"] = json!(true);
    state["graceSeconds"] = json!(0);
    state["batchLimit"] = Value::Null;
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
    fn explicit_asset_cleanup_reclaims_only_retired_objects() -> Result<()> {
        let (dir, store, previews, id) = setup()?;
        let old = object(&previews, dir.path(), &id, "old", "preview")?;
        let new = object(&previews, dir.path(), &id, "new", "thumbnail")?;
        let other = object(&previews, dir.path(), "other", "other", "thumbnail")?;
        legacy(&store, &id, &old, "old")?;
        let thumbnail = ready(&store, &id, &new, "new")?;
        switch_preview(&*store.lock()?, "lib", &id, &thumbnail, 0)?;
        enqueue(&*store.lock()?, "lib", "other", &other, &Value::Null, 0)?;
        assert_eq!(store.collect_asset_cache_garbage(&previews, "lib", &id)?, 1);
        assert!(previews.contains(&new)?);
        assert!(previews.contains(&other)?);
        assert!(!previews.contains(&old)?);
        assert_eq!(
            std::fs::read(dir.path().join("original.jpg"))?,
            b"original must remain unchanged"
        );
        Ok(())
    }

    #[test]
    fn referenced_cache_is_never_removed() -> Result<()> {
        let (dir, store, previews, id) = setup()?;
        let current = object(&previews, dir.path(), &id, "current", "thumbnail")?;
        legacy(&store, &id, &current, "current")?;
        ready(&store, &id, &current, "current")?;
        enqueue(&*store.lock()?, "lib", &id, &current, &Value::Null, 0)?;
        assert_eq!(store.collect_asset_cache_garbage(&previews, "lib", &id)?, 0);
        store
            .lock()?
            .execute("DELETE FROM derivative_objects", [])?;
        assert_eq!(store.collect_asset_cache_garbage(&previews, "lib", &id)?, 0);
        store
            .lock()?
            .execute("UPDATE media_cache SET thumbnail=NULL", [])?;
        assert_eq!(store.collect_asset_cache_garbage(&previews, "lib", &id)?, 1);
        Ok(())
    }

    #[test]
    fn deletion_failure_is_reported_and_preserved_for_manual_retry() -> Result<()> {
        let (dir, store, previews, id) = setup()?;
        let old = object(&previews, dir.path(), &id, "old", "thumbnail")?;
        enqueue(&*store.lock()?, "lib", &id, &old, &Value::Null, 0)?;
        let path = previews.object_path(&old)?;
        std::fs::remove_file(&path)?;
        std::fs::create_dir(&path)?;
        let failure = store
            .collect_asset_cache_garbage(&previews, "lib", &id)
            .unwrap_err();
        assert!(format!("{failure:#}").contains("清理照片"));
        let (attempts, error): (i64, String) =
            store
                .lock()?
                .query_row("SELECT attempts,last_error FROM media_cache_gc", [], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })?;
        assert_eq!(attempts, 1);
        assert!(!error.is_empty());
        std::fs::remove_dir(&path)?;
        assert_eq!(store.collect_asset_cache_garbage(&previews, "lib", &id)?, 1);
        Ok(())
    }

    #[test]
    fn legacy_queue_owner_migration_is_explicit_and_preserves_unowned_flat_keys() -> Result<()> {
        let (dir, store, previews, id) = setup()?;
        let owned = object(&previews, dir.path(), &id, "old", "thumbnail")?;
        let flat_key = format!("{}-1200.heic", "a".repeat(64));
        let flat = json!({"bucket":"keeps-previews","key":flat_key});
        std::fs::write(previews.object_path(&flat)?, b"legacy")?;
        let path = dir.path().join("catalog");
        store.lock()?.execute_batch("DROP INDEX media_cache_gc_asset; ALTER TABLE media_cache_gc DROP COLUMN asset_id; PRAGMA user_version=17;")?;
        for object in [&owned, &flat] {
            store.lock()?.execute("INSERT INTO media_cache_gc(library_id,bucket,object_key,not_before) VALUES('lib',?1,?2,0)", params![object["bucket"].as_str(), object["key"].as_str()])?;
        }
        drop(store);
        assert!(Store::open(&path, false).is_err());
        let store = Store::open(&path, true)?;
        assert_eq!(store.collect_asset_cache_garbage(&previews, "lib", &id)?, 1);
        assert!(previews.contains(&flat)?);
        enqueue(&*store.lock()?, "lib", &id, &flat, &Value::Null, 0)?;
        assert_eq!(store.collect_asset_cache_garbage(&previews, "lib", &id)?, 1);
        Ok(())
    }

    #[test]
    fn invalid_or_foreign_object_is_rejected_at_retirement() -> Result<()> {
        let (_dir, store, _previews, id) = setup()?;
        for key in [
            "../original.jpg",
            "photo.heic",
            "libraries/lib/assets/other/derivatives/thumbnail/a.heic",
        ] {
            assert!(
                enqueue(
                    &*store.lock()?,
                    "lib",
                    &id,
                    &json!({"bucket":"keeps-previews","key":key}),
                    &Value::Null,
                    0
                )
                .is_err()
            );
        }
        Ok(())
    }
}
