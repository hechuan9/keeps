//! Persistent fast-browse derivatives of the existing preview, never the original.
use crate::{cache_pipeline, media::MediaProcessor, previews::PreviewStorage, store::Store};
use anyhow::Result;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

pub const SPEC: &str = "browse-heic-64-q50-v1";
const MAX_ATTEMPTS: i64 = 4;

pub fn migrate(db: &Connection) -> Result<()> {
    let columns: Vec<String> = db
        .prepare("PRAGMA table_info(media_cache)")?
        .query_map([], |r| r.get(1))?
        .collect::<rusqlite::Result<_>>()?;
    for (name, definition) in [
        ("browse_thumbnail", "TEXT"),
        ("browse_source_version", "TEXT"),
        ("browse_spec", "TEXT"),
        ("browse_attempts", "INTEGER NOT NULL DEFAULT 0"),
        ("browse_available_at", "INTEGER NOT NULL DEFAULT 0"),
        ("browse_last_error", "TEXT"),
    ] {
        if !columns.iter().any(|c| c == name) {
            db.execute_batch(&format!(
                "ALTER TABLE media_cache ADD COLUMN {name} {definition}"
            ))?;
        }
    }
    db.execute("UPDATE media_cache SET browse_source_version=json_extract(thumbnail,'$.version'),browse_spec=?1,browse_attempts=0,browse_available_at=0,browse_last_error=NULL WHERE thumbnail IS NOT NULL AND (browse_source_version IS NOT json_extract(thumbnail,'$.version') OR browse_spec IS NOT ?1)", [SPEC])?;
    db.execute_batch(&format!("CREATE INDEX IF NOT EXISTS media_cache_browse_ref ON media_cache(json_extract(browse_thumbnail,'$.objectRef.bucket'),json_extract(browse_thumbnail,'$.objectRef.key'));
CREATE INDEX IF NOT EXISTS media_cache_browse_pending ON media_cache(browse_available_at,asset_id) WHERE browse_thumbnail IS NULL OR json_extract(browse_thumbnail,'$.sourceThumbnailVersion') IS NOT browse_source_version OR json_extract(browse_thumbnail,'$.spec') IS NOT browse_spec;
CREATE TRIGGER IF NOT EXISTS media_cache_browse_changed AFTER UPDATE OF thumbnail ON media_cache WHEN json_extract(NEW.thumbnail,'$.version') IS NOT OLD.browse_source_version BEGIN UPDATE media_cache SET browse_source_version=json_extract(NEW.thumbnail,'$.version'),browse_spec='{SPEC}',browse_attempts=0,browse_available_at=0,browse_last_error=NULL WHERE library_id=NEW.library_id AND asset_id=NEW.asset_id; END;
CREATE TRIGGER IF NOT EXISTS media_cache_browse_insert AFTER INSERT ON media_cache BEGIN UPDATE media_cache SET browse_source_version=json_extract(NEW.thumbnail,'$.version'),browse_spec='{SPEC}' WHERE library_id=NEW.library_id AND asset_id=NEW.asset_id; END;"))?;
    Ok(())
}

pub fn status(db: &Connection, library: &str) -> Result<Value> {
    Ok(db.query_row("SELECT count(*),coalesce(sum(c.browse_thumbnail IS NOT NULL AND c.browse_source_version=json_extract(c.thumbnail,'$.version') AND c.browse_spec=?2 AND json_extract(c.browse_thumbnail,'$.sourceThumbnailVersion')=c.browse_source_version AND json_extract(c.browse_thumbnail,'$.spec')=?2),0),coalesce(sum(c.browse_last_error IS NOT NULL AND c.browse_attempts>=?3),0) FROM media_cache c JOIN catalog_assets a ON a.library_id=c.library_id AND a.id=c.asset_id LEFT JOIN catalog_defaults d ON d.library_id=a.library_id AND d.asset_id=a.id WHERE c.library_id=?1 AND c.thumbnail IS NOT NULL AND c.status='ready' AND c.spec=?4 AND c.source_hash=coalesce(d.content_hash,a.content_hash)",params![library,SPEC,MAX_ATTEMPTS,cache_pipeline::spec()?],|r| Ok(json!({"spec":SPEC,"eligible":r.get::<_,i64>(0)?,"ready":r.get::<_,i64>(1)?,"failed":r.get::<_,i64>(2)?,"maxAttempts":MAX_ATTEMPTS})))?)
}

impl Store {
    pub fn browse_descriptor(&self, library: &str, asset: &str) -> Result<Option<Value>> {
        let media = self.media_snapshot(library, asset)?;
        Ok((!media["browse"].is_null()).then(|| media["browse"].clone()))
    }
}

pub fn process_next(store: &Store, previews: &PreviewStorage) -> Result<bool> {
    let selected = {
        let db = store.lock()?;
        db.query_row("SELECT c.library_id,c.asset_id,c.source_hash,c.thumbnail FROM media_cache c INDEXED BY media_cache_browse_pending JOIN catalog_assets a ON a.library_id=c.library_id AND a.id=c.asset_id LEFT JOIN catalog_defaults d ON d.library_id=a.library_id AND d.asset_id=a.id WHERE c.status='ready' AND c.spec=?1 AND c.source_hash=coalesce(d.content_hash,a.content_hash) AND c.thumbnail IS NOT NULL AND (c.browse_thumbnail IS NULL OR json_extract(c.browse_thumbnail,'$.sourceThumbnailVersion') IS NOT c.browse_source_version OR json_extract(c.browse_thumbnail,'$.spec') IS NOT c.browse_spec) AND c.browse_attempts<?2 AND c.browse_available_at<=unixepoch() AND NOT EXISTS(SELECT 1 FROM catalog_paths p JOIN import_compute_leases l ON l.library_id=p.library_id AND l.path=p.path WHERE p.library_id=c.library_id AND p.asset_id=c.asset_id AND l.expires_at>unixepoch()) ORDER BY c.browse_available_at,c.asset_id LIMIT 1",params![cache_pipeline::spec()?,MAX_ATTEMPTS], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?))).optional()?
    };
    let Some((lib, id, hash, thumbnail)) = selected else {
        return Ok(false);
    };
    let thumbnail: Value = serde_json::from_str(&thumbnail)?;
    let version = thumbnail["version"].as_str().unwrap_or_default();
    store.lock()?.execute("UPDATE media_cache SET browse_attempts=browse_attempts+1 WHERE library_id=? AND asset_id=?", params![lib,id])?;
    let result: Result<()> = (|| {
        let input = previews.object_path(&thumbnail["objectRef"])?;
        let scratch = tempfile::tempdir()?;
        let output = scratch.path().join("browse.heic");
        let generated = MediaProcessor::new().generate_image_quality(&input, &output, 64, 50)?;
        let object =
            previews.put_generated_role(&lib, &id, &generated.sha256, &output, "browse")?;
        let descriptor = json!({"objectRef":object,"width":generated.width,"height":generated.height,"sizeBytes":generated.size_bytes,"version":format!("{SPEC}:{}",generated.sha256),"spec":SPEC,"sourceThumbnailVersion":version});
        publish(store, &lib, &id, &hash, version, &descriptor)?;
        Ok(())
    })();
    if let Err(error) = result {
        let trace = format!("{error:#}");
        store.lock()?.execute("UPDATE media_cache SET browse_last_error=?1,browse_available_at=unixepoch()+60*browse_attempts*browse_attempts WHERE library_id=?2 AND asset_id=?3 AND browse_source_version=?4",params![trace,lib,id,version])?;
        tracing::error!(library_id=%lib,asset_id=%id,error=%trace,"Browse thumbnail generation failed");
    }
    Ok(true)
}

pub(crate) fn publish(
    store: &Store,
    lib: &str,
    id: &str,
    hash: &str,
    version: &str,
    descriptor: &Value,
) -> Result<()> {
    let mut db = store.lock()?;
    let tx = db.transaction()?;
    let previous: Option<String> = tx
        .query_row(
            "SELECT browse_thumbnail FROM media_cache WHERE library_id=? AND asset_id=?",
            params![lib, id],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    let changed = tx.execute("UPDATE media_cache SET browse_thumbnail=?1,browse_last_error=NULL WHERE library_id=?2 AND asset_id=?3 AND source_hash=?4 AND json_extract(thumbnail,'$.version')=?5 AND status='ready' AND spec=?6 AND EXISTS(SELECT 1 FROM catalog_assets a LEFT JOIN catalog_defaults d ON d.library_id=a.library_id AND d.asset_id=a.id WHERE a.library_id=?2 AND a.id=?3 AND coalesce(d.content_hash,a.content_hash)=?4)",params![descriptor.to_string(),lib,id,hash,version,cache_pipeline::spec()?])?;
    if changed > 0 {
        if let Some(previous) = previous {
            let previous: Value = serde_json::from_str(&previous)?;
            crate::cache_gc::enqueue(
                &tx,
                lib,
                &previous["objectRef"],
                &descriptor["objectRef"],
                chrono::Utc::now().timestamp(),
            )?;
        }
        tx.execute(
            "INSERT OR IGNORE INTO catalog_revision_dirty(library_id,kind,key) VALUES(?,'asset',?)",
            params![lib, id],
        )?;
        crate::revisions::flush(&tx)?;
    } else {
        crate::cache_gc::enqueue(
            &tx,
            lib,
            &descriptor["objectRef"],
            &Value::Null,
            chrono::Utc::now().timestamp(),
        )?;
    }
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn seed(store: &Store) -> Result<()> {
        store.lock()?.execute("INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES('lib','asset','{}','hash','fingerprint','2024-01-01','photo.jpg',0,'none',NULL,1)", [])?;
        store.lock()?.execute("INSERT INTO media_cache(library_id,asset_id,source_hash,spec,status,thumbnail,browse_source_version,browse_spec) VALUES('lib','asset','hash',?,'ready',?, 'preview-v1',?)",params![cache_pipeline::spec()?,json!({"version":"preview-v1","objectRef":{"bucket":"keeps-previews","key":"libraries/lib/assets/asset/derivatives/thumbnail/missing.heic"}}).to_string(),SPEC])?;
        Ok(())
    }
    fn descriptor() -> Value {
        json!({"sourceThumbnailVersion":"preview-v1","spec":SPEC,"version":"browse-v1","objectRef":{"bucket":"keeps-previews","key":"libraries/lib/assets/asset/derivatives/browse/one.heic"},"width":64,"height":48})
    }
    #[test]
    fn publication_includes_trash_and_rejects_stale_preview_and_original() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let store = Store::open(&temp.path().join("db"), true)?;
        seed(&store)?;
        publish(&store, "lib", "asset", "hash", "preview-v1", &descriptor())?;
        assert!(store.browse_descriptor("lib", "asset")?.is_some());
        store.lock()?.execute("UPDATE media_cache SET thumbnail=json_set(thumbnail,'$.version','preview-v2'),browse_source_version='preview-v2'",[])?;
        assert!(store.browse_descriptor("lib", "asset")?.is_none());
        publish(&store, "lib", "asset", "hash", "preview-v1", &descriptor())?;
        assert!(store.browse_descriptor("lib", "asset")?.is_none());
        store.lock()?.execute("UPDATE media_cache SET thumbnail=json_set(thumbnail,'$.version','preview-v1'),browse_source_version='preview-v1'",[])?;
        store
            .lock()?
            .execute("UPDATE catalog_assets SET content_hash='new-original'", [])?;
        assert!(store.browse_descriptor("lib", "asset")?.is_none());
        Ok(())
    }
    #[test]
    fn missing_preview_has_persistent_bounded_retries() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let path = temp.path().join("db");
        let previews = PreviewStorage::new(
            &temp.path().join("keeps"),
            None,
            "http://localhost",
            "secret",
        )?;
        let store = Store::open(&path, true)?;
        seed(&store)?;
        for _ in 0..MAX_ATTEMPTS {
            store
                .lock()?
                .execute("UPDATE media_cache SET browse_available_at=0", [])?;
            assert!(process_next(&store, &previews)?);
        }
        drop(store);
        let store = Store::open(&path, false)?;
        assert!(!process_next(&store, &previews)?);
        let error: String =
            store
                .lock()?
                .query_row("SELECT browse_last_error FROM media_cache", [], |r| {
                    r.get(0)
                })?;
        assert!(error.contains("resolving"));
        assert!(store.browse_descriptor("lib", "asset")?.is_none());
        Ok(())
    }
    #[test]
    fn progress_only_counts_current_source_and_preview_spec() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let store = Store::open(&temp.path().join("db"), true)?;
        seed(&store)?;
        publish(&store, "lib", "asset", "hash", "preview-v1", &descriptor())?;
        let check = |eligible: i64, ready: i64| -> Result<()> {
            let db = store.lock()?;
            let result = status(&db, "lib")?;
            assert_eq!(result["eligible"], eligible);
            assert_eq!(result["ready"], ready);
            Ok(())
        };
        check(1, 1)?;
        store
            .lock()?
            .execute("UPDATE catalog_assets SET content_hash='new'", [])?;
        check(0, 0)?;
        store
            .lock()?
            .execute("UPDATE catalog_assets SET content_hash='hash'", [])?;
        store.lock()?.execute("INSERT INTO catalog_defaults(library_id,asset_id,content_hash,user_selected) VALUES('lib','asset','selected-new',1)",[])?;
        check(0, 0)?;
        store.lock()?.execute("DELETE FROM catalog_defaults", [])?;
        store
            .lock()?
            .execute("UPDATE media_cache SET spec='obsolete'", [])?;
        check(0, 0)?;
        store.lock()?.execute(
            "UPDATE media_cache SET spec=?,status='pending'",
            [cache_pipeline::spec()?],
        )?;
        check(0, 0)?;
        Ok(())
    }

    #[test]
    #[ignore = "requires ImageMagick HEIC encoder, identify and heif-convert"]
    fn generates_real_heif_from_preview_and_publishes_revision() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let store = Store::open(&temp.path().join("db"), true)?;
        let previews = PreviewStorage::new(
            &temp.path().join("keeps"),
            None,
            "http://localhost",
            "secret",
        )?;
        seed(&store)?;
        let png = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../shared/Sources/KeepsAPI/Resources/ThumbnailPlaceholder.png");
        let source = temp.path().join("preview.heic");
        let image = MediaProcessor::new().generate_image_quality(&png, &source, 512, 50)?;
        let source_hash = crate::media::sha256_file(&source)?;
        let object =
            previews.put_generated_role("lib", "asset", &image.sha256, &source, "thumbnail")?;
        let thumbnail = json!({"objectRef":object,"version":"real-preview-v1","width":image.width,"height":image.height});
        store.lock()?.execute(
            "UPDATE media_cache SET thumbnail=?",
            [thumbnail.to_string()],
        )?;
        let before = store.library_revision("lib")?;
        assert!(process_next(&store, &previews)?);
        let browse = store
            .browse_descriptor("lib", "asset")?
            .expect("generated browse descriptor");
        assert_eq!(browse["sourceThumbnailVersion"], "real-preview-v1");
        assert_eq!(browse["spec"], SPEC);
        assert_eq!(
            browse["width"]
                .as_u64()
                .unwrap()
                .max(browse["height"].as_u64().unwrap()),
            64
        );
        let path = previews.object_path(&browse["objectRef"])?;
        assert!(path.to_string_lossy().contains("/derivatives/browse/"));
        let bytes = std::fs::read(&path)?;
        assert_eq!(&bytes[4..8], b"ftyp");
        assert!(
            bytes[..64.min(bytes.len())]
                .windows(4)
                .any(|v| v == b"heic" || v == b"mif1")
        );
        assert_eq!(
            browse["version"],
            format!("{SPEC}:{}", crate::media::sha256_file(&path)?)
        );
        assert_ne!(store.library_revision("lib")?, before);
        assert_eq!(crate::media::sha256_file(&source)?, source_hash);
        assert!(!process_next(&store, &previews)?);
        Ok(())
    }
}
