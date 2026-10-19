//! Client-rendered non-destructive edits. Original files are only read here.
use crate::{
    api::{ApiError, AppState},
    store::{Store, StoreError},
};
use anyhow::{Context, Result, ensure};
use axum::response::{IntoResponse, Response};
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    routing::{get, post},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{path::PathBuf, sync::Arc};

fn error(status: u16, message: &str) -> anyhow::Error {
    StoreError {
        status,
        code: if status == 409 {
            "edit_conflict"
        } else {
            "invalid_edit"
        }
        .into(),
        message: message.into(),
    }
    .into()
}
pub(crate) fn migrate(db: &Connection) -> Result<()> {
    db.execute_batch("ALTER TABLE catalog_assets ADD COLUMN negative_hash TEXT;
ALTER TABLE catalog_assets ADD COLUMN edit_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE catalog_assets ADD COLUMN negative_selected INTEGER NOT NULL DEFAULT 0;
ALTER TABLE catalog_assets ADD COLUMN last_edit_request TEXT;
CREATE TABLE photo_edits(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,negative_hash TEXT NOT NULL,exposure_ev REAL,algorithm_version TEXT NOT NULL,renderer_version TEXT NOT NULL,standard TEXT NOT NULL,thumbnail TEXT NOT NULL,browse TEXT NOT NULL,recipe TEXT,PRIMARY KEY(library_id,asset_id));
CREATE TABLE photo_edit_requests(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,request_id TEXT NOT NULL,payload TEXT NOT NULL,response TEXT NOT NULL,PRIMARY KEY(library_id,asset_id,request_id));")?;
    let pairs = db
        .prepare("SELECT library_id,id FROM catalog_assets")?
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (lib, id) in pairs {
        choose(db, &lib, &id)?;
    }
    Ok(())
}
pub(crate) fn migrate_recipe(db: &Connection) -> Result<()> {
    let columns = db
        .prepare("PRAGMA table_info(photo_edits)")?
        .query_map([], |r| Ok((r.get::<_, String>(1)?, r.get::<_, bool>(3)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let has_recipe = columns.iter().any(|(name, _)| name == "recipe");
    let nullable_exposure = columns
        .iter()
        .any(|(name, required)| name == "exposure_ev" && !required);
    if has_recipe && nullable_exposure {
        return Ok(());
    }
    db.execute_batch("ALTER TABLE photo_edits RENAME TO photo_edits_upgrade;
CREATE TABLE photo_edits(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,negative_hash TEXT NOT NULL,exposure_ev REAL,algorithm_version TEXT NOT NULL,renderer_version TEXT NOT NULL,standard TEXT NOT NULL,thumbnail TEXT NOT NULL,browse TEXT NOT NULL,recipe TEXT,PRIMARY KEY(library_id,asset_id));")?;
    let recipe = if has_recipe { "recipe" } else { "NULL" };
    db.execute_batch(&format!("INSERT INTO photo_edits SELECT library_id,asset_id,negative_hash,exposure_ev,algorithm_version,renderer_version,standard,thumbnail,browse,{recipe} FROM photo_edits_upgrade; DROP TABLE photo_edits_upgrade;"))?;
    Ok(())
}
pub(crate) fn choose(db: &Connection, lib: &str, id: &str) -> Result<()> {
    let frozen:bool=db.query_row("SELECT negative_selected<>0 OR edit_revision<>0 FROM catalog_assets WHERE library_id=? AND id=?",params![lib,id],|r|r.get(0))?;
    if frozen {
        return Ok(());
    }
    let mut q=db.prepare("SELECT v.content_hash,p.path,v.width*v.height,v.evidence FROM catalog_versions v JOIN catalog_version_paths p USING(library_id,asset_id,content_hash) WHERE v.library_id=? AND v.asset_id=? AND p.available=1 AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path) ORDER BY v.width*v.height DESC,v.content_hash,p.path")?;
    let rows = q
        .query_map(params![lib, id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, String>(3)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let extension = |p: &str| {
        std::path::Path::new(p)
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
    };
    let arw = rows.iter().find(|r| extension(&r.1) == "arw");
    let raw_3fr = rows.iter().find(|r| extension(&r.1) == "3fr");
    let best = if arw.is_some() {
        arw
    } else if raw_3fr.is_some() {
        rows.iter()
            .find(|r| {
                ["heic", "heif", "hif"].contains(&extension(&r.1).as_str())
                    && serde_json::from_str::<Value>(&r.3)
                        .is_ok_and(|v| v["generatedFrom"].is_null())
            })
            .or(raw_3fr)
    } else {
        rows.iter()
            .find(|r| !crate::media::is_video(std::path::Path::new(&r.1)))
    };
    let changed=db.execute("UPDATE catalog_assets SET negative_hash=?,negative_selected=1 WHERE library_id=? AND id=? AND negative_hash IS NOT ?",params![best.map(|r|&r.0),lib,id,best.map(|r|&r.0)])?;
    if changed > 0 {
        db.execute(
            "INSERT OR IGNORE INTO catalog_revision_dirty(library_id,kind,key) VALUES(?,'asset',?)",
            params![lib, id],
        )?;
    }
    Ok(())
}
fn source(db: &Connection, lib: &str, id: &str, hash: &str) -> Result<PathBuf> {
    let paths=db.prepare("SELECT path FROM catalog_version_paths p WHERE library_id=? AND asset_id=? AND content_hash=? AND available=1 AND NOT EXISTS(SELECT 1 FROM catalog_deprecated_files x WHERE x.library_id=p.library_id AND x.path=p.path) ORDER BY path")?.query_map(params![lib,id,hash],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
    paths
        .into_iter()
        .map(PathBuf::from)
        .find(|p| p.is_file() && !crate::media::is_video(p))
        .ok_or_else(|| error(409, "底片不存在或不可用，请重新选择底片"))
}
type EditStateRow = (Option<String>, i64, Option<String>, Option<f64>);
type MediaSnapshotRow = (
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
);

fn current_version(db: &Connection, lib: &str, id: &str) -> Result<Option<String>> {
    let descriptor: Option<String> = db
        .query_row(
            "SELECT standard FROM photo_edits WHERE library_id=? AND asset_id=?",
            params![lib, id],
            |r| r.get(0),
        )
        .optional()?;
    let descriptor = descriptor
        .map(|v| serde_json::from_str::<Value>(&v))
        .transpose()?;
    Ok(descriptor
        .as_ref()
        .and_then(|v| v["version"].as_str())
        .and_then(|v| v.strip_prefix("edit:"))
        .and_then(|v| v.split(':').next())
        .and_then(crate::identity::normalize))
}

fn state(db: &Connection, lib: &str, id: &str) -> Result<Value> {
    let root: String = db
        .query_row(
            "SELECT root_id FROM catalog_identity_roots WHERE library_id=? AND asset_id=?",
            params![lib, id],
            |r| r.get(0),
        )
        .optional()?
        .unwrap_or_else(|| id.to_owned());
    let version = current_version(db, lib, id)?;
    let row:Option<EditStateRow>=db.query_row("SELECT a.negative_hash,a.edit_revision,a.last_edit_request,e.exposure_ev FROM catalog_assets a LEFT JOIN photo_edits e ON e.library_id=a.library_id AND e.asset_id=a.id WHERE a.library_id=? AND a.id=?",params![lib,id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
    let (hash, revision, last, ev) = row.ok_or_else(|| error(404, "照片不存在"))?;
    let recipe: Option<String> = db
        .query_row(
            "SELECT recipe FROM photo_edits WHERE library_id=? AND asset_id=?",
            params![lib, id],
            |r| r.get(0),
        )
        .optional()?
        .flatten();
    let recipe = recipe
        .map(|r| serde_json::from_str::<Value>(&r))
        .transpose()?;
    let decision: Option<String> = db
        .query_row(
            "SELECT metadata FROM photo_edit_decisions WHERE library_id=? AND asset_id=?",
            params![lib, id],
            |r| r.get(0),
        )
        .optional()?;
    let path = match hash.as_deref().map(|h| source(db, lib, id, h)).transpose() {
        Ok(path) => path,
        Err(e)
            if e.downcast_ref::<StoreError>()
                .is_some_and(|e| e.status == 409) =>
        {
            None
        }
        Err(e) => return Err(e),
    };
    let mut value = json!({"rootID":root,"currentVersionID":version,"decisionMetadata":decision,"negativeContentHash":hash,"revision":revision,"lastRequestID":last,"hasEdit":ev.is_some() || recipe.is_some(),"recipe":recipe,"exposureEV":ev,"sourceAvailable":path.is_some(),"sourceFilename":path.as_ref().and_then(|p|p.file_name()).and_then(|v|v.to_str()),"sourceSizeBytes":path.as_ref().map(std::fs::metadata).transpose()?.map(|m|m.len()),"sourceFileHash":hash});
    if let Some(version) = version {
        let receipt: Option<String> = db.query_row("SELECT response FROM photo_edit_requests WHERE library_id=? AND asset_id=? AND request_id=?", params![lib,id,version], |r| r.get(0)).optional()?;
        if let Some(receipt) = receipt {
            let receipt: Value = serde_json::from_str(&receipt)?;
            for key in [
                "versionID",
                "previousVersionID",
                "sourceContentHash",
                "sourceVersionID",
                "createdAt",
            ] {
                if let Some(field) = receipt.get(key) {
                    value[key] = field.clone();
                }
            }
        }
    }
    Ok(value)
}
impl Store {
    pub fn initialize_negative(&self, lib: &str, id: &str) -> Result<()> {
        let mut db = self.lock()?;
        let tx = db.transaction()?;
        choose(&tx, lib, id)?;
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(())
    }
    pub fn edit_state(&self, lib: &str, id: &str) -> Result<Value> {
        let mut connection = self.read()?;
        let db = connection.transaction()?;
        state(&db, lib, id)
    }
    pub fn media_snapshot(&self, lib: &str, id: &str) -> Result<Value> {
        let db = self.read()?;
        let row:Option<MediaSnapshotRow>=db.query_row("SELECT coalesce(e.thumbnail,c.thumbnail),coalesce(e.standard,c.standard),coalesce(e.browse,CASE WHEN c.browse_source_version=json_extract(c.thumbnail,'$.version') AND c.browse_spec=?4 AND json_extract(c.browse_thumbnail,'$.sourceThumbnailVersion')=c.browse_source_version AND json_extract(c.browse_thumbnail,'$.spec')=c.browse_spec THEN c.browse_thumbnail END),a.negative_hash FROM catalog_assets a LEFT JOIN photo_edits e ON e.library_id=a.library_id AND e.asset_id=a.id LEFT JOIN catalog_defaults d ON d.library_id=a.library_id AND d.asset_id=a.id LEFT JOIN media_cache c ON c.library_id=a.library_id AND c.asset_id=a.id AND c.published_source_hash=coalesce(d.content_hash,a.content_hash) AND c.published_spec=?3 WHERE a.library_id=?1 AND a.id=?2",params![lib,id,crate::cache_pipeline::spec()?,crate::browse_cache::SPEC],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
        let Some((thumb, standard, browse, negative)) = row else {
            return Ok(Value::Null);
        };
        let parse = |s: Option<String>| -> Result<Value> {
            Ok(s.map(|s| serde_json::from_str(&s))
                .transpose()?
                .unwrap_or(Value::Null))
        };
        Ok(
            json!({"thumbnail":parse(thumb)?,"standard":parse(standard)?,"browse":parse(browse)?,"negativeContentHash":negative}),
        )
    }
    pub fn edited_descriptor(&self, lib: &str, id: &str, role: &str) -> Result<Option<Value>> {
        ensure!(
            ["standard", "thumbnail", "browse"].contains(&role),
            "invalid edit role"
        );
        let value: Option<String> = self
            .lock()?
            .query_row(
                &format!("SELECT {role} FROM photo_edits WHERE library_id=? AND asset_id=?"),
                params![lib, id],
                |r| r.get(0),
            )
            .optional()?;
        value
            .map(|s| serde_json::from_str(&s).map_err(Into::into))
            .transpose()
    }
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UploadRequest {
    #[serde(rename = "requestID")]
    request_id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SourceQuery {
    content_hash: String,
}
fn object(lib: &str, id: &str, request: &str, role: &str) -> Value {
    json!({"bucket":"keeps-previews","key":format!("libraries/{lib}/assets/{id}/derivatives/{role}/edit-{request}.heic")})
}
fn validate_request(v: &Value) -> Result<(&str, i64)> {
    let request = v["requestID"].as_str().context("requestID required")?;
    uuid::Uuid::parse_str(request).map_err(|_| error(422, "requestID must be UUID"))?;
    let revision = v["expectedRevision"]
        .as_i64()
        .filter(|r| *r >= 0)
        .ok_or_else(|| error(422, "expectedRevision required"))?;
    Ok((request, revision))
}
fn validate_outputs(
    s: &AppState,
    lib: &str,
    id: &str,
    request: &str,
    v: &Value,
) -> Result<Vec<Value>> {
    let outputs = v["outputs"]
        .as_array()
        .filter(|a| a.len() == 3)
        .ok_or_else(|| error(422, "three rendered outputs required"))?;
    let mut descriptors = Vec::new();
    for role in ["standard", "thumbnail", "browse"] {
        let out = outputs
            .iter()
            .find(|o| o["role"] == role)
            .ok_or_else(|| error(422, "missing output role"))?;
        let expected = object(lib, id, request, role);
        if out["objectRef"] != expected {
            return Err(error(422, "output does not belong to this edit"));
        }
        let path = s.previews.object_path(&expected)?;
        if std::fs::metadata(&path)?.len() != out["sizeBytes"].as_u64().unwrap_or(0)
            || crate::media::sha256_file(&path)? != out["contentHash"].as_str().unwrap_or("")
        {
            return Err(error(422, "output checksum or size mismatch"));
        }
        let m = crate::media::MediaProcessor::new().extract(&path)?;
        let limit = match role {
            "thumbnail" => 512,
            "browse" => 64,
            _ => 65536,
        };
        if m.width < 1
            || m.height < 1
            || m.width > limit
            || m.height > limit
            || out["width"] != m.width
            || out["height"] != m.height
        {
            return Err(error(422, "invalid output image dimensions"));
        }
        descriptors.push(json!({"objectRef":expected,"width":m.width,"height":m.height,"version":format!("edit:{request}:{}",out["contentHash"].as_str().unwrap_or("")),"sizeBytes":out["sizeBytes"]}));
    }
    Ok(descriptors)
}
fn validate_recipe(value: &Value) -> Result<Option<String>> {
    if value.is_null() {
        return Ok(None);
    }
    if value["engine"] != "darktable" || value["engineVersion"] != "5.6.2" {
        return Err(error(422, "unsupported recipe engine or version"));
    }
    let json = value["recipeJSON"]
        .as_str()
        .filter(|s| s.len() <= 12 * 1024 * 1024)
        .ok_or_else(|| error(422, "recipeJSON required (maximum 12 MiB)"))?;
    if !serde_json::from_str::<Value>(json).is_ok_and(|v| v.is_object()) {
        return Err(error(422, "recipeJSON must encode an object"));
    }
    let xmp = value["xmp"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 1024 * 1024)
        .ok_or_else(|| error(422, "xmp required (maximum 1 MiB)"))?;
    if !xmp.contains("darktable:xmp_version") {
        return Err(error(422, "darktable XMP required"));
    }
    if !value["metadata"].is_null() {
        let metadata = value["metadata"]
            .as_str()
            .filter(|s| s.len() <= 256 * 1024)
            .ok_or_else(|| error(422, "metadata must be JSON text (maximum 256 KiB)"))?;
        if !serde_json::from_str::<Value>(metadata).is_ok_and(|v| v.is_object()) {
            return Err(error(422, "metadata must encode an object"));
        }
    }
    Ok(Some(value.to_string()))
}

fn mutate(s: &AppState, lib: &str, id: &str, v: Value, action: &str) -> Result<Value> {
    let _directory_guard = s.jobs.directory_mutation.read().unwrap();
    let (request, revision) = validate_request(&v)?;
    let payload = json!({"action":action,"body":v}).to_string();
    {
        let db = s.store.lock()?;
        let receipt:Option<(String,String)>=db.query_row("SELECT payload,response FROM photo_edit_requests WHERE library_id=? AND asset_id=? AND request_id=?",params![lib,id,request],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
        if let Some((old, response)) = receipt {
            if old != payload {
                return Err(error(409, "requestID 已用于不同操作"));
            }
            drop(db);
            s.store.collect_asset_cache_garbage(&s.previews, lib, id)?;
            return Ok(serde_json::from_str(&response)?);
        }
        if state(&db, lib, id)?["revision"] != revision {
            return Err(error(409, "照片调整已变化，请刷新后重试"));
        }
    }
    let source_stamp = if action == "commit" {
        let hash = v["negativeContentHash"]
            .as_str()
            .ok_or_else(|| error(422, "negativeContentHash required"))?;
        let path = source(&*s.store.lock()?, lib, id, hash)?;
        s.jobs
            .validate_path(path.parent().context("source parent")?)?;
        let before = crate::cache_pipeline::file_mtime(&path)?;
        if crate::media::sha256_file(&path)? != hash
            || crate::cache_pipeline::file_mtime(&path)? != before
        {
            return Err(error(409, "底片内容已变化，等待索引更新后重试"));
        }
        Some((path, before))
    } else {
        None
    };
    let descriptors = if action == "commit" {
        validate_outputs(s, lib, id, request, &v)?
    } else {
        Vec::new()
    };
    let mut db = s.store.lock()?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let old:Option<(String,String)>=tx.query_row("SELECT payload,response FROM photo_edit_requests WHERE library_id=? AND asset_id=? AND request_id=?",params![lib,id,request],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    if let Some((old, response)) = old {
        if old != payload {
            return Err(error(409, "requestID 已用于不同操作"));
        }
        return Ok(serde_json::from_str(&response)?);
    }
    let current = state(&tx, lib, id)?;
    if current["revision"] != revision {
        return Err(error(409, "照片调整已变化，请刷新后重试"));
    }
    let previous: Option<(String, String, String)> = tx
        .query_row(
            "SELECT standard,thumbnail,browse FROM photo_edits WHERE library_id=? AND asset_id=?",
            params![lib, id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    if action == "negative" {
        if current["hasEdit"] == true {
            return Err(error(409, "更换已调整照片的底片需要重新渲染"));
        }
        let hash = v["contentHash"].as_str().context("contentHash required")?;
        source(&tx, lib, id, hash)?;
        tx.execute(
            "UPDATE catalog_assets SET negative_hash=? WHERE library_id=? AND id=?",
            params![hash, lib, id],
        )?;
    } else if action == "reset" {
        tx.execute(
            "DELETE FROM photo_edits WHERE library_id=? AND asset_id=?",
            params![lib, id],
        )?;
    } else {
        let hash = v["negativeContentHash"]
            .as_str()
            .context("negativeContentHash required")?;
        let path = source(&tx, lib, id, hash)?;
        if source_stamp.as_ref() != Some(&(path.clone(), crate::cache_pipeline::file_mtime(&path)?))
        {
            return Err(error(409, "底片内容已变化"));
        }
        s.jobs
            .validate_path(path.parent().context("source parent")?)?;
        let recipe = validate_recipe(&v["recipe"])?;
        let ev = if recipe.is_some() {
            if !v["exposureEV"].is_null() {
                return Err(error(422, "recipe and exposureEV are mutually exclusive"));
            }
            None
        } else {
            Some(
                v["exposureEV"]
                    .as_f64()
                    .filter(|e| e.is_finite() && (-2.0..=2.0).contains(e))
                    .ok_or_else(|| error(422, "exposureEV outside -2...2"))?,
            )
        };
        let algorithm = v["algorithmVersion"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() < 128)
            .context("algorithmVersion required")?;
        let renderer = v["rendererVersion"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() < 128)
            .context("rendererVersion required")?;
        tx.execute("INSERT INTO photo_edits VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(library_id,asset_id) DO UPDATE SET negative_hash=excluded.negative_hash,exposure_ev=excluded.exposure_ev,algorithm_version=excluded.algorithm_version,renderer_version=excluded.renderer_version,standard=excluded.standard,thumbnail=excluded.thumbnail,browse=excluded.browse,recipe=excluded.recipe",params![lib,id,hash,ev,algorithm,renderer,descriptors[0].to_string(),descriptors[1].to_string(),descriptors[2].to_string(),recipe])?;
        tx.execute(
            "UPDATE catalog_assets SET negative_hash=? WHERE library_id=? AND id=?",
            params![hash, lib, id],
        )?;
    }
    let previous_is_version: bool = match current["currentVersionID"].as_str() {
        Some(version) => tx.query_row("SELECT EXISTS(SELECT 1 FROM photo_edit_requests WHERE library_id=? AND asset_id=? AND request_id=? AND json_extract(payload,'$.action')='commit')",params![lib,id,version],|r|r.get(0))?,
        None => false,
    };
    if let Some((a, b, c)) = previous.filter(|_| !previous_is_version) {
        for old in [a, b, c] {
            let old: Value = serde_json::from_str(&old)?;
            crate::cache_gc::enqueue(
                &tx,
                lib,
                id,
                &old["objectRef"],
                &Value::Null,
                chrono::Utc::now().timestamp(),
            )?;
        }
    }
    tx.execute("UPDATE catalog_assets SET edit_revision=edit_revision+1,negative_selected=1,last_edit_request=?,snapshot=json_set(snapshot,'$.updatedAt',?) WHERE library_id=? AND id=?",params![request,chrono::Utc::now().to_rfc3339(),lib,id])?;
    tx.execute(
        "DELETE FROM photo_edit_decisions WHERE library_id=? AND asset_id=?",
        params![lib, id],
    )?;
    let mut response = state(&tx, lib, id)?;
    if action == "commit" {
        response["versionID"] = json!(request);
        response["previousVersionID"] = current["currentVersionID"].clone();
        response["sourceContentHash"] = v["negativeContentHash"].clone();
        let source_version: Option<String> = tx.query_row("SELECT json_extract(evidence,'$.versionID') FROM catalog_versions WHERE library_id=? AND asset_id=? AND content_hash=?",params![lib,id,v["negativeContentHash"].as_str()],|r|r.get(0)).optional()?.flatten();
        response["sourceVersionID"] = json!(source_version);
        response["createdAt"] = json!(chrono::Utc::now().to_rfc3339());
    }
    tx.execute(
        "INSERT INTO photo_edit_requests VALUES(?,?,?,?,?)",
        params![lib, id, request, payload, response.to_string()],
    )?;
    crate::revisions::flush(&tx)?;
    tx.commit()?;
    drop(db);
    s.store.collect_asset_cache_garbage(&s.previews, lib, id)?;
    Ok(response)
}
fn confirm_original(s: &AppState, lib: &str, id: &str, v: Value) -> Result<Value> {
    let (request, revision) = validate_request(&v)?;
    let metadata = v["metadata"]
        .as_str()
        .filter(|s| s.len() <= 256 * 1024)
        .ok_or_else(|| error(422, "metadata required (maximum 256 KiB)"))?;
    if !serde_json::from_str::<Value>(metadata).is_ok_and(|v| v.is_object()) {
        return Err(error(422, "metadata must encode an object"));
    }
    let payload = json!({"action":"confirm-original","body":v}).to_string();
    let mut db = s.store.lock()?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let receipt: Option<(String,String)> = tx.query_row("SELECT payload,response FROM photo_edit_requests WHERE library_id=? AND asset_id=? AND request_id=?",params![lib,id,request],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    if let Some((old, response)) = receipt {
        if old != payload {
            return Err(error(409, "requestID 已用于不同操作"));
        }
        return Ok(serde_json::from_str(&response)?);
    }
    if state(&tx, lib, id)?["revision"] != revision {
        return Err(error(409, "照片调整已变化，请刷新后重试"));
    }
    tx.execute("INSERT INTO photo_edit_decisions(library_id,asset_id,metadata) VALUES(?,?,?) ON CONFLICT(library_id,asset_id) DO UPDATE SET metadata=excluded.metadata",params![lib,id,metadata])?;
    let result = state(&tx, lib, id)?;
    tx.execute("INSERT INTO photo_edit_requests(library_id,asset_id,request_id,payload,response) VALUES(?,?,?,?,?)",params![lib,id,request,payload,result.to_string()])?;
    tx.commit()?;
    Ok(result)
}
async fn decision(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    Json(v): Json<Value>,
) -> Result<Response, ApiError> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|_| error(422, "invalid asset UUID"))?
        .to_string();
    run(move || confirm_original(&s, &lib, &id, v)).await
}
pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route(
            "/libraries/{library}/assets/{asset}/edit/versions",
            get(get_versions),
        )
        .route(
            "/libraries/{library}/assets/{asset}/edit/decisions",
            post(decision).layer(axum::extract::DefaultBodyLimit::max(2 * 1024 * 1024)),
        )
        .route(
            "/libraries/{library}/assets/{asset}/edit",
            get(get_edit)
                .put(commit)
                .delete(reset)
                .layer(axum::extract::DefaultBodyLimit::max(32 * 1024 * 1024)),
        )
        .route(
            "/libraries/{library}/assets/{asset}/negative-version",
            axum::routing::put(negative),
        )
        .route(
            "/libraries/{library}/assets/{asset}/edit/source",
            get(download),
        )
        .route(
            "/libraries/{library}/assets/{asset}/edit/uploads",
            post(uploads),
        )
}
async fn run<F: FnOnce() -> Result<Value> + Send + 'static>(f: F) -> Result<Response, ApiError> {
    Ok(Json(
        tokio::task::spawn_blocking(f)
            .await
            .map_err(anyhow::Error::from)??,
    )
    .into_response())
}
async fn get_edit(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
) -> Result<Response, ApiError> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|_| error(422, "invalid asset UUID"))?
        .to_string();
    run(move || s.store.edit_state(&lib, &id)).await
}
fn edit_versions(s: &AppState, lib: &str, id: &str) -> Result<Value> {
    let rows = {
        let db = s.store.read()?;
        state(&db, lib, id)?;
        db.prepare("SELECT request_id,payload,response FROM photo_edit_requests WHERE library_id=? AND asset_id=? AND json_extract(payload,'$.action')='commit' ORDER BY json_extract(response,'$.revision') DESC")?.query_map(params![lib,id], |r| Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?)))?.collect::<rusqlite::Result<Vec<_>>>()?
    };
    let mut items = Vec::new();
    for (version, payload, response) in rows {
        let payload: Value = serde_json::from_str(&payload)?;
        let response: Value = serde_json::from_str(&response)?;
        let body = &payload["body"];
        let mut item = json!({"versionID":version,"previousVersionID":response["previousVersionID"],"sourceContentHash":body["negativeContentHash"],"sourceVersionID":response["sourceVersionID"],"createdAt":response["createdAt"],"recipe":body["recipe"],"exposureEV":body["exposureEV"],"available":true});
        for role in ["standard", "thumbnail", "browse"] {
            let output = body["outputs"]
                .as_array()
                .and_then(|outputs| outputs.iter().find(|v| v["role"] == role));
            let available = match output {
                Some(out) => s.previews.contains(&out["objectRef"])?,
                None => false,
            };
            if !available {
                item["available"] = json!(false);
            }
            item[role] = match output {
                Some(out) => {
                    json!({"available":available,"downloadURL":if available {Some(s.previews.download_url(&out["objectRef"])?)} else {None},"width":out["width"],"height":out["height"],"version":format!("edit:{version}:{}",out["contentHash"].as_str().unwrap_or(""))})
                }
                None => Value::Null,
            };
        }
        items.push(item);
    }
    Ok(json!({"items":items}))
}
async fn get_versions(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
) -> Result<Response, ApiError> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|_| error(422, "invalid asset UUID"))?
        .to_string();
    run(move || edit_versions(&s, &lib, &id)).await
}

async fn negative(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    Json(v): Json<Value>,
) -> Result<Response, ApiError> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|_| error(422, "invalid asset UUID"))?
        .to_string();
    run(move || mutate(&s, &lib, &id, v, "negative")).await
}
async fn commit(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    Json(v): Json<Value>,
) -> Result<Response, ApiError> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|_| error(422, "invalid asset UUID"))?
        .to_string();
    run(move || mutate(&s, &lib, &id, v, "commit")).await
}
async fn reset(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    Json(v): Json<Value>,
) -> Result<Response, ApiError> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|_| error(422, "invalid asset UUID"))?
        .to_string();
    run(move || mutate(&s, &lib, &id, v, "reset")).await
}
async fn uploads(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    Json(v): Json<UploadRequest>,
) -> Result<Response, ApiError> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|_| error(422, "invalid asset UUID"))?
        .to_string();
    run(move||{
    uuid::Uuid::parse_str(&v.request_id).map_err(|_|error(422,"requestID must be UUID"))?;
    s.store.edit_state(&lib,&id)?;
    let objects=["standard","thumbnail","browse"].into_iter().map(|role|{let object=object(&lib,&id,&v.request_id,role);Ok(json!({"role":role,"objectRef":object,"uploadURL":s.previews.signed_url(&object,"upload")?}))}).collect::<Result<Vec<_>>>()?;
    Ok(json!({"requestID":v.request_id,"objects":objects}))}).await
}
async fn download(
    State(s): State<Arc<AppState>>,
    Path((lib, id)): Path<(String, String)>,
    Query(q): Query<SourceQuery>,
) -> Result<Response, ApiError> {
    let id = uuid::Uuid::parse_str(&id)
        .map_err(|_| error(422, "invalid asset UUID"))?
        .to_string();
    let p = tokio::task::spawn_blocking(move || -> Result<_> {
        let p = source(&*s.store.lock()?, &lib, &id, &q.content_hash)?;
        if !std::fs::symlink_metadata(&p)?.file_type().is_file() {
            return Err(error(409, "底片不是常规文件，请重新扫描"));
        }
        s.jobs.validate_path(p.parent().context("source parent")?)?;
        Ok(p)
    })
    .await
    .map_err(anyhow::Error::from)??;
    let f = tokio::fs::File::open(p)
        .await
        .map_err(anyhow::Error::from)?;
    let size = f.metadata().await.map_err(anyhow::Error::from)?.len();
    Ok((
        [
            ("content-type", "application/octet-stream".to_string()),
            ("content-length", size.to_string()),
        ],
        axum::body::Body::from_stream(tokio_util::io::ReaderStream::new(f)),
    )
        .into_response())
}

pub(crate) async fn upload(
    State(s): State<Arc<AppState>>,
    Path(token): Path<String>,
    request: axum::extract::Request,
) -> Result<Response, ApiError> {
    use http_body_util::BodyExt;
    use tokio::io::AsyncWriteExt;
    let object = s.previews.verify(&token, "upload")?;
    let key = object["key"].as_str().context("upload key")?;
    let parts = key.split('/').collect::<Vec<_>>();
    if parts.len() != 7
        || parts[0] != "libraries"
        || parts[1] != s.library_id
        || parts[2] != "assets"
        || parts[4] != "derivatives"
        || !["standard", "thumbnail", "browse"].contains(&parts[5])
        || !parts[6].starts_with("edit-")
    {
        return Err(error(422, "invalid edit upload token").into());
    }
    let destination = s.previews.object_path(&object)?;
    let parent = destination.parent().context("upload parent")?;
    std::fs::create_dir_all(parent).map_err(anyhow::Error::from)?;
    let temporary = tempfile::NamedTempFile::new_in(parent).map_err(anyhow::Error::from)?;
    let mut output = tokio::fs::File::from_std(temporary.reopen().map_err(anyhow::Error::from)?);
    let mut body = request.into_body();
    let mut size = 0usize;
    while let Some(frame) = body.frame().await {
        let frame = frame.map_err(anyhow::Error::from)?;
        if let Ok(bytes) = frame.into_data() {
            size += bytes.len();
            if size > 256 * 1024 * 1024 {
                return Err(error(413, "rendered output exceeds 256 MiB").into());
            }
            output
                .write_all(&bytes)
                .await
                .map_err(anyhow::Error::from)?;
        }
    }
    output.sync_all().await.map_err(anyhow::Error::from)?;
    drop(output);
    tokio::task::spawn_blocking(move || -> Result<()> {
        match temporary.persist_noclobber(&destination) {
            Ok(_) => Ok::<(), anyhow::Error>(()),
            Err(e) if e.error.kind() == std::io::ErrorKind::AlreadyExists => {
                if crate::media::sha256_file(e.file.path())?
                    != crate::media::sha256_file(&destination)?
                {
                    return Err(error(409, "uploaded edit object is immutable"));
                }
                Ok(())
            }
            Err(e) => Err(e.into()),
        }?;
        Ok(())
    })
    .await
    .map_err(anyhow::Error::from)??;
    Ok(axum::http::StatusCode::NO_CONTENT.into_response())
}

#[cfg(test)]
pub(crate) fn remove_schema(db: &Connection) -> Result<()> {
    db.execute_batch("DROP TRIGGER IF EXISTS catalog_sync_asset_negative;")?;
    db.execute_batch(
        "DROP TABLE photo_edit_requests; DROP TABLE photo_edits;
ALTER TABLE catalog_assets DROP COLUMN negative_hash;
ALTER TABLE catalog_assets DROP COLUMN edit_revision;
ALTER TABLE catalog_assets DROP COLUMN negative_selected;
ALTER TABLE catalog_assets DROP COLUMN last_edit_request;",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use http_body_util::BodyExt;
    use tower::ServiceExt;
    #[test]
    fn darktable_recipe_roundtrips_and_rejects_invalid_payloads() -> Result<()> {
        let (_dir, s, id) = setup()?;
        let recipe = json!({"engine":"darktable","engineVersion":"5.6.2","recipeJSON":"{\"exposureEV\":0.5}","xmp":"<rdf:Description darktable:xmp_version=\"5\"/>","metadata":"{\"opinion\":\"保留暖光\"}"});
        let stored = validate_recipe(&recipe)?.unwrap();
        s.store.lock()?.execute("INSERT INTO photo_edits VALUES('lib',?,'hash',NULL,'ai-v1','darktable-5.6.2','{}','{}','{}',?)", params![id,stored])?;
        let state = s.store.edit_state("lib", &id)?;
        assert_eq!(state["hasEdit"], true);
        assert_eq!(state["recipe"], recipe);
        assert!(state["exposureEV"].is_null());
        let mut invalid = recipe.clone();
        invalid["engineVersion"] = json!("6.0");
        assert!(validate_recipe(&invalid).is_err());
        invalid = recipe.clone();
        invalid["recipeJSON"] = json!("[]");
        assert!(validate_recipe(&invalid).is_err());
        invalid = recipe.clone();
        invalid["metadata"] = json!("[]");
        assert!(validate_recipe(&invalid).is_err());
        invalid = recipe;
        invalid["xmp"] = json!("");
        assert!(validate_recipe(&invalid).is_err());
        Ok(())
    }
    #[test]
    fn recipe_accepts_embedded_masks_with_a_bounded_total_size() -> Result<()> {
        let mut recipe = json!({"engine":"darktable","engineVersion":"5.6.2",
            "recipeJSON":json!({"mask":"A".repeat(2*1024*1024)}).to_string(),
            "xmp":"<rdf:Description darktable:xmp_version=\"5\"/>"});
        assert!(validate_recipe(&recipe)?.is_some());
        recipe["recipeJSON"] = json!(json!({"mask":"A".repeat(12*1024*1024)}).to_string());
        assert!(validate_recipe(&recipe).is_err());
        Ok(())
    }
    #[tokio::test]
    async fn edit_route_accepts_embedded_mask_payload_above_two_mib() -> Result<()> {
        let (_dir, state, id) = setup()?;
        let before = state.store.edit_state("lib", &id)?;
        let body = json!({"requestID":uuid::Uuid::new_v4().to_string(),"expectedRevision":before["revision"],"recipe":{"recipeJSON":json!({"mask":"A".repeat(3*1024*1024)}).to_string()}});
        let response = crate::api::router(state)
            .oneshot(
                axum::http::Request::builder()
                    .method("PUT")
                    .uri(format!("/libraries/lib/assets/{id}/edit"))
                    .header("authorization", "Bearer test")
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(body.to_string()))?,
            )
            .await?;
        assert_eq!(
            response.status(),
            axum::http::StatusCode::UNPROCESSABLE_ENTITY
        );
        Ok(())
    }
    #[tokio::test]
    async fn original_confirmation_route_accepts_opinion_history_above_global_limit() -> Result<()>
    {
        let (_dir, s, id) = setup()?;
        let before = s.store.edit_state("lib", &id)?;
        let metadata = json!({"opinion":"x".repeat(128*1024)}).to_string();
        let body=json!({"requestID":uuid::Uuid::new_v4().to_string(),"expectedRevision":before["revision"],"metadata":metadata}).to_string();
        let response = crate::api::router(s.clone())
            .oneshot(
                axum::http::Request::builder()
                    .method("POST")
                    .uri(format!("/libraries/lib/assets/{id}/edit/decisions"))
                    .header("authorization", "Bearer test")
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(body))?,
            )
            .await?;
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        assert_eq!(
            s.store.edit_state("lib", &id)?["decisionMetadata"],
            metadata
        );
        Ok(())
    }
    #[test]
    fn original_confirmation_persists_opinion_without_changing_published_edit() -> Result<()> {
        let (_dir, s, id) = setup()?;
        let before = s.store.edit_state("lib", &id)?;
        let revision = s.store.library_revision("lib")?;
        let input = json!({"requestID":uuid::Uuid::new_v4().to_string(),"expectedRevision":before["revision"],"metadata":"{\"opinion\":\"保留原图\"}"});
        let result = confirm_original(&s, "lib", &id, input.clone())?;
        assert_eq!(result["decisionMetadata"], input["metadata"]);
        assert_eq!(result["recipe"], before["recipe"]);
        assert_eq!(result["revision"], before["revision"]);
        assert_eq!(s.store.library_revision("lib")?, revision);
        assert_eq!(confirm_original(&s, "lib", &id, input.clone())?, result);
        assert_eq!(s.store.edit_state("lib", &id)?, result);
        let mut conflict = input.clone();
        conflict["metadata"] = json!("{}");
        assert!(confirm_original(&s, "lib", &id, conflict).is_err());
        let mut stale = input;
        stale["requestID"] = json!(uuid::Uuid::new_v4().to_string());
        stale["expectedRevision"] = json!(99);
        assert!(confirm_original(&s, "lib", &id, stale).is_err());
        let reset = mutate(
            &s,
            "lib",
            &id,
            json!({"requestID":uuid::Uuid::new_v4().to_string(),"expectedRevision":before["revision"]}),
            "reset",
        )?;
        assert!(reset["decisionMetadata"].is_null());

        Ok(())
    }
    fn setup() -> Result<(tempfile::TempDir, Arc<AppState>, String)> {
        let dir = tempfile::tempdir()?;
        let root = dir.path().canonicalize()?;
        let photos = root.join("photos");
        std::fs::create_dir(&photos)?;
        let path = photos.join("photo.jpg");
        std::fs::write(&path, b"unchanged original")?;
        let hash = crate::media::sha256_file(&path)?;
        let store = Store::open(&root.join("catalog.sqlite"), true)?;
        let id=store.ingest_original("lib",path.to_str().unwrap(),&json!({"contentHash":hash,"sizeBytes":18,"role":"jpeg_original"}),&json!({"contentFingerprint":hash,"metadataFingerprint":"meta","originalFilename":"photo.jpg","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","rating":0,"tags":[],"flagState":"unflagged"}))?;
        let jobs = crate::jobs::Jobs::open(&root.join("jobs.sqlite"), &photos)?;
        jobs.add_folder("lib", photos.to_str().unwrap())?;
        let s = Arc::new(AppState {
            store: Arc::new(store),
            jobs: Arc::new(jobs),
            previews: Arc::new(crate::previews::PreviewStorage::new(
                &root.join("keeps"),
                Some(&photos),
                "http://localhost",
                "test",
            )?),
            access_token: "test".into(),
            library_id: "lib".into(),
            original_root_names: Default::default(),
        });
        Ok((dir, s, id))
    }
    fn add_version(
        s: &AppState,
        id: &str,
        name: &str,
        pixels: i64,
        generated: bool,
    ) -> Result<String> {
        let path = s.jobs.root().join(name);
        std::fs::write(&path, name)?;
        let hash = crate::media::sha256_file(&path)?;
        let db = s.store.lock()?;
        db.execute(
            "INSERT INTO catalog_versions VALUES('lib',?,?,NULL,NULL,?,1,1,?)",
            params![
                id,
                hash,
                pixels,
                if generated {
                    json!({"generatedFrom":"raw"})
                } else {
                    json!({})
                }
                .to_string()
            ],
        )?;
        db.execute(
            "INSERT INTO catalog_version_paths VALUES('lib',?,?,?,1)",
            params![path.to_str(), id, hash],
        )?;
        Ok(hash)
    }
    fn edited(s: &AppState, id: &str) -> Result<Vec<Value>> {
        let request = uuid::Uuid::new_v4().to_string();
        let mut descriptors = Vec::new();
        for role in ["standard", "thumbnail", "browse"] {
            let object = object("lib", id, &request, role);
            let path = s.previews.object_path(&object)?;
            std::fs::create_dir_all(path.parent().unwrap())?;
            std::fs::write(path, role)?;
            descriptors.push(json!({"objectRef":object,"version":request,"width":64,"height":64}));
        }
        let hash = s.store.edit_state("lib", id)?["negativeContentHash"]
            .as_str()
            .unwrap()
            .to_owned();
        s.store.lock()?.execute(
            "INSERT INTO photo_edits VALUES('lib',?,?,1,'test','test',?,?,?,NULL)",
            params![
                id,
                hash,
                descriptors[0].to_string(),
                descriptors[1].to_string(),
                descriptors[2].to_string()
            ],
        )?;
        Ok(descriptors)
    }
    #[test]
    fn negative_selection_waits_for_group_and_then_stays_fixed() -> Result<()> {
        let (_dir, s, id) = setup()?;
        let raw = add_version(&s, &id, "photo.ARW", 100, false)?;
        add_version(&s, &id, "photo-large.jpg", 1000, false)?;
        s.store.initialize_negative("lib", &id)?;
        assert_eq!(s.store.edit_state("lib", &id)?["negativeContentHash"], raw);
        let before = s.store.library_revision("lib")?;
        add_version(&s, &id, "photo-new.ARW", 2000, false)?;
        s.store.initialize_negative("lib", &id)?;
        assert_eq!(s.store.edit_state("lib", &id)?["negativeContentHash"], raw);
        assert!(
            s.store.versions("lib", &id)?["items"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v["contentHash"] == raw && v["isNegative"] == true)
        );
        let after = s.store.library_revision("lib")?;
        s.store.initialize_negative("lib", &id)?;
        assert_eq!(s.store.library_revision("lib")?, after);
        assert!(after["revision"].as_i64() >= before["revision"].as_i64());
        Ok(())
    }
    #[test]
    fn hasselblad_prefers_non_generated_heif() -> Result<()> {
        let (_dir, s, id) = setup()?;
        add_version(&s, &id, "photo.3FR", 1000, false)?;
        add_version(&s, &id, "photo-generated.heic", 2000, true)?;
        let heif = add_version(&s, &id, "photo.HIF", 200, false)?;
        s.store.initialize_negative("lib", &id)?;
        assert_eq!(s.store.edit_state("lib", &id)?["negativeContentHash"], heif);
        Ok(())
    }
    #[test]
    fn hasselblad_unbound_negative_uses_raw_without_available_external_heif() -> Result<()> {
        let (_dir, s, id) = setup()?;
        let raw = add_version(&s, &id, "photo.3FR", 100, false)?;
        add_version(&s, &id, "photo-generated.heic", 1000, true)?;
        let missing = add_version(&s, &id, "photo-missing.HIF", 200, false)?;
        s.store.lock()?.execute(
            "UPDATE catalog_version_paths SET available=0 WHERE content_hash=?",
            params![missing],
        )?;
        // Old selection left RAW-only Hasselblad groups unbound; normal indexing repairs them.
        assert!(s.store.edit_state("lib", &id)?["negativeContentHash"].is_null());
        s.store.initialize_negative("lib", &id)?;
        assert_eq!(s.store.edit_state("lib", &id)?["negativeContentHash"], raw);
        add_version(&s, &id, "photo-new.HIF", 200, false)?;
        s.store.initialize_negative("lib", &id)?;
        assert_eq!(s.store.edit_state("lib", &id)?["negativeContentHash"], raw);
        Ok(())
    }
    #[test]
    fn hasselblad_does_not_rebind_user_selected_negative() -> Result<()> {
        let (_dir, s, id) = setup()?;
        let raw = add_version(&s, &id, "photo.3FR", 100, false)?;
        add_version(&s, &id, "photo.HIF", 200, false)?;
        mutate(
            &s,
            "lib",
            &id,
            json!({"requestID":uuid::Uuid::new_v4().to_string(),"expectedRevision":0,"contentHash":raw}),
            "negative",
        )?;
        s.store.initialize_negative("lib", &id)?;
        assert_eq!(s.store.edit_state("lib", &id)?["negativeContentHash"], raw);
        Ok(())
    }
    #[test]
    fn durable_idempotency_conflicts_reset_and_gc_preserve_original() -> Result<()> {
        let (dir, s, id) = setup()?;
        s.store.initialize_negative("lib", &id)?;
        let hash = s.store.edit_state("lib", &id)?["negativeContentHash"].clone();
        let request = json!({"requestID":uuid::Uuid::new_v4().to_string(),"expectedRevision":0,"contentHash":hash});
        let result = mutate(&s, "lib", &id, request.clone(), "negative")?;
        assert_eq!(result["revision"], 1);
        assert_eq!(mutate(&s, "lib", &id, request.clone(), "negative")?, result);
        let reopened = Store::open(&dir.path().join("catalog.sqlite"), false)?;
        assert_eq!(reopened.edit_state("lib", &id)?, result);
        let mut conflict = request.clone();
        conflict["requestID"] = json!(uuid::Uuid::new_v4().to_string());
        assert_eq!(
            mutate(&s, "lib", &id, conflict, "negative")
                .unwrap_err()
                .downcast_ref::<StoreError>()
                .unwrap()
                .status,
            409
        );
        let descriptors = edited(&s, &id)?;
        assert_eq!(
            s.store.cache_descriptors("lib", &id)?.unwrap().0,
            descriptors[1]
        );
        assert_eq!(
            s.store.browse_descriptor("lib", &id)?.unwrap(),
            descriptors[2]
        );
        let reset = json!({"requestID":uuid::Uuid::new_v4().to_string(),"expectedRevision":1});
        let result = mutate(&s, "lib", &id, reset.clone(), "reset")?;
        assert_eq!(result["hasEdit"], false);
        assert_eq!(result["revision"], 2);
        assert_eq!(result["negativeContentHash"], hash);
        assert_eq!(mutate(&s, "lib", &id, reset, "reset")?, result);
        assert_eq!(
            s.store
                .collect_asset_cache_garbage(&s.previews, "lib", &id)?,
            0
        );
        assert_eq!(
            std::fs::read(s.jobs.root().join("photo.jpg"))?,
            b"unchanged original"
        );
        Ok(())
    }
    #[test]
    fn committed_versions_survive_reset_and_gc_and_report_missing_files() -> Result<()> {
        let (_dir, s, id) = setup()?;
        s.store.initialize_negative("lib", &id)?;
        let descriptors = edited(&s, &id)?;
        let version = uuid::Uuid::new_v4().to_string();
        let mut standard = descriptors[0].clone();
        standard["version"] = json!(format!("edit:{version}:checksum"));
        let outputs: Vec<Value> = ["standard","thumbnail","browse"].into_iter().zip(&descriptors).map(|(role,d)| json!({"role":role,"objectRef":d["objectRef"],"contentHash":"checksum","width":64,"height":64})).collect();
        let payload =
            json!({"action":"commit","body":{"negativeContentHash":"source","outputs":outputs}});
        {
            let db = s.store.lock()?;
            db.execute(
                "UPDATE photo_edits SET standard=? WHERE asset_id=?",
                params![standard.to_string(), id],
            )?;
            db.execute(
                "INSERT INTO photo_edit_requests VALUES('lib',?,?,?,?)",
                params![
                    id,
                    version,
                    payload.to_string(),
                    json!({"revision":1,"versionID":version}).to_string()
                ],
            )?;
        }
        assert_eq!(s.store.edit_state("lib", &id)?["currentVersionID"], version);
        let listed = edit_versions(&s, "lib", &id)?;
        assert_eq!(listed["items"][0]["versionID"], version);
        assert_eq!(listed["items"][0]["available"], true);
        assert!(
            listed["items"][0]["standard"]["downloadURL"]
                .as_str()
                .is_some()
        );
        let reset = json!({"requestID":uuid::Uuid::new_v4().to_string(),"expectedRevision":0});
        let result = mutate(&s, "lib", &id, reset.clone(), "reset")?;
        assert!(result["currentVersionID"].is_null());
        assert_eq!(mutate(&s, "lib", &id, reset, "reset")?, result);
        assert_eq!(
            s.store
                .collect_asset_cache_garbage(&s.previews, "lib", &id)?,
            0
        );
        assert_eq!(
            edit_versions(&s, "lib", &id)?["items"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            edit_versions(&s, "lib", &id)?["items"][0]["available"],
            true
        );
        std::fs::remove_file(s.previews.object_path(&descriptors[0]["objectRef"])?)?;
        let missing = edit_versions(&s, "lib", &id)?;
        assert_eq!(missing["items"][0]["available"], false);
        assert!(missing["items"][0]["standard"]["downloadURL"].is_null());
        Ok(())
    }
    #[tokio::test]
    async fn source_download_rejects_replaced_symlink() -> Result<()> {
        let (_dir, s, id) = setup()?;
        s.store.initialize_negative("lib", &id)?;
        let hash = s.store.edit_state("lib", &id)?["negativeContentHash"]
            .as_str()
            .unwrap()
            .to_owned();
        let source = s.jobs.root().join("photo.jpg");
        let moved = s.jobs.root().join("fixture.jpg");
        std::fs::rename(&source, &moved)?;
        std::os::unix::fs::symlink(&moved, &source)?;
        let response = crate::api::router(s)
            .oneshot(
                axum::http::Request::builder()
                    .uri(format!(
                        "/libraries/lib/assets/{id}/edit/source?contentHash={hash}"
                    ))
                    .header("authorization", "Bearer test")
                    .body(axum::body::Body::empty())?,
            )
            .await?;
        assert_eq!(response.status(), 409);
        Ok(())
    }
    #[tokio::test]
    async fn uppercase_uuid_routes_and_upload_retry_are_supported() -> Result<()> {
        let (_dir, s, id) = setup()?;
        s.store.initialize_negative("lib", &id)?;
        let app = crate::api::router(s.clone());
        let path = format!("/libraries/lib/assets/{}/edit", id.to_uppercase());
        let response = app
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .uri(&path)
                    .header("authorization", "Bearer test")
                    .body(axum::body::Body::empty())?,
            )
            .await?;
        assert_eq!(response.status(), 200);
        let request = uuid::Uuid::new_v4().to_string();
        let response = app
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .method("POST")
                    .uri(format!("{path}/uploads"))
                    .header("authorization", "Bearer test")
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(
                        json!({"requestID":request}).to_string(),
                    ))?,
            )
            .await?;
        assert_eq!(response.status(), 200);
        let uploads: Value =
            serde_json::from_slice(&response.into_body().collect().await?.to_bytes())?;
        let url = url::Url::parse(uploads["objects"][0]["uploadURL"].as_str().unwrap())?;
        for (body, status) in [
            (vec![1u8; 70_000], 204),
            (vec![1u8; 70_000], 204),
            (vec![2u8; 70_000], 409),
        ] {
            let response = app
                .clone()
                .oneshot(
                    axum::http::Request::builder()
                        .method("PUT")
                        .uri(url.path())
                        .body(axum::body::Body::from(body))?,
                )
                .await?;
            assert_eq!(response.status(), status);
        }
        assert_eq!(
            s.store
                .collect_asset_cache_garbage(&s.previews, "lib", &id)?,
            0
        );
        let restored = app
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .method("PUT")
                    .uri(url.path())
                    .body(axum::body::Body::from(vec![1u8; 70_000]))?,
            )
            .await?;
        assert_eq!(restored.status(), 204);
        let source = s.store.edit_state("lib", &id)?["negativeContentHash"]
            .as_str()
            .unwrap()
            .to_owned();
        let response = app
            .oneshot(
                axum::http::Request::builder()
                    .uri(format!("{path}/source?contentHash={source}"))
                    .header("authorization", "Bearer test")
                    .body(axum::body::Body::empty())?,
            )
            .await?;
        assert_eq!(response.status(), 200);
        assert_eq!(
            &response.into_body().collect().await?.to_bytes()[..],
            b"unchanged original"
        );
        Ok(())
    }
}

#[cfg(test)]
mod render_integration {
    use super::*;
    use http_body_util::BodyExt;
    use tower::ServiceExt;
    #[tokio::test]
    #[ignore = "requires ExifTool and KEEPS_EDIT_TEST_FIXTURES containing rendered HEIF files"]
    async fn real_heif_commit_is_atomic_idempotent_and_validated() -> Result<()> {
        real_commit(false).await?;
        real_commit(true).await
    }
    async fn real_commit(darktable: bool) -> Result<()> {
        let fixtures = PathBuf::from(std::env::var("KEEPS_EDIT_TEST_FIXTURES")?);
        let dir = tempfile::tempdir()?;
        let root = dir.path().canonicalize()?;
        let photos = root.join("photos");
        std::fs::create_dir(&photos)?;
        let path = photos.join("source.heic");
        std::fs::copy(fixtures.join("source.heic"), &path)?;
        let hash = crate::media::sha256_file(&path)?;
        let size = std::fs::metadata(&path)?.len();
        let store = Store::open(&root.join("catalog.sqlite"), true)?;
        let id=store.ingest_original("lib",path.to_str().unwrap(),&json!({"contentHash":hash,"sizeBytes":size,"role":"jpeg_original"}),&json!({"contentFingerprint":hash,"metadataFingerprint":"meta","originalFilename":"source.heic","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"}))?;
        let jobs = crate::jobs::Jobs::open(&root.join("jobs.sqlite"), &photos)?;
        jobs.add_folder("lib", photos.to_str().unwrap())?;
        let s = Arc::new(AppState {
            store: Arc::new(store),
            jobs: Arc::new(jobs),
            previews: Arc::new(crate::previews::PreviewStorage::new(
                &root.join("keeps"),
                Some(&photos),
                "http://localhost",
                "test",
            )?),
            access_token: "test".into(),
            library_id: "lib".into(),
            original_root_names: Default::default(),
        });
        let app = crate::api::router(s.clone());
        let edit_path = format!("/libraries/lib/assets/{id}/edit");
        s.store.initialize_negative("lib", &id)?;
        let request = uuid::Uuid::new_v4().to_string();
        let prepared = app
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .method("POST")
                    .uri(format!("{edit_path}/uploads"))
                    .header("authorization", "Bearer test")
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(
                        json!({"requestID":request}).to_string(),
                    ))?,
            )
            .await?;
        assert_eq!(prepared.status(), 200);
        let uploads: Value =
            serde_json::from_slice(&prepared.into_body().collect().await?.to_bytes())?;
        let mut outputs = Vec::new();
        for role in ["standard", "thumbnail", "browse"] {
            let input = fixtures.join(format!("{role}.heic"));
            let metadata = crate::media::MediaProcessor::new().extract(&input)?;
            let object = object("lib", &id, &request, role);
            let target = uploads["objects"]
                .as_array()
                .unwrap()
                .iter()
                .find(|target| target["role"] == role)
                .unwrap();
            assert_eq!(target["objectRef"], object);
            let url = url::Url::parse(target["uploadURL"].as_str().unwrap())?;
            let uri = match url.query() {
                Some(query) => format!("{}?{query}", url.path()),
                None => url.path().to_owned(),
            };
            let uploaded = app
                .clone()
                .oneshot(
                    axum::http::Request::builder()
                        .method("PUT")
                        .uri(uri)
                        .body(axum::body::Body::from(std::fs::read(&input)?))?,
                )
                .await?;
            assert_eq!(uploaded.status(), 204);
            outputs.push(json!({"role":role,"objectRef":object,"contentHash":crate::media::sha256_file(&input)?,"width":metadata.width,"height":metadata.height,"sizeBytes":std::fs::metadata(&input)?.len()}));
        }
        let mut input = json!({"requestID":request,"expectedRevision":0,"negativeContentHash":hash,"exposureEV":1.99609375,"algorithmVersion":"test-auto-v1","rendererVersion":"test-ci-v1","outputs":outputs});
        if darktable {
            input.as_object_mut().unwrap().remove("exposureEV");
            input["recipe"] = json!({"engine":"darktable","engineVersion":"5.6.2","recipeJSON":"{\"exposureEV\":0.5}","xmp":"<rdf:Description darktable:xmp_version=\"5\"/>"});
        }
        let mut invalid = input.clone();
        invalid["outputs"][0]["width"] = json!(1);
        assert_eq!(
            mutate(&s, "lib", &id, invalid, "commit")
                .unwrap_err()
                .downcast_ref::<StoreError>()
                .unwrap()
                .status,
            422
        );
        assert_eq!(s.store.edit_state("lib", &id)?["revision"], 0);
        s.store.lock()?.execute_batch("CREATE TRIGGER reject_edit BEFORE INSERT ON photo_edit_requests BEGIN SELECT RAISE(ABORT,'injected commit failure'); END;")?;
        assert!(mutate(&s, "lib", &id, input.clone(), "commit").is_err());
        assert_eq!(s.store.edit_state("lib", &id)?["hasEdit"], false);
        assert_eq!(s.store.edit_state("lib", &id)?["revision"], 0);
        s.store.lock()?.execute_batch("DROP TRIGGER reject_edit;")?;
        let saved = app
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .method("PUT")
                    .uri(&edit_path)
                    .header("authorization", "Bearer test")
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(input.to_string()))?,
            )
            .await?;
        assert_eq!(saved.status(), 200);
        let response: Value =
            serde_json::from_slice(&saved.into_body().collect().await?.to_bytes())?;
        assert_eq!(response["revision"], 1);
        assert_eq!(response["hasEdit"], true);
        assert_eq!(response["currentVersionID"], request);
        assert_eq!(response["versionID"], request);
        assert!(response["previousVersionID"].is_null());
        assert_eq!(response["sourceContentHash"], hash);
        assert_eq!(
            edit_versions(&s, "lib", &id)?["items"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        if darktable {
            assert_eq!(response["recipe"], input["recipe"]);
        }
        let media = s.store.media_snapshot("lib", &id)?;
        for role in ["standard", "thumbnail", "browse"] {
            assert!(media[role]["version"].as_str().unwrap().contains(&request));
        }
        let repeated = app
            .clone()
            .oneshot(
                axum::http::Request::builder()
                    .method("PUT")
                    .uri(&edit_path)
                    .header("authorization", "Bearer test")
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(input.to_string()))?,
            )
            .await?;
        assert_eq!(repeated.status(), 200);
        let repeated: Value =
            serde_json::from_slice(&repeated.into_body().collect().await?.to_bytes())?;
        assert_eq!(repeated, response);
        let reopened = Store::open(&root.join("catalog.sqlite"), false)?;
        assert_eq!(reopened.edit_state("lib", &id)?, response);
        let mut stale = input;
        stale["requestID"] = json!(uuid::Uuid::new_v4().to_string());
        assert_eq!(
            mutate(&s, "lib", &id, stale, "commit")
                .unwrap_err()
                .downcast_ref::<StoreError>()
                .unwrap()
                .status,
            409
        );
        assert_eq!(crate::media::sha256_file(&path)?, hash);
        Ok(())
    }
}
