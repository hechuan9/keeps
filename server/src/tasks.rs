//! Worker activity and the two user-visible task summaries.
use crate::{jobs::Jobs, store::Store};
use anyhow::Result;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use std::collections::HashSet;

pub fn begin(jobs: &Jobs, library: &str, class: &str, photo: Option<&str>) -> Result<()> {
    jobs.db.lock().unwrap().execute("INSERT INTO worker_activity(id,library_id,work_class,current_photo,last_error,active) VALUES(1,?,?,?,NULL,1) ON CONFLICT(id) DO UPDATE SET library_id=excluded.library_id,work_class=excluded.work_class,current_photo=excluded.current_photo,last_error=NULL,active=1", params![library,class,photo])?;
    Ok(())
}
pub fn begin_photo(
    jobs: &Jobs,
    library: &str,
    class: &str,
    photo: &std::path::Path,
    paths: &[std::path::PathBuf],
) -> Result<()> {
    let mut db = jobs.db.lock().unwrap();
    let tx = db.transaction()?;
    tx.execute("INSERT INTO worker_activity(id,library_id,work_class,current_photo,last_error,active) VALUES(1,?,?,?,NULL,1) ON CONFLICT(id) DO UPDATE SET library_id=excluded.library_id,work_class=excluded.work_class,current_photo=excluded.current_photo,last_error=NULL,active=1",params![library,class,photo.to_str()])?;
    tx.execute("DELETE FROM worker_photo_files", [])?;
    for path in paths {
        tx.execute("INSERT INTO worker_photo_files VALUES(?)", [path.to_str()])?;
    }
    tx.commit()?;
    Ok(())
}
pub fn finish(jobs: &Jobs, error: Option<&str>) -> Result<()> {
    let mut db = jobs.db.lock().unwrap();
    let tx = db.transaction()?;
    tx.execute("DELETE FROM worker_photo_files", [])?;
    tx.execute(
        "UPDATE worker_activity SET current_photo=NULL,last_error=?,active=0 WHERE id=1",
        [error],
    )?;
    tx.commit()?;
    Ok(())
}
/// An interrupted unit cannot use the incremental file-state shortcut on restart.
pub fn recover(jobs: &Jobs) -> Result<()> {
    let current: Option<String> = {
        let db = jobs.db.lock().unwrap();
        db.query_row(
            "SELECT current_photo FROM worker_activity WHERE id=1 AND active=1 AND work_class='manual'",
            [],
            |r| r.get::<_, Option<String>>(0),
        )
        .optional()?
        .flatten()
    };
    if let Some(path) = current
        && let Some(folder) = jobs
            .folders()?
            .into_iter()
            .filter(|f| f.active && std::path::Path::new(&path).starts_with(&f.path))
            .max_by_key(|f| f.path.len())
    {
        jobs.enqueue_operation_file(&folder.id, std::path::Path::new(&path), 0)?;
    }
    let mut db = jobs.db.lock().unwrap();
    let tx = db.transaction()?;
    tx.execute(
        "DELETE FROM files WHERE EXISTS(SELECT 1 FROM worker_activity WHERE id=1 AND active=1 AND work_class='manual') AND (path IN (SELECT path FROM worker_photo_files) OR path=(SELECT current_photo FROM worker_activity WHERE id=1))",
        [],
    )?;
    tx.execute("DELETE FROM worker_photo_files", [])?;
    tx.execute("DELETE FROM worker_activity", [])?;
    tx.commit()?;
    Ok(())
}

#[derive(serde::Deserialize)]
struct TaskCursor {
    pending: Vec<std::path::PathBuf>,
    current: Option<std::path::PathBuf>,
    last_name: Option<String>,
}

struct TaskScope {
    path: String,
    kind: String,
    state: String,
    error: Option<String>,
    class: String,
    cursor: Option<TaskCursor>,
    processed: i64,
    failed: i64,
    current_path: Option<String>,
}

fn photo_key(path: &str) -> String {
    let path = std::path::Path::new(path);
    format!(
        "path:{}/{}",
        path.parent().unwrap_or(path).display(),
        path.file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .to_ascii_lowercase()
    )
}

impl TaskScope {
    fn remaining(&self, path: &str) -> bool {
        let Some(cursor) = &self.cursor else {
            return true;
        };
        let path = std::path::Path::new(path);
        if cursor
            .pending
            .iter()
            .any(|directory| path.starts_with(directory))
        {
            return true;
        }
        path.parent() == cursor.current.as_deref()
            && cursor.last_name.as_ref().is_none_or(|last| {
                path.file_name()
                    .is_some_and(|name| name.to_string_lossy().as_ref() > last.as_str())
            })
    }

    fn photo_ids(&self, db: &rusqlite::Connection, library: &str) -> Result<HashSet<String>> {
        if self.kind == "file" {
            let id: Option<String> = db
                .query_row(
                    "SELECT asset_id FROM catalog_paths WHERE library_id=? AND path=?",
                    params![library, self.path],
                    |r| r.get(0),
                )
                .optional()?;
            return Ok(HashSet::from([id.unwrap_or_else(|| photo_key(&self.path))]));
        }
        let prefix = format!("{}/", self.path.trim_end_matches('/'));
        let mut q=db.prepare("SELECT asset_id,path FROM catalog_paths WHERE library_id=?1 AND path>=?2 AND path<?3 AND (?4='recursive' OR instr(substr(path,length(?2)+1),'/')=0)")?;
        let rows = q
            .query_map(
                params![
                    library,
                    prefix,
                    format!("{}0", self.path.trim_end_matches('/')),
                    self.kind
                ],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut remaining = HashSet::new();
        let mut completed = HashSet::new();
        for (id, path) in rows {
            if self.remaining(&path) {
                remaining.insert(id);
            } else {
                completed.insert(id);
            }
        }
        // A completed version marks the whole photo group complete, including later filenames.
        remaining.retain(|id| !completed.contains(id));
        Ok(remaining)
    }
}

pub fn status(store: &Store, jobs: &Jobs, library: &str) -> Result<Value> {
    let (scopes, activity) = {
        let db = jobs.db.lock().unwrap();
        let mut q=db.prepare("SELECT COALESCE(j.scope_path,f.path),j.scope_kind,j.status,j.error,j.work_class,j.checkpoint,j.processed,j.failed,j.current_path FROM jobs j JOIN folders f ON f.id=j.folder_id WHERE f.library_id=? AND f.active=1 AND j.status IN ('pending','running','failed') ORDER BY j.updated_at DESC")?;
        let rows = q
            .query_map([library], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, Option<String>>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, i64>(7)?,
                    r.get::<_, Option<String>>(8)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let scopes = rows
            .into_iter()
            .map(
                |(path, kind, state, error, class, checkpoint, processed, failed, current_path)| {
                    Ok(TaskScope {
                        path,
                        kind,
                        state,
                        error,
                        class,
                        processed,
                        failed,
                        current_path,
                        cursor: checkpoint.map(|c| serde_json::from_str(&c)).transpose()?,
                    })
                },
            )
            .collect::<Result<Vec<_>>>()?;
        let activity: Option<(String,Option<String>,Option<String>,bool)>=db.query_row("SELECT work_class,current_photo,last_error,active FROM worker_activity WHERE id=1 AND library_id=?",[library],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
        (scopes, activity)
    };
    let mut pending = HashSet::new();
    let mut failed = HashSet::new();
    let mut error = None;
    let identity = jobs.identity_status(library)?;
    let (gc_pending, gc_failed, gc_error, runtime_error) = {
        let mut connection = store.read()?;
        let db = connection.transaction()?;
        let mut manual = HashSet::new();
        for scope in scopes
            .iter()
            .filter(|j| j.class == "manual" && j.state != "failed")
        {
            manual.extend(scope.photo_ids(&db, library)?);
        }
        let mut q=db.prepare("SELECT c.asset_id,c.status,c.last_error FROM media_cache c JOIN catalog_assets a ON a.library_id=c.library_id AND a.id=c.asset_id WHERE c.library_id=? AND a.trashed=0 AND c.status IN ('pending','processing','failed')")?;
        for row in q.query_map([library], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        })? {
            let (id, state, e) = row?;
            if manual.contains(&id) {
                continue;
            }
            if state == "failed" {
                failed.insert(id);
            } else {
                pending.insert(id);
            }
            if error.is_none() {
                error = e;
            }
        }
        for scope in scopes.iter().filter(|j| j.class == "automatic") {
            let ids = scope.photo_ids(&db, library)?;
            if scope.state == "failed" {
                failed.extend(ids);
            } else {
                pending.extend(ids);
            }
            if error.is_none() {
                error = scope.error.clone();
            }
        }
        // A retry supersedes an older terminal failure for the same logical photo.
        failed.retain(|id| !pending.contains(id));
        let counts:(i64,i64)=db.query_row("SELECT count(*) FILTER(WHERE attempts<4),count(*) FILTER(WHERE attempts>=4) FROM media_cache_gc WHERE library_id=?",[library],|r|Ok((r.get(0)?,r.get(1)?)))?;
        let gc_error:Option<String>=db.query_row("SELECT last_error FROM media_cache_gc WHERE library_id=? AND last_error IS NOT NULL ORDER BY not_before DESC LIMIT 1",[library],|r|r.get(0)).optional()?;
        let runtime: Option<String> = if activity.as_ref().is_some_and(|a| a.0 == "maintenance") {
            db.query_row("SELECT last_error FROM cache_runtime WHERE id=1", [], |r| {
                r.get(0)
            })?
        } else {
            None
        };
        (counts.0, counts.1, gc_error, runtime)
    };
    let automatic_active = activity.as_ref().is_some_and(|a| a.0 == "automatic" && a.3);
    let current = activity
        .as_ref()
        .filter(|a| a.0 == "automatic" && a.3)
        .and_then(|a| a.1.clone());
    let automatic_status = if automatic_active {
        "running"
    } else if !pending.is_empty()
        || scopes
            .iter()
            .any(|j| j.class == "automatic" && j.state != "failed")
    {
        "pending"
    } else if !failed.is_empty()
        || scopes
            .iter()
            .any(|j| j.class == "automatic" && j.state == "failed")
    {
        "failed"
    } else {
        "idle"
    };
    let maintenance_error = identity["errors"]
        .as_array()
        .and_then(|errors| errors.first())
        .and_then(|e| e["error"].as_str())
        .map(str::to_owned)
        .or(gc_error)
        .or(runtime_error);
    let maintenance_failed = identity["failed"].as_i64().unwrap_or(0) > 0
        || gc_failed > 0
        || maintenance_error.is_some();
    let maintenance_pending = identity["pending"].as_i64().unwrap_or(0) > 0 || gc_pending > 0;
    let active = activity.as_ref().filter(|a| a.0 != "automatic" && a.3);
    let waiting = scopes
        .iter()
        .find(|j| j.class != "automatic" && j.state != "failed");
    let failed_job = scopes
        .iter()
        .find(|j| j.class != "automatic" && j.state == "failed");
    let activity_error = activity
        .as_ref()
        .filter(|a| a.0 != "automatic" && a.2.is_some());
    let (long_status, kind, long_error) = if let Some(a) = active {
        (
            "running",
            Some(a.0.clone()),
            a.2.clone().or(maintenance_error),
        )
    } else if let Some(j) = failed_job {
        ("failed", Some(j.class.clone()), j.error.clone())
    } else if let Some(a) = activity_error {
        ("failed", Some(a.0.clone()), a.2.clone())
    } else if maintenance_failed {
        ("failed", Some("maintenance".into()), maintenance_error)
    } else if let Some(j) = waiting {
        ("pending", Some(j.class.clone()), j.error.clone())
    } else if maintenance_pending {
        ("pending", Some("maintenance".into()), None)
    } else {
        ("idle", None, None)
    };
    let current_scope = if active.is_some() {
        scopes
            .iter()
            .find(|scope| scope.state == "running" && Some(&scope.class) == kind.as_ref())
    } else if long_status == "failed" {
        failed_job.filter(|scope| Some(&scope.class) == kind.as_ref())
    } else {
        waiting
    };
    let long_current = active.and_then(|activity| activity.1.clone()).or_else(|| {
        current_scope
            .filter(|scope| scope.state == "running")
            .and_then(|scope| scope.current_path.clone())
    });
    let mut result = json!({"automatic":{"status":automatic_status,"currentPhoto":current,"remainingPhotos":pending.len(),"failedPhotos":failed.len(),"error":error},"longTask":{"status":long_status,"kind":kind,"error":long_error,"path":current_scope.map(|scope| &scope.path),"currentPhoto":long_current,"processed":current_scope.map(|scope| scope.processed),"failed":current_scope.map(|scope| scope.failed)}});
    if let Some(cleanup) = crate::rejected_trash::cleanup_status(jobs, library)?
        && (cleanup["status"] != "failed" || long_status == "idle")
    {
        result["longTask"] = cleanup;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> Result<(tempfile::TempDir, Store, Jobs, crate::jobs::Folder)> {
        let dir = tempfile::tempdir()?;
        let originals = dir.path().join("originals");
        std::fs::create_dir(&originals)?;
        let store = Store::open(&dir.path().join("catalog"), true)?;
        let jobs = Jobs::open(&dir.path().join("jobs"), &originals)?;
        let folder = jobs.add_folder("lib", ".")?;
        Ok((dir, store, jobs, folder))
    }

    fn photo(store: &Store, jobs: &Jobs, library: &str, name: &str, id: &str) -> Result<()> {
        let path = jobs.root().join(name);
        let db = store.lock()?;
        db.execute("INSERT OR IGNORE INTO catalog_assets(library_id,id,snapshot,content_hash,fingerprint,sort_time,filename,rating,flag) VALUES(?,?,'{}',?,'meta','2026',?,0,'unflagged')",params![library,id,id,name])?;
        db.execute(
            "INSERT INTO catalog_paths VALUES(?,?,?,?,'jpeg_original')",
            params![library, path.to_str(), id, id],
        )?;
        Ok(())
    }

    #[test]
    fn interrupted_automatic_photo_is_not_requeued_or_invalidated() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let originals = dir.path().join("originals");
        std::fs::create_dir(&originals)?;
        let path = originals.join("photo.jpg");
        std::fs::write(&path, b"original")?;
        let jobs = Jobs::open(&dir.path().join("jobs"), &originals)?;
        let folder = jobs.add_folder("lib", ".")?;
        jobs.record_file(
            &folder.id,
            path.to_str().unwrap(),
            8,
            1,
            "asset",
            "hash",
            None,
        )?;
        begin_photo(
            &jobs,
            "lib",
            "automatic",
            &path,
            std::slice::from_ref(&path),
        )?;
        recover(&jobs)?;
        assert!(jobs.claim_class("manual")?.is_none());
        assert!(jobs.claim_class("automatic")?.is_none());
        assert!(
            jobs.file_state(&folder.id, path.to_str().unwrap())?
                .is_some()
        );
        Ok(())
    }

    #[test]
    fn interrupted_photo_restarts_all_members_but_preserves_completed_photos() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let originals = dir.path().join("originals");
        std::fs::create_dir(&originals)?;
        for name in ["pair.jpg", "pair.heic", "complete.jpg"] {
            std::fs::write(originals.join(name), b"original")?;
        }
        let jobs_path = dir.path().join("jobs");
        let jobs = Jobs::open(&jobs_path, &originals)?;
        let folder = jobs.add_folder("lib", ".")?;
        let paths: Vec<_> = ["pair.jpg", "pair.heic"]
            .iter()
            .map(|n| jobs.root().join(n))
            .collect();
        let complete = jobs.root().join("complete.jpg");
        for path in paths.iter().chain([&complete]) {
            jobs.record_file(
                &folder.id,
                path.to_str().unwrap(),
                8,
                1,
                "asset",
                "hash",
                None,
            )?;
        }
        begin_photo(&jobs, "lib", "manual", &paths[0], &paths)?;
        drop(jobs);
        let jobs = Jobs::open(&jobs_path, &originals)?;
        recover(&jobs)?;
        for path in &paths {
            assert!(
                jobs.file_state(&folder.id, path.to_str().unwrap())?
                    .is_none()
            );
            assert_eq!(std::fs::read(path)?, b"original");
        }
        assert!(
            jobs.file_state(&folder.id, complete.to_str().unwrap())?
                .is_some()
        );
        assert_eq!(
            jobs.claim_class("manual")?.unwrap().path,
            paths[0].to_str().unwrap()
        );
        begin_photo(&jobs, "lib", "automatic", &paths[0], &paths)?;
        for path in &paths {
            jobs.record_file(
                &folder.id,
                path.to_str().unwrap(),
                8,
                1,
                "asset",
                "hash",
                None,
            )?;
        }
        finish(&jobs, None)?;
        recover(&jobs)?;
        for path in &paths {
            assert!(
                jobs.file_state(&folder.id, path.to_str().unwrap())?
                    .is_some()
            );
        }
        Ok(())
    }

    #[test]
    fn checkpoint_reduces_photo_count_and_versions_are_one_photo() -> Result<()> {
        let (_dir, store, jobs, folder) = setup()?;
        photo(&store, &jobs, "lib", "a.jpg", "one")?;
        photo(&store, &jobs, "lib", "a.raw", "one")?;
        photo(&store, &jobs, "lib", "b.jpg", "two")?;
        let job = jobs.enqueue_directory_change(&folder.id, jobs.root(), 0)?;
        assert_eq!(
            status(&store, &jobs, "lib")?["automatic"]["remainingPhotos"],
            2
        );
        jobs.db.lock().unwrap().execute(
            "UPDATE jobs SET checkpoint=? WHERE id=?",
            params![
                json!({"pending":[],"current":jobs.root(),"last_name":"a.jpg"}).to_string(),
                job.id
            ],
        )?;
        assert_eq!(
            status(&store, &jobs, "lib")?["automatic"]["remainingPhotos"],
            1
        );
        jobs.db.lock().unwrap().execute(
            "UPDATE jobs SET checkpoint=? WHERE id=?",
            params![
                json!({"pending":[],"current":jobs.root(),"last_name":"b.jpg"}).to_string(),
                job.id
            ],
        )?;
        assert_eq!(
            status(&store, &jobs, "lib")?["automatic"]["remainingPhotos"],
            0
        );
        Ok(())
    }

    #[test]
    fn unknown_photo_pairs_are_deduplicated_and_other_libraries_do_not_leak() -> Result<()> {
        let (_dir, store, jobs, folder) = setup()?;
        jobs.enqueue_file_change(&folder.id, &jobs.root().join("IMG.JPG"), 0)?;
        jobs.enqueue_file_change(&folder.id, &jobs.root().join("img.raw"), 0)?;
        photo(&store, &jobs, "other", "foreign.jpg", "foreign")?;
        store.reconcile_cache()?;
        assert_eq!(
            status(&store, &jobs, "lib")?["automatic"]["remainingPhotos"],
            1
        );
        assert_eq!(
            status(&store, &jobs, "other")?["automatic"]["remainingPhotos"],
            1
        );
        assert_eq!(
            status(&store, &jobs, "empty")?["automatic"]["remainingPhotos"],
            0
        );
        Ok(())
    }

    #[test]
    fn manual_scope_excludes_cache_but_not_actual_automatic_work() -> Result<()> {
        let (_dir, store, jobs, folder) = setup()?;
        photo(&store, &jobs, "lib", "a.jpg", "one")?;
        store.reconcile_cache()?;
        jobs.enqueue_scan(&folder.id)?;
        assert_eq!(
            status(&store, &jobs, "lib")?["automatic"]["remainingPhotos"],
            0
        );
        jobs.enqueue_file_change(&folder.id, &jobs.root().join("a.jpg"), 0)?;
        assert_eq!(
            status(&store, &jobs, "lib")?["automatic"]["remainingPhotos"],
            1
        );
        Ok(())
    }

    #[test]
    fn maintenance_failure_survives_other_activity_and_active_without_photo_is_running()
    -> Result<()> {
        let (_dir, store, jobs, folder) = setup()?;
        let path = jobs.root().join("a.jpg");
        jobs.record_file(
            &folder.id,
            path.to_str().unwrap(),
            1,
            1,
            "one",
            "hash",
            None,
        )?;
        jobs.identity_result(&folder.id, path.to_str().unwrap(), Some("identity failed"))?;
        begin(&jobs, "other", "automatic", Some("other.jpg"))?;
        let state = status(&store, &jobs, "lib")?;
        assert_eq!(state["longTask"]["status"], "failed");
        assert_eq!(state["longTask"]["error"], "identity failed");
        assert_eq!(
            status(&store, &jobs, "other")?["longTask"]["status"],
            "idle"
        );
        begin(&jobs, "lib", "maintenance", None)?;
        assert_eq!(
            status(&store, &jobs, "lib")?["longTask"]["status"],
            "running"
        );
        Ok(())
    }

    #[test]
    fn gc_pending_and_failed_are_library_scoped() -> Result<()> {
        let (_dir, store, jobs, _folder) = setup()?;
        store.lock()?.execute("INSERT INTO media_cache_gc(library_id,bucket,object_key,not_before) VALUES('lib','cache','orphan',0)",[])?;
        assert_eq!(
            status(&store, &jobs, "lib")?["longTask"]["status"],
            "pending"
        );
        store.lock()?.execute(
            "UPDATE media_cache_gc SET attempts=4,last_error='cannot delete'",
            [],
        )?;
        assert_eq!(
            status(&store, &jobs, "lib")?["longTask"]["error"],
            "cannot delete"
        );
        assert_eq!(
            status(&store, &jobs, "other")?["longTask"]["status"],
            "idle"
        );
        Ok(())
    }
}
