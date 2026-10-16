//! Bounded current-state synchronization, with acknowledgements per database replica.
use anyhow::Result;
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::BTreeSet;
use uuid::Uuid;

pub(crate) const LEASE_SECONDS: i64 = 30 * 24 * 60 * 60;

pub(crate) fn migrate(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS catalog_sync_navigation(library_id TEXT NOT NULL,path TEXT NOT NULL,page_json TEXT NOT NULL,PRIMARY KEY(library_id,path));
CREATE TABLE IF NOT EXISTS catalog_sync_state(library_id TEXT PRIMARY KEY,generation TEXT NOT NULL,floor INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS catalog_sync_assets(library_id TEXT NOT NULL,asset_id TEXT NOT NULL,revision INTEGER NOT NULL,deleted INTEGER NOT NULL,changed_at INTEGER NOT NULL,PRIMARY KEY(library_id,asset_id));
CREATE INDEX IF NOT EXISTS catalog_sync_assets_revision ON catalog_sync_assets(library_id,revision);
CREATE TABLE IF NOT EXISTS catalog_replicas(library_id TEXT NOT NULL,replica_id TEXT NOT NULL,generation TEXT NOT NULL,ack_revision INTEGER,delivered_revision INTEGER NOT NULL,expires_at INTEGER NOT NULL,PRIMARY KEY(library_id,replica_id));")?;
    let libs = db
        .prepare("SELECT library_id FROM catalog_version_revision")?
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for lib in libs {
        initialize(db, &lib)?;
    }
    db.execute_batch("INSERT OR IGNORE INTO catalog_sync_assets SELECT a.library_id,a.id,coalesce(v.revision,0),NOT EXISTS(SELECT 1 FROM catalog_paths p WHERE p.library_id=a.library_id AND p.asset_id=a.id),unixepoch() FROM catalog_assets a LEFT JOIN catalog_version_revision v ON v.library_id=a.library_id;")?;
    // These columns feed the mobile projection but were absent from the cache revision triggers.
    for (table, columns) in [
        (
            "media_cache",
            "source_hash,spec,status,thumbnail,standard,browse_thumbnail,browse_spec,browse_source_version",
        ),
        (
            "photo_edits",
            "negative_hash,standard,thumbnail,browse,recipe",
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
            let visible = if table == "media_cache" {
                match event {
                    "INSERT" => "NEW.status='ready'",
                    "DELETE" => "OLD.status='ready'",
                    _ => "(OLD.status='ready' OR NEW.status='ready')",
                }
            } else {
                "1"
            };
            let when = if event == "UPDATE" {
                format!(" WHEN ({changed}) AND {visible}")
            } else {
                format!(" WHEN {visible}")
            };
            let body=sides.iter().map(|side|format!("INSERT INTO catalog_revision_dirty VALUES({side}.library_id,'asset',lower({side}.asset_id)) ON CONFLICT DO NOTHING;")).collect::<String>();
            db.execute_batch(&format!("CREATE TRIGGER IF NOT EXISTS catalog_sync_{table}_{event} AFTER {event} ON {table}{when} BEGIN {body} END;"))?;
        }
    }
    db.execute_batch("CREATE TRIGGER IF NOT EXISTS catalog_sync_asset_negative AFTER UPDATE OF negative_hash ON catalog_assets WHEN OLD.negative_hash IS NOT NEW.negative_hash BEGIN INSERT INTO catalog_revision_dirty VALUES(NEW.library_id,'asset',lower(NEW.id)) ON CONFLICT DO NOTHING; END;")?;
    Ok(())
}
pub(crate) fn initialize(db: &Connection, lib: &str) -> Result<()> {
    db.execute(
        "INSERT OR IGNORE INTO catalog_sync_state VALUES(?,?,0)",
        params![lib, Uuid::new_v4().to_string()],
    )?;
    Ok(())
}
pub(crate) fn state(db: &Connection, lib: &str) -> Result<Option<(String, i64)>> {
    Ok(db
        .query_row(
            "SELECT generation,floor FROM catalog_sync_state WHERE library_id=?",
            [lib],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?)
}
pub(crate) fn record_changes(
    db: &Connection,
    lib: &str,
    assets: &BTreeSet<(String, String)>,
    now: i64,
) -> Result<()> {
    initialize(db, lib)?;
    let revision = crate::revisions::read(db, lib, None)?;
    let mut stmt=db.prepare_cached("INSERT INTO catalog_sync_assets VALUES(?1,?2,?3,NOT EXISTS(SELECT 1 FROM catalog_assets a JOIN catalog_paths p ON p.library_id=a.library_id AND p.asset_id=a.id WHERE a.library_id=?1 AND a.id=?2),?4) ON CONFLICT(library_id,asset_id) DO UPDATE SET revision=excluded.revision,deleted=excluded.deleted,changed_at=excluded.changed_at")?;
    for (_, id) in assets.iter().filter(|(library, _)| library == lib) {
        stmt.execute(params![lib, id, revision, now])?;
    }
    Ok(())
}
/// Cleanup runs inside a write transaction. floor survives tombstone removal.
pub(crate) fn prune(db: &Connection, lib: &str, now: i64) -> Result<()> {
    db.execute(
        "DELETE FROM catalog_replicas WHERE library_id=? AND expires_at<=?",
        params![lib, now],
    )?;
    let watermark:i64=db.query_row("SELECT coalesce(min(coalesce(ack_revision,0)),?2) FROM catalog_replicas WHERE library_id=?1",params![lib,crate::revisions::read(db,lib,None)?],|r|r.get(0))?;
    let floor:Option<i64>=db.query_row("SELECT max(revision) FROM catalog_sync_assets WHERE library_id=? AND deleted=1 AND (revision<=? OR changed_at<=?)",params![lib,watermark,now-LEASE_SECONDS],|r|r.get(0))?;
    if let Some(floor) = floor {
        db.execute(
            "UPDATE catalog_sync_state SET floor=max(floor,?) WHERE library_id=?",
            params![floor, lib],
        )?;
        db.execute(
            "DELETE FROM catalog_sync_assets WHERE library_id=? AND deleted=1 AND revision<=?",
            params![lib, floor],
        )?;
    }
    Ok(())
}
pub(crate) fn can_delta(
    db: &Connection,
    lib: &str,
    replica: &str,
    generation: &str,
    since: i64,
    now: i64,
) -> Result<bool> {
    let Some((current, floor)) = state(db, lib)? else {
        return Ok(false);
    };
    if generation != current || since < floor || since > crate::revisions::read(db, lib, None)? {
        return Ok(false);
    }
    Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM catalog_replicas WHERE library_id=? AND replica_id=? AND generation=? AND ack_revision IS NOT NULL AND ack_revision<=? AND delivered_revision>=? AND expires_at>?)",params![lib,replica,generation,since,since,now],|r|r.get(0))?)
}
pub(crate) fn delivered(
    db: &Connection,
    lib: &str,
    replica: &str,
    generation: &str,
    revision: i64,
    now: i64,
) -> Result<()> {
    db.execute("INSERT INTO catalog_replicas VALUES(?,?,?,NULL,?,?) ON CONFLICT(library_id,replica_id) DO UPDATE SET ack_revision=CASE WHEN catalog_replicas.generation=excluded.generation AND catalog_replicas.expires_at>?6 THEN catalog_replicas.ack_revision END,generation=excluded.generation,delivered_revision=max(CASE WHEN catalog_replicas.generation=excluded.generation THEN catalog_replicas.delivered_revision ELSE 0 END,excluded.delivered_revision),expires_at=excluded.expires_at",params![lib,replica,generation,revision,now+LEASE_SECONDS,now])?;
    Ok(())
}
fn require(valid: bool, message: &str) -> Result<()> {
    if valid {
        return Ok(());
    }
    Err(crate::store::StoreError {
        status: 409,
        code: "replica_rebuild_required".into(),
        message: message.into(),
    }
    .into())
}
pub(crate) fn acknowledge(
    db: &Connection,
    lib: &str,
    replica: &str,
    generation: &str,
    revision: i64,
    now: i64,
) -> Result<()> {
    let current = state(db, lib)?.map(|s| s.0);
    require(
        current.as_deref() == Some(generation),
        "replica generation is obsolete; rebuild required",
    )?;
    require(revision >= 0, "negative replica revision")?;
    let changed=db.execute("UPDATE catalog_replicas SET ack_revision=max(coalesce(ack_revision,0),?4),expires_at=?5 WHERE library_id=?1 AND replica_id=?2 AND generation=?3 AND delivered_revision>=?4 AND expires_at>?6",params![lib,replica,generation,revision,now+LEASE_SECONDS,now])?;
    require(
        changed == 1,
        "replica revision was not delivered or lease expired; rebuild required",
    )?;
    prune(db, lib, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Store;

    #[test]
    fn replica_ack_bootstrap_leases_generations_and_cleanup_are_safe() -> Result<()> {
        let root = tempfile::tempdir()?;
        let store = Store::open(&root.path().join("catalog"), true)?;
        let mut db = store.lock()?;
        let tx = db.transaction()?;
        initialize(&tx, "lib")?;
        tx.execute("INSERT INTO catalog_version_revision VALUES('lib',20)", [])?;
        let generation = state(&tx, "lib")?.unwrap().0;
        let now = 1000;
        assert!(!can_delta(&tx, "lib", "first", &generation, 0, now)?);
        assert!(acknowledge(&tx, "lib", "first", &generation, 0, now).is_err());
        delivered(&tx, "lib", "first", &generation, 10, now)?;
        assert!(!can_delta(&tx, "lib", "first", &generation, 10, now)?);
        assert!(acknowledge(&tx, "lib", "first", &generation, 11, now).is_err());
        acknowledge(&tx, "lib", "first", &generation, 10, now)?;
        delivered(&tx, "lib", "second", &generation, 20, now)?;
        acknowledge(&tx, "lib", "second", &generation, 20, now)?;
        assert!(can_delta(&tx, "lib", "first", &generation, 10, now)?);
        assert!(!can_delta(&tx, "lib", "first", "old-generation", 10, now)?);
        assert!(!can_delta(&tx, "lib", "first", &generation, 21, now)?);
        tx.execute(
            "INSERT INTO catalog_sync_assets VALUES('lib','deleted',15,1,?)",
            [now],
        )?;
        prune(&tx, "lib", now)?;
        assert_eq!(
            tx.query_row("SELECT count(*) FROM catalog_sync_assets", [], |r| r
                .get::<_, i64>(0))?,
            1
        );
        delivered(&tx, "lib", "first", &generation, 20, now)?;
        acknowledge(&tx, "lib", "first", &generation, 20, now)?;
        assert_eq!(state(&tx, "lib")?.unwrap().1, 15);
        assert_eq!(
            tx.query_row("SELECT count(*) FROM catalog_sync_assets", [], |r| r
                .get::<_, i64>(0))?,
            0
        );
        acknowledge(&tx, "lib", "first", &generation, 10, now)?;
        assert_eq!(
            tx.query_row(
                "SELECT ack_revision FROM catalog_replicas WHERE replica_id='first'",
                [],
                |r| r.get::<_, i64>(0)
            )?,
            20
        );
        assert!(!can_delta(&tx, "lib", "first", &generation, 10, now)?);
        assert!(!can_delta(
            &tx,
            "lib",
            "first",
            &generation,
            20,
            now + LEASE_SECONDS
        )?);
        assert!(acknowledge(&tx, "lib", "first", &generation, 20, now + LEASE_SECONDS).is_err());
        prune(&tx, "lib", now + LEASE_SECONDS)?;
        assert_eq!(
            tx.query_row("SELECT count(*) FROM catalog_replicas", [], |r| r
                .get::<_, i64>(0))?,
            0
        );
        tx.commit()?;
        Ok(())
    }

    #[test]
    fn tombstones_expire_even_when_active_replica_is_stalled() -> Result<()> {
        let root = tempfile::tempdir()?;
        let store = Store::open(&root.path().join("catalog"), true)?;
        let mut db = store.lock()?;
        let tx = db.transaction()?;
        initialize(&tx, "lib")?;
        tx.execute("INSERT INTO catalog_version_revision VALUES('lib',20)", [])?;
        let generation = state(&tx, "lib")?.unwrap().0;
        delivered(&tx, "lib", "slow", &generation, 10, 0)?;
        acknowledge(&tx, "lib", "slow", &generation, 10, 0)?;
        tx.execute(
            "INSERT INTO catalog_sync_assets VALUES('lib','deleted',15,1,0)",
            [],
        )?;
        acknowledge(&tx, "lib", "slow", &generation, 10, LEASE_SECONDS - 1)?;
        prune(&tx, "lib", LEASE_SECONDS)?;
        assert_eq!(state(&tx, "lib")?.unwrap().1, 15);
        assert!(!can_delta(
            &tx,
            "lib",
            "slow",
            &generation,
            10,
            LEASE_SECONDS
        )?);
        assert_eq!(
            tx.query_row("SELECT count(*) FROM catalog_replicas", [], |r| r
                .get::<_, i64>(0))?,
            1
        );
        Ok(())
    }

    #[test]
    fn schema_eighteen_requires_explicit_migration_and_seeds_existing_assets() -> Result<()> {
        let root = tempfile::tempdir()?;
        let path = root.path().join("catalog");
        let store = Store::open(&path, true)?;
        {
            let db = store.lock()?;
            db.execute_batch("INSERT INTO catalog_version_revision VALUES('lib',8); INSERT INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag,color,trashed) VALUES('lib','asset','{}','hash','hash','','a.jpg',0,'none',NULL,0); INSERT INTO catalog_paths VALUES('lib','/a.jpg','asset','hash','jpeg_original'); DELETE FROM catalog_revision_dirty; DROP TABLE catalog_sync_state; DROP TABLE catalog_sync_assets; DROP TABLE catalog_replicas; DROP TABLE catalog_sync_navigation; PRAGMA user_version=18;")?;
        }
        drop(store);
        assert!(Store::open(&path, false).is_err());
        let store = Store::open(&path, true)?;
        let db = store.lock()?;
        assert!(Uuid::parse_str(&state(&db, "lib")?.unwrap().0).is_ok());
        assert_eq!(
            db.query_row(
                "SELECT revision FROM catalog_sync_assets WHERE asset_id='asset'",
                [],
                |r| r.get::<_, i64>(0)
            )?,
            8
        );
        Ok(())
    }
}
