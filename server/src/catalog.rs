use crate::store::{Store, StoreError};
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::Utc;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use uuid::Uuid;

fn missing_paths_query(scope: &str) -> Result<String> {
    let predicate = match scope {
        "file" => "p.path=?2",
        "directory" => "p.path>=?2 AND p.path<?3 AND instr(substr(p.path,length(?2)+1),'/')=0",
        "recursive" => "p.path>=?2 AND p.path<?3",
        _ => anyhow::bail!("invalid missing reconciliation scope"),
    };
    Ok(format!(
        "SELECT p.asset_id,p.path,p.content_hash,f.size,p.role FROM catalog_paths p JOIN catalog_files f ON f.library_id=p.library_id AND f.asset_id=p.asset_id AND f.content_hash=p.content_hash AND f.role=p.role WHERE p.library_id=?1 AND f.holder='keeps-nas' AND {predicate}"
    ))
}

const VERSION: i64 = 14;
const DIRECTORY_ASSET_SET: &str =
    " AND a.id IN (SELECT f.asset_id FROM catalog_paths f WHERE f.library_id=? AND ";
// Ordering by path must not make SQLite scan the whole library for every asset.
const ASSET_PATHS: &str = "SELECT path FROM catalog_paths INDEXED BY catalog_paths_asset WHERE library_id=? AND asset_id=? ORDER BY path";
const SCHEMA: &str = r#"
CREATE TABLE catalog_assets(library_id TEXT NOT NULL,id TEXT NOT NULL,snapshot TEXT NOT NULL,content_hash TEXT NOT NULL,fingerprint TEXT NOT NULL,sort_time TEXT NOT NULL,filename TEXT NOT NULL,rating INTEGER NOT NULL,flag TEXT NOT NULL,color TEXT,trashed INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(library_id,id));
CREATE INDEX catalog_hash ON catalog_assets(library_id,content_hash);
CREATE INDEX catalog_fingerprint ON catalog_assets(library_id,fingerprint);
CREATE INDEX catalog_sort ON catalog_assets(library_id,trashed,sort_time,id);
CREATE TABLE catalog_files(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,content_hash TEXT NOT NULL,size INTEGER NOT NULL,role TEXT NOT NULL,holder TEXT NOT NULL,availability TEXT NOT NULL,PRIMARY KEY(library_id,asset_id,content_hash,role,holder));
CREATE INDEX catalog_file_hash ON catalog_files(library_id,content_hash);
CREATE TABLE catalog_paths(library_id TEXT NOT NULL,path TEXT NOT NULL,asset_id TEXT NOT NULL,content_hash TEXT NOT NULL,role TEXT NOT NULL,PRIMARY KEY(library_id,path));
CREATE INDEX catalog_paths_asset ON catalog_paths(library_id,asset_id);
"#;

pub fn ensure_schema(db: &mut Connection, allow_migrate: bool) -> Result<()> {
    let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
    ensure!(
        version <= VERSION,
        "database schema {version} is newer than this server supports ({VERSION})"
    );
    if version == VERSION {
        db.prepare("SELECT library_id,asset_id,metadata FROM photo_edit_decisions LIMIT 0")?;
        db.prepare("SELECT library_id,kind,revision,content FROM ai_editing_state LIMIT 0")?;
        db.prepare("SELECT negative_hash,edit_revision,negative_selected,last_edit_request FROM catalog_assets LIMIT 0")?;
        db.prepare(
            "SELECT negative_hash,exposure_ev,standard,thumbnail,browse,recipe FROM photo_edits LIMIT 0",
        )?;
        db.prepare("SELECT request_id,payload,response FROM photo_edit_requests LIMIT 0")?;
        db.prepare("SELECT library_id,path,retained_path,basis,reason FROM catalog_deprecated_files LIMIT 0")?;
        db.prepare("SELECT library_id,asset_id,root_id FROM catalog_identity_roots LIMIT 0")?;
        db.prepare("SELECT library_id,root_id,asset_id FROM catalog_identity_aliases LIMIT 0")?;
        db.prepare("SELECT id,expires_at,completed FROM remote_cache_tasks LIMIT 0")?;
        db.prepare("SELECT library_id,batch_id,path,worker_id,expires_at FROM import_compute_leases LIMIT 0")?;
        db.prepare("SELECT library_id,asset_id,role,file_object,object_bucket,object_key,object_etag,pixel_width,pixel_height,updated_at FROM derivative_objects LIMIT 0")?;
        db.prepare("SELECT library_id,bucket,object_key,not_before,attempts,last_error FROM media_cache_gc LIMIT 0")?;
        db.prepare("SELECT library_id,id,snapshot FROM photos LIMIT 0")?;
        db.prepare("SELECT library_id,id,snapshot FROM videos LIMIT 0")?;
        db.prepare("SELECT library_id,path,parent_path FROM directories LIMIT 0")?;
        db.prepare("SELECT library_id,asset_id,source_hash,spec,status,attempts,available_at,last_error,thumbnail,standard,updated_at,audited_at FROM media_cache LIMIT 0")?;
        db.prepare("SELECT next_batch_at,last_batch_count,last_batch_at,last_error,free_bytes FROM cache_runtime LIMIT 0")?;
        db.prepare("SELECT snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed FROM catalog_assets LIMIT 0")?;
        db.prepare(
            "SELECT asset_id,content_hash,size,role,holder,availability FROM catalog_files LIMIT 0",
        )?;
        db.prepare("SELECT library_id,path,asset_id,content_hash,role FROM catalog_paths LIMIT 0")?;
        db.prepare("SELECT library_id,path FROM catalog_hidden_directories LIMIT 0")?;
        db.prepare("SELECT library_id,asset_id,content_hash,visual_hash,capture_key,width,height,priority,evidence FROM catalog_versions LIMIT 0")?;
        db.prepare("SELECT library_id,path,asset_id,content_hash,available FROM catalog_version_paths LIMIT 0")?;
        db.prepare(
            "SELECT library_id,asset_id,content_hash,user_selected FROM catalog_defaults LIMIT 0",
        )?;
        db.prepare("SELECT library_id,revision FROM catalog_version_revision LIMIT 0")?;
        db.prepare(
            "SELECT library_id,path,parent_path,revision FROM catalog_directory_revisions LIMIT 0",
        )?;
        db.prepare("SELECT library_id,kind,key FROM catalog_revision_dirty LIMIT 0")?;
        db.prepare("SELECT library_id,value FROM catalog_revision_sequence LIMIT 0")?;
        db.prepare(
            "SELECT library_id,path,owner,last_changed_at FROM catalog_revision_updates LIMIT 0",
        )?;
        db.prepare("SELECT browse_thumbnail,browse_spec,browse_source_version,browse_attempts,browse_available_at,browse_last_error FROM media_cache LIMIT 0")?;
        return Ok(());
    }
    ensure!(
        allow_migrate,
        "database migration required: stop the service, back up SQLite, then run keeps-server migrate"
    );
    tracing::info!(from = version, to = VERSION, "migrating NAS catalog");
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if version == 0 {
        let legacy: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name='ledger_events')", [], |r| r.get(0))?;
        if legacy {
            let populated: bool =
                tx.query_row("SELECT EXISTS(SELECT 1 FROM ledger_events)", [], |r| {
                    r.get(0)
                })?;
            ensure!(
                !populated,
                "legacy ledger-only database requires explicit conversion with the previous server; historical events are never replayed by this server"
            );
        }
        tx.execute_batch(SCHEMA)?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS derivative_objects(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,role TEXT NOT NULL,file_object TEXT NOT NULL,object_bucket TEXT NOT NULL,object_key TEXT NOT NULL,object_etag TEXT,pixel_width INTEGER NOT NULL,pixel_height INTEGER NOT NULL,updated_at TEXT NOT NULL,PRIMARY KEY(library_id,asset_id,role));")?;
    }

    if version < 2 {
        tx.execute_batch("CREATE TABLE catalog_hidden_directories(library_id TEXT NOT NULL,path TEXT NOT NULL,PRIMARY KEY(library_id,path));")?;
    }
    if version < 3 {
        crate::versions::migrate(&tx)?;
    }
    if version < 4 {
        crate::revisions::migrate(&tx)?;
    }
    if version < 5 {
        crate::revisions::migrate_updates(&tx)?;
    }
    if version < 6 {
        crate::cache_pipeline::migrate(&tx)?;
    }
    if version < 7 {
        let has_event_sequence = tx
            .prepare("PRAGMA table_info(derivative_objects)")?
            .query_map([], |r| r.get::<_, String>(1))?
            .collect::<rusqlite::Result<Vec<_>>>()?
            .iter()
            .any(|name| name == "declared_event_seq");
        if has_event_sequence {
            tx.execute_batch("ALTER TABLE derivative_objects DROP COLUMN declared_event_seq;")?;
        }
        tx.execute_batch("DROP TABLE IF EXISTS archive_receipts; DROP TABLE IF EXISTS sync_conflicts; DROP TABLE IF EXISTS device_states; DROP TABLE IF EXISTS ledger_sequence_counters; DROP TABLE IF EXISTS ledger_events;")?;
    }
    if version < 8 {
        crate::remote_worker::migrate(&tx)?;
    }
    if version < 9 {
        tx.execute_batch("CREATE TABLE catalog_identity_roots(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,root_id TEXT NOT NULL,PRIMARY KEY(library_id,asset_id));
            CREATE TABLE catalog_identity_aliases(library_id TEXT NOT NULL,root_id TEXT NOT NULL,asset_id TEXT NOT NULL,PRIMARY KEY(library_id,root_id));
            INSERT INTO catalog_identity_roots SELECT library_id,id,id FROM catalog_assets;
            INSERT INTO catalog_identity_aliases SELECT library_id,id,id FROM catalog_assets;")?;
    }
    if version < 10 {
        crate::photo_relations::migrate(&tx)?;
    }
    crate::browse_cache::migrate(&tx)?;
    if version < 12 {
        crate::edits::migrate(&tx)?;
    }
    if version < 14 {
        crate::remote_worker::migrate(&tx)?;
        crate::edits::migrate_recipe(&tx)?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS ai_editing_state(library_id TEXT NOT NULL,kind TEXT NOT NULL,revision INTEGER NOT NULL,content TEXT,PRIMARY KEY(library_id,kind)); CREATE TABLE IF NOT EXISTS photo_edit_decisions(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,metadata TEXT NOT NULL,PRIMARY KEY(library_id,asset_id));")?;
    }
    tx.pragma_update(None, "user_version", VERSION)?;
    tx.commit()?;
    Ok(())
}

fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key].as_str().with_context(|| format!("missing {key}"))
}
fn existing(db: &Connection, lib: &str, id: &str) -> Result<Option<Value>> {
    let s: Option<String> = db
        .query_row(
            "SELECT snapshot FROM catalog_assets WHERE library_id=? AND id=?",
            params![lib, id],
            |r| r.get(0),
        )
        .optional()?;
    s.map(|s| serde_json::from_str(&s).map_err(Into::into))
        .transpose()
}
fn save(db: &Connection, lib: &str, a: &Value) -> Result<()> {
    db.execute("INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(library_id,id) DO UPDATE SET snapshot=excluded.snapshot,content_hash=excluded.content_hash,fingerprint=excluded.fingerprint,sort_time=excluded.sort_time,filename=excluded.filename,rating=excluded.rating,flag=excluded.flag,color=excluded.color,trashed=excluded.trashed",params![lib,text(a,"id")?,a.to_string(),text(a,"contentFingerprint")?,text(a,"metadataFingerprint")?,a["captureTime"].as_str().unwrap_or(text(a,"createdAt")?),text(a,"originalFilename")?,a["rating"].as_i64().unwrap_or(0),a["flagState"].as_str().unwrap_or("unflagged"),a["colorLabel"].as_str(),a["trashed"].as_bool().unwrap_or(false)])?;
    Ok(())
}

pub(crate) fn register_derivative(db: &Connection, lib: &str, id: &str, d: &Value) -> Result<()> {
    ensure!(
        existing(db, lib, id)?.is_some(),
        "derivative asset does not exist"
    );
    ensure!(
        d["assetID"].as_str().is_none_or(|asset| asset == id),
        "derivative asset mismatch"
    );
    db.execute("INSERT INTO derivative_objects(library_id,asset_id,role,file_object,object_bucket,object_key,object_etag,pixel_width,pixel_height,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(library_id,asset_id,role) DO UPDATE SET file_object=excluded.file_object,object_bucket=excluded.object_bucket,object_key=excluded.object_key,object_etag=excluded.object_etag,pixel_width=excluded.pixel_width,pixel_height=excluded.pixel_height,updated_at=excluded.updated_at",params![lib,id,text(d,"role")?,d["fileObject"].to_string(),text(&d["objectRef"],"bucket")?,text(&d["objectRef"],"key")?,d["objectRef"]["eTag"].as_str(),d["pixelSize"]["width"].as_i64().context("missing derivative width")?,d["pixelSize"]["height"].as_i64().context("missing derivative height")?,Utc::now().to_rfc3339()])?;
    Ok(())
}

fn register_file(
    db: &Connection,
    lib: &str,
    id: &str,
    file: &Value,
    availability: &str,
) -> Result<()> {
    db.execute("INSERT INTO catalog_files(library_id,asset_id,content_hash,size,role,holder,availability) VALUES (?,?,?,?,?,'keeps-nas',?) ON CONFLICT(library_id,asset_id,content_hash,role,holder) DO UPDATE SET availability=excluded.availability",params![lib,id,text(file,"contentHash")?,file["sizeBytes"].as_i64().context("file size missing")?,text(file,"role")?,availability])?;
    Ok(())
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetQuery {
    pub q: Option<String>,
    pub min_rating: Option<i64>,
    pub flag_state: Option<String>,
    pub color_label: Option<String>,
    pub tag: Option<String>,
    pub trashed: Option<bool>,
    pub sort: Option<String>,
    pub directory: Option<String>,
    pub recursive: Option<bool>,
    pub show_hidden: Option<bool>,
    pub cursor: Option<String>,
    pub limit: Option<usize>,
    #[serde(rename = "folderID")]
    pub folder_id: Option<String>,
}
fn invalid(message: &str) -> anyhow::Error {
    StoreError {
        status: 422,
        code: "invalid_request".into(),
        message: message.into(),
    }
    .into()
}
fn not_found() -> anyhow::Error {
    StoreError {
        status: 404,
        code: "asset_not_found".into(),
        message: "asset not found".into(),
    }
    .into()
}
fn decorate(db: &Connection, lib: &str, mut a: Value) -> Result<Value> {
    let id = text(&a, "id")?.to_owned();
    a["negativeContentHash"] = json!(db.query_row(
        "SELECT negative_hash FROM catalog_assets WHERE library_id=? AND id=?",
        params![lib, id],
        |r| r.get::<_, Option<String>>(0)
    )?);
    let mut paths = db.prepare_cached(ASSET_PATHS)?;
    a["paths"] = json!(
        paths
            .query_map(params![lib, id], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?
    );
    let preview:Option<String>=db.query_row("SELECT json_object('objectRef',json_object('bucket',object_bucket,'key',object_key),'width',pixel_width,'height',pixel_height,'version',json_extract(file_object,'$.contentHash')) FROM derivative_objects WHERE library_id=? AND asset_id=? AND role='preview'",params![lib,id],|r|r.get(0)).optional()?;
    a["_preview"] = preview
        .map(|s| serde_json::from_str(&s))
        .transpose()?
        .unwrap_or(Value::Null);
    Ok(a)
}

fn hidden_filter(
    filter: &mut String,
    values: &mut Vec<rusqlite::types::Value>,
    lib: &str,
    directory: Option<&str>,
) {
    filter.push_str(" AND a.id NOT IN (SELECT p.asset_id FROM catalog_hidden_directories h JOIN catalog_paths p ON p.library_id=h.library_id AND p.path>=rtrim(h.path,'/') || '/' AND p.path<rtrim(h.path,'/') || '0' WHERE h.library_id=? AND NOT (?=h.path OR substr(?,1,length(rtrim(h.path,'/'))+1)=rtrim(h.path,'/') || '/'))");
    values.push(lib.to_string().into());
    let directory = directory
        .map(|p| if p == "/" { p } else { p.trim_end_matches('/') })
        .unwrap_or("");
    values.push(directory.to_string().into());
    values.push(directory.to_string().into());
}

impl Store {
    pub fn hidden_directories(&self, lib: &str) -> Result<Value> {
        let db = self.read()?;
        let mut statement = db.prepare(
            "SELECT path FROM catalog_hidden_directories WHERE library_id=? ORDER BY path",
        )?;
        let paths = statement
            .query_map([lib], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(json!({"paths": paths}))
    }
    pub fn set_hidden_directory(&self, lib: &str, path: &str, hidden: bool) -> Result<Value> {
        if !path.starts_with('/')
            || path.contains('\0')
            || path.split('/').any(|part| part == "." || part == "..")
            || path.contains("//")
        {
            return Err(invalid(
                "path must be an absolute normalized directory path",
            ));
        }
        let path = if path == "/" {
            path
        } else {
            path.trim_end_matches('/')
        };
        {
            let mut connection = self.lock()?;
            let db = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            if hidden {
                db.execute("INSERT INTO catalog_hidden_directories(library_id,path) VALUES (?,?) ON CONFLICT DO NOTHING", params![lib,path])?;
            } else {
                db.execute(
                    "DELETE FROM catalog_hidden_directories WHERE library_id=? AND path=?",
                    params![lib, path],
                )?;
            }
            crate::revisions::flush(&db)?;
            db.commit()?;
        }
        self.hidden_directories(lib)
    }
    pub fn query_assets(&self, lib: &str, q: &AssetQuery) -> Result<Value> {
        let sort = q.sort.as_deref().unwrap_or("capture_desc");
        let limit = q.limit.unwrap_or(100).clamp(1, 200);
        let order = match sort {
            "capture_desc" => "a.sort_time DESC,a.id",
            "capture_asc" => "a.sort_time ASC,a.id",
            "filename" => "a.filename COLLATE NOCASE,a.id",
            "rating_desc" => "a.rating DESC,a.sort_time DESC,a.id",
            _ => return Err(invalid("invalid sort")),
        };
        let mut boundary: Option<(String, String)> = None;
        let mut offset = 0_i64;
        if let Some(cursor) = &q.cursor {
            if sort == "capture_desc" && cursor.starts_with("cd1.") {
                let encoded = &cursor[4..];
                let bytes = URL_SAFE_NO_PAD
                    .decode(encoded)
                    .map_err(|_| invalid("invalid cursor"))?;
                boundary =
                    Some(serde_json::from_slice(&bytes).map_err(|_| invalid("invalid cursor"))?);
            } else {
                // Installed clients may resume a persisted offset; the next page upgrades it.
                offset = cursor.parse().map_err(|_| invalid("invalid cursor"))?;
                if offset < 0 {
                    return Err(invalid("invalid cursor"));
                }
            }
        }
        let mut filter = "a.library_id=? AND a.trashed=? AND EXISTS(SELECT 1 FROM catalog_paths live WHERE live.library_id=a.library_id AND live.asset_id=a.id)".to_string();
        let mut values: Vec<rusqlite::types::Value> = vec![
            lib.to_string().into(),
            (q.trashed.unwrap_or(false) as i64).into(),
        ];
        if let Some(s) = q.q.as_ref().filter(|v| !v.is_empty()) {
            filter.push_str(" AND (a.filename LIKE ? ESCAPE '\\' OR json_extract(a.snapshot,'$.cameraModel') LIKE ? ESCAPE '\\')");
            let pattern = format!("%{}%", escape_like(s));
            values.push(pattern.clone().into());
            values.push(pattern.into());
        }
        if let Some(rating) = q.min_rating {
            if !(0..=5).contains(&rating) {
                return Err(invalid("minRating must be 0...5"));
            }
            filter.push_str(" AND a.rating>=?");
            values.push(rating.into());
        }
        for (value, column) in [(&q.flag_state, "a.flag"), (&q.color_label, "a.color")] {
            if let Some(value) = value {
                filter.push_str(&format!(" AND {column}=?"));
                values.push(value.clone().into());
            }
        }
        if let Some(tag) = &q.tag {
            filter.push_str(
                " AND EXISTS(SELECT 1 FROM json_each(a.snapshot,'$.tags') WHERE value=?)",
            );
            values.push(tag.clone().into());
        }
        if let Some(path) = &q.directory {
            // Materialize the directory asset set once; a correlated EXISTS can repeat
            // the entire path range scan for every asset in a large library.
            filter.push_str(DIRECTORY_ASSET_SET);
            values.push(lib.to_string().into());
            let root = path.trim_end_matches('/');
            filter.push_str("f.path>=? AND f.path<?");
            values.push(format!("{root}/").into());
            values.push(format!("{root}0").into());
            if !q.recursive.unwrap_or(true) {
                filter.push_str(" AND substr(f.path,?) NOT LIKE '%/%'");
                values.push(((root.chars().count() + 2) as i64).into());
            }
            filter.push(')');
        }
        if !q.show_hidden.unwrap_or(false) {
            hidden_filter(&mut filter, &mut values, lib, q.directory.as_deref());
        }
        let mut connection = self.read()?;
        let db = connection.transaction()?;
        let revision = crate::revisions::read(&db, lib, q.directory.as_deref())?;
        let is_updating = crate::revisions::is_updating(&db, lib, q.directory.as_deref())?;
        let total: i64 = db.query_row(
            &format!("SELECT count(*) FROM catalog_assets a WHERE {filter}"),
            rusqlite::params_from_iter(&values),
            |r| r.get(0),
        )?;
        if let Some((time, id)) = boundary {
            filter.push_str(" AND (a.sort_time<? OR (a.sort_time=? AND a.id>?))");
            values.extend([time.clone().into(), time.into(), id.into()]);
        }
        let mut statement=db.prepare(&format!("SELECT a.snapshot,a.sort_time,a.id FROM catalog_assets a WHERE {filter} ORDER BY {order} LIMIT ? OFFSET ?"))?;
        values.push(((limit + 1) as i64).into());
        values.push(offset.into());
        let rows = statement
            .query_map(rusqlite::params_from_iter(&values), |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let has_more = rows.len() > limit;
        let mut items = Vec::new();
        let mut last_key = None;
        for (snapshot, time, id) in rows.into_iter().take(limit) {
            items.push(decorate(&db, lib, serde_json::from_str(&snapshot)?)?);
            last_key = Some((time, id));
        }
        let next_cursor = if has_more {
            Some(if sort == "capture_desc" {
                format!(
                    "cd1.{}",
                    URL_SAFE_NO_PAD.encode(serde_json::to_vec(&last_key)?)
                )
            } else {
                (offset + items.len() as i64).to_string()
            })
        } else {
            None
        };
        Ok(
            json!({"items":items,"total":total,"nextCursor":next_cursor,"revision":revision,"isUpdating":is_updating}),
        )
    }

    pub fn asset(&self, lib: &str, id: &str) -> Result<Value> {
        let mut connection = self.read()?;
        let db = connection.transaction()?;
        decorate(&db, lib, existing(&db, lib, id)?.ok_or_else(not_found)?)
    }
    pub fn counts(&self, lib: &str, show_hidden: bool) -> Result<Value> {
        let db = self.read()?;
        let mut filter = "a.library_id=? AND EXISTS(SELECT 1 FROM catalog_paths live WHERE live.library_id=a.library_id AND live.asset_id=a.id)".to_string();
        let mut values: Vec<rusqlite::types::Value> = vec![lib.to_string().into()];
        if !show_hidden {
            hidden_filter(&mut filter, &mut values, lib, None);
        }
        let result=db.query_row(&format!("SELECT count(*) FILTER(WHERE trashed=0),count(*) FILTER(WHERE trashed=1),count(*) FILTER(WHERE trashed=0 AND flag='picked') FROM catalog_assets a WHERE {filter}"),rusqlite::params_from_iter(&values),|r|Ok(json!({"all":r.get::<_,i64>(0)?,"trashed":r.get::<_,i64>(1)?,"picked":r.get::<_,i64>(2)?})))?;
        Ok(result)
    }
    /// Indexed descendant counts; each asset counts once even with multiple paths.
    pub fn directory_photo_counts(&self, lib: &str, paths: &[String]) -> Result<Vec<(i64, i64)>> {
        let mut connection = self.read()?;
        let db = connection.transaction()?;
        let mut statement = db.prepare("SELECT count(DISTINCT CASE WHEN instr(substr(p.path,length(?2)+1),'/')=0 THEN p.asset_id END), count(DISTINCT p.asset_id) FROM catalog_paths p JOIN catalog_assets a ON a.library_id=p.library_id AND a.id=p.asset_id WHERE p.library_id=?1 AND p.path>=?2 AND p.path<?3 AND a.trashed=0")?;
        paths
            .iter()
            .map(|path| {
                let root = path.trim_end_matches('/');
                Ok(statement.query_row(
                    params![lib, format!("{root}/"), format!("{root}0")],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )?)
            })
            .collect()
    }
    pub fn directories(&self, lib: &str) -> Result<Value> {
        let db = self.read()?;
        let mut statement =
            db.prepare("SELECT path,asset_id FROM catalog_paths WHERE library_id=?")?;
        let paths = statement.query_map([lib], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })?;
        let mut counts = std::collections::BTreeMap::<String, BTreeSet<String>>::new();
        for row in paths {
            let (path, id) = row?;
            if let Some(parent) = std::path::Path::new(&path).parent() {
                counts
                    .entry(parent.to_string_lossy().into_owned())
                    .or_default()
                    .insert(id);
            }
        }
        Ok(
            json!({"directories":counts.into_iter().map(|(path,count)|json!({"path":path,"count":count.len()})).collect::<Vec<_>>()}),
        )
    }
    pub fn patch_asset(&self, lib: &str, id: &str, patch: &Value) -> Result<Value> {
        let fields = patch
            .as_object()
            .ok_or_else(|| invalid("metadata patch must be an object"))?;
        if fields.is_empty()
            || fields
                .keys()
                .any(|k| !["rating", "flagState", "colorLabel", "tags"].contains(&k.as_str()))
        {
            return Err(invalid("unsupported metadata patch"));
        }
        if fields
            .get("rating")
            .is_some_and(|v| !v.as_i64().is_some_and(|n| (0..=5).contains(&n)))
        {
            return Err(invalid("rating must be 0...5"));
        }
        if fields.get("flagState").is_some_and(|v| {
            !v.as_str()
                .is_some_and(|s| ["unflagged", "picked", "rejected"].contains(&s))
        }) {
            return Err(invalid("invalid flagState"));
        }
        if fields.get("colorLabel").is_some_and(|v| {
            !v.is_null()
                && !v
                    .as_str()
                    .is_some_and(|s| ["red", "yellow", "green", "blue", "purple"].contains(&s))
        }) {
            return Err(invalid("invalid colorLabel"));
        }
        if fields.get("tags").is_some_and(|v| {
            !v.as_array().is_some_and(|a| {
                a.len() <= 100
                    && a.iter()
                        .all(|v| v.as_str().is_some_and(|s| !s.is_empty() && s.len() <= 128))
            })
        }) {
            return Err(invalid(
                "tags must be an array of at most 100 nonempty strings",
            ));
        }
        let mut db = self.lock()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut asset = existing(&tx, lib, id)?.ok_or_else(not_found)?;
        let old = asset.clone();
        for (key, value) in fields {
            if key == "tags" {
                let tags: BTreeSet<&str> = value
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter_map(Value::as_str)
                    .collect();
                asset[key] = json!(tags);
            } else {
                asset[key] = value.clone();
            }
        }
        if asset != old {
            asset["updatedAt"] = json!(Utc::now().to_rfc3339());
            save(&tx, lib, &asset)?;
        }
        let a = decorate(&tx, lib, existing(&tx, lib, id)?.ok_or_else(not_found)?)?;
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(a)
    }
    pub fn set_trashed(&self, lib: &str, id: &str, trashed: bool) -> Result<Value> {
        let mut db = self.lock()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut asset = existing(&tx, lib, id)?.ok_or_else(not_found)?;
        if asset["trashed"] != trashed {
            asset["trashed"] = json!(trashed);
            asset["updatedAt"] = json!(Utc::now().to_rfc3339());
            save(&tx, lib, &asset)?;
        }
        let a = decorate(&tx, lib, existing(&tx, lib, id)?.ok_or_else(not_found)?)?;
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(a)
    }
}
fn escape_like(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

fn moved_original(db: &Connection, lib: &str, hash: &str) -> Result<Option<(String, Vec<String>)>> {
    let ids = {
        let mut q = db.prepare("SELECT DISTINCT asset_id FROM catalog_files WHERE library_id=? AND content_hash=? AND role IN ('jpeg_original','raw_original') LIMIT 2")?;
        q.query_map(params![lib, hash], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    if ids.len() != 1 {
        return Ok(None);
    }
    let id = &ids[0];
    let paths = {
        let mut q = db.prepare("SELECT path FROM catalog_paths WHERE library_id=?1 AND asset_id=?2 AND content_hash=?3 UNION SELECT path FROM catalog_version_paths WHERE library_id=?1 AND asset_id=?2 AND content_hash=?3")?;
        q.query_map(params![lib, id, hash], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    if paths.is_empty() {
        return Ok(None);
    }
    for path in &paths {
        match std::fs::symlink_metadata(path) {
            Ok(_) => return Ok(None),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e).with_context(|| format!("check moved original {path}")),
        }
    }
    Ok(Some((id.clone(), paths)))
}

pub(crate) fn merge_unlocated_identity(
    db: &Connection,
    lib: &str,
    old: &str,
    target: &str,
) -> Result<()> {
    let located: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM catalog_paths WHERE library_id=? AND asset_id=?)",
        params![lib, old],
        |r| r.get(0),
    )?;
    if located {
        return Ok(());
    }
    let Some(previous) = existing(db, lib, old)? else {
        return Ok(());
    };
    let mut current = existing(db, lib, target)?.context("identity merge target missing")?;
    crate::edits::merge(db, lib, old, target)?;
    let tags: BTreeSet<String> = [&current, &previous]
        .into_iter()
        .flat_map(|s| {
            s["tags"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
        })
        .collect();
    current["tags"] = json!(tags);
    current["rating"] = json!(
        current["rating"]
            .as_i64()
            .unwrap_or(0)
            .max(previous["rating"].as_i64().unwrap_or(0))
    );
    if current["flagState"]
        .as_str()
        .is_none_or(|v| v == "unflagged")
        && !previous["flagState"].is_null()
    {
        current["flagState"] = previous["flagState"].clone();
    }
    if current["colorLabel"].is_null() {
        current["colorLabel"] = previous["colorLabel"].clone();
    }
    let mut history = current["identityMergedFrom"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    history.push(previous);
    current["identityMergedFrom"] = json!(history);
    current["updatedAt"] = json!(Utc::now().to_rfc3339());
    save(db, lib, &current)?;
    db.execute("INSERT OR IGNORE INTO catalog_files SELECT library_id,?3,content_hash,size,role,holder,availability FROM catalog_files WHERE library_id=?1 AND asset_id=?2",params![lib,old,target])?;
    db.execute("INSERT OR IGNORE INTO catalog_versions SELECT library_id,?3,content_hash,visual_hash,capture_key,width,height,priority,evidence FROM catalog_versions WHERE library_id=?1 AND asset_id=?2",params![lib,old,target])?;
    db.execute(
        "UPDATE catalog_version_paths SET asset_id=? WHERE library_id=? AND asset_id=?",
        params![target, lib, old],
    )?;
    db.execute(
        "UPDATE catalog_identity_aliases SET asset_id=? WHERE library_id=? AND asset_id=?",
        params![target, lib, old],
    )?;
    for table in [
        "catalog_files",
        "catalog_versions",
        "catalog_defaults",
        "catalog_identity_roots",
        "media_cache",
        "remote_cache_tasks",
        "derivative_objects",
    ] {
        db.execute(
            &format!("DELETE FROM {table} WHERE library_id=? AND asset_id=?"),
            params![lib, old],
        )?;
    }
    for table in ["photos", "videos", "catalog_assets"] {
        db.execute(
            &format!("DELETE FROM {table} WHERE library_id=? AND id=?"),
            params![lib, old],
        )?;
    }
    Ok(())
}

fn metadata_identity_updated(
    db: &Connection,
    lib: &str,
    id: &str,
    path: &str,
    old: &str,
    metadata: (&str, u64, &str),
) -> Result<()> {
    let (new, size, mtime) = metadata;
    db.execute("UPDATE catalog_assets SET negative_hash=?4,edit_revision=edit_revision+1 WHERE library_id=?1 AND id=?2 AND negative_hash=?3",params![lib,id,old,new])?;
    db.execute("UPDATE photo_edits SET negative_hash=?4 WHERE library_id=?1 AND asset_id=?2 AND negative_hash=?3",params![lib,id,old,new])?;
    let size = i64::try_from(size)?;
    db.execute("INSERT OR REPLACE INTO catalog_files SELECT library_id,asset_id,?4,?5,role,holder,availability FROM catalog_files WHERE library_id=?1 AND asset_id=?2 AND content_hash=?3",params![lib,id,old,new,size])?;
    db.execute("INSERT OR IGNORE INTO catalog_versions SELECT library_id,asset_id,?4,visual_hash,capture_key,width,height,priority,json_set(evidence,'$.capture.contentFingerprint',?4) FROM catalog_versions WHERE library_id=?1 AND asset_id=?2 AND content_hash=?3",params![lib,id,old,new])?;
    db.execute(
        "UPDATE catalog_paths SET content_hash=? WHERE library_id=? AND path=?",
        params![new, lib, path],
    )?;
    db.execute(
        "UPDATE catalog_version_paths SET content_hash=? WHERE library_id=? AND path=?",
        params![new, lib, path],
    )?;
    db.execute("UPDATE catalog_defaults SET content_hash=? WHERE library_id=? AND asset_id=? AND content_hash=?",params![new,lib,id,old])?;
    db.execute("UPDATE catalog_assets SET content_hash=?4,snapshot=json_set(snapshot,'$.contentFingerprint',?4) WHERE library_id=?1 AND id=?2 AND content_hash=?3",params![lib,id,old,new])?;
    db.execute(
        "UPDATE media_cache SET source_hash=? WHERE library_id=? AND asset_id=? AND source_hash=?",
        params![new, lib, id, old],
    )?;
    db.execute("UPDATE remote_cache_tasks SET source_hash=?4 WHERE library_id=?1 AND asset_id=?2 AND source_hash=?3 AND completed<>0",params![lib,id,old,new])?;
    db.execute("UPDATE remote_cache_tasks SET input_hash=?4 WHERE library_id=?1 AND input_path=?2 AND input_hash=?3 AND completed<>0",params![lib,path,old,new])?;
    db.execute("UPDATE media_cache SET standard=json_set(standard,'$.version',?3,'$.sizeBytes',?4,'$.mtimeNs',?5) WHERE library_id=?1 AND json_extract(standard,'$.path')=?2",params![lib,path,new,size,mtime])?;
    db.execute("UPDATE catalog_versions SET evidence=json_set(evidence,'$.generatedFrom',?4) WHERE library_id=?1 AND asset_id=?2 AND json_extract(evidence,'$.generatedFrom')=?3",params![lib,id,old,new])?;
    let other:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM catalog_paths WHERE library_id=? AND asset_id=? AND content_hash=?)",params![lib,id,old],|r|r.get(0))?;
    if !other {
        db.execute(
            "DELETE FROM catalog_files WHERE library_id=? AND asset_id=? AND content_hash=?",
            params![lib, id, old],
        )?;
        db.execute(
            "DELETE FROM catalog_versions WHERE library_id=? AND asset_id=? AND content_hash=?",
            params![lib, id, old],
        )?;
        db.execute("UPDATE catalog_version_paths SET content_hash=? WHERE library_id=? AND asset_id=? AND content_hash=?",params![new,lib,id,old])?;
    }
    Ok(())
}

impl Store {
    pub fn root_id(&self, lib: &str, asset: &str) -> Result<String> {
        Ok(self.lock()?.query_row(
            "SELECT root_id FROM catalog_identity_roots WHERE library_id=? AND asset_id=?",
            params![lib, asset],
            |r| r.get(0),
        )?)
    }
    pub fn existing_asset_for_path(&self, lib: &str, path: &str) -> Result<Option<String>> {
        Ok(self
            .lock()?
            .query_row(
                "SELECT asset_id FROM catalog_paths WHERE library_id=? AND path=?",
                params![lib, path],
                |r| r.get(0),
            )
            .optional()?)
    }
    pub fn with_identity_update<F>(
        &self,
        lib: &str,
        path: &str,
        expected_hash: &str,
        action: F,
    ) -> Result<bool>
    where
        F: FnOnce() -> Result<Option<(String, u64, String)>>,
    {
        // Source mutation precedes the database lock; media claims use the same
        // order, while ordinary catalog reads and edits never wait for file I/O.
        let _source = self
            .source_mutation
            .write()
            .map_err(|_| anyhow::anyhow!("source mutation lock poisoned"))?;
        let indexed: Option<(String, String)> = {
            let db = self.lock()?;
            let indexed: Option<(String, String)> = db
                .query_row(
                    "SELECT asset_id,content_hash FROM catalog_paths WHERE library_id=? AND path=?",
                    params![lib, path],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            if let Some((id, hash)) = &indexed {
                ensure!(
                    hash == expected_hash,
                    "identity update source changed in catalog"
                );
                let processing: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM media_cache WHERE library_id=? AND asset_id=? AND status='processing')", params![lib,id], |r| r.get(0))?;
                if processing {
                    return Ok(false);
                }
            }
            indexed
        };
        let updated = action()?;
        let mut db = self.lock()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current: Option<(String, String)> = tx
            .query_row(
                "SELECT asset_id,content_hash FROM catalog_paths WHERE library_id=? AND path=?",
                params![lib, path],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        ensure!(
            current == indexed,
            "identity update source changed in catalog during file update"
        );
        if let Some((hash, size, mtime)) = updated
            && let Some((id, old)) = indexed
        {
            metadata_identity_updated(&tx, lib, &id, path, &old, (&hash, size, &mtime))?;
        }
        crate::revisions::flush(&tx)?;
        tx.commit()?;
        Ok(true)
    }
    pub fn original_is_online(&self, lib: &str, path: &str, hash: &str) -> Result<bool> {
        Ok(self.lock()?.query_row("SELECT EXISTS(SELECT 1 FROM catalog_paths p JOIN catalog_files f ON f.library_id=p.library_id AND f.asset_id=p.asset_id AND f.content_hash=p.content_hash AND f.role=p.role WHERE p.library_id=? AND p.path=? AND p.content_hash=? AND f.holder='keeps-nas' AND f.availability='online')",params![lib,path,hash],|r|r.get(0))?)
    }
    pub fn ingest_original(
        &self,
        lib: &str,
        path: &str,
        file: &Value,
        snapshot: &Value,
    ) -> Result<String> {
        self.ingest_original_with_evidence(lib, path, file, snapshot, &Default::default())
    }
    pub fn ingest_original_with_evidence(
        &self,
        lib: &str,
        path: &str,
        file: &Value,
        snapshot: &Value,
        evidence: &crate::versions::VersionEvidence,
    ) -> Result<String> {
        self.ingest_original_with_revision(lib, path, file, snapshot, evidence, None)
    }
    pub(crate) fn ingest_original_with_revision(
        &self,
        lib: &str,
        path: &str,
        file: &Value,
        snapshot: &Value,
        evidence: &crate::versions::VersionEvidence,
        batch_id: Option<&str>,
    ) -> Result<String> {
        let mut db = self.lock()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let hash = text(file, "contentHash")?;
        let directory = std::path::Path::new(path)
            .parent()
            .context("original has no parent directory")?
            .to_str()
            .context("original directory must be UTF-8")?;
        let prefix = format!("{}/", directory.trim_end_matches('/'));
        // Missing version paths retain identity when an original reappears.
        let by_path: Option<String> = tx.query_row("SELECT asset_id FROM catalog_paths WHERE library_id=?1 AND path=?2 AND content_hash=?3 UNION ALL SELECT asset_id FROM catalog_version_paths WHERE library_id=?1 AND path=?2 AND content_hash=?3 LIMIT 1",params![lib,path,hash],|r|r.get(0)).optional()?;
        let root = snapshot["originalDocumentID"]
            .as_str()
            .map(|value| Uuid::parse_str(value).map(|id| id.to_string()))
            .transpose()
            .context("invalid originalDocumentID")?;
        let previous_path_asset: Option<String> = tx
            .query_row(
                "SELECT asset_id FROM catalog_paths WHERE library_id=? AND path=?",
                params![lib, path],
                |r| r.get(0),
            )
            .optional()?;
        let identity_match = if let Some(root) = &root {
            let known: Option<String> = tx.query_row("SELECT asset_id FROM catalog_identity_aliases WHERE library_id=? AND root_id=?",params![lib,root],|r|r.get(0)).optional()?;
            known.or_else(|| previous_path_asset.clone())
        } else {
            None
        };
        let capture_match = crate::photo_relations::capture_match(&tx, lib, path, snapshot)?;
        let matched = if identity_match.is_some() {
            identity_match
        } else if previous_path_asset.is_none() && capture_match.is_some() {
            capture_match
        } else if root.is_some() {
            None
        } else if by_path.is_some() {
            by_path
        } else {
            let by_hash: Option<String> = tx.query_row("SELECT c.asset_id FROM (SELECT asset_id FROM catalog_files WHERE library_id=?1 AND content_hash=?3 AND role IN ('jpeg_original','raw_original') UNION SELECT id FROM catalog_assets WHERE library_id=?1 AND content_hash=?3) c WHERE EXISTS(SELECT 1 FROM catalog_paths p WHERE p.library_id=?1 AND p.asset_id=c.asset_id AND p.content_hash=?3 AND p.role IN ('jpeg_original','raw_original') AND substr(p.path,1,length(?2))=?2 AND instr(substr(p.path,length(?2)+1),'/')=0) ORDER BY c.asset_id LIMIT 1",params![lib,prefix,hash],|r|r.get(0)).optional()?;
            by_hash.or(crate::versions::exact_match(&tx, lib, &prefix, evidence)?)
        };
        let moved = if root.is_none() && matched.is_none() && std::path::Path::new(path).is_file() {
            moved_original(&tx, lib, hash)?
        } else {
            None
        };
        let id = matched
            .or_else(|| moved.as_ref().map(|(id, _)| id.clone()))
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        if existing(&tx, lib, &id)?.is_none() {
            let mut snapshot = snapshot.clone();
            snapshot
                .as_object_mut()
                .context("snapshot is not an object")?
                .remove("assetID");
            snapshot["id"] = json!(id);
            snapshot["trashed"] = json!(false);
            save(&tx, lib, &snapshot)?;
        }
        let canonical = root.as_deref().unwrap_or(&id);
        tx.execute(
            "INSERT OR IGNORE INTO catalog_identity_aliases VALUES(?,?,?)",
            params![lib, canonical, id],
        )?;
        tx.execute("INSERT INTO catalog_identity_roots VALUES(?,?,?) ON CONFLICT(library_id,asset_id) DO UPDATE SET root_id=CASE WHEN ? THEN excluded.root_id ELSE root_id END",params![lib,id,canonical,root.is_some()])?;
        register_file(&tx, lib, &id, file, "online")?;
        tx.execute("INSERT INTO catalog_paths VALUES(?,?,?,?,?) ON CONFLICT(library_id,path) DO UPDATE SET asset_id=excluded.asset_id,content_hash=excluded.content_hash,role=excluded.role",params![lib,path,id,hash,text(file,"role")?])?;
        crate::versions::register(&tx, lib, &id, path, file, snapshot, evidence)?;
        if let Some((_, paths)) = moved {
            // Register the replacement first so the selected version and its preview remain valid.
            for old in paths {
                tx.execute(
                    "DELETE FROM catalog_paths WHERE library_id=? AND path=? AND asset_id=?",
                    params![lib, old, id],
                )?;
                crate::versions::missing_path(&tx, lib, &id, &old)?;
            }
        }
        if root.is_some() {
            let paths = {
                let mut q = tx.prepare(
                    "SELECT path FROM catalog_paths WHERE library_id=? AND asset_id=? AND path<>?",
                )?;
                q.query_map(params![lib, id, path], |r| r.get::<_, String>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            };
            for old in paths {
                match std::fs::symlink_metadata(&old) {
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                        tx.execute(
                            "DELETE FROM catalog_paths WHERE library_id=? AND path=?",
                            params![lib, old],
                        )?;
                        crate::versions::missing_path(&tx, lib, &id, &old)?;
                    }
                    Err(e) => return Err(e).with_context(|| format!("check identity path {old}")),
                    Ok(_) => {}
                }
            }
        }
        if let Some(previous) = previous_path_asset.filter(|previous| previous != &id) {
            merge_unlocated_identity(&tx, lib, &previous, &id)?;
        }
        crate::photo_relations::reconcile_directory(&tx, lib, directory)?;
        let id = tx.query_row(
            "SELECT asset_id FROM catalog_paths WHERE library_id=? AND path=?",
            params![lib, path],
            |r| r.get::<_, String>(0),
        )?;
        crate::revisions::flush_for_batch(&tx, batch_id)?;
        tx.commit()?;
        Ok(id)
    }
    pub fn declare_generated_preview(&self, lib: &str, id: &str, derivative: &Value) -> Result<()> {
        self.declare_preview_with_revision(lib, id, None, derivative, None)
            .map(|_| ())
    }
    pub fn declare_generated_preview_for_version(
        &self,
        lib: &str,
        id: &str,
        hash: &str,
        derivative: &Value,
    ) -> Result<bool> {
        self.declare_preview_with_revision(lib, id, Some(hash), derivative, None)
    }
    pub(crate) fn declare_preview_with_revision(
        &self,
        lib: &str,
        id: &str,
        hash: Option<&str>,
        derivative: &Value,
        batch_id: Option<&str>,
    ) -> Result<bool> {
        let mut db = self.lock()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(hash) = hash {
            let selected: Option<String> = tx
                .query_row(
                    "SELECT content_hash FROM catalog_defaults WHERE library_id=? AND asset_id=?",
                    params![lib, id],
                    |r| r.get(0),
                )
                .optional()?;
            if selected.as_deref() != Some(hash) {
                return Ok(false);
            }
        }
        let current:Option<String>=tx.query_row("SELECT json_object('fileObject',json(file_object),'bucket',object_bucket,'key',object_key,'eTag',object_etag,'width',pixel_width,'height',pixel_height) FROM derivative_objects WHERE library_id=? AND asset_id=? AND role='preview'",params![lib,id],|r|r.get(0)).optional()?;
        let current = current
            .map(|value| serde_json::from_str::<Value>(&value))
            .transpose()?;
        let next = json!({"fileObject":derivative["fileObject"],"bucket":derivative["objectRef"]["bucket"],"key":derivative["objectRef"]["key"],"eTag":derivative["objectRef"]["eTag"],"width":derivative["pixelSize"]["width"],"height":derivative["pixelSize"]["height"]});
        if current.as_ref() != Some(&next) {
            register_derivative(&tx, lib, id, derivative)?;
        }

        crate::revisions::flush_for_batch(&tx, batch_id)?;
        tx.commit()?;
        Ok(true)
    }
    pub fn mark_missing_under(&self, lib: &str, directory: &str) -> Result<usize> {
        self.mark_missing_under_with_revision(lib, directory, None)
    }
    pub(crate) fn mark_missing_under_with_revision(
        &self,
        lib: &str,
        directory: &str,
        batch_id: Option<&str>,
    ) -> Result<usize> {
        self.mark_missing_scope_with_revision(lib, directory, "recursive", batch_id)
    }
    pub(crate) fn mark_missing_scope_with_revision(
        &self,
        lib: &str,
        directory: &str,
        scope: &str,
        batch_id: Option<&str>,
    ) -> Result<usize> {
        let mut db = self.lock()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let files = {
            let query = missing_paths_query(scope)?;
            let mut statement = tx.prepare(&query)?;
            let directory = directory.trim_end_matches('/');
            let bindings = if scope == "file" {
                vec![lib.to_owned(), directory.to_owned()]
            } else {
                vec![
                    lib.to_owned(),
                    format!("{directory}/"),
                    format!("{directory}0"),
                ]
            };
            statement
                .query_map(rusqlite::params_from_iter(bindings), |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, i64>(3)?,
                        r.get::<_, String>(4)?,
                    ))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?
        };
        let mut missing = 0;
        let mut changed_directories = BTreeSet::new();
        for (id, path, hash, size, role) in files {
            match std::fs::symlink_metadata(&path) {
                Ok(_) => continue,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e).with_context(|| format!("check original {path}")),
            }
            tx.execute(
                "DELETE FROM catalog_paths WHERE library_id=? AND path=?",
                params![lib, path],
            )?;
            if let Some(parent) = std::path::Path::new(&path).parent() {
                changed_directories.insert(parent.to_string_lossy().into_owned());
            }
            crate::versions::missing_path(&tx, lib, &id, &path)?;
            let other:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM catalog_paths WHERE library_id=? AND asset_id=? AND content_hash=? AND role=?)",params![lib,id,hash,role],|r|r.get(0))?;
            if other {
                continue;
            }
            let file = json!({"contentHash":hash,"sizeBytes":size,"role":role});
            register_file(&tx, lib, &id, &file, "missing")?;
            missing += 1;
        }
        for directory in changed_directories {
            crate::photo_relations::reconcile_directory(&tx, lib, &directory)?;
        }
        crate::revisions::flush_for_batch(&tx, batch_id)?;
        tx.commit()?;
        Ok(missing)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_ai_state_survives_reopen_and_schema_twelve_migration() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("catalog.sqlite");
        let store = Store::open(&path, true)?;
        store.lock()?.execute(
            "INSERT INTO ai_editing_state VALUES ('lib','workspace',7,'saved draft')",
            [],
        )?;
        drop(store);
        let store = Store::open(&path, false)?;
        let content: String = store.lock()?.query_row(
            "SELECT content FROM ai_editing_state WHERE library_id='lib' AND kind='workspace'",
            [],
            |row| row.get(0),
        )?;
        assert_eq!(content, "saved draft");
        store
            .lock()?
            .execute_batch("DROP TABLE ai_editing_state; PRAGMA user_version=12;")?;
        drop(store);
        assert!(Store::open(&path, false).is_err());
        let store = Store::open(&path, true)?;
        let count: i64 =
            store
                .lock()?
                .query_row("SELECT COUNT(*) FROM ai_editing_state", [], |row| {
                    row.get(0)
                })?;
        assert_eq!(count, 0);
        Ok(())
    }
    fn snapshot() -> Value {
        json!({"assetID":Uuid::new_v4(),"captureTime":"2024-01-01T00:00:00Z","cameraMake":"Canon","cameraModel":"R3","lensModel":"50mm","originalFilename":"photo.jpg","contentFingerprint":"photo-hash","metadataFingerprint":"2024|Canon|R3|photo","rating":1,"flagState":"unflagged","tags":[],"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"})
    }
    #[test]
    fn capture_cursor_survives_inserts_removed_boundary_and_time_ties() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let insert = |id: &str, time: &str| -> Result<()> {
            let mut asset = snapshot();
            asset["id"] = json!(id);
            asset["captureTime"] = json!(time);
            store.lock()?.execute(
                "INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES ('lib',?,?, 'hash','fingerprint',?,'photo.jpg',1,'unflagged',NULL,0)",
                params![id, asset.to_string(), time],
            )?;
            store.lock()?.execute(
                "INSERT INTO catalog_paths VALUES('lib',?,?,'hash','jpeg_original')",
                params![format!("/photos/{id}.jpg"), id],
            )?;
            Ok(())
        };
        for (id, time) in [
            ("a", "2024-03"),
            ("b", "2024-02"),
            ("c", "2024-02"),
            ("d", "2024-01"),
        ] {
            insert(id, time)?;
        }
        let mut query = AssetQuery {
            limit: Some(2),
            ..Default::default()
        };
        let first = store.query_assets("lib", &query)?;
        assert_eq!(first["items"][0]["id"], "a");
        assert_eq!(first["items"][1]["id"], "b");
        query.cursor = first["nextCursor"].as_str().map(str::to_owned);
        insert("new", "2024-04")?;
        let after_insert = store.query_assets("lib", &query)?;
        assert_eq!(after_insert["items"][0]["id"], "c");
        assert_eq!(after_insert["items"][1]["id"], "d");
        // Removing both the boundary and an earlier result must not skip older photos.
        store
            .lock()?
            .execute("DELETE FROM catalog_assets WHERE id IN ('a','b')", [])?;
        let second = store.query_assets("lib", &query)?;
        assert_eq!(second["total"], 3);
        assert_eq!(second["items"].as_array().unwrap().len(), 2);
        assert_eq!(second["items"][0]["id"], "c");
        assert_eq!(second["items"][1]["id"], "d");
        assert!(second["nextCursor"].is_null());
        for cursor in ["-1", "bad", "cd1.invalid", "cd1.bnVsbA"] {
            query.cursor = Some(cursor.into());
            assert!(store.query_assets("lib", &query).is_err());
        }
        query.cursor = Some("1".into());
        query.limit = Some(1);
        let migrated = store.query_assets("lib", &query)?;
        assert_eq!(migrated["items"][0]["id"], "c");
        assert!(migrated["nextCursor"].as_str().unwrap().starts_with("cd1."));
        query.cursor = migrated["nextCursor"].as_str().map(str::to_owned);
        assert_eq!(store.query_assets("lib", &query)?["items"][0]["id"], "d");
        query.limit = Some(2);
        query.cursor = None;
        query.sort = Some("capture_asc".into());
        let ascending = store.query_assets("lib", &query)?;
        assert_eq!(ascending["nextCursor"], "2");
        query.cursor = Some("2".into());
        assert_eq!(store.query_assets("lib", &query)?["items"][0]["id"], "new");
        Ok(())
    }
    #[test]
    fn missing_reconciliation_respects_file_and_shallow_directory_scope() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let paths = [
            dir.path().join("first.jpg"),
            dir.path().join("second.jpg"),
            dir.path().join("child/nested.jpg"),
        ];
        for (index, path) in paths.iter().enumerate() {
            let hash = format!("hash-{index}");
            let file = json!({"contentHash":hash,"sizeBytes":5,"role":"jpeg_original"});
            let mut snap = snapshot();
            snap["contentFingerprint"] = json!(hash);
            store.ingest_original("lib", path.to_str().unwrap(), &file, &snap)?;
        }
        assert_eq!(
            store.mark_missing_scope_with_revision(
                "lib",
                paths[0].to_str().unwrap(),
                "file",
                None
            )?,
            1
        );
        assert_eq!(
            store.mark_missing_scope_with_revision(
                "lib",
                dir.path().to_str().unwrap(),
                "directory",
                None
            )?,
            1
        );
        assert_eq!(
            store.mark_missing_scope_with_revision(
                "lib",
                dir.path().to_str().unwrap(),
                "recursive",
                None
            )?,
            1
        );
        Ok(())
    }

    #[test]
    fn trusted_root_merges_unlocated_previous_asset_and_user_metadata() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let a = dir.path().join("a.jpg");
        let b = dir.path().join("b.jpg");
        std::fs::write(&a, b"first")?;
        std::fs::write(&b, b"second")?;
        let file = json!({"contentHash":"photo-hash","sizeBytes":5,"role":"jpeg_original"});
        let first = store.ingest_original("lib", a.to_str().unwrap(), &file, &snapshot())?;
        let other = json!({"contentHash":"second-hash","sizeBytes":6,"role":"jpeg_original"});
        let mut snap = snapshot();
        snap["contentFingerprint"] = json!("second-hash");
        snap["rating"] = json!(5);
        snap["tags"] = json!(["wedding"]);
        snap["colorLabel"] = json!("red");
        let second = store.ingest_original("lib", b.to_str().unwrap(), &other, &snap)?;
        assert_ne!(first, second);
        store.reconcile_cache()?;
        snap["originalDocumentID"] = json!(first);
        assert_eq!(
            store.ingest_original("lib", b.to_str().unwrap(), &other, &snap)?,
            first
        );
        let db = store.lock()?;
        assert!(existing(&db, "lib", &second)?.is_none());
        let merged = existing(&db, "lib", &first)?.unwrap();
        assert_eq!(merged["rating"], 5);
        assert_eq!(merged["tags"], json!(["wedding"]));
        assert_eq!(merged["identityMergedFrom"][0]["id"], second);
        assert_eq!(
            db.query_row(
                "SELECT asset_id FROM catalog_identity_aliases WHERE root_id=?",
                [&second],
                |r| r.get::<_, String>(0)
            )?,
            first
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM media_cache WHERE asset_id=?",
                [&second],
                |r| r.get::<_, i64>(0)
            )?,
            0
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM catalog_versions WHERE asset_id=?",
                [&first],
                |r| r.get::<_, i64>(0)
            )?,
            2
        );
        assert_eq!(std::fs::read(&a)?, b"first");
        assert_eq!(std::fs::read(&b)?, b"second");
        Ok(())
    }
    #[test]
    fn root_identity_joins_versions_and_preserves_existing_asset() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let a = dir.path().join("a.jpg");
        let b = dir.path().join("b.jpg");
        std::fs::write(&a, b"first")?;
        std::fs::write(&b, b"edited")?;
        let file = json!({"contentHash":"photo-hash","sizeBytes":5,"role":"jpeg_original"});
        let id = store.ingest_original("lib", a.to_str().unwrap(), &file, &snapshot())?;
        assert_eq!(store.root_id("lib", &id)?, id);
        let root = Uuid::new_v4().to_string();
        let mut snap = snapshot();
        snap["originalDocumentID"] = json!(root);
        assert_eq!(
            store.ingest_original("lib", a.to_str().unwrap(), &file, &snap)?,
            id
        );
        assert_eq!(store.root_id("lib", &id)?, root);
        let edited = json!({"contentHash":"edited-hash","sizeBytes":6,"role":"jpeg_original"});
        assert_eq!(
            store.ingest_original("lib", b.to_str().unwrap(), &edited, &snap)?,
            id
        );
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT count(*) FROM catalog_paths", [], |r| r
                    .get::<_, i64>(0))?,
            2
        );
        std::fs::remove_file(&a)?;
        store.ingest_original("lib", b.to_str().unwrap(), &edited, &snap)?;
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT count(*) FROM catalog_paths", [], |r| r
                    .get::<_, i64>(0))?,
            1
        );
        Ok(())
    }
    #[test]
    fn metadata_update_preserves_other_copy_of_original_hash() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let file = json!({"contentHash":"photo-hash","sizeBytes":5,"role":"jpeg_original"});
        let id = store.ingest_original("lib", "/a.jpg", &file, &snapshot())?;
        assert_eq!(
            store.ingest_original("lib", "/b.jpg", &file, &snapshot())?,
            id
        );
        store.with_identity_update("lib", "/a.jpg", "photo-hash", || {
            Ok(Some(("new-hash".into(), 9, "2".into())))
        })?;
        let db = store.lock()?;
        let old: String = db.query_row(
            "SELECT content_hash FROM catalog_paths WHERE path='/b.jpg'",
            [],
            |r| r.get(0),
        )?;
        assert_eq!(old, "photo-hash");
        assert_eq!(
            db.query_row("SELECT count(*) FROM catalog_versions", [], |r| r
                .get::<_, i64>(0))?,
            2
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM catalog_files WHERE content_hash='photo-hash'",
                [],
                |r| r.get::<_, i64>(0)
            )?,
            1
        );
        Ok(())
    }
    #[test]
    fn identity_metadata_update_keeps_ready_cache_and_defers_processing() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let file = json!({"contentHash":"photo-hash","sizeBytes":5,"role":"jpeg_original"});
        let id = store.ingest_original("lib", "/a.jpg", &file, &snapshot())?;
        store.lock()?.execute("INSERT INTO media_cache(library_id,asset_id,source_hash,spec,status,thumbnail,standard) VALUES('lib',?,'photo-hash','test','ready','{}',?)",params![id,json!({"path":"/a.jpg","version":"photo-hash","sizeBytes":5,"mtimeNs":"1"}).to_string()])?;
        for (task, path, completed) in [
            ("done", "/a.jpg", 1),
            ("other", "/copy.jpg", 1),
            ("cancelled", "/a.jpg", -1),
        ] {
            store.lock()?.execute("INSERT INTO remote_cache_tasks VALUES(?,'lib',?,'photo-hash','photo-hash',?,'worker',0,?)",params![task,id,path,completed])?;
        }
        assert!(
            store.with_identity_update("lib", "/a.jpg", "photo-hash", || Ok(Some((
                "new-hash".into(),
                9,
                "2".into()
            ))))?
        );
        let result: (String, String, String) = store.lock()?.query_row(
            "SELECT status,source_hash,json_extract(standard,'$.version') FROM media_cache",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )?;
        assert_eq!(
            result,
            ("ready".into(), "new-hash".into(), "new-hash".into())
        );
        let tasks = {
            let db = store.lock()?;
            let mut q =
                db.prepare("SELECT id,source_hash,input_hash FROM remote_cache_tasks ORDER BY id")?;
            q.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
        };
        assert_eq!(
            tasks,
            vec![
                ("cancelled".into(), "new-hash".into(), "new-hash".into()),
                ("done".into(), "new-hash".into(), "new-hash".into()),
                ("other".into(), "new-hash".into(), "photo-hash".into())
            ]
        );

        store
            .lock()?
            .execute("UPDATE media_cache SET status='processing'", [])?;
        assert!(
            !store.with_identity_update("lib", "/a.jpg", "new-hash", || panic!(
                "must not write a processing source"
            ))?
        );
        Ok(())
    }
    #[test]
    fn mixed_paths_remain_hidden_and_v1_migration_preserves_assets() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("db");
        let store = Store::open(&path, true)?;
        let file = json!({"contentHash":"photo-hash","sizeBytes":100,"role":"jpeg_original"});
        let asset = snapshot();
        let id = store.ingest_original("lib", "/private/photo.jpg", &file, &asset)?;
        // Preserve the historical cross-directory association without creating new ones.
        store.lock()?.execute(
            "INSERT INTO catalog_paths VALUES(?,?,?,?,?)",
            params![
                "lib",
                "/public/photo.jpg",
                id,
                "photo-hash",
                "jpeg_original"
            ],
        )?;
        assert_eq!(
            store.ingest_original("lib", "/public/photo.jpg", &file, &asset)?,
            id
        );
        store.set_hidden_directory("lib", "/private", true)?;
        let all = store.query_assets(
            "lib",
            &AssetQuery {
                show_hidden: Some(true),
                ..Default::default()
            },
        )?;
        assert_eq!(
            all["items"][0]["paths"],
            json!(["/private/photo.jpg", "/public/photo.jpg"])
        );
        assert_eq!(store.asset("lib", &id)?["paths"], all["items"][0]["paths"]);
        assert_eq!(
            store.query_assets(
                "lib",
                &AssetQuery {
                    directory: Some("/public".into()),
                    ..Default::default()
                }
            )?["total"],
            0
        );
        assert_eq!(
            store.query_assets(
                "lib",
                &AssetQuery {
                    directory: Some("/private".into()),
                    ..Default::default()
                }
            )?["total"],
            1
        );
        store.set_hidden_directory("lib", "/", true)?;
        assert_eq!(
            store.query_assets("lib", &AssetQuery::default())?["total"],
            0
        );
        assert_eq!(
            store.query_assets(
                "lib",
                &AssetQuery {
                    directory: Some("/private".into()),
                    ..Default::default()
                }
            )?["total"],
            1
        );
        drop(store);
        let db = Connection::open(&path)?;
        crate::revisions::remove_schema(&db)?;
        crate::edits::remove_schema(&db)?;
        db.execute_batch("DROP TABLE catalog_identity_roots; DROP TABLE catalog_identity_aliases; DROP TABLE catalog_hidden_directories; DROP TABLE catalog_versions; DROP TABLE catalog_version_paths; DROP TABLE catalog_defaults; PRAGMA user_version=1;")?;
        drop(db);
        assert!(Store::open(&path, false).is_err());
        let store = Store::open(&path, true)?;
        assert_eq!(store.counts("lib", false)?["all"], 1);
        assert_eq!(store.hidden_directories("lib")?, json!({"paths":[]}));
        drop(store);
        Store::open(&path, false)?;
        Ok(())
    }
    #[test]
    fn nas_commands_projection_and_idempotency() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(&dir.path().join("db"), true).unwrap();
        let file = json!({"contentHash":"photo-hash","sizeBytes":100,"role":"jpeg_original"});
        let id = store
            .ingest_original("lib", "/photos/photo.jpg", &file, &snapshot())
            .unwrap();
        assert_eq!(
            store
                .ingest_original("lib", "/photos/photo.jpg", &file, &snapshot())
                .unwrap(),
            id
        );
        assert_eq!(store.counts("lib", false).unwrap()["all"], 1);
        let result = store
            .patch_asset(
                "lib",
                &id,
                &json!({"rating":5,"flagState":"picked","tags":["旅行","北京"],"colorLabel":"red"}),
            )
            .unwrap();
        assert_eq!(result["rating"], 5);
        let before = store.asset("lib", &id).unwrap();
        store.patch_asset("lib", &id, &json!({"rating":5})).unwrap();
        assert_eq!(store.asset("lib", &id).unwrap(), before);
        let q = AssetQuery {
            tag: Some("北京".into()),
            min_rating: Some(4),
            ..Default::default()
        };
        assert_eq!(store.query_assets("lib", &q).unwrap()["total"], 1);
        store.set_trashed("lib", &id, true).unwrap();
        assert_eq!(store.counts("lib", false).unwrap()["trashed"], 1);
        assert_eq!(
            store.query_assets("lib", &AssetQuery::default()).unwrap()["total"],
            0
        );
        store.set_trashed("lib", &id, false).unwrap();
        assert!(store.patch_asset("lib", &id, &json!({"rating":6})).is_err());
        assert_eq!(store.asset("lib", &id).unwrap()["rating"], 5);
    }
    #[test]
    fn moved_legacy_original_preserves_imported_holder_identity() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let old = dir.path().join("old/photo.jpg");
        let new = dir.path().join("new/photo.jpg");
        std::fs::create_dir_all(old.parent().unwrap())?;
        std::fs::create_dir_all(new.parent().unwrap())?;
        std::fs::write(&old, b"same")?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let file = json!({"contentHash":"same","sizeBytes":4,"role":"jpeg_original"});
        let id = store.ingest_original("lib", old.to_str().unwrap(), &file, &snapshot())?;
        store
            .lock()?
            .execute("UPDATE catalog_files SET holder='legacy-mac'", [])?;
        store
            .lock()?
            .execute("DELETE FROM catalog_version_paths", [])?;
        std::fs::rename(&old, &new)?;
        assert_eq!(
            store.ingest_original("lib", new.to_str().unwrap(), &file, &snapshot())?,
            id
        );
        assert!(store.original_is_online("lib", new.to_str().unwrap(), "same")?);
        assert!(!store.original_is_online("lib", old.to_str().unwrap(), "same")?);
        assert_eq!(store.counts("lib", false)?["all"], 1);
        Ok(())
    }
    #[test]
    fn cross_directory_move_preserves_identity_and_default() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let old = dir.path().join("old/photo.jpg");
        let new = dir.path().join("new/photo.jpg");
        std::fs::create_dir_all(old.parent().unwrap())?;
        std::fs::create_dir_all(new.parent().unwrap())?;
        std::fs::write(&old, b"same")?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let file = json!({"contentHash":"same","sizeBytes":4,"role":"jpeg_original"});
        let id = store.ingest_original("lib", old.to_str().unwrap(), &file, &snapshot())?;
        store.patch_asset("lib", &id, &json!({"rating":5,"tags":["keep"]}))?;
        store.set_default_version("lib", &id, "same")?;
        store.declare_generated_preview("lib", &id, &json!({"role":"preview","fileObject":{},"objectRef":{"bucket":"local","key":"preview"},"pixelSize":{"width":10,"height":10}}))?;
        std::fs::rename(&old, &new)?;
        assert_eq!(
            store.ingest_original("lib", new.to_str().unwrap(), &file, &snapshot())?,
            id
        );
        assert_eq!(
            store.default_version("lib", &id)?.unwrap().path,
            new.to_str().unwrap()
        );
        assert_eq!(store.asset("lib", &id)?["rating"], 5);
        assert_eq!(store.asset("lib", &id)?["tags"], json!(["keep"]));
        assert!(!store.original_is_online("lib", old.to_str().unwrap(), "same")?);
        assert!(store.original_is_online("lib", new.to_str().unwrap(), "same")?);
        let db = store.lock()?;
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM derivative_objects WHERE asset_id=? AND role='preview'",
                params![id],
                |r| r.get::<_, i64>(0)
            )?,
            1
        );
        assert_eq!(
            db.query_row(
                "SELECT available FROM catalog_version_paths WHERE path=?",
                params![old.to_str().unwrap()],
                |r| r.get::<_, i64>(0)
            )?,
            0
        );
        assert_eq!(
            db.query_row(
                "SELECT user_selected FROM catalog_defaults WHERE asset_id=?",
                params![id],
                |r| r.get::<_, i64>(0)
            )?,
            1
        );
        Ok(())
    }

    #[test]
    fn cross_directory_live_copies_and_ambiguous_moves_stay_separate() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let file = json!({"contentHash":"same","sizeBytes":4,"role":"jpeg_original"});
        let mut ids = Vec::new();
        let mut paths = Vec::new();
        for name in ["a", "b"] {
            let path = dir.path().join(name).join("photo.jpg");
            std::fs::create_dir_all(path.parent().unwrap())?;
            std::fs::write(&path, b"same")?;
            ids.push(store.ingest_original("lib", path.to_str().unwrap(), &file, &snapshot())?);
            paths.push(path);
        }
        assert_ne!(ids[0], ids[1]);
        for path in paths {
            std::fs::remove_file(path)?;
        }
        let new = dir.path().join("c/photo.jpg");
        std::fs::create_dir_all(new.parent().unwrap())?;
        std::fs::write(&new, b"same")?;
        let id = store.ingest_original("lib", new.to_str().unwrap(), &file, &snapshot())?;
        assert!(!ids.contains(&id));
        assert_eq!(store.counts("lib", false)?["all"], 3);
        Ok(())
    }
    #[test]
    fn duplicate_paths_and_missing_restore_keep_one_asset() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let photos = dir.path().join("photos");
        std::fs::create_dir(&photos)?;
        let a = photos.join("one.jpg");
        let b = photos.join("two.jpg");
        std::fs::write(&a, b"same")?;
        std::fs::write(&b, b"same")?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let file = json!({"contentHash":"same","sizeBytes":4,"role":"jpeg_original"});
        let id = store.ingest_original("lib", a.to_str().unwrap(), &file, &snapshot())?;
        assert_eq!(
            store.ingest_original("lib", b.to_str().unwrap(), &file, &snapshot())?,
            id
        );
        assert!(store.original_is_online("lib", a.to_str().unwrap(), "same")?);
        std::fs::remove_file(&a)?;
        assert_eq!(
            store.mark_missing_under("lib", photos.to_str().unwrap())?,
            0
        );
        assert!(store.original_is_online("lib", b.to_str().unwrap(), "same")?);
        std::fs::remove_file(&b)?;
        assert_eq!(
            store.mark_missing_under("lib", photos.to_str().unwrap())?,
            1
        );
        assert_eq!(store.asset("lib", &id)?["paths"], json!([]));
        assert_eq!(
            store.query_assets("lib", &AssetQuery::default())?["items"],
            json!([])
        );
        assert_eq!(store.counts("lib", false)?["all"], 0);
        std::fs::write(&a, b"same")?;
        assert_eq!(
            store.ingest_original("lib", a.to_str().unwrap(), &file, &snapshot())?,
            id
        );
        assert!(store.original_is_online("lib", a.to_str().unwrap(), "same")?);
        assert_eq!(store.counts("lib", false)?["all"], 1);
        Ok(())
    }
}

#[cfg(test)]
mod directory_plan_tests {
    use super::*;

    #[test]
    fn missing_scope_queries_use_exact_or_bounded_path_index() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let db = store.lock()?;
        for scope in ["file", "directory", "recursive"] {
            let bindings = if scope == "file" {
                vec!["lib", "/photo/one.jpg"]
            } else {
                vec!["lib", "/photo/", "/photo0"]
            };
            let mut query = db.prepare(&format!(
                "EXPLAIN QUERY PLAN {}",
                missing_paths_query(scope)?
            ))?;
            let plan = query
                .query_map(rusqlite::params_from_iter(bindings), |row| {
                    row.get::<_, String>(3)
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let paths = plan
                .iter()
                .find(|step| step.contains("SEARCH p "))
                .expect("catalog path index search");
            assert!(paths.contains("library_id=?"), "{scope}: {plan:?}");
            if scope == "file" {
                assert!(paths.contains("path=?"), "{scope}: {plan:?}");
            } else {
                assert!(
                    paths.contains("path>?") && paths.contains("path<?"),
                    "{scope}: {plan:?}"
                );
            }
        }
        Ok(())
    }

    #[test]
    fn ordered_asset_paths_use_asset_lookup() -> Result<()> {
        let db = Connection::open_in_memory()?;
        db.execute_batch(SCHEMA)?;
        let plan = db
            .prepare(&format!("EXPLAIN QUERY PLAN {ASSET_PATHS}"))?
            .query_map(params!["photos", "asset"], |row| row.get::<_, String>(3))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        assert!(
            plan.iter().any(|step| step.contains("catalog_paths_asset")
                && step.contains("library_id=? AND asset_id=?")),
            "{plan:?}"
        );
        Ok(())
    }

    #[test]
    fn directory_asset_set_is_not_correlated_per_catalog_asset() -> Result<()> {
        let db = Connection::open_in_memory()?;
        db.execute_batch("CREATE TABLE catalog_assets(library_id TEXT,id TEXT,trashed INTEGER,PRIMARY KEY(library_id,id)); CREATE INDEX catalog_sort ON catalog_assets(library_id,trashed); CREATE TABLE catalog_paths(library_id TEXT,path TEXT,asset_id TEXT,PRIMARY KEY(library_id,path)); CREATE INDEX catalog_paths_asset ON catalog_paths(library_id,asset_id);")?;
        for suffix in [
            "f.path>=? AND f.path<?)",
            "f.path>=? AND f.path<? AND substr(f.path,7) NOT LIKE '%/%')",
        ] {
            let mut query = db.prepare(&format!("EXPLAIN QUERY PLAN SELECT count(*) FROM catalog_assets a WHERE a.library_id=? AND a.trashed=?{DIRECTORY_ASSET_SET}{suffix}"))?;
            let plan = query
                .query_map(
                    params!["photos", 0, "photos", "/photo/", "/photo0"],
                    |row| row.get::<_, String>(3),
                )?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            assert!(
                plan.iter().all(|step| !step.contains("CORRELATED")),
                "{plan:?}"
            );
            assert!(
                plan.iter().any(|step| step.contains("LIST SUBQUERY")),
                "{plan:?}"
            );
            assert!(
                plan.iter()
                    .any(|step| step.contains("path>?") && step.contains("path<?")),
                "{plan:?}"
            );
        }
        Ok(())
    }
}
