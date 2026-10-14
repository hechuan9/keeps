//! Version evidence and stable display selection. Migration never regroups existing assets.
use crate::store::{Store, StoreError};
use anyhow::{Context, Result};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

// Path ordering otherwise encourages SQLite to scan the library-wide path primary key.
const VERSION_PATHS: &str = "SELECT p.path,p.available FROM catalog_version_paths p INDEXED BY catalog_version_paths_asset WHERE p.library_id=? AND p.asset_id=? AND p.content_hash=? AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path) ORDER BY p.path";
const AVAILABLE_VERSION_PATHS: &str = "SELECT p.path FROM catalog_version_paths p INDEXED BY catalog_version_paths_asset JOIN catalog_versions v USING(library_id,asset_id,content_hash) JOIN catalog_assets a ON a.library_id=p.library_id AND a.id=p.asset_id WHERE p.library_id=? AND p.asset_id=? AND p.content_hash=? AND p.available=1 AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path) ORDER BY p.path";

#[derive(Default, Debug, Clone)]
pub struct VersionEvidence {
    /// Exact image content only: never a perceptual or downsampled hash.
    pub visual_hash: Option<String>,
    pub width: i64,
    pub height: i64,
    pub edited: bool,
    pub camera_serial: String,
    pub capture_original: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DefaultVersion {
    pub content_hash: String,
    pub path: String,
}
pub(crate) fn migrate(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE catalog_versions(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,content_hash TEXT NOT NULL,visual_hash TEXT,capture_key TEXT,width INTEGER NOT NULL,height INTEGER NOT NULL,priority INTEGER NOT NULL,evidence TEXT NOT NULL,PRIMARY KEY(library_id,asset_id,content_hash));
        CREATE INDEX version_visual ON catalog_versions(library_id,visual_hash);
        CREATE INDEX version_capture ON catalog_versions(library_id,capture_key);
        CREATE TABLE catalog_version_paths(library_id TEXT NOT NULL,path TEXT NOT NULL,asset_id TEXT NOT NULL,content_hash TEXT NOT NULL,available INTEGER NOT NULL,PRIMARY KEY(library_id,path));
        CREATE INDEX catalog_version_paths_asset ON catalog_version_paths(library_id,asset_id,content_hash,available);
        CREATE TABLE catalog_defaults(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,content_hash TEXT NOT NULL,user_selected INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(library_id,asset_id));
        CREATE TABLE IF NOT EXISTS catalog_version_revision(library_id TEXT PRIMARY KEY,revision INTEGER NOT NULL);")?;
    Ok(())
}
fn touch(db: &Connection, lib: &str, id: &str) -> Result<()> {
    db.execute("UPDATE catalog_assets SET snapshot=json_set(snapshot,'$.updatedAt',?) WHERE library_id=? AND id=?",params![chrono::Utc::now().to_rfc3339(),lib,id])?;
    Ok(())
}
pub(crate) fn capture_key(snapshot: &Value) -> Option<String> {
    let fields = ["captureTime", "cameraMake", "cameraModel", "lensModel"];
    let values: Option<Vec<&str>> = fields
        .iter()
        .map(|key| snapshot[key].as_str().filter(|s| !s.trim().is_empty()))
        .collect();
    values.map(|v| json!(v).to_string())
}
pub(crate) fn exact_match(
    db: &Connection,
    lib: &str,
    directory_prefix: &str,
    evidence: &VersionEvidence,
) -> Result<Option<String>> {
    let Some(hash) = evidence.visual_hash.as_deref().filter(|s| !s.is_empty()) else {
        return Ok(None);
    };
    Ok(db.query_row("SELECT DISTINCT v.asset_id FROM catalog_versions v JOIN catalog_paths p ON p.library_id=v.library_id AND p.asset_id=v.asset_id WHERE v.library_id=?1 AND v.visual_hash=?2 AND p.content_hash=v.content_hash AND p.role IN ('jpeg_original','raw_original') AND substr(p.path,1,length(?3))=?3 AND instr(substr(p.path,length(?3)+1),'/')=0 ORDER BY v.asset_id LIMIT 1", params![lib,hash,directory_prefix], |r|r.get(0)).optional()?)
}
pub(crate) fn register(
    db: &Connection,
    lib: &str,
    id: &str,
    path: &str,
    file: &Value,
    snapshot: &Value,
    evidence: &VersionEvidence,
) -> Result<()> {
    if file["role"] == "sidecar" {
        return Ok(());
    }
    let hash = file["contentHash"]
        .as_str()
        .context("missing contentHash")?;
    let priority = if evidence.edited {
        3
    } else if file["role"] == "raw_original" {
        1
    } else {
        2
    };
    type StoredVersion = (Option<String>, Option<String>, i64, i64, i64, String);
    let old: Option<StoredVersion> = db.query_row(
        "SELECT visual_hash,capture_key,width,height,priority,evidence FROM catalog_versions WHERE library_id=? AND asset_id=? AND content_hash=?",
        params![lib,id,hash], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?)),
    ).optional()?;
    let previous_detail = old
        .as_ref()
        .map(|o| serde_json::from_str::<Value>(&o.5))
        .transpose()?;
    let version_id = previous_detail
        .as_ref()
        .and_then(|v| v["versionID"].as_str())
        .and_then(crate::identity::normalize)
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let mut capture = snapshot.clone();
    if let Some(old) = &old {
        let previous: Value = serde_json::from_str(&old.5)?;
        // Scan identity and filename-derived fields are shared across all paths of a version.
        // Actual capture metadata remains comparable below, including sidecar ratings.
        if let Some(capture) = capture.as_object_mut() {
            for key in [
                "createdAt",
                "updatedAt",
                "assetID",
                "originalFilename",
                "metadataFingerprint",
            ] {
                if let Some(value) = previous["capture"].get(key) {
                    capture.insert(key.into(), value.clone());
                } else {
                    capture.remove(key);
                }
            }
        }
    }
    let visual = evidence
        .visual_hash
        .clone()
        .or_else(|| old.as_ref().and_then(|o| o.0.clone()));
    let key = capture_key(snapshot).or_else(|| old.as_ref().and_then(|o| o.1.clone()));
    let width = evidence.width.max(old.as_ref().map_or(0, |o| o.2));
    let height = evidence.height.max(old.as_ref().map_or(0, |o| o.3));
    let generated_from = old
        .as_ref()
        .map(|o| serde_json::from_str::<Value>(&o.5))
        .transpose()?
        .and_then(|v| v.get("generatedFrom").cloned());
    let priority = if generated_from.is_some() {
        1
    } else {
        priority.max(old.as_ref().map_or(0, |o| o.4))
    };
    let mut detail = json!({"versionID":version_id,"exactVisualHash":evidence.visual_hash,"edited":evidence.edited,"cameraSerial":evidence.camera_serial,"captureOriginal":evidence.capture_original,"capture":capture});
    if let Some(source) = generated_from {
        detail["generatedFrom"] = source;
    }
    if let Some(source) = previous_detail
        .as_ref()
        .and_then(|v| v.get("sourceVersionID"))
    {
        detail["sourceVersionID"] = source.clone();
    }
    let detail = detail.to_string();
    let changed = old.as_ref()
        != Some(&(
            visual.clone(),
            key.clone(),
            width,
            height,
            priority,
            detail.clone(),
        ));
    if changed {
        db.execute("INSERT INTO catalog_versions VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(library_id,asset_id,content_hash) DO UPDATE SET visual_hash=excluded.visual_hash,capture_key=excluded.capture_key,width=excluded.width,height=excluded.height,priority=excluded.priority,evidence=excluded.evidence", params![lib,id,hash,visual,key,width,height,priority,detail])?;
    }
    let previous: Option<String> = db
        .query_row(
            "SELECT asset_id FROM catalog_version_paths WHERE library_id=? AND path=?",
            params![lib, path],
            |r| r.get(0),
        )
        .optional()?;
    let path_changed = db.execute("INSERT INTO catalog_version_paths VALUES(?,?,?,?,1) ON CONFLICT(library_id,path) DO UPDATE SET asset_id=excluded.asset_id,content_hash=excluded.content_hash,available=1 WHERE asset_id IS NOT excluded.asset_id OR content_hash IS NOT excluded.content_hash OR available<>1",params![lib,path,id,hash])? > 0;
    let default_changed = choose(db, lib, id)?;
    if let Some(previous) = previous.filter(|p| p != id) {
        choose(db, lib, &previous)?;
        touch(db, lib, &previous)?;
    }
    if changed || path_changed || default_changed {
        touch(db, lib, id)?;
    }
    Ok(())
}
pub(crate) fn choose(db: &Connection, lib: &str, id: &str) -> Result<bool> {
    let current:Option<(String,i64,i64)>=db.query_row("SELECT d.content_hash,d.user_selected,v.priority FROM catalog_defaults d JOIN catalog_versions v USING(library_id,asset_id,content_hash) WHERE d.library_id=? AND d.asset_id=? AND EXISTS(SELECT 1 FROM catalog_version_paths p WHERE p.library_id=d.library_id AND p.asset_id=d.asset_id AND p.content_hash=d.content_hash AND p.available=1 AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path))",params![lib,id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional()?;
    let best:Option<(String,i64)>=db.query_row("SELECT v.content_hash,v.priority FROM catalog_versions v WHERE v.library_id=? AND v.asset_id=? AND EXISTS(SELECT 1 FROM catalog_version_paths p WHERE p.library_id=v.library_id AND p.asset_id=v.asset_id AND p.content_hash=v.content_hash AND p.available=1 AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path)) ORDER BY v.priority DESC,v.width*v.height DESC,v.content_hash LIMIT 1",params![lib,id],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    if let Some((_, user, priority)) = &current
        && (*user == 1 || best.as_ref().is_some_and(|b| b.1 <= *priority))
    {
        return Ok(false);
    }
    let hash = best.map(|b| b.0);
    let old: Option<String> = db
        .query_row(
            "SELECT content_hash FROM catalog_defaults WHERE library_id=? AND asset_id=?",
            params![lib, id],
            |r| r.get(0),
        )
        .optional()?;
    if old == hash {
        return Ok(false);
    }
    db.execute(
        "DELETE FROM catalog_defaults WHERE library_id=? AND asset_id=?",
        params![lib, id],
    )?;
    if let Some(hash) = hash {
        db.execute(
            "INSERT INTO catalog_defaults VALUES(?,?,?,0)",
            params![lib, id, hash],
        )?;
    }
    db.execute(
        "DELETE FROM derivative_objects WHERE library_id=? AND asset_id=? AND role='preview'",
        params![lib, id],
    )?;
    Ok(true)
}
pub(crate) fn missing_path(db: &Connection, lib: &str, id: &str, path: &str) -> Result<()> {
    let changed = db.execute(
        "UPDATE catalog_version_paths SET available=0 WHERE library_id=? AND path=? AND available<>0",
        params![lib, path],
    )? > 0;
    if changed {
        choose(db, lib, id)?;
        touch(db, lib, id)?;
    }
    Ok(())
}

fn invalid(message: &str) -> anyhow::Error {
    StoreError {
        status: 422,
        code: "invalid_version".into(),
        message: message.into(),
    }
    .into()
}
impl Store {
    pub fn generated_standard_target(
        &self,
        lib: &str,
        id: &str,
        source: &std::path::Path,
        source_hash: &str,
    ) -> Result<std::path::PathBuf> {
        let stem = source
            .file_stem()
            .and_then(|s| s.to_str())
            .context("source filename must be UTF-8")?;
        for version in 0_u64.. {
            let name = if version == 0 {
                format!("{stem}.heic")
            } else {
                format!("{stem}.{version}.heic")
            };
            let target = source.with_file_name(name);
            let path = target.to_str().context("standard path must be UTF-8")?;
            let owners: Vec<(String, Option<String>)> = {
                let db = self.read()?;
                let mut q = db.prepare("SELECT p.asset_id,json_extract(v.evidence,'$.generatedFrom') FROM (SELECT library_id,asset_id,content_hash,path FROM catalog_paths UNION SELECT library_id,asset_id,content_hash,path FROM catalog_version_paths) p LEFT JOIN catalog_versions v USING(library_id,asset_id,content_hash) WHERE p.library_id=? AND p.path=?")?;
                q.query_map(params![lib, path], |r| Ok((r.get(0)?, r.get(1)?)))?
                    .collect::<rusqlite::Result<_>>()?
            };
            let owned = !owners.is_empty()
                && owners
                    .iter()
                    .all(|(owner, hash)| owner == id && hash.as_deref() == Some(source_hash));
            match std::fs::symlink_metadata(&target) {
                Ok(meta)
                    if owned
                        && meta.is_file()
                        && self.generated_standard_matches(lib, id, &target)? =>
                {
                    return Ok(target);
                }
                Ok(_) => continue,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    if owners.is_empty() || owned {
                        return Ok(target);
                    }
                }
                Err(e) => return Err(e.into()),
            }
        }
        unreachable!()
    }

    pub fn generated_standard_matches(
        &self,
        lib: &str,
        id: &str,
        path: &std::path::Path,
    ) -> Result<bool> {
        if std::fs::symlink_metadata(path)?.file_type().is_symlink() {
            return Ok(false);
        }
        let hash = crate::media::sha256_file(path)?;
        Ok(self.read()?.query_row("SELECT EXISTS(SELECT 1 FROM catalog_paths WHERE library_id=? AND asset_id=? AND path=? AND content_hash=?)", params![lib,id,path.to_str().context("path must be UTF-8")?,hash], |r|r.get(0))?)
    }

    pub fn publish_generated_standard(
        &self,
        lib: &str,
        id: &str,
        source_hash: &str,
        staged: &std::path::Path,
        target: &std::path::Path,
        dimensions: (i64, i64),
    ) -> Result<()> {
        let hash = crate::media::sha256_file(staged)?;
        let size = i64::try_from(std::fs::metadata(staged)?.len())?;
        let path = target.to_str().context("standard path must be UTF-8")?;
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let snapshot: String = tx.query_row(
            "SELECT snapshot FROM catalog_assets WHERE library_id=? AND id=?",
            params![lib, id],
            |r| r.get(0),
        )?;
        let original: Option<(String,i64)> = tx.query_row("SELECT content_hash,user_selected FROM catalog_defaults WHERE library_id=? AND asset_id=?", params![lib,id], |r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        anyhow::ensure!(
            !target.exists(),
            "standard photo target already exists; refusing to replace it"
        );
        let file = json!({"contentHash":hash,"sizeBytes":size,"role":"jpeg_original"});
        let reserved: Option<(String,Option<String>)> = tx.query_row("SELECT p.asset_id,json_extract(v.evidence,'$.generatedFrom') FROM (SELECT library_id,asset_id,content_hash,path FROM catalog_paths UNION SELECT library_id,asset_id,content_hash,path FROM catalog_version_paths) p LEFT JOIN catalog_versions v ON v.library_id=p.library_id AND v.asset_id=p.asset_id AND v.content_hash=p.content_hash WHERE p.library_id=? AND p.path=?",params![lib,path],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        anyhow::ensure!(reserved.as_ref().is_none_or(|(owner,source)| owner == id && source.as_deref() == Some(source_hash)), "standard photo path belongs to another source");
        tx.execute(
            "INSERT INTO catalog_paths VALUES(?,?,?,?,?) ON CONFLICT(library_id,path) DO UPDATE SET content_hash=excluded.content_hash",
            params![lib, path, id, hash, "jpeg_original"],
        )?;
        tx.execute("INSERT INTO catalog_files VALUES(?,?,?,?,?,'keeps-nas','online') ON CONFLICT DO NOTHING", params![lib,id,hash,size,"jpeg_original"])?;
        let source_version: Option<String> = tx.query_row("SELECT json_extract(evidence,'$.versionID') FROM catalog_versions WHERE library_id=? AND asset_id=? AND content_hash=?",params![lib,id,source_hash],|r|r.get(0)).optional()?.flatten();
        tx.execute("INSERT OR IGNORE INTO catalog_versions(library_id,asset_id,content_hash,width,height,priority,evidence) VALUES(?,?,?,?,?,1,?)",params![lib,id,hash,dimensions.0,dimensions.1,json!({"versionID":uuid::Uuid::new_v4().to_string(),"sourceVersionID":source_version,"generatedFrom":source_hash,"capture":serde_json::from_str::<Value>(&snapshot)?}).to_string()])?;
        register(
            &tx,
            lib,
            id,
            path,
            &file,
            &serde_json::from_str(&snapshot)?,
            &VersionEvidence {
                width: dimensions.0,
                height: dimensions.1,
                ..Default::default()
            },
        )?;
        tx.execute("UPDATE catalog_versions SET evidence=json_set(evidence,'$.generatedFrom',?),priority=1 WHERE library_id=? AND asset_id=? AND content_hash=?",params![source_hash,lib,id,hash])?;
        tx.execute(
            "DELETE FROM catalog_defaults WHERE library_id=? AND asset_id=?",
            params![lib, id],
        )?;
        if let Some((hash, user)) = original {
            tx.execute(
                "INSERT INTO catalog_defaults VALUES(?,?,?,?)",
                params![lib, id, hash, user],
            )?;
        }
        crate::revisions::flush(&tx)?;
        // Commit the association before publishing, so a restart can never scan an unregistered
        // generated file. A missing reserved target can be retried for the same source only.
        tx.commit()?;
        drop(db);
        std::fs::hard_link(staged, target)
            .context("publish standard photo without replacing existing file")?;
        Ok(())
    }

    pub fn defaults_needing_previews(&self, lib: &str, scope: &str) -> Result<Vec<String>> {
        let db = self.read()?;
        let root = scope.trim_end_matches('/');
        let mut statement=db.prepare("SELECT d.asset_id FROM catalog_defaults d WHERE d.library_id=? AND d.asset_id IN (SELECT p.asset_id FROM catalog_version_paths p WHERE p.library_id=? AND p.path>=? AND p.path<?) AND EXISTS(SELECT 1 FROM catalog_version_paths p WHERE p.library_id=d.library_id AND p.asset_id=d.asset_id AND p.content_hash=d.content_hash AND p.available=1 AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path)) AND NOT EXISTS(SELECT 1 FROM derivative_objects o WHERE o.library_id=d.library_id AND o.asset_id=d.asset_id AND o.role='preview') ORDER BY d.asset_id")?;
        Ok(statement
            .query_map(
                params![lib, lib, format!("{root}/"), format!("{root}0")],
                |r| r.get(0),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }
    pub fn default_version(&self, lib: &str, id: &str) -> Result<Option<DefaultVersion>> {
        Ok(self.read()?.query_row("SELECT d.content_hash,p.path FROM catalog_defaults d JOIN catalog_version_paths p USING(library_id,asset_id,content_hash) WHERE d.library_id=? AND d.asset_id=? AND p.available=1 AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path) ORDER BY p.path LIMIT 1",params![lib,id],|r|Ok(DefaultVersion{content_hash:r.get(0)?,path:r.get(1)?})).optional()?)
    }
    pub fn available_version_paths(&self, lib: &str, id: &str, hash: &str) -> Result<Vec<String>> {
        let db = self.read()?;
        let mut statement = db.prepare(AVAILABLE_VERSION_PATHS)?;
        Ok(statement
            .query_map(params![lib, id, hash], |row| row.get(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }
    pub fn versions(&self, lib: &str, id: &str) -> Result<Value> {
        let mut connection = self.read()?;
        let db = connection.transaction()?;
        let negative: Option<String> = db
            .query_row(
                "SELECT negative_hash FROM catalog_assets WHERE library_id=? AND id=?",
                params![lib, id],
                |r| r.get(0),
            )
            .optional()?
            .ok_or_else(|| StoreError {
                status: 404,
                code: "asset_not_found".into(),
                message: "asset not found".into(),
            })?;
        let mut stmt=db.prepare("SELECT v.content_hash,v.width,v.height,v.priority,v.evidence,coalesce(d.content_hash=v.content_hash,0),coalesce(d.user_selected,0),EXISTS(SELECT 1 FROM catalog_version_paths p WHERE p.library_id=v.library_id AND p.asset_id=v.asset_id AND p.content_hash=v.content_hash AND p.available=1 AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path)) FROM catalog_versions v LEFT JOIN catalog_defaults d USING(library_id,asset_id) WHERE v.library_id=? AND v.asset_id=? ORDER BY v.priority DESC,v.width*v.height DESC,v.content_hash")?;
        let rows = stmt
            .query_map(params![lib, id], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, i64>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, bool>(5)?,
                    r.get::<_, bool>(6)?,
                    r.get::<_, bool>(7)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut items = Vec::new();
        for (hash, width, height, priority, evidence, default, user, available) in rows {
            let mut paths = db.prepare(VERSION_PATHS)?;
            let paths = paths
                .query_map(params![lib, id, hash], |r| {
                    Ok(json!({"path":r.get::<_,String>(0)?,"available":r.get::<_,bool>(1)?}))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            if paths.is_empty() {
                continue;
            }
            let evidence: Value = serde_json::from_str(&evidence)?;
            items.push(json!({"versionID":evidence["versionID"],"sourceVersionID":evidence["sourceVersionID"],"contentHash":hash,"width":width,"height":height,"priority":priority,"evidence":evidence,"isNegative":negative.as_deref()==Some(hash.as_str()),"isDefault":default,"userSelected":default&&user,"available":available,"paths":paths}));
        }
        let deprecated = crate::photo_relations::deprecated_files(&db, lib, id)?;
        Ok(json!({"items":items,"deprecatedFiles":deprecated,"negativeContentHash":negative}))
    }
    pub fn version_candidates(&self, lib: &str, id: &str) -> Result<Value> {
        let mut connection = self.read()?;
        let db = connection.transaction()?;
        let exists: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM catalog_assets WHERE library_id=? AND id=?)",
            params![lib, id],
            |row| row.get(0),
        )?;
        anyhow::ensure!(
            exists,
            StoreError {
                status: 404,
                code: "asset_not_found".into(),
                message: "asset not found".into(),
            }
        );
        let mut stmt=db.prepare("SELECT DISTINCT b.asset_id FROM catalog_versions a JOIN catalog_versions b ON a.library_id=b.library_id AND a.capture_key=b.capture_key WHERE a.library_id=? AND a.asset_id=? AND b.asset_id<>a.asset_id AND (coalesce(json_extract(a.evidence,'$.cameraSerial'),'')='' OR coalesce(json_extract(b.evidence,'$.cameraSerial'),'')='' OR json_extract(a.evidence,'$.cameraSerial')=json_extract(b.evidence,'$.cameraSerial')) ORDER BY b.asset_id")?;
        let items=stmt.query_map(params![lib,id],|r|Ok(json!({"assetID":r.get::<_,String>(0)?,"evidence":"matching_capture_metadata","requiresVisualConfirmation":true})))?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(json!({"items":items}))
    }
    pub fn set_default_version(&self, lib: &str, id: &str, hash: &str) -> Result<Value> {
        self.asset(lib, id)?;
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        let available:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM catalog_version_paths p WHERE library_id=? AND asset_id=? AND content_hash=? AND available=1 AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path))",params![lib,id,hash],|r|r.get(0))?;
        if !available {
            return Err(invalid("version is not available for this asset"));
        }
        let old: Option<String> = tx
            .query_row(
                "SELECT content_hash FROM catalog_defaults WHERE library_id=? AND asset_id=?",
                params![lib, id],
                |r| r.get(0),
            )
            .optional()?;
        let changed = tx.execute("INSERT INTO catalog_defaults VALUES(?,?,?,1) ON CONFLICT(library_id,asset_id) DO UPDATE SET content_hash=excluded.content_hash,user_selected=1 WHERE content_hash IS NOT excluded.content_hash OR user_selected<>1",params![lib,id,hash])? > 0;
        if old.as_deref() != Some(hash) {
            tx.execute("DELETE FROM derivative_objects WHERE library_id=? AND asset_id=? AND role='preview'",params![lib,id])?;
        }
        if changed {
            touch(&tx, lib, id)?;
        }
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        drop(db);
        self.versions(lib, id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_paths_are_scoped_available_and_not_deprecated() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let id =
            store.ingest_original("lib", "/photos/a.mp4", &file("video", false), &snapshot())?;
        {
            let db = store.lock()?;
            for (path, available) in [
                ("/photos/z.mp4", 1),
                ("/photos/missing.mp4", 0),
                ("/photos/deprecated.mp4", 1),
            ] {
                db.execute(
                    "INSERT INTO catalog_version_paths VALUES(?,?,?,?,?)",
                    params!["lib", path, id, "video", available],
                )?;
            }
            db.execute(
                "INSERT INTO catalog_deprecated_files VALUES(?,?,?,?,?)",
                params![
                    "lib",
                    "/photos/deprecated.mp4",
                    "/photos/a.mp4",
                    "duplicate",
                    "duplicate"
                ],
            )?;
        }
        assert_eq!(
            store.available_version_paths("lib", &id, "video")?,
            vec!["/photos/a.mp4", "/photos/z.mp4"]
        );
        assert!(
            store
                .available_version_paths("other", &id, "video")?
                .is_empty()
        );
        assert!(
            store
                .available_version_paths("lib", "other", "video")?
                .is_empty()
        );
        assert!(
            store
                .available_version_paths("lib", &id, "other")?
                .is_empty()
        );
        let versions = store.versions("lib", &id)?;
        assert_eq!(versions["items"][0]["paths"].as_array().unwrap().len(), 3);
        Ok(())
    }

    #[test]
    fn ordered_version_paths_use_asset_index_instead_of_library_scan() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let db = store.read()?;
        for sql in [VERSION_PATHS, AVAILABLE_VERSION_PATHS] {
            let mut query = db.prepare(&format!("EXPLAIN QUERY PLAN {sql}"))?;
            let plan = query
                .query_map(params!["lib", "asset", "hash"], |row| {
                    row.get::<_, String>(3)
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            assert!(plan.iter().any(|step| step.contains("SEARCH p USING INDEX catalog_version_paths_asset (library_id=? AND asset_id=? AND content_hash=?")), "{plan:?}");
        }
        Ok(())
    }

    #[test]
    fn standard_names_skip_user_files_and_reuse_confirmed_versions() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let raw = dir.path().join("DSC02514.ARW");
        std::fs::write(&raw, b"raw")?;
        let id = store.ingest_original(
            "lib",
            raw.to_str().unwrap(),
            &file("rawhash", true),
            &snapshot(),
        )?;
        assert_eq!(
            store.generated_standard_target("lib", &id, &raw, "rawhash")?,
            dir.path().join("DSC02514.heic")
        );
        let original = dir.path().join("DSC02514.heic");
        std::fs::write(&original, b"user photo")?;
        let target = store.generated_standard_target("lib", &id, &raw, "rawhash")?;
        assert_eq!(target, dir.path().join("DSC02514.1.heic"));
        let stage = dir.path().join("stage");
        std::fs::write(&stage, b"generated")?;
        store.publish_generated_standard("lib", &id, "rawhash", &stage, &target, (100, 100))?;
        let listed = store.versions("lib", &id)?;
        let items = listed["items"].as_array().unwrap();
        let source = items
            .iter()
            .find(|v| v["contentHash"] == "rawhash")
            .unwrap();
        let generated = items
            .iter()
            .find(|v| v["contentHash"] != "rawhash")
            .unwrap();
        assert_eq!(generated["sourceVersionID"], source["versionID"]);
        assert_ne!(generated["versionID"], source["versionID"]);
        assert_eq!(
            store.generated_standard_target("lib", &id, &raw, "rawhash")?,
            target
        );
        assert_eq!(
            store.generated_standard_target("lib", &id, &raw, "differentraw")?,
            dir.path().join("DSC02514.2.heic")
        );
        std::fs::write(&target, b"user replacement")?;
        assert_eq!(
            store.generated_standard_target("lib", &id, &raw, "rawhash")?,
            dir.path().join("DSC02514.2.heic")
        );
        assert_eq!(std::fs::read(original)?, b"user photo");
        Ok(())
    }

    #[test]
    fn generated_standard_stays_same_asset_after_rescan_and_never_overwrites() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let raw = dir.path().join("source.arw");
        std::fs::write(&raw, b"raw")?;
        let id = store.ingest_original(
            "lib",
            raw.to_str().unwrap(),
            &file("rawhash", true),
            &snapshot(),
        )?;
        store.lock()?.execute("INSERT INTO derivative_objects VALUES(?,?,'preview','{}','previews','old',NULL,10,10,'now')",params!["lib",id])?;
        let staged = dir.path().join("stage");
        let target = dir.path().join("source.arw.keeps.heic");
        std::fs::write(&staged, b"generated")?;
        store.publish_generated_standard("lib", &id, "rawhash", &staged, &target, (100, 100))?;
        assert!(store.generated_standard_matches("lib", &id, &target)?);
        let hash = crate::media::sha256_file(&target)?;
        let rescanned = store.ingest_original(
            "lib",
            target.to_str().unwrap(),
            &file(&hash, false),
            &snapshot(),
        )?;
        assert_eq!(rescanned, id);
        assert_eq!(store.counts("lib", false)?["all"], 1);
        assert_eq!(
            store.default_version("lib", &id)?.unwrap().content_hash,
            "rawhash"
        );
        let generated: String=store.lock()?.query_row("SELECT json_extract(evidence,'$.generatedFrom') FROM catalog_versions WHERE library_id='lib' AND asset_id=? AND content_hash=?",params![id,hash],|r|r.get(0))?;
        assert_eq!(generated, "rawhash");
        assert_eq!(
            store.lock()?.query_row(
                "SELECT count(*) FROM derivative_objects WHERE library_id='lib' AND asset_id=?",
                [&id],
                |r| r.get::<_, i64>(0)
            )?,
            1
        );
        assert!(
            store
                .publish_generated_standard("lib", &id, "rawhash", &staged, &target, (100, 100))
                .is_err()
        );
        assert_eq!(std::fs::read(&target)?, b"generated");
        // Simulate a committed association whose file publication was interrupted.
        std::fs::remove_file(&target)?;
        store.publish_generated_standard("lib", &id, "rawhash", &staged, &target, (100, 100))?;
        assert!(store.generated_standard_matches("lib", &id, &target)?);
        assert_eq!(store.counts("lib", false)?["all"], 1);
        assert_eq!(std::fs::read(&raw)?, b"raw");
        Ok(())
    }
    fn snapshot() -> Value {
        json!({"assetID":uuid::Uuid::new_v4(),"captureTime":"2024-01-01T00:00:00Z","cameraMake":"Canon","cameraModel":"R3","lensModel":"50mm","originalFilename":"same.jpg","contentFingerprint":"unused","metadataFingerprint":"same","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"})
    }
    fn file(hash: &str, raw: bool) -> Value {
        json!({"contentHash":hash,"sizeBytes":100,"role":if raw{"raw_original"}else{"jpeg_original"}})
    }
    fn evidence(visual: &str) -> VersionEvidence {
        VersionEvidence {
            visual_hash: Some(visual.into()),
            width: 100,
            height: 100,
            ..Default::default()
        }
    }
    #[test]
    fn repeated_scan_preserves_revision_but_exif_changes_invalidate() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let original = snapshot();
        let id = store.ingest_original_with_evidence(
            "lib",
            "/photos/a.jpg",
            &file("a", false),
            &original,
            &evidence("pixels"),
        )?;
        let before = store.library_revision("lib")?;
        let before_asset = store.asset("lib", &id)?;
        let before_versions = store.versions("lib", &id)?;
        assert!(
            crate::identity::normalize(before_versions["items"][0]["versionID"].as_str().unwrap())
                .is_some()
        );
        let mut rescanned = snapshot();
        rescanned["createdAt"] = json!("2026-09-28T00:00:00Z");
        rescanned["updatedAt"] = rescanned["createdAt"].clone();
        assert_eq!(
            store.ingest_original_with_evidence(
                "lib",
                "/photos/a.jpg",
                &file("a", false),
                &rescanned,
                &evidence("pixels")
            )?,
            id
        );
        assert_eq!(store.library_revision("lib")?, before);
        assert_eq!(store.asset("lib", &id)?, before_asset);
        assert_eq!(store.versions("lib", &id)?, before_versions);
        rescanned["lensModel"] = json!("85mm");
        store.ingest_original_with_evidence(
            "lib",
            "/photos/a.jpg",
            &file("a", false),
            &rescanned,
            &evidence("pixels"),
        )?;
        assert!(store.library_revision("lib")?["revision"].as_i64() > before["revision"].as_i64());
        assert_eq!(
            store.versions("lib", &id)?["items"][0]["evidence"]["capture"]["lensModel"],
            "85mm"
        );
        Ok(())
    }
    #[test]
    fn changed_file_gets_new_version_with_same_photo_identity() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let mut snapshot = snapshot();
        snapshot["originalDocumentID"] = json!(uuid::Uuid::new_v4().to_string());
        let id = store.ingest_original_with_evidence(
            "lib",
            "/photos/a.jpg",
            &file("first", false),
            &snapshot,
            &evidence("first"),
        )?;
        let first = store.versions("lib", &id)?["items"][0]["versionID"].clone();
        assert_eq!(
            store.ingest_original_with_evidence(
                "lib",
                "/photos/a.jpg",
                &file("second", false),
                &snapshot,
                &evidence("second")
            )?,
            id
        );
        let second = store.versions("lib", &id)?["items"][0]["versionID"].clone();
        assert_ne!(first, second);
        assert!(crate::identity::normalize(second.as_str().unwrap()).is_some());
        store.ingest_original_with_evidence(
            "lib",
            "/photos/a.jpg",
            &file("second", false),
            &snapshot,
            &evidence("second"),
        )?;
        assert_eq!(store.versions("lib", &id)?["items"][0]["versionID"], second);
        Ok(())
    }
    #[test]
    fn rescanning_content_aliases_preserves_revision_and_sidecar_changes_are_visible() -> Result<()>
    {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let metadata = crate::media::Metadata {
            capture_time: Some("2024-01-01T00:00:00Z".into()),
            camera_make: "Canon".into(),
            camera_model: "R3".into(),
            lens_model: "50mm".into(),
            ..Default::default()
        };
        let snapshots: Vec<_> = ["/photos/a.jpg", "/photos/b.jpg"]
            .iter()
            .map(|path| {
                let path = std::path::Path::new(path);
                let mut value = snapshot();
                value["originalFilename"] = json!(path.file_name().unwrap().to_str().unwrap());
                value["metadataFingerprint"] = json!(metadata.fingerprint(path));
                value
            })
            .collect();
        assert_ne!(
            snapshots[0]["metadataFingerprint"],
            snapshots[1]["metadataFingerprint"]
        );
        let first = store.ingest_original_with_evidence(
            "lib",
            "/photos/a.jpg",
            &file("same", false),
            &snapshots[0],
            &evidence("pixels"),
        )?;
        assert_eq!(
            store.ingest_original_with_evidence(
                "lib",
                "/photos/b.jpg",
                &file("same", false),
                &snapshots[1],
                &evidence("pixels")
            )?,
            first
        );
        let revision = store.library_revision("lib")?;
        let versions = store.versions("lib", &first)?;
        for _ in 0..2 {
            for (path, snapshot) in ["/photos/a.jpg", "/photos/b.jpg"].iter().zip(&snapshots) {
                store.ingest_original_with_evidence(
                    "lib",
                    path,
                    &file("same", false),
                    snapshot,
                    &evidence("pixels"),
                )?;
                assert_eq!(store.library_revision("lib")?, revision);
                assert_eq!(store.versions("lib", &first)?, versions);
            }
        }
        let mut updated = snapshots[1].clone();
        updated["rating"] = json!(4);
        store.ingest_original_with_evidence(
            "lib",
            "/photos/b.jpg",
            &file("same", false),
            &updated,
            &evidence("pixels"),
        )?;
        assert!(
            store.library_revision("lib")?["revision"].as_i64() > revision["revision"].as_i64()
        );
        assert_eq!(
            store.versions("lib", &first)?["items"][0]["evidence"]["capture"]["rating"],
            4
        );
        Ok(())
    }
    #[test]
    fn repeated_default_selection_and_missing_path_do_not_invalidate() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let id = store.ingest_original("lib", "/photos/a.jpg", &file("a", false), &snapshot())?;
        let automatic = store.library_revision("lib")?;
        store.set_default_version("lib", &id, "a")?;
        let selected = store.library_revision("lib")?;
        assert!(selected["revision"].as_i64() > automatic["revision"].as_i64());
        let asset = store.asset("lib", &id)?;
        store.set_default_version("lib", &id, "a")?;
        assert_eq!(store.library_revision("lib")?, selected);
        assert_eq!(store.asset("lib", &id)?, asset);
        for _ in 0..2 {
            let mut db = store.lock()?;
            let tx = db.transaction()?;
            missing_path(&tx, "lib", &id, "/photos/a.jpg")?;
            crate::revisions::flush(&tx)?;
            tx.commit()?;
            drop(db);
            if store.default_version("lib", &id)?.is_some() {
                anyhow::bail!("missing path retained default");
            }
        }
        let missing = store.library_revision("lib")?;
        // The first missing transition is the only transaction that changes data.
        assert_eq!(
            missing["revision"].as_i64(),
            selected["revision"].as_i64().map(|v| v + 1)
        );
        Ok(())
    }
    #[test]
    fn new_hash_and_visual_matches_stay_in_direct_parent_directory() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let mut ids = Vec::new();
        for path in ["/photos/a.jpg", "/photos/sub/a.jpg", "/photos-other/a.jpg"] {
            ids.push(store.ingest_original_with_evidence(
                "lib",
                path,
                &file("same", false),
                &snapshot(),
                &evidence("same-image"),
            )?);
        }
        assert_ne!(ids[0], ids[1]);
        assert_ne!(ids[0], ids[2]);
        assert_ne!(ids[1], ids[2]);
        for (index, directory) in ["/photos", "/photos/sub", "/photos-other"]
            .iter()
            .enumerate()
        {
            assert_eq!(
                store.ingest_original_with_evidence(
                    "lib",
                    &format!("{directory}/copy.jpg"),
                    &file("same", false),
                    &snapshot(),
                    &evidence("same-image")
                )?,
                ids[index]
            );
            assert_eq!(
                store.ingest_original_with_evidence(
                    "lib",
                    &format!("{directory}/edited-metadata.jpg"),
                    &file(&format!("changed-{index}"), false),
                    &snapshot(),
                    &evidence("same-image")
                )?,
                ids[index]
            );
        }
        let elsewhere = store.ingest_original_with_evidence(
            "lib",
            "/elsewhere/new.jpg",
            &file("other", false),
            &snapshot(),
            &evidence("same-image"),
        )?;
        assert!(!ids.contains(&elsewhere));
        Ok(())
    }
    #[test]
    fn historical_cross_directory_assets_do_not_bridge_content_evidence() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let id = store.ingest_original_with_evidence(
            "lib",
            "/one/a.jpg",
            &file("a", false),
            &snapshot(),
            &evidence("image-a"),
        )?;
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES(?,?,?,?,?)",
            params!["lib", "/two/b.jpg", id, "b", "jpeg_original"],
        )?;
        assert_eq!(
            store.ingest_original_with_evidence(
                "lib",
                "/two/b.jpg",
                &file("b", false),
                &snapshot(),
                &evidence("image-b")
            )?,
            id
        );
        let visual = store.ingest_original_with_evidence(
            "lib",
            "/one/metadata-copy.jpg",
            &file("b-metadata", false),
            &snapshot(),
            &evidence("image-b"),
        )?;
        assert_ne!(visual, id);
        let hash = store.ingest_original_with_evidence(
            "lib",
            "/one/hash-copy.jpg",
            &file("b", false),
            &snapshot(),
            &VersionEvidence::default(),
        )?;
        assert_ne!(hash, id);
        assert_ne!(hash, visual);
        assert_eq!(
            store.ingest_original_with_evidence(
                "lib",
                "/two/copy.jpg",
                &file("b", false),
                &snapshot(),
                &evidence("image-b")
            )?,
            id
        );
        Ok(())
    }
    #[test]
    fn capture_metadata_is_only_candidate_and_serial_conflicts_are_excluded() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let a = store.ingest_original_with_evidence(
            "lib",
            "/a.jpg",
            &file("a", false),
            &snapshot(),
            &evidence("image-a"),
        )?;
        let b = store.ingest_original_with_evidence(
            "lib",
            "/b.jpg",
            &file("b", false),
            &snapshot(),
            &evidence("image-b"),
        )?;
        assert_ne!(a, b);
        assert_eq!(
            store.version_candidates("lib", &a)?["items"][0]["assetID"],
            b
        );
        let mut ev = evidence("image-c");
        ev.camera_serial = "serial1".into();
        let c = store.ingest_original_with_evidence(
            "lib",
            "/c.jpg",
            &file("c", false),
            &snapshot(),
            &ev,
        )?;
        ev.camera_serial = "serial2".into();
        ev.visual_hash = Some("image-d".into());
        let d = store.ingest_original_with_evidence(
            "lib",
            "/d.jpg",
            &file("d", false),
            &snapshot(),
            &ev,
        )?;
        assert!(
            !store.version_candidates("lib", &c)?["items"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v["assetID"] == d)
        );
        let mut unknown = snapshot();
        unknown["lensModel"] = json!("");
        let e = store.ingest_original("lib", "/e.jpg", &file("e", false), &unknown)?;
        assert!(
            store.version_candidates("lib", &e)?["items"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        Ok(())
    }
    #[test]
    fn distinct_versions_default_remains_stable_with_user_override() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let mut ev = evidence("raw-pixels");
        let metadata = snapshot();
        let id = store.ingest_original_with_evidence(
            "lib",
            "/a.raw",
            &file("a", true),
            &metadata,
            &ev,
        )?;
        ev.visual_hash = Some("jpeg-pixels".into());
        let before = store.library_revision("lib")?["revision"].as_i64().unwrap();
        assert_eq!(
            id,
            store.ingest_original_with_evidence(
                "lib",
                "/a.jpg",
                &file("b", false),
                &metadata,
                &ev
            )?
        );
        assert_eq!(
            store.default_version("lib", &id)?.unwrap().content_hash,
            "b"
        );
        ev.width = 200;
        ev.visual_hash = Some("larger-pixels".into());
        store.ingest_original_with_evidence("lib", "/a.heic", &file("c", false), &metadata, &ev)?;
        assert_eq!(
            store.default_version("lib", &id)?.unwrap().content_hash,
            "b"
        );
        {
            let db = store.lock()?;
            db.execute("INSERT INTO derivative_objects VALUES(?,?,'preview','{}','previews','old',NULL,10,10,'now')",params!["lib",id])?;
        }
        assert!(!store.asset("lib", &id)?["_preview"].is_null());
        store.set_default_version("lib", &id, "a")?;
        assert!(store.asset("lib", &id)?["_preview"].is_null());
        ev.edited = true;
        ev.visual_hash = Some("edited-pixels".into());
        store.ingest_original_with_evidence("lib", "/a.png", &file("d", false), &metadata, &ev)?;
        assert_eq!(
            store.default_version("lib", &id)?.unwrap().content_hash,
            "a"
        );
        assert_eq!(
            store.versions("lib", &id)?["items"]
                .as_array()
                .unwrap()
                .len(),
            4
        );
        assert!(store.library_revision("lib")?["revision"].as_i64().unwrap() > before);
        assert!(store.set_default_version("lib", &id, "foreign").is_err());
        assert!(!store.declare_generated_preview_for_version("lib", &id, "b", &json!({}))?);
        {
            let db = store.lock()?;
            missing_path(&db, "lib", &id, "/a.raw")?;
        }
        assert_eq!(
            store.default_version("lib", &id)?.unwrap().content_hash,
            "d"
        );
        Ok(())
    }
    #[test]
    fn missing_default_preview_is_repaired_even_when_replacement_is_outside_scope() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let ev = evidence("same");
        let id = store.ingest_original_with_evidence(
            "lib",
            "/a/one.jpg",
            &file("one", false),
            &snapshot(),
            &ev,
        )?;
        // Seed a legacy association; new cross-directory files now stay separate.
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES(?,?,?,?,?)",
            params!["lib", "/b/two.jpg", id, "two", "jpeg_original"],
        )?;
        store.ingest_original_with_evidence(
            "lib",
            "/b/two.jpg",
            &file("two", false),
            &snapshot(),
            &ev,
        )?;
        {
            let db = store.lock()?;
            db.execute("INSERT INTO derivative_objects VALUES(?,?,'preview','{}','previews','old',NULL,10,10,'now')",params!["lib",id])?;
        }
        assert!(store.defaults_needing_previews("lib", "/a")?.is_empty());
        {
            let db = store.lock()?;
            missing_path(&db, "lib", &id, "/a/one.jpg")?;
        }
        assert_eq!(
            store.default_version("lib", &id)?.unwrap().path,
            "/b/two.jpg"
        );
        assert_eq!(store.defaults_needing_previews("lib", "/a")?, vec![id]);
        assert!(
            store
                .defaults_needing_previews("lib", "/unrelated")?
                .is_empty()
        );
        Ok(())
    }
    #[test]
    fn v2_migration_does_not_regroup_or_backfill_legacy_assets() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("db");
        let store = Store::open(&path, true)?;
        let a = store.ingest_original("lib", "/a.jpg", &file("a", false), &snapshot())?;
        let b = store.ingest_original("lib", "/b.jpg", &file("b", false), &snapshot())?;
        assert_ne!(a, b);
        {
            let db = store.lock()?;
            crate::revisions::remove_schema(&db)?;
            crate::edits::remove_schema(&db)?;
            db.execute_batch("DROP TABLE catalog_versions;DROP TABLE catalog_defaults;DROP TABLE catalog_version_paths;DROP TABLE catalog_version_revision;DROP TABLE catalog_identity_roots; DROP TABLE catalog_identity_aliases; PRAGMA user_version=2;")?;
        }
        drop(store);
        assert!(Store::open(&path, false).is_err());
        let store = Store::open(&path, true)?;
        assert_eq!(store.counts("lib", false)?["all"], 2);
        assert_eq!(store.versions("lib", &a)?["items"], json!([]));
        assert_eq!(
            store.ingest_original("lib", "/a.jpg", &file("a", false), &snapshot())?,
            a
        );
        Ok(())
    }
}
