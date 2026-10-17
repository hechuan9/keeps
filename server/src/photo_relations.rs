//! Classify indexed originals before scheduling media work. Never mutate source files.
use anyhow::Result;
use rusqlite::{Connection, params};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

pub(crate) fn migrate(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS catalog_deprecated_files(library_id TEXT NOT NULL,path TEXT NOT NULL,retained_path TEXT NOT NULL,basis TEXT NOT NULL,reason TEXT NOT NULL,PRIMARY KEY(library_id,path));")?;
    db.execute_batch("CREATE INDEX IF NOT EXISTS catalog_identity_aliases_asset ON catalog_identity_aliases(library_id,asset_id); CREATE INDEX IF NOT EXISTS remote_cache_asset ON remote_cache_tasks(library_id,asset_id);")?;
    let directories = {
        let mut q = db.prepare("SELECT library_id,path FROM catalog_paths WHERE role IN ('raw_original','jpeg_original')")?;
        q.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?
            .into_iter()
            .filter_map(|(lib, path)| {
                Path::new(&path)
                    .parent()
                    .map(|p| (lib, p.to_string_lossy().into_owned()))
            })
            .collect::<BTreeSet<_>>()
    };
    for (lib, directory) in directories {
        reconcile_directory(db, &lib, &directory)?;
    }
    Ok(())
}

struct Original {
    path: String,
    asset: String,
    hash: String,
    visual: Option<String>,
}

pub(crate) fn filename_match(
    db: &Connection,
    lib: &str,
    path: &str,
    snapshot: &Value,
) -> Result<Option<String>> {
    let path = Path::new(path);
    let stem = Path::new(snapshot["originalFilename"].as_str().unwrap_or(""))
        .file_stem()
        .and_then(|v| v.to_str())
        .unwrap_or("");
    if stem.is_empty() {
        return Ok(None);
    }
    let directory = path.parent().unwrap_or(Path::new(""));
    let prefix = format!("{}/", directory.to_string_lossy().trim_end_matches('/'));
    let end = format!("{}0", directory.to_string_lossy().trim_end_matches('/'));
    let mut q = db.prepare("SELECT DISTINCT p.asset_id,a.snapshot FROM catalog_paths p JOIN catalog_assets a ON a.library_id=p.library_id AND a.id=p.asset_id WHERE p.library_id=?1 AND p.path>=?2 AND p.path<?3 AND instr(substr(p.path,length(?2)+1),'/')=0")?;
    let mut matches = BTreeSet::new();
    for row in q.query_map(params![lib, prefix, end], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })? {
        let (id, detail) = row?;
        let detail: Value = serde_json::from_str(&detail)?;
        let other = Path::new(detail["originalFilename"].as_str().unwrap_or(""));
        if !other
            .file_stem()
            .and_then(|v| v.to_str())
            .is_some_and(|v| v.eq_ignore_ascii_case(stem))
        {
            continue;
        }
        let conflict = ["cameraImageID", "cameraMake", "cameraModel", "captureTime"]
            .iter()
            .any(|key| {
                let a = snapshot[key].as_str().filter(|v| !v.is_empty());
                let b = detail[key].as_str().filter(|v| !v.is_empty());
                matches!((a,b),(Some(a),Some(b)) if a!=b)
            });
        if !conflict {
            matches.insert(id);
        }
    }
    Ok(if matches.len() == 1 {
        matches.into_iter().next()
    } else {
        None
    })
}

fn originals(db: &Connection, lib: &str, directory: &str) -> Result<Vec<Original>> {
    let prefix = format!("{}/", directory.trim_end_matches('/'));
    let end = format!("{}0", directory.trim_end_matches('/'));
    let mut q = db.prepare("SELECT p.path,p.asset_id,p.content_hash,v.visual_hash FROM catalog_paths p LEFT JOIN catalog_versions v ON v.library_id=p.library_id AND v.asset_id=p.asset_id AND v.content_hash=p.content_hash LEFT JOIN catalog_defaults d ON d.library_id=p.library_id AND d.asset_id=p.asset_id LEFT JOIN media_cache c ON c.library_id=p.library_id AND c.asset_id=p.asset_id LEFT JOIN catalog_deprecated_files x ON x.library_id=p.library_id AND x.path=p.path WHERE p.library_id=?1 AND p.path>=?2 AND p.path<?3 AND instr(substr(p.path,length(?2)+1),'/')=0 AND p.role IN ('raw_original','jpeg_original') ORDER BY coalesce(d.user_selected=1 AND d.content_hash=p.content_hash,0) DESC,(x.path IS NOT NULL),coalesce(v.priority,0) DESC,coalesce(c.status='ready',0) DESC,length(p.path),p.path")?;
    Ok(q.query_map(params![lib, prefix, end], |r| {
        Ok(Original {
            path: r.get(0)?,
            asset: r.get(1)?,
            hash: r.get(2)?,
            visual: r.get(3)?,
        })
    })?
    .collect::<rusqlite::Result<Vec<_>>>()?)
}

pub(crate) fn reconcile_directory(db: &Connection, lib: &str, directory: &str) -> Result<()> {
    for id in mark_duplicates(db, lib, directory)? {
        crate::versions::choose(db, lib, &id)?;
    }
    Ok(())
}

fn mark_duplicates(db: &Connection, lib: &str, directory: &str) -> Result<BTreeSet<String>> {
    let rows = originals(db, lib, directory)?;
    let mut hashes = BTreeMap::<(String, String), String>::new();
    let mut visuals = BTreeMap::<(String, String), String>::new();
    let mut desired = BTreeMap::<String, (String, String, String)>::new();
    for row in rows {
        let duplicate = hashes
            .get(&(row.asset.clone(), row.hash.clone()))
            .map(|p| (p, "sha256"))
            .or_else(|| {
                row.visual
                    .as_ref()
                    .and_then(|v| visuals.get(&(row.asset.clone(), v.clone())))
                    .map(|p| (p, "exact_jpeg_image"))
            });
        if let Some((retained, basis)) = duplicate {
            let description = if basis == "sha256" {
                "文件 SHA-256 相同"
            } else {
                "JPEG 精确图像指纹相同（图像编码、方向和颜色信息一致，仅元数据可能不同）"
            };
            let reason =
                format!("重复照片：{description}；保留 {retained}。此文件仅标记弃用，未删除。");
            desired.insert(row.path, (retained.clone(), basis.to_owned(), reason));
        } else {
            hashes.insert((row.asset.clone(), row.hash), row.path.clone());
            if let Some(visual) = row.visual {
                visuals.insert((row.asset, visual), row.path);
            }
        }
    }
    let prefix = format!("{}/", directory.trim_end_matches('/'));
    let end = format!("{}0", directory.trim_end_matches('/'));
    let previous = {
        let mut q = db.prepare("SELECT path,retained_path,basis,reason FROM catalog_deprecated_files WHERE library_id=?1 AND path>=?2 AND path<?3 AND instr(substr(path,length(?2)+1),'/')=0")?;
        q.query_map(params![lib, prefix, end], |r| {
            Ok((
                r.get::<_, String>(0)?,
                (
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                ),
            ))
        })?
        .collect::<rusqlite::Result<BTreeMap<_, _>>>()?
    };
    if previous == desired {
        return Ok(BTreeSet::new());
    }
    for path in previous.keys().filter(|p| !desired.contains_key(*p)) {
        db.execute(
            "DELETE FROM catalog_deprecated_files WHERE library_id=? AND path=?",
            params![lib, path],
        )?;
    }
    for (path, (retained, basis, reason)) in &desired {
        db.execute("INSERT INTO catalog_deprecated_files VALUES(?,?,?,?,?) ON CONFLICT(library_id,path) DO UPDATE SET retained_path=excluded.retained_path,basis=excluded.basis,reason=excluded.reason WHERE retained_path IS NOT excluded.retained_path OR basis IS NOT excluded.basis OR reason IS NOT excluded.reason",params![lib,path,retained,basis,reason])?;
    }
    let mut ids = BTreeSet::new();
    for path in previous
        .keys()
        .chain(desired.keys())
        .collect::<BTreeSet<_>>()
    {
        db.execute("INSERT OR IGNORE INTO catalog_revision_dirty SELECT library_id,'asset',asset_id FROM catalog_paths WHERE library_id=? AND path=?",params![lib,path])?;
        let mut q =
            db.prepare("SELECT asset_id FROM catalog_paths WHERE library_id=? AND path=?")?;
        ids.extend(
            q.query_map(params![lib, path], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?,
        );
    }
    Ok(ids)
}

pub(crate) fn deprecated_files(db: &Connection, lib: &str, id: &str) -> Result<Vec<Value>> {
    let mut q = db.prepare("SELECT x.path,x.retained_path,x.basis,x.reason FROM catalog_deprecated_files x JOIN catalog_paths p ON p.library_id=x.library_id AND p.path=x.retained_path WHERE p.library_id=? AND p.asset_id=? ORDER BY x.path")?;
    Ok(q.query_map(params![lib,id],|r| Ok(json!({"path":r.get::<_,String>(0)?,"retainedPath":r.get::<_,String>(1)?,"basis":r.get::<_,String>(2)?,"reason":r.get::<_,String>(3)?})))?.collect::<rusqlite::Result<Vec<_>>>()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{store::Store, versions::VersionEvidence};

    fn snapshot(hash: &str) -> Value {
        json!({"cameraMake":"Hasselblad","cameraModel":"X2D II 100C","lensModel":"XCD 35-100E@100","captureTime":"2026-09-28T20:33:57Z","originalFilename":"B0018262","contentFingerprint":hash,"metadataFingerprint":"capture","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-01T00:00:00Z","rating":0,"tags":[]})
    }
    fn ingest(
        store: &Store,
        path: &Path,
        hash: &str,
        metadata: &Value,
        visual: Option<&str>,
    ) -> Result<String> {
        std::fs::create_dir_all(path.parent().unwrap())?;
        std::fs::write(path, hash)?;
        store.ingest_original_with_evidence("lib",path.to_str().unwrap(),&json!({"contentHash":hash,"sizeBytes":hash.len(),"role":if crate::media::is_raw(path) {"raw_original"} else {"jpeg_original"}}),metadata,&VersionEvidence { visual_hash:visual.map(str::to_owned),width:100,height:100,..Default::default() })
    }

    #[test]
    fn raw_heif_pair_in_either_order_shares_one_cache_and_preserves_versions() -> Result<()> {
        for raw_first in [true, false] {
            let dir = tempfile::tempdir()?;
            let store = Store::open(&dir.path().join("db"), true)?;
            let raw = dir.path().join("photos/B0018262.3FR");
            let heif = raw.with_extension("HEIC");
            let files = if raw_first {
                [(&raw, "raw"), (&heif, "heif")]
            } else {
                [(&heif, "heif"), (&raw, "raw")]
            };
            let first = ingest(&store, files[0].0, files[0].1, &snapshot(files[0].1), None)?;
            let second = ingest(&store, files[1].0, files[1].1, &snapshot(files[1].1), None)?;
            assert_eq!(first, second);
            assert_eq!(
                store.default_version("lib", &first)?.unwrap().content_hash,
                "heif"
            );
            let versions = store.versions("lib", &first)?;
            assert_eq!(versions["items"].as_array().unwrap().len(), 2);
            assert!(versions["deprecatedFiles"].as_array().unwrap().is_empty());
            store.reconcile_cache()?;
            let db = store.lock()?;
            assert_eq!(
                db.query_row("SELECT count(*) FROM media_cache", [], |r| r
                    .get::<_, i64>(0))?,
                1
            );
            assert_eq!(
                db.query_row("SELECT source_hash FROM media_cache", [], |r| r
                    .get::<_, String>(0))?,
                "heif"
            );
            assert_eq!(std::fs::read_to_string(raw)?, "raw");
            assert_eq!(std::fs::read_to_string(heif)?, "heif");
        }
        Ok(())
    }

    #[test]
    fn numbered_raw_pairs_with_camera_heif_despite_display_timezone() -> Result<()> {
        for raw_first in [true, false] {
            let dir = tempfile::tempdir()?;
            let store = Store::open(&dir.path().join("db"), true)?;
            let raw = dir.path().join("photos/B0000764 (1).3FR");
            let heif = dir.path().join("photos/B0000764.HEIC");
            let files = if raw_first {
                [
                    (&raw, "raw", "2025-11-28T18:03:27Z"),
                    (&heif, "heif", "2025-11-28T17:03:27Z"),
                ]
            } else {
                [
                    (&heif, "heif", "2025-11-28T17:03:27Z"),
                    (&raw, "raw", "2025-11-28T18:03:27Z"),
                ]
            };
            let mut ids = Vec::new();
            for (path, hash, time) in files {
                std::fs::create_dir_all(path.parent().unwrap())?;
                std::fs::write(path, hash)?;
                let mut metadata = snapshot(hash);
                metadata["captureTime"] = json!(time);
                metadata["originalDocumentID"] = json!(uuid::Uuid::new_v4().to_string());
                metadata["cameraImageID"] = json!("camera-pair");
                ids.push(store.ingest_original_with_evidence(
                    "lib", path.to_str().unwrap(),
                    &json!({"contentHash":hash,"sizeBytes":hash.len(),"role":if crate::media::is_raw(path) {"raw_original"} else {"jpeg_original"}}),
                    &metadata,
                    &VersionEvidence { capture_original:"2025:11:28 12:03:27-06:00".into(),width:100,height:100,..Default::default() },
                )?);
            }
            assert_eq!(ids[0], ids[1], "raw_first={raw_first}");
            assert_eq!(
                store.versions("lib", &ids[0])?["items"]
                    .as_array()
                    .unwrap()
                    .len(),
                2
            );
        }
        Ok(())
    }

    #[test]
    fn raw_heif_pair_across_directories_shares_identity() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let raw = dir.path().join("Mexico/B0003498.3FR");
        let heif = dir.path().join("Vail/B0003498.HEIC");
        let evidence = VersionEvidence {
            capture_original: "2025:11:28 12:03:27-06:00".into(),
            width: 100,
            height: 100,
            ..Default::default()
        };
        let mut ids = Vec::new();
        for (path, hash) in [(&heif, "heif"), (&raw, "raw")] {
            std::fs::create_dir_all(path.parent().unwrap())?;
            std::fs::write(path, hash)?;
            let mut metadata = snapshot(hash);
            metadata["originalDocumentID"] = json!(uuid::Uuid::new_v4().to_string());
            metadata["cameraImageID"] = json!("camera-pair");
            ids.push(store.ingest_original_with_evidence(
                "lib", path.to_str().unwrap(),
                &json!({"contentHash":hash,"sizeBytes":hash.len(),"role":if crate::media::is_raw(path) {"raw_original"} else {"jpeg_original"}}),
                &metadata, &evidence,
            )?);
        }
        assert_eq!(ids[0], ids[1]);
        assert_eq!(
            store.versions("lib", &ids[0])?["items"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        for directory in ["Mexico", "Vail"] {
            let query = crate::catalog::AssetQuery {
                directory: Some(dir.path().join(directory).to_string_lossy().into_owned()),
                ..Default::default()
            };
            assert_eq!(store.query_assets("lib", &query)?["total"], 1);
        }
        let unrelated = dir.path().join("Other/B0003498.HEIC");
        std::fs::create_dir_all(unrelated.parent().unwrap())?;
        std::fs::write(&unrelated, "different")?;
        let mut metadata = snapshot("different");
        metadata["originalDocumentID"] = json!(uuid::Uuid::new_v4().to_string());
        let unrelated_id = store.ingest_original_with_evidence(
            "lib",
            unrelated.to_str().unwrap(),
            &json!({"contentHash":"different","sizeBytes":9,"role":"jpeg_original"}),
            &metadata,
            &VersionEvidence {
                capture_original: "2025:11:29 12:03:27-06:00".into(),
                ..evidence
            },
        )?;
        assert_ne!(unrelated_id, ids[0]);
        Ok(())
    }

    #[test]
    fn exact_duplicates_are_deprecated_with_reason_not_extra_versions() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let a = dir.path().join("photos/a.jpg");
        let b = a.with_file_name("b.jpg");
        let c = a.with_file_name("c.jpg");
        let id = ingest(&store, &a, "same", &snapshot("same"), Some("pixels"))?;
        assert_eq!(
            ingest(&store, &b, "same", &snapshot("same"), Some("pixels"))?,
            id
        );
        assert_eq!(
            ingest(
                &store,
                &c,
                "other-metadata",
                &snapshot("other-metadata"),
                Some("pixels")
            )?,
            id
        );
        reconcile_directory(
            &*store.lock()?,
            "lib",
            a.parent().unwrap().to_str().unwrap(),
        )?;
        let versions = store.versions("lib", &id)?;
        assert_eq!(versions["items"].as_array().unwrap().len(), 1);
        assert_eq!(versions["items"][0]["paths"].as_array().unwrap().len(), 1);
        let deprecated = versions["deprecatedFiles"].as_array().unwrap();
        assert_eq!(deprecated.len(), 2);
        assert_eq!(deprecated[0]["basis"], "sha256");
        assert_eq!(deprecated[1]["basis"], "exact_jpeg_image");
        for entry in deprecated {
            assert_eq!(entry["retainedPath"], a.to_str().unwrap());
            assert!(entry["reason"].as_str().unwrap().contains("未删除"));
        }
        assert!(
            store
                .set_default_version("lib", &id, "other-metadata")
                .is_err()
        );

        ingest(
            &store,
            &c,
            "other-metadata",
            &snapshot("other-metadata"),
            Some("pixels"),
        )?;
        reconcile_directory(
            &*store.lock()?,
            "lib",
            a.parent().unwrap().to_str().unwrap(),
        )?;
        assert_eq!(
            store.versions("lib", &id)?["deprecatedFiles"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert_eq!(std::fs::read_to_string(b)?, "same");
        assert_eq!(std::fs::read_to_string(c)?, "other-metadata");
        Ok(())
    }

    #[test]
    fn filename_pairing_needs_scope_and_no_explicit_conflict() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let mut raw = snapshot("raw");
        raw["originalFilename"] = json!("a.3FR");
        let id = ingest(&store, &dir.path().join("photos/a.3FR"), "raw", &raw, None)?;
        for relative in ["other/a.HEIC", "photos/b.HEIC"] {
            let mut meta = raw.clone();
            meta["originalFilename"] =
                json!(Path::new(relative).file_name().unwrap().to_str().unwrap());
            assert_ne!(
                ingest(&store, &dir.path().join(relative), relative, &meta, None)?,
                id
            );
        }
        let mut meta = raw.clone();
        meta["originalFilename"] = json!("a.HEIC");
        meta.as_object_mut().unwrap().remove("captureTime");
        assert_eq!(
            ingest(
                &store,
                &dir.path().join("photos/a.HEIC"),
                "heif",
                &meta,
                None
            )?,
            id
        );
        Ok(())
    }

    #[test]
    fn explicit_distinct_roots_are_not_overridden_by_capture_match() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let raw = dir.path().join("photos/a.3FR");
        let heif = raw.with_extension("HEIC");
        let raw_root = uuid::Uuid::new_v4().to_string();
        let heif_root = uuid::Uuid::new_v4().to_string();
        let mut raw_metadata = snapshot("raw");
        let mut heif_metadata = snapshot("heif");
        raw_metadata["originalDocumentID"] = json!(raw_root);
        heif_metadata["originalDocumentID"] = json!(heif_root);
        let raw_id = ingest(&store, &raw, "raw", &raw_metadata, None)?;
        let heif_id = ingest(&store, &heif, "heif", &heif_metadata, None)?;
        assert_ne!(raw_id, heif_id);
        assert_eq!(store.root_id("lib", &raw_id)?, raw_root);
        assert_eq!(store.root_id("lib", &heif_id)?, heif_root);
        assert_eq!(store.counts("lib", false)?["all"], 2);
        assert_eq!(
            ingest(&store, &heif, "heif", &heif_metadata, None)?,
            heif_id
        );
        Ok(())
    }

    #[test]
    fn missing_retained_file_promotes_existing_copy_without_deleting_it() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let a = dir.path().join("photos/a.jpg");
        let b = a.with_file_name("b.jpg");
        let id = ingest(&store, &a, "same", &snapshot("same"), None)?;
        ingest(&store, &b, "same", &snapshot("same"), None)?;
        std::fs::rename(&a, dir.path().join("external.jpg"))?;
        store.mark_missing_under("lib", a.parent().unwrap().to_str().unwrap())?;
        assert_eq!(
            store.default_version("lib", &id)?.unwrap().path,
            b.to_str().unwrap()
        );
        let versions = store.versions("lib", &id)?;
        assert!(versions["deprecatedFiles"].as_array().unwrap().is_empty());
        assert_eq!(std::fs::read_to_string(b)?, "same");
        Ok(())
    }

    #[test]
    fn schema_nine_preserves_existing_identities_cache_and_annotations() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let database = dir.path().join("db");
        let store = Store::open(&database, true)?;
        let raw = dir.path().join("photos/a.3FR");
        let heif = raw.with_extension("HEIC");
        let mut raw_metadata = snapshot("raw");
        raw_metadata["captureTime"] = json!("2026-09-28T20:33:58Z");
        raw_metadata["originalDocumentID"] = json!(uuid::Uuid::new_v4().to_string());
        let mut heif_metadata = snapshot("heif");
        heif_metadata["originalDocumentID"] = json!(uuid::Uuid::new_v4().to_string());
        let raw_id = ingest(&store, &raw, "raw", &raw_metadata, None)?;
        let heif_id = ingest(&store, &heif, "heif", &heif_metadata, None)?;
        assert_ne!(raw_id, heif_id);
        store.patch_asset("lib", &raw_id, &json!({"rating":5,"tags":["keep"]}))?;
        store.reconcile_cache()?;
        {
            let db = store.lock()?;
            db.execute(
                "UPDATE catalog_versions SET capture_key=? WHERE asset_id=?",
                params![crate::versions::capture_key(&heif_metadata), raw_id],
            )?;
            db.execute("UPDATE media_cache SET status='ready',thumbnail='{}',standard='{}' WHERE asset_id=?",[&heif_id])?;
            crate::edits::remove_schema(&db)?;
            db.execute_batch("DROP TABLE catalog_deprecated_files; PRAGMA user_version=9;")?;
        }
        drop(store);
        assert!(Store::open(&database, false).is_err());
        let store = Store::open(&database, true)?;
        assert_eq!(store.counts("lib", false)?["all"], 2);
        assert_eq!(store.asset("lib", &raw_id)?["rating"], 5);
        assert_eq!(store.asset("lib", &raw_id)?["tags"], json!(["keep"]));
        assert_eq!(
            store
                .default_version("lib", &heif_id)?
                .unwrap()
                .content_hash,
            "heif"
        );
        assert_eq!(
            store.versions("lib", &heif_id)?["items"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(store.cache_descriptors("lib", &heif_id)?.is_some());
        let db = store.lock()?;
        assert_eq!(
            db.query_row("SELECT count(*) FROM media_cache", [], |r| r
                .get::<_, i64>(0))?,
            2
        );
        assert_eq!(
            db.query_row(
                "SELECT asset_id FROM catalog_identity_aliases WHERE root_id=?",
                [raw_metadata["originalDocumentID"].as_str().unwrap()],
                |r| r.get::<_, String>(0)
            )?,
            raw_id
        );
        assert_eq!(std::fs::read_to_string(raw)?, "raw");
        assert_eq!(std::fs::read_to_string(heif)?, "heif");
        Ok(())
    }

    #[test]
    fn duplicate_reconciliation_keeps_exact_user_selected_version() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let a = dir.path().join("photos/a.jpg");
        let b = dir.path().join("photos/a.HEIC");
        let id = ingest(&store, &a, "a", &snapshot("a"), Some("first"))?;
        ingest(&store, &b, "b", &snapshot("b"), Some("second"))?;
        store.set_default_version("lib", &id, "b")?;
        {
            let mut db = store.lock()?;
            let tx = db.transaction()?;
            tx.execute(
                "UPDATE catalog_versions SET visual_hash='same' WHERE asset_id=?",
                [&id],
            )?;
            reconcile_directory(&tx, "lib", a.parent().unwrap().to_str().unwrap())?;
            crate::revisions::flush(&tx)?;
            tx.commit()?;
        }
        let versions = store.versions("lib", &id)?;
        assert_eq!(versions["items"].as_array().unwrap().len(), 1);
        assert_eq!(versions["items"][0]["contentHash"], "b");
        assert_eq!(versions["items"][0]["userSelected"], true);
        assert_eq!(versions["deprecatedFiles"][0]["path"], a.to_str().unwrap());
        Ok(())
    }

    #[test]
    fn known_identity_and_capture_match_do_not_split_identity_aliases() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let first = dir.path().join("first/a.3FR");
        let second = dir.path().join("second/a.HEIC");
        let root = uuid::Uuid::new_v4().to_string();
        let mut metadata = snapshot("raw");
        metadata["originalDocumentID"] = json!(root);
        ingest(&store, &first, "raw", &metadata, None)?;
        ingest(&store, &second, "heif", &snapshot("heif"), None)?;
        let copied = dir.path().join("second/a.3FR");
        let id = ingest(&store, &copied, "raw", &metadata, None)?;
        let db = store.lock()?;
        let alias: String = db.query_row(
            "SELECT asset_id FROM catalog_identity_aliases WHERE library_id='lib' AND root_id=?",
            [&root],
            |r| r.get(0),
        )?;
        assert_eq!(alias, id);
        assert_eq!(
            db.query_row(
                "SELECT count(DISTINCT asset_id) FROM catalog_paths",
                [],
                |r| r.get::<_, i64>(0)
            )?,
            2
        );
        Ok(())
    }

    #[test]
    fn legacy_asset_without_versions_still_exposes_deprecation_reason() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let a = dir.path().join("photos/a.jpg");
        let b = a.with_file_name("copy.jpg");
        let id = ingest(&store, &a, "same", &snapshot("same"), None)?;
        ingest(&store, &b, "same", &snapshot("same"), None)?;
        reconcile_directory(
            &*store.lock()?,
            "lib",
            a.parent().unwrap().to_str().unwrap(),
        )?;
        store
            .lock()?
            .execute("DELETE FROM catalog_versions WHERE asset_id=?", [&id])?;
        let response = store.versions("lib", &id)?;
        assert!(response["items"].as_array().unwrap().is_empty());
        assert_eq!(response["deprecatedFiles"][0]["path"], b.to_str().unwrap());
        assert_eq!(
            response["deprecatedFiles"][0]["retainedPath"],
            a.to_str().unwrap()
        );
        assert_eq!(response["deprecatedFiles"][0]["basis"], "sha256");
        Ok(())
    }
}
