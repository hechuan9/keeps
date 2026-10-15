//! User-submitted task progress and worker activity.
use crate::{jobs::Jobs, store::Store};
use anyhow::Result;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};

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
/// Interrupted work remains visible for an explicit user retry.
pub fn recover(jobs: &Jobs) -> Result<()> {
    let mut db = jobs.db.lock().unwrap();
    let tx = db.transaction()?;
    tx.execute("DELETE FROM worker_photo_files", [])?;
    tx.execute("UPDATE worker_activity SET active=0,last_error='服务重启导致任务中断，请手动重试' WHERE active=1", [])?;
    tx.commit()?;
    Ok(())
}

struct TaskScope {
    id: String,
    phase: String,
    path: String,
    state: String,
    error: Option<String>,
    class: String,
    processed: i64,
    failed: i64,
    current_path: Option<String>,
}

pub fn status(_store: &Store, jobs: &Jobs, library: &str) -> Result<Value> {
    let (scopes, activity) = {
        let db = jobs.db.lock().unwrap();
        let mut q=db.prepare("SELECT COALESCE(j.scope_path,f.path),j.status,j.error,j.work_class,j.processed,j.failed,j.current_path,j.id,j.phase FROM jobs j JOIN folders f ON f.id=j.folder_id WHERE f.library_id=? AND f.active=1 AND j.work_class='manual' AND j.status IN ('pending','running','failed') ORDER BY j.updated_at DESC")?;
        let scopes = q
            .query_map([library], |r| {
                Ok(TaskScope {
                    id: r.get(7)?,
                    phase: r.get(8)?,
                    path: r.get(0)?,
                    state: r.get(1)?,
                    error: r.get(2)?,
                    class: r.get(3)?,
                    processed: r.get(4)?,
                    failed: r.get(5)?,
                    current_path: r.get(6)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let activity: Option<(String,Option<String>,Option<String>,bool)>=db.query_row("SELECT work_class,current_photo,last_error,active FROM worker_activity WHERE id=1 AND library_id=?",[library],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
        (scopes, activity)
    };
    let relevant_activity = activity
        .as_ref()
        .filter(|a| matches!(a.0.as_str(), "manual" | "import-media" | "trash"));
    let active = relevant_activity.filter(|a| a.3);
    let waiting = scopes.iter().find(|j| j.state != "failed");
    let failed_job = scopes.iter().find(|j| j.state == "failed");
    let activity_error = relevant_activity.filter(|a| a.2.is_some());
    let (long_status, kind, long_error) = if let Some(a) = active {
        ("running", Some(a.0.clone()), a.2.clone())
    } else if let Some(j) = failed_job {
        ("failed", Some(j.class.clone()), j.error.clone())
    } else if let Some(j) = waiting {
        ("pending", Some(j.class.clone()), j.error.clone())
    } else if let Some(a) = activity_error {
        ("failed", Some(a.0.clone()), a.2.clone())
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
    let mut result = json!({"automatic":{"status":"idle","currentPhoto":null,"remainingPhotos":0,"failedPhotos":0,"error":null},"longTask":{"status":long_status,"jobID":current_scope.map(|scope| &scope.id),"phase":current_scope.map(|scope| &scope.phase),"kind":kind,"error":long_error,"path":current_scope.map(|scope| &scope.path),"currentPhoto":long_current,"processed":current_scope.map(|scope| scope.processed),"failed":current_scope.map(|scope| scope.failed)}});
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
    fn interrupted_manual_work_preserves_files_and_requires_user_retry() -> Result<()> {
        let (_dir, store, jobs, folder) = setup()?;
        let path = jobs.root().join("a.jpg");
        jobs.record_file(
            &folder.id,
            path.to_str().unwrap(),
            8,
            1,
            "asset",
            "hash",
            None,
        )?;
        begin_photo(&jobs, "lib", "manual", &path, std::slice::from_ref(&path))?;
        recover(&jobs)?;
        assert!(
            jobs.file_state(&folder.id, path.to_str().unwrap())?
                .is_some()
        );
        assert!(jobs.claim_class("manual")?.is_none());
        let state = status(&store, &jobs, "lib")?;
        assert_eq!(state["longTask"]["status"], "failed");
        assert!(
            state["longTask"]["error"]
                .as_str()
                .unwrap()
                .contains("中断")
        );
        Ok(())
    }

    #[test]
    fn cache_identity_and_gc_backlogs_do_not_create_tasks() -> Result<()> {
        let (_dir, store, jobs, folder) = setup()?;
        photo(&store, &jobs, "lib", "a.jpg", "one")?;
        store.reconcile_cache()?;
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
        store.lock()?.execute("INSERT INTO media_cache_gc(library_id,bucket,object_key,not_before) VALUES('lib','cache','orphan',0)", [])?;
        for failed in [false, true] {
            if failed {
                jobs.identity_result(&folder.id, path.to_str().unwrap(), Some("identity failed"))?;
                store.lock()?.execute(
                    "UPDATE media_cache SET status='failed',last_error='cache failed'",
                    [],
                )?;
                store.lock()?.execute(
                    "UPDATE media_cache_gc SET attempts=4,last_error='cannot delete'",
                    [],
                )?;
            }
            let state = status(&store, &jobs, "lib")?;
            assert_eq!(state["automatic"]["status"], "idle");
            assert_eq!(state["automatic"]["remainingPhotos"], 0);
            assert_eq!(state["automatic"]["failedPhotos"], 0);
            assert_eq!(state["longTask"]["status"], "idle");
            assert!(state["longTask"]["error"].is_null());
        }
        Ok(())
    }

    #[test]
    fn user_tasks_and_import_activity_remain_visible_and_library_scoped() -> Result<()> {
        let (_dir, store, jobs, folder) = setup()?;
        let job = jobs.enqueue_scan(&folder.id)?;
        let state = status(&store, &jobs, "lib")?;
        assert_eq!(state["longTask"]["status"], "pending");
        assert_eq!(state["longTask"]["kind"], "manual");
        assert_eq!(state["longTask"]["jobID"], job.id);
        assert_eq!(state["longTask"]["phase"], "waiting");
        jobs.db.lock().unwrap().execute(
            "UPDATE jobs SET status='failed',error='scan failed' WHERE id=?",
            [&job.id],
        )?;
        assert_eq!(
            status(&store, &jobs, "lib")?["longTask"]["error"],
            "scan failed"
        );
        let failed = status(&store, &jobs, "lib")?;
        assert_eq!(failed["longTask"]["jobID"], job.id);
        jobs.retry(failed["longTask"]["jobID"].as_str().unwrap())?;
        let retried = status(&store, &jobs, "lib")?;
        assert_eq!(retried["longTask"]["status"], "pending");
        assert!(retried["longTask"]["error"].is_null());
        begin(&jobs, "other", "import-media", Some("import.jpg"))?;
        assert_eq!(
            status(&store, &jobs, "other")?["longTask"]["kind"],
            "import-media"
        );
        assert_eq!(
            status(&store, &jobs, "other")?["longTask"]["status"],
            "running"
        );
        finish(&jobs, Some("import failed"))?;
        assert_eq!(
            status(&store, &jobs, "other")?["longTask"]["error"],
            "import failed"
        );
        assert_eq!(
            status(&store, &jobs, "empty")?["longTask"]["status"],
            "idle"
        );
        Ok(())
    }
}
