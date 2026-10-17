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

/// A file changes no directory siblings; only its ancestor pages can be new.
/// Caller serializes directory mutations with Jobs::directory_mutation.
pub fn refresh_file(
    store: &Store,
    jobs: &Jobs,
    library: &str,
    file: &std::path::Path,
) -> Result<()> {
    let roots = jobs
        .folders()?
        .into_iter()
        .filter(|folder| folder.active && folder.library_id == library)
        .map(|folder| std::path::PathBuf::from(folder.path))
        .collect::<Vec<_>>();
    let mut pages = BTreeMap::new();
    let mut current = file.parent();
    while let Some(path) = current {
        if path == jobs.root() || !roots.iter().any(|root| path.starts_with(root)) {
            break;
        }
        let key = path.to_str().context("directory path must be UTF-8")?;
        let page = match std::fs::symlink_metadata(path) {
            Ok(_) => Some(serde_json::to_string(&navigation(
                jobs,
                library,
                Some(key),
                &RootNames::new(),
            )?)?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => {
                return Err(error).with_context(|| format!("inspect directory {}", path.display()));
            }
        };
        pages.insert(key.to_owned(), page);
        current = path.parent();
    }
    pages.insert(
        String::new(),
        Some(serde_json::to_string(&navigation(
            jobs,
            library,
            None,
            &RootNames::new(),
        )?)?),
    );
    let mut db = store.lock()?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    for (path, page) in pages {
        use rusqlite::OptionalExtension;
        let previous: Option<String> = tx
            .query_row(
                "SELECT page_json FROM catalog_sync_navigation WHERE library_id=?1 AND path=?2",
                params![library, path],
                |row| row.get(0),
            )
            .optional()?;
        if previous == page {
            continue;
        }
        if let Some(page) = page {
            tx.execute("INSERT INTO catalog_sync_navigation(library_id,path,page_json) VALUES(?1,?2,?3) ON CONFLICT(library_id,path) DO UPDATE SET page_json=excluded.page_json", params![library,path,page])?;
        } else {
            tx.execute(
                "DELETE FROM catalog_sync_navigation WHERE library_id=?1 AND path=?2",
                params![library, path],
            )?;
        }
        dirty(&tx, library, &path)?;
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
    fn file_publication_discovers_ancestors_without_refreshing_unrelated_subtrees() -> Result<()> {
        let fixture = tempfile::tempdir()?;
        let root = fixture.path().join("originals");
        std::fs::create_dir_all(root.join("unrelated/child/deep"))?;
        let root = root.canonicalize()?;
        let jobs = Jobs::open(&fixture.path().join("jobs.sqlite"), &root)?;
        let store = Store::open(&fixture.path().join("catalog.sqlite"), true)?;
        jobs.add_folder("lib", root.to_str().unwrap())?;
        refresh(&store, &jobs, "lib")?;
        let unrelated_path = root.join("unrelated/child/deep");
        let unrelated = pages(&store.read()?, "lib")?[unrelated_path.to_str().unwrap()].clone();
        std::fs::create_dir(unrelated_path.join("new"))?;
        let photo = root.join("2024/trip/photo.ARW");
        std::fs::create_dir_all(photo.parent().unwrap())?;
        std::fs::write(&photo, b"photo fixture")?;
        refresh_file(&store, &jobs, "lib", &photo)?;
        let projected = pages(&store.read()?, "lib")?;
        assert!(projected.contains_key(photo.parent().unwrap().to_str().unwrap()));
        assert!(projected.contains_key(root.join("2024").to_str().unwrap()));
        assert_eq!(projected[""]["directories"][0]["hasChildren"], true);
        assert_eq!(projected[unrelated_path.to_str().unwrap()], unrelated);
        let revision = store.catalog_revision("lib", None, false)?;
        refresh_file(&store, &jobs, "lib", &photo)?;
        assert_eq!(revision, store.catalog_revision("lib", None, false)?);
        refresh(&store, &jobs, "lib")?;
        assert_ne!(
            pages(&store.read()?, "lib")?[unrelated_path.to_str().unwrap()],
            unrelated
        );
        Ok(())
    }

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
