//! Persist directory structure at explicit mutation boundaries for pinned replica snapshots.
use crate::{
    jobs::Jobs,
    navigation::{RootNames, navigation},
    store::Store,
};
use anyhow::{Context, Result};
use rusqlite::{TransactionBehavior, params};
use serde_json::Value;
use std::collections::BTreeMap;

/// Caller serializes directory mutations with Jobs::directory_mutation.
pub fn refresh(store: &Store, jobs: &Jobs, library: &str) -> Result<()> {
    let mut pages = BTreeMap::new();
    let mut pending = vec![String::new()];
    while let Some(path) = pending.pop() {
        let page = navigation(
            jobs,
            library,
            (!path.is_empty()).then_some(path.as_str()),
            &RootNames::new(),
        )?;
        for child in page["directories"]
            .as_array()
            .context("navigation directories missing")?
        {
            pending.push(
                child["path"]
                    .as_str()
                    .context("navigation path missing")?
                    .to_owned(),
            );
        }
        pages.insert(path, serde_json::to_string(&page)?);
    }
    let mut db = store.lock()?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let previous = tx
        .prepare("SELECT path,page_json FROM catalog_sync_navigation WHERE library_id=?")?
        .query_map([library], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<BTreeMap<_, _>>>()?;
    for (path, page) in &pages {
        if previous.get(path) == Some(page) {
            continue;
        }
        tx.execute("INSERT INTO catalog_sync_navigation(library_id,path,page_json) VALUES(?1,?2,?3) ON CONFLICT(library_id,path) DO UPDATE SET page_json=excluded.page_json", params![library,path,page])?;
        dirty(&tx, library, path)?;
    }
    for path in previous.keys().filter(|path| !pages.contains_key(*path)) {
        tx.execute(
            "DELETE FROM catalog_sync_navigation WHERE library_id=?1 AND path=?2",
            params![library, path],
        )?;
        dirty(&tx, library, path)?;
    }
    crate::revisions::flush(&tx)?;
    tx.commit()?;
    Ok(())
}

fn dirty(db: &rusqlite::Connection, library: &str, path: &str) -> Result<()> {
    db.execute("INSERT INTO catalog_revision_dirty(library_id,kind,key) VALUES(?1,'navigation',?2) ON CONFLICT DO NOTHING",params![library,path])?;
    Ok(())
}

pub fn pages(db: &rusqlite::Connection, library: &str) -> Result<BTreeMap<String, Value>> {
    let rows = db
        .prepare(
            "SELECT path,page_json FROM catalog_sync_navigation WHERE library_id=? ORDER BY path",
        )?
        .query_map([library], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    rows.into_iter()
        .map(|(path, json)| Ok((path, serde_json::from_str(&json)?)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn projection_tracks_empty_directories_and_tracking_without_noop_versions() -> Result<()> {
        let fixture = tempfile::tempdir()?;
        let root = fixture.path().join("originals");
        std::fs::create_dir_all(root.join("branch/empty"))?;
        let root = root.canonicalize()?;
        let jobs = Jobs::open(&fixture.path().join("jobs.sqlite"), &root)?;
        let store = Store::open(&fixture.path().join("catalog.sqlite"), true)?;
        let folder = jobs.add_folder("lib", root.to_str().unwrap())?;
        refresh(&store, &jobs, "lib")?;
        let revision = store.catalog_revision("lib", None, false)?;
        refresh(&store, &jobs, "lib")?;
        assert_eq!(revision, store.catalog_revision("lib", None, false)?);
        let db = store.read()?;
        let initial = pages(&db, "lib")?;
        assert_eq!(initial.len(), 3);
        assert!(initial.contains_key(root.join("branch/empty").to_str().unwrap()));
        std::fs::rename(root.join("branch/empty"), root.join("renamed"))?;
        refresh(&store, &jobs, "lib")?;
        let moved = pages(&db, "lib")?;
        assert!(!moved.contains_key(root.join("branch/empty").to_str().unwrap()));
        assert!(moved.contains_key(root.join("renamed").to_str().unwrap()));
        assert_ne!(revision, store.catalog_revision("lib", None, false)?);
        std::fs::remove_dir(root.join("renamed"))?;
        refresh(&store, &jobs, "lib")?;
        assert!(!pages(&db, "lib")?.contains_key(root.join("renamed").to_str().unwrap()));
        jobs.remove_folder(&folder.id)?;
        refresh(&store, &jobs, "lib")?;
        let removed = pages(&db, "lib")?;
        assert_eq!(removed.len(), 1);
        assert_eq!(removed[""]["directories"], serde_json::json!([]));
        assert!(root.join("branch").is_dir());
        Ok(())
    }
}
