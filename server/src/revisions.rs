//! Persisted catalog revisions. Capture writes in SQLite, publish once per transaction.
use crate::store::{Store, StoreError};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

const DIRECTORY_REVISION: &str =
    "SELECT revision FROM catalog_directory_revisions WHERE library_id=? AND path=?";
const LIBRARY_REVISION: &str = "SELECT revision FROM catalog_version_revision WHERE library_id=?";
const QUIET_SECONDS: i64 = 15 * 60;
const UPDATING: &str =
    "SELECT EXISTS(SELECT 1 FROM catalog_revision_updates WHERE library_id=? AND path=?)";

pub(crate) fn normalize_directory(path: &str) -> Result<&str> {
    if !path.starts_with('/')
        || path.contains('\0')
        || path.contains("//")
        || path.split('/').any(|part| part == "." || part == "..")
    {
        return Err(StoreError {
            status: 422,
            code: "invalid_directory".into(),
            message: "path must be an absolute normalized directory path".into(),
        }
        .into());
    }
    Ok(if path == "/" {
        path
    } else {
        path.trim_end_matches('/')
    })
}

fn ancestors(paths: &mut BTreeSet<String>, directory: &str) {
    for path in Path::new(directory).ancestors() {
        if path.is_absolute() {
            paths.insert(path.to_string_lossy().into_owned());
        }
    }
}

fn file_ancestors(paths: &mut BTreeSet<String>, file: &str) {
    if let Some(parent) = Path::new(file).parent() {
        ancestors(paths, &parent.to_string_lossy());
    }
}

fn write_directories(
    db: &Connection,
    lib: &str,
    paths: &BTreeSet<String>,
    revision: i64,
) -> Result<()> {
    let mut statement = db.prepare_cached("INSERT INTO catalog_directory_revisions(library_id,path,parent_path,revision) VALUES(?,?,?,?) ON CONFLICT(library_id,path) DO UPDATE SET revision=excluded.revision")?;
    for path in paths.iter().filter(|path| !path.is_empty()) {
        let parent = Path::new(path)
            .parent()
            .and_then(Path::to_str)
            .unwrap_or("");
        statement.execute(params![lib, path, parent, revision])?;
    }
    Ok(())
}

pub(crate) fn migrate(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE catalog_directory_revisions(library_id TEXT NOT NULL,path TEXT NOT NULL,parent_path TEXT NOT NULL,revision INTEGER NOT NULL,PRIMARY KEY(library_id,path));
        CREATE INDEX catalog_directory_revision_parent ON catalog_directory_revisions(library_id,parent_path,path);
        CREATE TABLE catalog_revision_dirty(library_id TEXT NOT NULL,kind TEXT NOT NULL,key TEXT NOT NULL,PRIMARY KEY(library_id,kind,key));")?;
    db.execute_batch("INSERT INTO catalog_version_revision(library_id,revision)
        SELECT library_id,0 FROM (SELECT library_id FROM catalog_assets UNION SELECT library_id FROM catalog_hidden_directories) WHERE true ON CONFLICT DO NOTHING;
        UPDATE catalog_version_revision SET revision=revision+1;")?;
    // Older clients combined the event sequence with the version revision.
    let legacy: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name='ledger_events')",
        [],
        |r| r.get(0),
    )?;
    if legacy {
        db.execute_batch("UPDATE catalog_version_revision SET revision=revision+coalesce((SELECT max(global_seq) FROM ledger_events WHERE ledger_events.library_id=catalog_version_revision.library_id),0);")?;
    }
    let libraries = db
        .prepare("SELECT library_id,revision FROM catalog_version_revision")?
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (lib, revision) in libraries {
        let mut paths = BTreeSet::new();
        let mut statement = db.prepare("SELECT path FROM catalog_paths WHERE library_id=?1 UNION SELECT path FROM catalog_version_paths WHERE library_id=?1")?;
        for path in statement.query_map([&lib], |r| r.get::<_, String>(0))? {
            file_ancestors(&mut paths, &path?);
        }
        let mut statement =
            db.prepare("SELECT path FROM catalog_hidden_directories WHERE library_id=?")?;
        for path in statement.query_map([&lib], |r| r.get::<_, String>(0))? {
            ancestors(&mut paths, &path?);
        }
        write_directories(db, &lib, &paths, revision)?;
    }
    install_triggers(db)
}

pub(crate) fn migrate_updates(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE catalog_revision_sequence(library_id TEXT PRIMARY KEY,value INTEGER NOT NULL);
        INSERT INTO catalog_revision_sequence SELECT library_id,revision FROM catalog_version_revision;
        CREATE TABLE catalog_revision_updates(library_id TEXT NOT NULL,path TEXT NOT NULL,owner TEXT NOT NULL,last_changed_at INTEGER NOT NULL,PRIMARY KEY(library_id,path,owner));
        CREATE INDEX catalog_revision_update_owner ON catalog_revision_updates(owner,last_changed_at,library_id,path);")?;
    Ok(())
}

fn install_triggers(db: &Connection) -> Result<()> {
    // Audit timestamps do not change cached representations.
    for (table, asset, columns, path) in [
        (
            "catalog_assets",
            "id",
            "library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed",
            false,
        ),
        (
            "catalog_files",
            "asset_id",
            "library_id,asset_id,content_hash,size,role,holder,availability",
            false,
        ),
        (
            "catalog_paths",
            "asset_id",
            "library_id,path,asset_id,content_hash,role",
            true,
        ),
        (
            "catalog_version_paths",
            "asset_id",
            "library_id,path,asset_id,content_hash,available",
            true,
        ),
        (
            "catalog_versions",
            "asset_id",
            "library_id,asset_id,content_hash,visual_hash,capture_key,width,height,priority,evidence",
            false,
        ),
        (
            "catalog_defaults",
            "asset_id",
            "library_id,asset_id,content_hash,user_selected",
            false,
        ),
        (
            "derivative_objects",
            "asset_id",
            "library_id,asset_id,role,file_object,object_bucket,object_key,object_etag,pixel_width,pixel_height",
            false,
        ),
    ] {
        let changed = columns
            .split(',')
            .map(|c| format!("OLD.{c} IS NOT NEW.{c}"))
            .collect::<Vec<_>>()
            .join(" OR ");
        for (event, sides) in [
            ("INSERT", vec!["NEW"]),
            ("DELETE", vec!["OLD"]),
            ("UPDATE", vec!["OLD", "NEW"]),
        ] {
            let mut body = String::new();
            for side in sides {
                body.push_str(&format!("INSERT INTO catalog_revision_dirty VALUES({side}.library_id,'asset',lower({side}.{asset})) ON CONFLICT DO NOTHING;"));
                if path {
                    body.push_str(&format!("INSERT INTO catalog_revision_dirty VALUES({side}.library_id,'path',{side}.path) ON CONFLICT DO NOTHING;"));
                }
            }
            let condition = if event == "UPDATE" {
                format!(" WHEN {changed}")
            } else {
                String::new()
            };
            db.execute_batch(&format!("CREATE TRIGGER catalog_revision_{table}_{event} AFTER {event} ON {table}{condition} BEGIN {body} END;"))?;
        }
    }
    for (event, sides) in [
        ("INSERT", vec!["NEW"]),
        ("DELETE", vec!["OLD"]),
        ("UPDATE", vec!["OLD", "NEW"]),
    ] {
        let body = sides.iter().map(|side| format!("INSERT INTO catalog_revision_dirty VALUES({side}.library_id,'hidden',{side}.path) ON CONFLICT DO NOTHING;")).collect::<String>();
        let condition = if event == "UPDATE" {
            " WHEN OLD.library_id IS NOT NEW.library_id OR OLD.path IS NOT NEW.path"
        } else {
            ""
        };
        db.execute_batch(&format!("CREATE TRIGGER catalog_revision_hidden_{event} AFTER {event} ON catalog_hidden_directories{condition} BEGIN {body} END;"))?;
    }
    Ok(())
}

/// Must run before the caller commits. Both captured changes and revisions roll back together.
pub(crate) fn flush(db: &Connection) -> Result<()> {
    flush_for_batch(db, None)
}

pub(crate) fn flush_for_batch(db: &Connection, batch: Option<&str>) -> Result<()> {
    flush_at(db, batch, chrono::Utc::now().timestamp())
}

fn flush_at(db: &Connection, batch: Option<&str>, now: i64) -> Result<()> {
    ensure!(
        !db.is_autocommit(),
        "catalog revision publication requires a transaction"
    );
    let dirty = db
        .prepare("SELECT library_id,kind,key FROM catalog_revision_dirty")?
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut libraries = BTreeMap::<String, BTreeSet<String>>::new();
    let mut assets = BTreeSet::new();
    for (lib, kind, key) in dirty {
        let paths = libraries.entry(lib.clone()).or_default();
        match kind.as_str() {
            "asset" => {
                assets.insert((lib, key));
            }
            "path" => file_ancestors(paths, &key),
            "navigation" => {
                if !key.is_empty() {
                    ancestors(paths, &key);
                }
            }
            "hidden" => {
                ancestors(paths, &key);
                let root = key.trim_end_matches('/');
                // One asset may have paths outside the newly hidden subtree.
                let mut statement = db.prepare_cached("SELECT DISTINCT asset_id FROM catalog_paths WHERE library_id=? AND path>=? AND path<?")?;
                for id in statement
                    .query_map(params![lib, format!("{root}/"), format!("{root}0")], |r| {
                        r.get::<_, String>(0)
                    })?
                {
                    assets.insert((lib.clone(), id?));
                }
            }
            _ => anyhow::bail!("unknown catalog revision change kind: {kind}"),
        }
    }
    let mut statement = db.prepare_cached("SELECT path FROM catalog_paths WHERE library_id=?1 AND asset_id=?2 UNION SELECT path FROM catalog_version_paths WHERE library_id=?1 AND asset_id=?2")?;
    for (lib, id) in &assets {
        let paths = libraries.get_mut(lib).context("missing changed library")?;
        for path in statement.query_map(params![lib, id], |r| r.get::<_, String>(0))? {
            file_ancestors(paths, &path?);
        }
    }
    for (lib, mut paths) in libraries {
        paths.insert(String::new()); // The empty scope is the library, separate from filesystem /.
        publish(db, &lib, &paths)?;
        crate::replicas::record_changes(db, &lib, &assets, now)?;
        if let Some(batch) = batch {
            record_activity(db, &lib, &paths, batch, now)?;
        } else {
            let mut statement = db.prepare_cached("UPDATE catalog_revision_updates SET last_changed_at=max(last_changed_at,?) WHERE library_id=? AND path=?")?;
            for path in paths {
                statement.execute(params![now, lib, path])?;
            }
        }
    }
    db.execute("DELETE FROM catalog_revision_dirty", [])?;
    Ok(())
}

fn publish(db: &Connection, lib: &str, paths: &BTreeSet<String>) -> Result<()> {
    if paths.is_empty() {
        return Ok(());
    }
    // All changed scopes share the same transaction publication.
    let revision: i64 = db.query_row("INSERT INTO catalog_revision_sequence VALUES(?1,coalesce((SELECT revision FROM catalog_version_revision WHERE library_id=?1),0)+1)
        ON CONFLICT(library_id) DO UPDATE SET value=max(value,excluded.value-1)+1 RETURNING value", [lib], |r| r.get(0))?;
    if paths.contains("") {
        db.execute("INSERT INTO catalog_version_revision VALUES(?,?) ON CONFLICT(library_id) DO UPDATE SET revision=excluded.revision", params![lib, revision])?;
    }
    write_directories(db, lib, paths, revision)
}

pub(crate) fn is_updating(db: &Connection, lib: &str, path: Option<&str>) -> Result<bool> {
    Ok(db.query_row(
        UPDATING,
        params![
            lib,
            path.map(normalize_directory).transpose()?.unwrap_or("")
        ],
        |r| r.get(0),
    )?)
}

fn record_activity(
    db: &Connection,
    lib: &str,
    paths: &BTreeSet<String>,
    owner: &str,
    now: i64,
) -> Result<()> {
    ensure!(!owner.is_empty(), "revision batch ID must not be empty");

    let mut touch = db.prepare_cached("INSERT INTO catalog_revision_updates VALUES(?,?,?,?) ON CONFLICT(library_id,path,owner) DO UPDATE SET last_changed_at=max(last_changed_at,excluded.last_changed_at)")?;
    for path in paths {
        touch.execute(params![lib, path, owner, now])?;
    }
    Ok(())
}

fn stable_scope_count(
    db: &Connection,
    candidates: BTreeMap<String, BTreeSet<String>>,
) -> Result<usize> {
    let mut count = 0;
    let mut check = db.prepare_cached(UPDATING)?;
    for (lib, paths) in candidates {
        let mut stable = BTreeSet::new();
        for path in paths {
            if !check.query_row(params![lib, path], |r| r.get::<_, bool>(0))? {
                stable.insert(path);
            }
        }
        count += stable.len();
    }
    Ok(count)
}

fn finish_batch(db: &Connection, owner: &str, wait_for_quiet: bool) -> Result<()> {
    ensure!(!owner.is_empty(), "revision batch ID must not be empty");
    let rows = db
        .prepare(
            "SELECT library_id,path,last_changed_at FROM catalog_revision_updates WHERE owner=?",
        )?
        .query_map([owner], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    db.execute(
        "DELETE FROM catalog_revision_updates WHERE owner=?",
        [owner],
    )?;
    let mut candidates = BTreeMap::<String, BTreeSet<String>>::new();
    for (lib, path, last_changed) in rows {
        if wait_for_quiet {
            // Empty owner means no live task remains; the last real change starts the quiet timer.
            db.execute("INSERT INTO catalog_revision_updates VALUES(?,?,'',?) ON CONFLICT(library_id,path,owner) DO UPDATE SET last_changed_at=max(last_changed_at,excluded.last_changed_at)", params![lib, path, last_changed])?;
        } else {
            candidates.entry(lib).or_default().insert(path);
        }
    }
    stable_scope_count(db, candidates)?;
    Ok(())
}

fn settle_at(db: &Connection, now: i64) -> Result<usize> {
    let cutoff = now - QUIET_SECONDS;
    let rows = db.prepare("SELECT library_id,path FROM catalog_revision_updates WHERE owner='' AND last_changed_at<=?")?
        .query_map([cutoff], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    db.execute(
        "DELETE FROM catalog_revision_updates WHERE owner='' AND last_changed_at<=?",
        [cutoff],
    )?;
    let mut candidates = BTreeMap::<String, BTreeSet<String>>::new();
    for (lib, path) in rows {
        candidates.entry(lib).or_default().insert(path);
    }
    stable_scope_count(db, candidates)
}

pub(crate) fn read(db: &Connection, lib: &str, path: Option<&str>) -> Result<i64> {
    Ok(if let Some(path) = path {
        db.query_row(
            DIRECTORY_REVISION,
            params![lib, normalize_directory(path)?],
            |r| r.get(0),
        )
        .optional()?
    } else {
        db.query_row(LIBRARY_REVISION, [lib], |r| r.get(0))
            .optional()?
    }
    .unwrap_or(0))
}

impl Store {
    /// A filesystem event marks only its scope and ancestors, without scanning photos.
    pub fn note_revision_activity(&self, lib: &str, batch_id: &str, directory: &str) -> Result<()> {
        let directory = normalize_directory(directory)?;
        let mut paths = BTreeSet::from([String::new()]);
        ancestors(&mut paths, directory);
        let mut connection = self.lock()?;
        let db = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        record_activity(&db, lib, &paths, batch_id, chrono::Utc::now().timestamp())?;
        db.commit()?;
        Ok(())
    }

    pub fn revision_batch_ids(&self) -> Result<Vec<String>> {
        let db = self.lock()?;
        Ok(db
            .prepare("SELECT DISTINCT owner FROM catalog_revision_updates WHERE owner<>''")?
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn finish_revision_batch(&self, batch_id: &str, wait_for_quiet: bool) -> Result<()> {
        let mut connection = self.lock()?;
        let db = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        finish_batch(&db, batch_id, wait_for_quiet)?;
        db.commit()?;
        Ok(())
    }

    pub fn settle_revision_updates(&self) -> Result<usize> {
        let mut connection = self.lock()?;
        let db = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let count = settle_at(&db, chrono::Utc::now().timestamp())?;
        db.commit()?;
        Ok(count)
    }

    pub fn library_revision(&self, lib: &str) -> Result<Value> {
        self.catalog_revision(lib, None, false)
    }

    /// Indexed catalog scopes, including retained revisions for removed paths; no filesystem I/O.
    pub fn catalog_revision(
        &self,
        lib: &str,
        path: Option<&str>,
        include_children: bool,
    ) -> Result<Value> {
        let path = path.map(normalize_directory).transpose()?;
        let mut connection = self.read()?;
        let db = connection.transaction()?;
        let generation = crate::replicas::state(&db, lib)?.map(|s| s.0);
        let mut result = json!({"revision":read(&db, lib, path)?, "generation":generation, "isUpdating":is_updating(&db, lib, path)?});
        if let Some(path) = path {
            result["path"] = json!(path);
        }
        if include_children {
            let mut statement = db.prepare("SELECT d.path,d.revision,EXISTS(SELECT 1 FROM catalog_revision_updates u WHERE u.library_id=d.library_id AND u.path=d.path) FROM catalog_directory_revisions d WHERE d.library_id=? AND d.parent_path=? ORDER BY d.path")?;
            result["children"] = json!(
                statement
                    .query_map(params![lib, path.unwrap_or("")], |r| Ok(
                        json!({"path":r.get::<_, String>(0)?,"revision":r.get::<_, i64>(1)?,"isUpdating":r.get::<_, bool>(2)?})
                    ))?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            );
        }
        db.commit()?;
        Ok(result)
    }
}

#[cfg(test)]
pub(crate) fn remove_schema(db: &Connection) -> Result<()> {
    let triggers = db.prepare("SELECT name FROM sqlite_schema WHERE type='trigger' AND (name LIKE 'catalog_revision_%' OR name LIKE 'catalog_sync_%')")?
        .query_map([], |r| r.get::<_, String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
    for trigger in triggers {
        db.execute_batch(&format!("DROP TRIGGER {trigger}"))?;
    }
    db.execute_batch("DROP TABLE catalog_directory_revisions; DROP TABLE catalog_revision_dirty; DROP TABLE IF EXISTS catalog_revision_sequence; DROP TABLE IF EXISTS catalog_revision_updates;")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::AssetQuery;
    use rusqlite::StatementStatus;

    fn seed(store: &Store, lib: &str, path: &str) -> Result<String> {
        store.ingest_original(
            lib,
            path,
            &json!({"contentHash":path,"sizeBytes":100,"role":"jpeg_original"}),
            &json!({"contentFingerprint":path,"metadataFingerprint":path,
                "cameraMake":"Canon","cameraModel":"R3","lensModel":"50mm",
                "originalFilename":"photo.jpg","rating":0,"flagState":"unflagged","tags":[],
                "createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"}),
        )
    }

    fn revision(store: &Store, lib: &str, path: Option<&str>) -> Result<i64> {
        Ok(store.catalog_revision(lib, path, false)?["revision"]
            .as_i64()
            .unwrap())
    }

    fn note_at(store: &Store, owner: &str, path: &str, now: i64) -> Result<()> {
        let mut connection = store.lock()?;
        let db = connection.transaction()?;
        let mut paths = BTreeSet::from([String::new()]);
        ancestors(&mut paths, path);
        record_activity(&db, "lib", &paths, owner, now)?;
        db.commit()?;
        Ok(())
    }

    fn settle(store: &Store, now: i64) -> Result<usize> {
        let mut connection = store.lock()?;
        let db = connection.transaction()?;
        let count = settle_at(&db, now)?;
        db.commit()?;
        Ok(count)
    }

    #[test]
    fn continuous_changes_publish_precise_versions_while_activity_is_independent() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let id = seed(&store, "lib", "/photos/summer/a.jpg")?;
        seed(&store, "lib", "/photos/winter/b.jpg")?;
        let initial = revision(&store, "lib", None)?;
        let sibling = revision(&store, "lib", Some("/photos/winter"))?;
        note_at(&store, "external", "/photos/summer", 100)?;
        let started = revision(&store, "lib", None)?;
        assert_eq!(started, initial);
        note_at(&store, "external", "/photos/summer", 200)?;
        {
            let mut connection = store.lock()?;
            let db = connection.transaction()?;
            db.execute("UPDATE catalog_assets SET rating=3,snapshot=json_set(snapshot,'$.rating',3) WHERE library_id='lib' AND id=?", [&id])?;
            flush_at(&db, Some("external"), 250)?;
            db.commit()?;
        }
        assert_eq!(revision(&store, "lib", None)?, started + 1);
        let page = store.query_assets(
            "lib",
            &AssetQuery {
                directory: Some("/photos/summer".into()),
                ..Default::default()
            },
        )?;
        assert_eq!(page["revision"], started + 1);
        assert_eq!(page["isUpdating"], true);
        assert_eq!(page["items"][0]["rating"], 3);
        store.finish_revision_batch("external", true)?;
        assert_eq!(settle(&store, 1149)?, 0);
        // A periodic scan with no actual difference must not restart the quiet window.
        {
            let mut connection = store.lock()?;
            let db = connection.transaction()?;
            db.execute("UPDATE catalog_assets SET rating=3,snapshot=json_set(snapshot,'$.rating',3) WHERE library_id='lib' AND id=?", [&id])?;
            flush_at(&db, Some("unchanged-scan"), 1149)?;
            db.commit()?;
        }
        assert!(store.revision_batch_ids()?.is_empty());
        assert_eq!(settle(&store, 1150)?, 4);
        assert_eq!(revision(&store, "lib", None)?, started + 1);
        assert_eq!(store.library_revision("lib")?["isUpdating"], false);
        assert_eq!(revision(&store, "lib", Some("/photos/winter"))?, sibling);
        assert_eq!(settle(&store, 2000)?, 0);
        note_at(&store, "next-burst", "/photos/summer", 2001)?;
        assert_eq!(revision(&store, "lib", None)?, started + 1);
        assert_eq!(store.library_revision("lib")?["isUpdating"], true);
        Ok(())
    }

    #[test]
    fn each_new_branch_invalidates_independently_and_foreground_edits_publish_immediately()
    -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let a = seed(&store, "lib", "/photos/a/a.jpg")?;
        seed(&store, "lib", "/photos/b/b.jpg")?;
        note_at(&store, "job-a", "/photos/a", 100)?;
        let root = revision(&store, "lib", None)?;
        note_at(&store, "job-b", "/photos/b", 200)?;
        assert_eq!(revision(&store, "lib", None)?, root);
        assert_eq!(revision(&store, "lib", Some("/photos/b"))?, root);
        store.finish_revision_batch("job-b", false)?;
        let stable_b = revision(&store, "lib", Some("/photos/b"))?;
        assert_eq!(
            store.catalog_revision("lib", Some("/photos/b"), false)?["isUpdating"],
            false
        );
        assert_eq!(store.library_revision("lib")?["isUpdating"], true);
        assert_eq!(revision(&store, "lib", None)?, root);
        store.patch_asset("lib", &a, &json!({"rating":5,"tags":["favorite"]}))?;
        let foreground = revision(&store, "lib", None)?;
        assert!(foreground > stable_b);
        assert_eq!(store.library_revision("lib")?["isUpdating"], true);
        assert_eq!(revision(&store, "lib", Some("/photos/b"))?, stable_b);
        store.finish_revision_batch("job-a", false)?;
        assert_eq!(revision(&store, "lib", None)?, foreground);
        assert_eq!(store.library_revision("lib")?["isUpdating"], false);
        assert_eq!(revision(&store, "lib", Some("/photos/b"))?, stable_b);
        store.finish_revision_batch("job-a", false)?;
        assert_eq!(revision(&store, "lib", None)?, foreground);
        Ok(())
    }

    #[test]
    fn queued_owners_and_quiet_windows_survive_restart_and_only_last_owner_can_settle() -> Result<()>
    {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("db");
        let store = Store::open(&path, true)?;
        note_at(&store, "job-a", "/photos/a", 100)?;
        note_at(&store, "job-b", "/photos/a", 200)?;
        let started = revision(&store, "lib", None)?;
        drop(store);
        let store = Store::open(&path, false)?;
        assert_eq!(store.revision_batch_ids()?, vec!["job-a", "job-b"]);
        assert_eq!(settle(&store, 10_000)?, 0);
        store.finish_revision_batch("job-a", false)?;
        assert_eq!(revision(&store, "lib", None)?, started);
        assert_eq!(store.library_revision("lib")?["isUpdating"], true);
        store.finish_revision_batch("job-b", true)?;
        drop(store);
        let store = Store::open(&path, false)?;
        assert!(store.revision_batch_ids()?.is_empty());
        assert_eq!(store.library_revision("lib")?["isUpdating"], true);
        assert_eq!(settle(&store, 1099)?, 0);
        assert_eq!(settle(&store, 1100)?, 4);
        assert_eq!(store.library_revision("lib")?["isUpdating"], false);
        assert_eq!(revision(&store, "lib", None)?, started);
        Ok(())
    }

    #[test]
    fn batched_imports_preview_and_missing_paths_use_the_same_update_window() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let file = json!({"contentHash":"hash","sizeBytes":100,"role":"jpeg_original"});
        let snapshot = json!({"contentFingerprint":"hash","metadataFingerprint":"hash","cameraMake":"Canon","cameraModel":"R3","lensModel":"50mm","originalFilename":"a.jpg","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"});
        let directory = dir.path().join("missing-fixture");
        let path = directory.join("a.jpg").to_string_lossy().into_owned();
        let id = store.ingest_original_with_revision(
            "lib",
            &path,
            &file,
            &snapshot,
            &Default::default(),
            Some("scan"),
        )?;
        let started = revision(&store, "lib", None)?;
        assert_eq!(store.library_revision("lib")?["isUpdating"], true);
        let preview = json!({"assetID":id,"role":"preview","fileObject":{"contentHash":"preview-hash","sizeBytes":100,"role":"preview"},"objectRef":{"bucket":"previews","key":"a.jpg"},"pixelSize":{"width":100,"height":100}});
        store.declare_preview_with_revision("lib", &id, Some("hash"), &preview, Some("scan"))?;
        store.mark_missing_under_with_revision("lib", directory.to_str().unwrap(), Some("scan"))?;
        assert_eq!(revision(&store, "lib", None)?, started + 2);
        store.finish_revision_batch("scan", false)?;
        assert_eq!(revision(&store, "lib", None)?, started + 2);
        assert_eq!(store.library_revision("lib")?["isUpdating"], false);
        Ok(())
    }

    #[test]
    fn rollback_does_not_publish_updating_and_schema_four_upgrade_preserves_stable_revision()
    -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("db");
        let store = Store::open(&path, true)?;
        seed(&store, "lib", "/photos/a.jpg")?;
        let old = revision(&store, "lib", None)?;
        {
            let mut connection = store.lock()?;
            let db = connection.transaction()?;
            let paths = BTreeSet::from([String::new(), "/".into(), "/photos".into()]);
            record_activity(&db, "lib", &paths, "rolled-back", 100)?;
            assert!(is_updating(&db, "lib", Some("/photos"))?);
        }
        assert_eq!(revision(&store, "lib", None)?, old);
        assert_eq!(store.library_revision("lib")?["isUpdating"], false);
        {
            let db = store.lock()?;
            crate::edits::remove_schema(&db)?;
            db.execute_batch("DROP TABLE catalog_revision_updates; DROP TABLE catalog_revision_sequence; DROP TABLE catalog_identity_roots; DROP TABLE catalog_identity_aliases; PRAGMA user_version=4;")?;
        }
        drop(store);
        assert!(Store::open(&path, false).is_err());
        let store = Store::open(&path, true)?;
        assert_eq!(revision(&store, "lib", None)?, old + 1);
        assert_eq!(
            store.catalog_revision("lib", Some("/photos"), false)?["isUpdating"],
            false
        );
        note_at(&store, "after-upgrade", "/photos", 200)?;
        assert_eq!(revision(&store, "lib", None)?, old + 1);
        Ok(())
    }

    #[test]
    fn populated_schema_five_upgrade_preserves_sequence_and_inflight_updates() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("db");
        let store = Store::open(&path, true)?;
        let id = seed(&store, "lib", "/photos/a.jpg")?;
        note_at(
            &store,
            "nas-scan-inflight",
            "/photos",
            chrono::Utc::now().timestamp(),
        )?;
        store.initialize_negative("lib", &id)?;
        let asset = store.asset("lib", &id)?;
        let versions = store.versions("lib", &id)?;
        let (sequence, updates) = {
            let db = store.lock()?;
            db.execute(
                "UPDATE catalog_revision_sequence SET value=12345 WHERE library_id='lib'",
                [],
            )?;
            let sequence = db.query_row(
                "SELECT value FROM catalog_revision_sequence WHERE library_id='lib'",
                [],
                |r| r.get::<_, i64>(0),
            )?;
            let updates=db.query_row("SELECT json_group_array(json_array(library_id,path,owner,last_changed_at)) FROM (SELECT * FROM catalog_revision_updates ORDER BY library_id,path,owner)",[],|r|r.get::<_,String>(0))?;
            crate::edits::remove_schema(&db)?;
            db.execute_batch("DROP TRIGGER photos_insert; DROP TRIGGER photos_update; DROP TRIGGER directories_insert; DROP TABLE photos; DROP TABLE videos; DROP TABLE directories; DROP TABLE media_cache_gc; DROP TABLE media_cache; DROP TABLE cache_runtime; DROP INDEX derivative_object_ref; DROP TABLE catalog_identity_roots; DROP TABLE catalog_identity_aliases; PRAGMA user_version=5;")?;
            assert!(db.prepare("SELECT * FROM media_cache").is_err());
            (sequence, updates)
        };
        drop(store);
        assert!(Store::open(&path, false).is_err());
        let store = Store::open(&path, true)?;
        assert_eq!(store.asset("lib", &id)?, asset);
        assert_eq!(store.versions("lib", &id)?, versions);
        {
            let db = store.lock()?;
            assert_eq!(
                db.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))?,
                21
            );
            assert_eq!(
                db.query_row(
                    "SELECT value FROM catalog_revision_sequence WHERE library_id='lib'",
                    [],
                    |r| r.get::<_, i64>(0)
                )?,
                sequence + 1
            );
            let after:String=db.query_row("SELECT json_group_array(json_array(library_id,path,owner,last_changed_at)) FROM (SELECT * FROM catalog_revision_updates ORDER BY library_id,path,owner)",[],|r|r.get(0))?;
            let before: serde_json::Value = serde_json::from_str(&updates)?;
            let after: serde_json::Value = serde_json::from_str(&after)?;
            assert_eq!(
                after.as_array().unwrap().len(),
                before.as_array().unwrap().len()
            );
            for (before, after) in before
                .as_array()
                .unwrap()
                .iter()
                .zip(after.as_array().unwrap())
            {
                assert_eq!(
                    &before.as_array().unwrap()[..3],
                    &after.as_array().unwrap()[..3]
                );
                assert!(after[3].as_i64() >= before[3].as_i64());
            }
            assert_eq!(
                db.query_row(
                    "SELECT count(*) FROM photos WHERE library_id='lib' AND id=?",
                    [&id],
                    |r| r.get::<_, i64>(0)
                )?,
                1
            );
            db.prepare("SELECT * FROM media_cache_gc")?;
        }
        drop(store);
        let store = Store::open(&path, false)?;
        assert_eq!(
            store.lock()?.query_row(
                "SELECT value FROM catalog_revision_sequence WHERE library_id='lib'",
                [],
                |r| r.get::<_, i64>(0)
            )?,
            sequence + 1
        );
        Ok(())
    }

    #[test]
    fn changes_publish_once_and_only_in_affected_ancestors() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        assert_eq!(revision(&store, "lib", None)?, 0);
        let id = seed(&store, "lib", "/photos/夏季/a.jpg")?;
        seed(&store, "lib", "/photos/winter/b.jpg")?;
        seed(&store, "other", "/photos/夏季/a.jpg")?;
        let before = revision(&store, "lib", None)?;
        let sibling = revision(&store, "lib", Some("/photos/winter"))?;
        let other = revision(&store, "other", None)?;
        store.patch_asset(
            "lib",
            &id,
            &json!({"rating":5,"flagState":"picked","tags":["a","b"]}),
        )?;
        assert_eq!(revision(&store, "lib", None)?, before + 1);
        for path in ["/", "/photos", "/photos/夏季"] {
            assert_eq!(revision(&store, "lib", Some(path))?, before + 1);
        }
        assert_eq!(revision(&store, "lib", Some("/photos/winter"))?, sibling);
        assert_eq!(revision(&store, "other", None)?, other);
        store.patch_asset("lib", &id, &json!({"rating":5,"tags":["b","a","a"]}))?;
        assert_eq!(revision(&store, "lib", None)?, before + 1);
        assert!(store.patch_asset("lib", &id, &json!({"rating":6})).is_err());
        assert_eq!(revision(&store, "lib", None)?, before + 1);
        let page = store.query_assets(
            "lib",
            &AssetQuery {
                directory: Some("/photos/夏季".into()),
                ..Default::default()
            },
        )?;
        assert_eq!(page["revision"], before + 1);
        assert_eq!(page["items"][0]["rating"], 5);
        store.set_trashed("lib", &id, true)?;
        let trashed = revision(&store, "lib", None)?;
        store.set_trashed("lib", &id, true)?;
        assert_eq!(revision(&store, "lib", None)?, trashed);
        store.set_trashed("lib", &id, false)?;
        assert_eq!(revision(&store, "lib", None)?, trashed + 1);
        Ok(())
    }

    #[test]
    fn rollback_restores_data_dirty_records_and_revisions() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let id = seed(&store, "lib", "/photos/a.jpg")?;
        let before = store.asset("lib", &id)?;
        let old = revision(&store, "lib", None)?;
        {
            let mut connection = store.lock()?;
            let db = connection.transaction()?;
            db.execute("UPDATE catalog_assets SET rating=5,snapshot=json_set(snapshot,'$.rating',5) WHERE library_id=? AND id=?", params!["lib",id])?;
            flush(&db)?;
            assert_eq!(read(&db, "lib", Some("/photos"))?, old + 1);
            // Drop the uncommitted transaction after publication.
        }
        assert_eq!(store.asset("lib", &id)?, before);
        assert_eq!(revision(&store, "lib", None)?, old);
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
    fn moving_and_removing_paths_invalidates_both_sides_and_retains_tombstones() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let database = dir.path().join("db");
        let store = Store::open(&database, true)?;
        seed(&store, "lib", "/photos/old/a.jpg")?;
        seed(&store, "lib", "/photos/sibling/b.jpg")?;
        let sibling = revision(&store, "lib", Some("/photos/sibling"))?;
        let old = revision(&store, "lib", None)?;
        {
            let mut connection = store.lock()?;
            let db = connection.transaction()?;
            for table in ["catalog_paths", "catalog_version_paths"] {
                db.execute(&format!("UPDATE {table} SET path='/photos/new/a.jpg' WHERE library_id='lib' AND path='/photos/old/a.jpg'"), [])?;
            }
            flush(&db)?;
            db.commit()?;
        }
        for path in ["/photos/old", "/photos/new", "/photos"] {
            assert_eq!(revision(&store, "lib", Some(path))?, old + 1);
        }
        assert_eq!(revision(&store, "lib", Some("/photos/sibling"))?, sibling);
        // Only an absent synthetic fixture path is removed from the catalog.
        store.mark_missing_under("lib", "/photos/new")?;
        let removed = revision(&store, "lib", Some("/photos/new"))?;
        assert_eq!(removed, old + 2);
        store.mark_missing_under("lib", "/photos/new")?;
        assert_eq!(revision(&store, "lib", Some("/photos/new"))?, removed);
        drop(store);
        let reopened = Store::open(&database, false)?;
        assert_eq!(revision(&reopened, "lib", Some("/photos/new"))?, removed);
        Ok(())
    }

    #[test]
    fn hiding_a_path_invalidates_all_aliases_but_not_unrelated_directories() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let id = seed(&store, "lib", "/private/a.jpg")?;
        seed(&store, "lib", "/unrelated/b.jpg")?;
        {
            let mut connection = store.lock()?;
            let db = connection.transaction()?;
            db.execute(
                "INSERT INTO catalog_paths VALUES('lib','/public/a.jpg',?,'hash','jpeg_original')",
                [&id],
            )?;
            flush(&db)?;
            db.commit()?;
        }
        let old = revision(&store, "lib", None)?;
        let unrelated = revision(&store, "lib", Some("/unrelated"))?;
        store.set_hidden_directory("lib", "/private", true)?;
        for path in ["/private", "/public"] {
            assert_eq!(revision(&store, "lib", Some(path))?, old + 1);
        }
        let query = AssetQuery {
            directory: Some("/public".into()),
            ..Default::default()
        };
        assert_eq!(store.query_assets("lib", &query)?["total"], 0);
        assert_eq!(revision(&store, "lib", Some("/unrelated"))?, unrelated);
        store.set_hidden_directory("lib", "/private", true)?;
        assert_eq!(revision(&store, "lib", None)?, old + 1);
        store.set_hidden_directory("lib", "/private", false)?;
        assert_eq!(revision(&store, "lib", Some("/public"))?, old + 2);
        assert_eq!(store.query_assets("lib", &query)?["total"], 1);
        Ok(())
    }

    #[test]
    fn preview_content_dimensions_and_removal_change_revision_but_retries_do_not() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let id = seed(&store, "lib", "/photos/a.jpg")?;
        let mut preview = json!({"assetID":id,"role":"preview","fileObject":{"contentHash":"preview-hash","sizeBytes":100,"role":"preview"},"objectRef":{"bucket":"previews","key":"a.jpg"},"pixelSize":{"width":100,"height":100}});
        store.declare_generated_preview("lib", &id, &preview)?;
        let old = revision(&store, "lib", None)?;
        store.declare_generated_preview("lib", &id, &preview)?;
        assert_eq!(revision(&store, "lib", None)?, old);
        preview["pixelSize"]["width"] = json!(200);
        store.declare_generated_preview("lib", &id, &preview)?;
        assert_eq!(revision(&store, "lib", Some("/photos"))?, old + 1);
        store.remove_derivative("lib", &id, "preview")?;
        assert_eq!(revision(&store, "lib", Some("/photos"))?, old + 2);
        store.remove_derivative("lib", &id, "preview")?;
        assert_eq!(revision(&store, "lib", None)?, old + 2);
        Ok(())
    }

    #[test]
    fn migration_preserves_data_and_monotonicity_then_replays_offline_changes_at_startup()
    -> Result<()> {
        let dir = tempfile::tempdir()?;
        let path = dir.path().join("db");
        let store = Store::open(&path, true)?;
        let id = seed(&store, "lib", "/photos/a.jpg")?;
        store.initialize_negative("lib", &id)?;
        let asset = store.asset("lib", &id)?;
        let versions = store.versions("lib", &id)?;
        let baseline;
        {
            let db = store.lock()?;
            remove_schema(&db)?;
            db.execute_batch(
                "DROP TABLE catalog_identity_roots; DROP TABLE catalog_identity_aliases;",
            )?;
            crate::edits::remove_schema(&db)?;
            db.pragma_update(None, "user_version", 3)?;
            baseline = db.query_row(
                "SELECT revision FROM catalog_version_revision WHERE library_id='lib'",
                [],
                |r| r.get::<_, i64>(0),
            )?;
        }
        drop(store);
        assert!(Store::open(&path, false).is_err());
        let store = Store::open(&path, true)?;
        assert_eq!(store.asset("lib", &id)?, asset);
        assert_eq!(store.versions("lib", &id)?, versions);
        assert_eq!(revision(&store, "lib", Some("/photos"))?, baseline + 2);
        drop(store);
        {
            let db = Connection::open(&path)?;
            db.execute("UPDATE catalog_assets SET rating=4,snapshot=json_set(snapshot,'$.rating',4) WHERE library_id='lib' AND id=?", [&id])?;
        }
        let store = Store::open(&path, false)?;
        assert_eq!(revision(&store, "lib", Some("/photos"))?, baseline + 3);
        assert_eq!(store.asset("lib", &id)?["rating"], 4);
        drop(store);
        let store = Store::open(&path, false)?;
        assert_eq!(revision(&store, "lib", None)?, baseline + 3);
        Ok(())
    }

    #[test]
    fn hundred_thousand_photos_use_indexed_revision_reads_and_one_batch_publication() -> Result<()>
    {
        let dir = tempfile::tempdir()?;
        let store = Store::open(&dir.path().join("db"), true)?;
        let mut connection = store.lock()?;
        let db = connection.transaction()?;
        db.execute_batch("WITH RECURSIVE n(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM n WHERE i<99999)
            INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) SELECT 'lib',printf('asset-%d',i),'{}','hash','fingerprint','2024','photo.jpg',0,'unflagged',NULL,0 FROM n;
            INSERT INTO catalog_paths SELECT 'lib',printf('/photos/%03d/%s.jpg',CAST(substr(id,7) AS INTEGER)/1000,id),id,'hash','jpeg_original' FROM catalog_assets;")?;
        flush(&db)?;
        assert_eq!(read(&db, "lib", None)?, 1);
        db.execute(
            "UPDATE catalog_assets SET rating=5 WHERE library_id='lib' AND id='asset-1234'",
            [],
        )?;
        flush(&db)?;
        assert_eq!(read(&db, "lib", Some("/photos/001"))?, 2);
        assert_eq!(read(&db, "lib", Some("/photos/002"))?, 1);
        for (sql, values) in [
            (LIBRARY_REVISION, vec!["lib"]),
            (DIRECTORY_REVISION, vec!["lib", "/photos/001"]),
        ] {
            let mut statement = db.prepare(sql)?;
            assert_eq!(
                statement.query_row(rusqlite::params_from_iter(&values), |r| r.get::<_, i64>(0))?,
                2
            );
            assert_eq!(statement.get_status(StatementStatus::FullscanStep), 0);
            assert!(statement.get_status(StatementStatus::VmStep) < 50);
            let plan = db
                .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))?
                .query_map(rusqlite::params_from_iter(&values), |r| {
                    r.get::<_, String>(3)
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            assert!(
                plan.iter()
                    .all(|step| step.contains("SEARCH") && step.contains("INDEX")),
                "{plan:?}"
            );
        }
        let changed: i64 = db.query_row("SELECT count(*) FROM catalog_directory_revisions WHERE library_id='lib' AND revision=2", [], |r| r.get(0))?;
        assert_eq!(changed, 3); // /, /photos and /photos/001, independent of photo count.
        let mut updating = db.prepare(UPDATING)?;
        assert!(!updating.query_row(params!["lib", "/photos/001"], |r| r.get::<_, bool>(0))?);
        assert_eq!(updating.get_status(StatementStatus::FullscanStep), 0);
        assert!(updating.get_status(StatementStatus::VmStep) < 50);
        drop(updating);
        db.commit()?;
        Ok(())
    }
}
