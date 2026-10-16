//! NAS-owned, non-overwriting moves with a durable reconciliation journal.
use crate::{
    jobs::Jobs,
    store::{Store, StoreError},
};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::{fs, path::Path};

fn error(status: u16, message: impl Into<String>) -> anyhow::Error {
    StoreError {
        status,
        code: "directory_move_failed".into(),
        message: message.into(),
    }
    .into()
}
pub(crate) fn initialize(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS directory_moves(id TEXT PRIMARY KEY,library_id TEXT NOT NULL,source TEXT NOT NULL,destination TEXT NOT NULL,completed INTEGER NOT NULL DEFAULT 0)")?;
    db.execute_batch("CREATE TABLE IF NOT EXISTS directory_move_tasks(id TEXT PRIMARY KEY,library_id TEXT NOT NULL,path TEXT NOT NULL,parent_path TEXT NOT NULL,destination TEXT NOT NULL,status TEXT NOT NULL,phase TEXT NOT NULL,error TEXT,created_at INTEGER NOT NULL DEFAULT(unixepoch()),updated_at INTEGER NOT NULL DEFAULT(unixepoch()),finished_at INTEGER)")?;
    crate::asset_move::initialize(db)?;
    Ok(())
}

fn rewrite(
    db: &Connection,
    table: &str,
    column: &str,
    scope: &str,
    library: &str,
    source: &str,
    destination: &str,
) -> Result<()> {
    db.execute(&format!("UPDATE {table} SET {column}=?3 || substr({column},length(?2)+1) WHERE {scope} AND ({column}=?2 OR ({column}>=?4 AND {column}<?5))"), params![library,source,destination,format!("{source}/"),format!("{source}0")])?;
    Ok(())
}
pub(crate) fn catalog(
    db: &Connection,
    library: &str,
    source: &str,
    destination: &str,
) -> Result<()> {
    for (table, column) in [
        ("catalog_paths", "path"),
        ("catalog_version_paths", "path"),
        ("catalog_hidden_directories", "path"),
        ("catalog_deprecated_files", "path"),
        ("catalog_deprecated_files", "retained_path"),
        ("remote_cache_tasks", "input_path"),
    ] {
        rewrite(
            db,
            table,
            column,
            "library_id=?1",
            library,
            source,
            destination,
        )?;
    }
    // Revision directory rows are history, so retain old entries and publish both ancestors.
    for path in [source, destination] {
        db.execute("INSERT OR IGNORE INTO catalog_revision_dirty(library_id,kind,key) VALUES(?1,'hidden',?2)",params![library,path])?;
    }
    db.execute("UPDATE media_cache SET standard=json_set(standard,'$.path',?3 || substr(json_extract(standard,'$.path'),length(?2)+1)) WHERE library_id=?1 AND (json_extract(standard,'$.path')=?2 OR (json_extract(standard,'$.path')>=?4 AND json_extract(standard,'$.path')<?5))",params![library,source,destination,format!("{source}/"),format!("{source}0")])?;
    db.execute("INSERT OR IGNORE INTO catalog_revision_updates(library_id,path,owner,last_changed_at) SELECT library_id,?3 || substr(path,length(?2)+1),owner,last_changed_at FROM catalog_revision_updates WHERE library_id=?1 AND (path=?2 OR (path>=?4 AND path<?5))",params![library,source,destination,format!("{source}/"),format!("{source}0")])?;
    crate::revisions::flush(db)?;
    Ok(())
}
pub(crate) fn tracking(
    db: &Connection,
    library: &str,
    source: &str,
    destination: &str,
) -> Result<()> {
    rewrite(
        db,
        "folders",
        "path",
        "library_id=?1",
        library,
        source,
        destination,
    )?;
    for (table, column) in [
        ("files", "path"),
        ("jobs", "scope_path"),
        ("jobs", "current_path"),
    ] {
        rewrite(
            db,
            table,
            column,
            "folder_id IN (SELECT id FROM folders WHERE library_id=?1)",
            library,
            source,
            destination,
        )?;
    }
    if Path::new(source).is_file() || Path::new(destination).is_file() {
        db.execute("UPDATE files SET folder_id=(SELECT id FROM folders WHERE library_id=?1 AND active=1 AND (?2>=path || '/' AND ?2<path || '0') ORDER BY length(path) DESC LIMIT 1) WHERE path=?2 AND folder_id IN (SELECT id FROM folders WHERE library_id=?1)",params![library,destination])?;
    }
    db.execute("UPDATE jobs SET checkpoint=NULL WHERE folder_id IN (SELECT id FROM folders WHERE library_id=?1) AND status IN ('pending','running')",[library])?;
    rewrite(
        db,
        "worker_photo_files",
        "path",
        "?1 IS NOT NULL",
        library,
        source,
        destination,
    )?;
    rewrite(
        db,
        "worker_activity",
        "current_photo",
        "library_id=?1",
        library,
        source,
        destination,
    )?;
    Ok(())
}
pub(crate) fn reconcile(
    jobs: &Jobs,
    store: &Store,
    id: &str,
    library: &str,
    source: &str,
    destination: &str,
) -> Result<()> {
    for directory in [Path::new(source).parent(), Path::new(destination).parent()]
        .into_iter()
        .flatten()
    {
        fs::File::open(directory)?
            .sync_all()
            .with_context(|| format!("sync moved directory parent {}", directory.display()))?;
    }
    transition(jobs, id, "catalog", None)?;
    {
        let mut db = store.lock()?;
        let tx = db.transaction()?;
        catalog(&tx, library, source, destination)?;
        tx.commit()?;
    }
    transition(jobs, id, "tracking", None)?;
    let mut db = jobs.db.lock().unwrap();
    let tx = db.transaction()?;
    tracking(&tx, library, source, destination)?;
    tx.commit()?;
    drop(db);
    crate::sync_navigation::refresh(store, jobs, library)?;
    jobs.db
        .lock()
        .unwrap()
        .execute("UPDATE directory_moves SET completed=1 WHERE id=?1", [id])?;
    Ok(())
}

// An exclusive rename prevents even an empty destination directory from being replaced.
pub(crate) fn rename_exclusive(source: &Path, destination: &Path) -> Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let source = std::ffi::CString::new(source.as_os_str().as_bytes())?;
    let destination = std::ffi::CString::new(destination.as_os_str().as_bytes())?;
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            destination.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(target_os = "macos")]
    let result =
        unsafe { libc::renamex_np(source.as_ptr(), destination.as_ptr(), libc::RENAME_EXCL) };
    if result != 0 {
        return Err(std::io::Error::last_os_error())
            .context("NAS directory move failed; cross-filesystem moves are unsupported");
    }
    Ok(())
}

pub(crate) fn ensure_reconciled(jobs: &Jobs) -> Result<()> {
    let pending: bool = jobs.db.lock().unwrap().query_row(
        "SELECT EXISTS(SELECT 1 FROM directory_moves WHERE completed=0)",
        [],
        |r| r.get(0),
    )?;
    ensure!(
        !pending,
        error(
            503,
            "A NAS folder move needs reconciliation; retry the move or restart the server"
        )
    );
    Ok(())
}

pub fn interrupt_pending(jobs: &Jobs) -> Result<()> {
    let db = jobs.trash_db.lock().unwrap();
    for table in ["directory_move_tasks", "asset_move_tasks"] {
        db.execute(&format!("UPDATE {table} SET status='failed',error=coalesce(error||char(10),'')||'服务已重启，移动任务已中断；请手动重试。已移动文件保留原位置。',finished_at=unixepoch(),updated_at=unixepoch() WHERE status IN ('pending','running')"), [])?;
    }
    Ok(())
}

pub fn recover(jobs: &Jobs, store: &Store) -> Result<()> {
    let _guard = jobs.directory_mutation.write().unwrap();
    recover_locked(jobs, store)
}
pub(crate) fn recover_locked(jobs: &Jobs, store: &Store) -> Result<()> {
    let pending = jobs
        .db
        .lock()
        .unwrap()
        .prepare("SELECT id,library_id,source,destination FROM directory_moves WHERE completed=0")?
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut files = std::collections::BTreeMap::<String, Vec<crate::asset_move::FileMove>>::new();
    for (id, lib, source, destination) in pending {
        match (
            Path::new(&source).try_exists()?,
            Path::new(&destination).try_exists()?,
        ) {
            (true, false) => {
                jobs.db
                    .lock()
                    .unwrap()
                    .execute("DELETE FROM directory_moves WHERE id=?1", [id])?;
            }
            (false, true) if Path::new(&destination).is_file() => {
                files
                    .entry(lib)
                    .or_default()
                    .push(crate::asset_move::FileMove {
                        id,
                        source,
                        destination,
                    });
            }
            (false, true) => reconcile(jobs, store, &id, &lib, &source, &destination)?,
            _ => anyhow::bail!(
                "Cannot recover directory move {id}: inspect {source} and {destination}"
            ),
        }
    }
    for (library, moves) in files {
        crate::asset_move::reconcile_files(jobs, store, &library, &moves)?;
    }
    Ok(())
}

fn destination_path(
    path: &str,
    parent_path: &str,
    name: Option<&str>,
) -> Result<std::path::PathBuf> {
    let name = match name {
        Some(name) => {
            ensure!(
                !name.trim().is_empty()
                    && !name.starts_with('.')
                    && name != "@eaDir"
                    && name != "#recycle"
                    && !name
                        .chars()
                        .any(|c| c == '/' || c == '\\' || c.is_control()),
                error(422, "name must be a single visible folder name")
            );
            std::ffi::OsStr::new(name)
        }
        None => Path::new(path)
            .file_name()
            .context(error(422, "Source must have a directory name"))?,
    };
    Ok(Path::new(parent_path).join(name))
}

pub(crate) fn move_directory(
    jobs: &Jobs,
    store: &Store,
    library: &str,
    path: &str,
    parent_path: &str,
    request_id: &str,
    name: Option<&str>,
) -> Result<Value> {
    let id = uuid::Uuid::parse_str(request_id)
        .map_err(|_| error(422, "requestID must be a UUID"))?
        .to_string();
    let requested_destination = destination_path(path, parent_path, name)?;
    let _guard = jobs.directory_mutation.write().unwrap();
    transition(jobs, &id, "validating", None)?;
    recover_locked(jobs, store)?;
    let existing: Option<(String, String, String)> = jobs
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT library_id,source,destination FROM directory_moves WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    if let Some((lib, source, destination)) = existing {
        ensure!(
            lib == library && source == path && Path::new(&destination) == requested_destination,
            error(409, "requestID belongs to another move")
        );
        return Ok(json!({"path":destination,"previousPath":source}));
    }
    let source = jobs
        .validate_path(Path::new(path))
        .map_err(|e| error(422, format!("{e:#}")))?;
    let parent = jobs
        .validate_path(Path::new(parent_path))
        .map_err(|e| error(422, format!("{e:#}")))?;
    ensure!(
        source.to_str() == Some(path) && parent.to_str() == Some(parent_path),
        error(422, "Paths must be canonical and absolute")
    );
    ensure!(
        source != jobs.root() && !parent.starts_with(&source),
        error(
            422,
            "Cannot move the originals root or a directory into itself or its descendants"
        )
    );
    let destination = requested_destination;
    ensure!(
        fs::symlink_metadata(&destination).is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
        error(409, "Destination already exists or is inaccessible")
    );
    let folders = jobs.folders()?;
    for candidate in [&source, &parent] {
        ensure!(
            folders
                .iter()
                .any(|f| f.active && f.library_id == library && candidate.starts_with(&f.path)),
            error(404, "Both directories must be tracked in this library")
        );
        ensure!(
            !folders.iter().any(|f| f.active
                && f.library_id != library
                && (candidate.starts_with(&f.path) || Path::new(&f.path).starts_with(candidate))),
            error(409, "Directory overlaps another library")
        );
    }
    let active_trash: bool = jobs.trash_db.lock().unwrap().query_row(
        "SELECT EXISTS(SELECT 1 FROM directory_trash_tasks WHERE status IN ('pending','running'))",
        [],
        |r| r.get(0),
    )?;
    ensure!(
        !active_trash,
        error(409, "Wait for active folder deletion to finish")
    );
    let active_import: bool = jobs.db.lock().unwrap().query_row("SELECT EXISTS(SELECT 1 FROM imports WHERE json_extract(manifest,'$.finished')=0 AND (json_extract(manifest,'$.targetPath')=?1 OR (json_extract(manifest,'$.targetPath')>=?2 AND json_extract(manifest,'$.targetPath')<?3)))",params![path,format!("{path}/"),format!("{path}0")],|r|r.get(0))?;
    ensure!(
        !active_import,
        error(
            409,
            "Finish active imports into this directory before moving it"
        )
    );
    let dest = destination.to_str().context("path must be UTF-8")?;
    // Preflight constraints before touching originals. Recovery then replays idempotent rewrites.
    {
        let mut db = store.lock()?;
        let tx = db.transaction()?;
        catalog(&tx, library, path, dest)?;
        tx.rollback()?;
    }
    {
        let mut db = jobs.db.lock().unwrap();
        let tx = db.transaction()?;
        tracking(&tx, library, path, dest)?;
        tx.rollback()?;
    }
    jobs.db.lock().unwrap().execute(
        "INSERT INTO directory_moves(id,library_id,source,destination) VALUES(?1,?2,?3,?4)",
        params![id, library, path, dest],
    )?;
    transition(jobs, &id, "moving", None)?;
    if let Err(failure) = rename_exclusive(&source, &destination) {
        jobs.db
            .lock()
            .unwrap()
            .execute("DELETE FROM directory_moves WHERE id=?1", [&id])?;
        return Err(failure);
    }
    reconcile(jobs, store, &id, library, path, dest).context(
        "Directory moved on NAS; catalog reconciliation will resume on retry or server restart",
    )?;
    Ok(json!({"path":dest,"previousPath":path}))
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveTask {
    pub id: String,
    pub path: String,
    pub parent_path: String,
    pub destination: String,
    pub status: String,
    pub phase: String,
    pub error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub finished_at: Option<i64>,
}
const TASK_SELECT: &str = "SELECT id,path,parent_path,destination,status,phase,error,created_at,updated_at,finished_at FROM directory_move_tasks";
fn task(row: &rusqlite::Row<'_>) -> rusqlite::Result<MoveTask> {
    Ok(MoveTask {
        id: row.get(0)?,
        path: row.get(1)?,
        parent_path: row.get(2)?,
        destination: row.get(3)?,
        status: row.get(4)?,
        phase: row.get(5)?,
        error: row.get(6)?,
        created_at: row.get(7)?,
        updated_at: row.get(8)?,
        finished_at: row.get(9)?,
    })
}
pub(crate) fn get(jobs: &Jobs, library: &str, id: &str) -> Result<MoveTask> {
    let id = uuid::Uuid::parse_str(id)
        .map_err(|_| error(422, "requestID must be a UUID"))?
        .to_string();
    jobs.trash_db
        .lock()
        .unwrap()
        .query_row(
            &format!("{TASK_SELECT} WHERE id=?1 AND library_id=?2"),
            params![id, library],
            task,
        )
        .optional()?
        .ok_or_else(|| error(404, "Directory move task not found"))
}
pub(crate) fn submit(
    jobs: &Jobs,
    library: &str,
    path: &str,
    parent_path: &str,
    id: &str,
    name: Option<&str>,
) -> Result<MoveTask> {
    let id = uuid::Uuid::parse_str(id)
        .map_err(|_| error(422, "requestID must be a UUID"))?
        .to_string();
    // Submission does not inspect the filesystem or wait for scans holding the directory lock.
    // Revalidate all filesystem and tracking constraints in the durable worker.
    ensure!(
        crate::revisions::normalize_directory(path)? == path
            && crate::revisions::normalize_directory(parent_path)? == parent_path,
        error(422, "Paths must be canonical and absolute")
    );
    let destination = destination_path(path, parent_path, name)?;
    let db = jobs.trash_db.lock().unwrap();
    db.execute("INSERT OR IGNORE INTO directory_move_tasks(id,library_id,path,parent_path,destination,status,phase) VALUES(?1,?2,?3,?4,?5,'pending','waiting')",params![id,library,path,parent_path,destination.to_str().context("path must be UTF-8")?])?;
    let (old_library, old_path, old_destination): (String, String, String) = db.query_row(
        "SELECT library_id,path,destination FROM directory_move_tasks WHERE id=?1",
        [&id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    ensure!(
        old_library == library && old_path == path && Path::new(&old_destination) == destination,
        error(409, "requestID belongs to another move request")
    );
    db.execute("UPDATE directory_move_tasks SET status='pending',error=NULL,finished_at=NULL,updated_at=unixepoch() WHERE id=?1 AND status='failed'", [&id])?;
    drop(db);
    get(jobs, library, &id)
}
fn transition(jobs: &Jobs, id: &str, phase: &str, message: Option<&str>) -> Result<()> {
    let status = match phase {
        "completed" => "completed",
        "failed" => "failed",
        _ => "running",
    };
    jobs.trash_db.lock().unwrap().execute("UPDATE directory_move_tasks SET status=?2,phase=?3,error=?4,updated_at=unixepoch(),finished_at=CASE WHEN ?2 IN ('completed','failed') THEN unixepoch() ELSE NULL END WHERE id=?1",params![id,status,phase,message])?;
    Ok(())
}
fn process(jobs: &Jobs, store: &Store, library: &str, current: &MoveTask) -> Result<()> {
    transition(jobs, &current.id, "waiting", None)?;
    match move_directory(
        jobs,
        store,
        library,
        &current.path,
        &current.parent_path,
        &current.id,
        Path::new(&current.destination)
            .file_name()
            .filter(|name| Some(*name) != Path::new(&current.path).file_name())
            .and_then(|name| name.to_str()),
    ) {
        Ok(_) => transition(jobs, &current.id, "completed", None),
        Err(failure) => {
            tracing::error!(id=%current.id,error=%format!("{failure:#}"),"Directory move task failed");
            transition(jobs, &current.id, "failed", Some(&format!("{failure:#}")))
        }
    }
}
pub fn run(
    jobs: std::sync::Arc<Jobs>,
    store: std::sync::Arc<Store>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
) -> Result<()> {
    while !stop.load(std::sync::atomic::Ordering::Relaxed) {
        let next = {
            let db = jobs.trash_db.lock().unwrap();
            db.query_row(
                &format!(
                    "{} WHERE status IN ('pending','running') ORDER BY created_at,id LIMIT 1",
                    TASK_SELECT.replace(" FROM", ",library_id FROM")
                ),
                [],
                |r| Ok((task(r)?, r.get::<_, String>(10)?)),
            )
            .optional()?
        };
        if let Some((current, library)) = next {
            process(&jobs, &store, &library, &current)?;
        } else if !crate::asset_move::process_next(&jobs, &store)? {
            std::thread::sleep(std::time::Duration::from_secs(5));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn setup() -> (tempfile::TempDir, Jobs, Store) {
        let tmp = tempfile::tempdir().unwrap();
        fs::create_dir(tmp.path().join("originals")).unwrap();
        let jobs = Jobs::open(
            &tmp.path().join("jobs.sqlite"),
            &tmp.path().join("originals"),
        )
        .unwrap();
        jobs.add_folder("lib", jobs.root().to_str().unwrap())
            .unwrap();
        let store = Store::open(&tmp.path().join("catalog.sqlite"), true).unwrap();
        (tmp, jobs, store)
    }
    #[test]
    fn startup_stops_move_until_same_request_is_explicitly_submitted() -> Result<()> {
        let (_tmp, jobs, _store) = setup();
        let source = jobs.root().join("source");
        let parent = jobs.root().join("target");
        fs::create_dir(&source)?;
        fs::create_dir(&parent)?;
        let id = uuid::Uuid::new_v4().to_string();
        submit(
            &jobs,
            "lib",
            source.to_str().unwrap(),
            parent.to_str().unwrap(),
            &id,
            None,
        )?;
        interrupt_pending(&jobs)?;
        assert_eq!(get(&jobs, "lib", &id)?.status, "failed");
        assert!(source.exists());
        assert!(!parent.join("source").exists());
        assert_eq!(
            submit(
                &jobs,
                "lib",
                source.to_str().unwrap(),
                parent.to_str().unwrap(),
                &id,
                None
            )?
            .status,
            "pending"
        );
        Ok(())
    }

    #[test]
    fn rename_preserves_originals_and_retries_match_destination() -> Result<()> {
        let (_tmp, jobs, store) = setup();
        let source = jobs.root().join("source");
        fs::create_dir(&source)?;
        fs::write(source.join("photo.raw"), b"original")?;
        let path = source.to_str().unwrap();
        let parent = jobs.root().to_str().unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let queued = submit(&jobs, "lib", path, parent, &id, Some("新名字"))?;
        assert_eq!(
            queued.destination,
            jobs.root().join("新名字").to_str().unwrap()
        );
        assert!(submit(&jobs, "lib", path, parent, &id, Some("different")).is_err());
        process(&jobs, &store, "lib", &queued)?;
        assert_eq!(get(&jobs, "lib", &id)?.status, "completed");
        assert!(!source.exists());
        assert_eq!(fs::read(jobs.root().join("新名字/photo.raw"))?, b"original");
        assert_eq!(
            submit(&jobs, "lib", path, parent, &id, Some("新名字"))?.status,
            "completed"
        );
        assert_eq!(
            move_directory(&jobs, &store, "lib", path, parent, &id, Some("新名字"))?["path"],
            queued.destination
        );
        assert!(
            move_directory(&jobs, &store, "lib", path, parent, &id, Some("different")).is_err()
        );
        Ok(())
    }

    #[test]
    fn rename_rejects_invalid_names_and_existing_destination() -> Result<()> {
        let (_tmp, jobs, store) = setup();
        let source = jobs.root().join("source");
        let existing = jobs.root().join("existing");
        fs::create_dir(&source)?;
        fs::create_dir(&existing)?;
        fs::write(source.join("photo.raw"), b"original")?;
        let path = source.to_str().unwrap();
        let parent = jobs.root().to_str().unwrap();
        for name in [
            "",
            " ",
            ".",
            "..",
            ".hidden",
            "@eaDir",
            "#recycle",
            "child/name",
            "/absolute",
            "child\\name",
            "bad\0name",
            "bad\nname",
            "bad\tname",
        ] {
            let id = uuid::Uuid::new_v4().to_string();
            assert!(submit(&jobs, "lib", path, parent, &id, Some(name)).is_err());
            assert!(move_directory(&jobs, &store, "lib", path, parent, &id, Some(name)).is_err());
        }
        let id = uuid::Uuid::new_v4().to_string();
        let queued = submit(&jobs, "lib", path, parent, &id, Some("existing"))?;
        process(&jobs, &store, "lib", &queued)?;
        assert_eq!(get(&jobs, "lib", &id)?.status, "failed");
        assert_eq!(fs::read(source.join("photo.raw"))?, b"original");
        assert!(existing.is_dir());
        assert_eq!(fs::read_dir(existing)?.count(), 0);
        Ok(())
    }

    #[test]
    fn async_submission_is_idempotent_status_is_nonblocking_and_worker_reports_phases() -> Result<()>
    {
        let (_tmp, jobs, store) = setup();
        let source = jobs.root().join("source");
        let parent = jobs.root().join("target");
        fs::create_dir(&source)?;
        fs::create_dir(&parent)?;
        fs::write(source.join("photo.raw"), b"original")?;
        let id = uuid::Uuid::new_v4().to_string();
        {
            let _directory_guard = jobs.directory_mutation.write().unwrap();
            let submitted = submit(
                &jobs,
                "lib",
                source.to_str().unwrap(),
                parent.to_str().unwrap(),
                &id,
                None,
            )?;
            assert_eq!(
                (submitted.status.as_str(), submitted.phase.as_str()),
                ("pending", "waiting")
            );
            assert_eq!(
                submit(
                    &jobs,
                    "lib",
                    source.to_str().unwrap(),
                    parent.to_str().unwrap(),
                    &id,
                    None
                )?
                .id,
                id
            );
            assert!(
                submit(
                    &jobs,
                    "other",
                    source.to_str().unwrap(),
                    parent.to_str().unwrap(),
                    &id,
                    None
                )
                .is_err()
            );
            assert!(
                submit(
                    &jobs,
                    "lib",
                    parent.to_str().unwrap(),
                    source.to_str().unwrap(),
                    &id,
                    None
                )
                .is_err()
            );
            let db = jobs.db.lock().unwrap();
            db.execute_batch("BEGIN IMMEDIATE; UPDATE folders SET active=active")?;
            assert_eq!(get(&jobs, "lib", &id)?.phase, "waiting");
            assert!(get(&jobs, "other", &id).is_err());
            db.execute_batch("ROLLBACK")?;
        }
        jobs.trash_db.lock().unwrap().execute_batch("CREATE TABLE move_phase_log(phase TEXT); CREATE TRIGGER log_move_phase AFTER UPDATE OF phase ON directory_move_tasks BEGIN INSERT INTO move_phase_log VALUES(NEW.phase); END")?;
        process(&jobs, &store, "lib", &get(&jobs, "lib", &id)?)?;
        let completed = get(&jobs, "lib", &id)?;
        assert_eq!(completed.status, "completed");
        assert!(completed.finished_at.is_some());
        assert_eq!(fs::read(parent.join("source/photo.raw"))?, b"original");
        let phases = jobs
            .trash_db
            .lock()
            .unwrap()
            .prepare("SELECT phase FROM move_phase_log")?
            .query_map([], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        assert_eq!(
            phases,
            [
                "waiting",
                "validating",
                "moving",
                "catalog",
                "tracking",
                "completed"
            ]
        );
        assert_eq!(
            submit(
                &jobs,
                "lib",
                source.to_str().unwrap(),
                parent.to_str().unwrap(),
                &id,
                None
            )?
            .status,
            "completed"
        );
        Ok(())
    }

    #[test]
    fn queued_and_interrupted_tasks_resume_after_reopen_and_failures_keep_originals() -> Result<()>
    {
        for renamed in [false, true] {
            let (tmp, jobs, store) = setup();
            let source = jobs.root().join("source");
            let parent = jobs.root().join("target");
            let destination = parent.join("source");
            fs::create_dir(&source)?;
            fs::create_dir(&parent)?;
            let id = uuid::Uuid::new_v4().to_string();
            submit(
                &jobs,
                "lib",
                source.to_str().unwrap(),
                parent.to_str().unwrap(),
                &id,
                None,
            )?;
            if renamed {
                transition(&jobs, &id, "moving", None)?;
                jobs.db.lock().unwrap().execute("INSERT INTO directory_moves(id,library_id,source,destination) VALUES(?1,'lib',?2,?3)",params![id,source.to_str().unwrap(),destination.to_str().unwrap()])?;
                rename_exclusive(&source, &destination)?;
            }
            drop(jobs);
            let jobs = Jobs::open(
                &tmp.path().join("jobs.sqlite"),
                &tmp.path().join("originals"),
            )?;
            recover(&jobs, &store)?;
            process(&jobs, &store, "lib", &get(&jobs, "lib", &id)?)?;
            assert_eq!(get(&jobs, "lib", &id)?.status, "completed");
            assert!(destination.exists());
            assert!(!source.exists());
        }
        let (_tmp, jobs, store) = setup();
        let source = jobs.root().join("source");
        let parent = jobs.root().join("target");
        fs::create_dir(&source)?;
        fs::create_dir_all(parent.join("source"))?;
        let id = uuid::Uuid::new_v4().to_string();
        submit(
            &jobs,
            "lib",
            source.to_str().unwrap(),
            parent.to_str().unwrap(),
            &id,
            None,
        )?;
        process(&jobs, &store, "lib", &get(&jobs, "lib", &id)?)?;
        let failed = get(&jobs, "lib", &id)?;
        assert_eq!(failed.status, "failed");
        assert!(failed.error.unwrap().contains("Destination already exists"));
        assert!(source.exists());
        assert!(parent.join("source").exists());
        Ok(())
    }

    #[test]
    fn moves_preserve_bytes_asset_identity_tracking_and_revisions() -> Result<()> {
        let (_tmp, jobs, store) = setup();
        let source = jobs.root().join("旅行_%");
        let parent = jobs.root().join("archive");
        fs::create_dir(&source)?;
        fs::create_dir(&parent)?;
        let photo = source.join("photo.jpg");
        fs::write(&photo, b"original")?;
        let folder = jobs.add_folder("lib", source.to_str().unwrap())?;
        let job = jobs.enqueue_scan(&folder.id)?;
        jobs.db.lock().unwrap().execute(
            "UPDATE jobs SET checkpoint=?2 WHERE id=?1",
            params![
                job.id,
                format!("{{\"pending\":[\"{}\"]}}", source.display())
            ],
        )?;
        store.ingest_original("lib",photo.to_str().unwrap(),&json!({"contentHash":"hash","sizeBytes":8,"role":"jpeg_original"}),&json!({"contentFingerprint":"hash","metadataFingerprint":"meta","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","originalFilename":"photo.jpg","rating":0,"flagState":"unflagged","tags":[]}))?;
        store.set_hidden_directory("lib", source.to_str().unwrap(), true)?;
        let before = store.library_revision("lib")?;
        let asset: String =
            store
                .lock()?
                .query_row("SELECT asset_id FROM catalog_paths", [], |r| r.get(0))?;
        let id = uuid::Uuid::new_v4().to_string();
        let result = move_directory(
            &jobs,
            &store,
            "lib",
            source.to_str().unwrap(),
            parent.to_str().unwrap(),
            &id,
            None,
        )?;
        assert!(jobs.load_checkpoint(&job.id)?.is_none());
        let dest = parent.join("旅行_%");
        assert_eq!(result["path"], dest.to_str().unwrap());
        assert_eq!(fs::read(dest.join("photo.jpg"))?, b"original");
        assert!(!source.exists());
        assert_eq!(jobs.job(&job.id)?.unwrap().path, dest.to_str().unwrap());
        let (after_asset, path): (String, String) =
            store
                .lock()?
                .query_row("SELECT asset_id,path FROM catalog_paths", [], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })?;
        assert_eq!(asset, after_asset);
        assert_eq!(path, dest.join("photo.jpg").to_str().unwrap());
        assert_ne!(before, store.library_revision("lib")?);
        assert_eq!(
            move_directory(
                &jobs,
                &store,
                "lib",
                source.to_str().unwrap(),
                parent.to_str().unwrap(),
                &id,
                None
            )?,
            result
        );
        Ok(())
    }
    #[test]
    fn rejects_descendants_existing_targets_untracked_and_other_library() -> Result<()> {
        let (_tmp, jobs, store) = setup();
        let source = jobs.root().join("source");
        let child = source.join("child");
        let parent = jobs.root().join("target");
        fs::create_dir_all(&child)?;
        fs::create_dir(&parent)?;
        let run = |source: &Path, parent: &Path| {
            move_directory(
                &jobs,
                &store,
                "lib",
                source.to_str().unwrap(),
                parent.to_str().unwrap(),
                &uuid::Uuid::new_v4().to_string(),
                None,
            )
        };
        assert!(run(&source, &child).is_err());
        assert!(run(jobs.root(), &parent).is_err());
        fs::create_dir(parent.join("source"))?;
        assert!(run(&source, &parent).is_err());
        assert!(rename_exclusive(&source, &parent.join("source")).is_err());
        assert!(child.exists());
        let other = jobs.root().join("other");
        fs::create_dir(&other)?;
        jobs.add_folder("other", other.to_str().unwrap())?;
        assert!(run(&source, &other).is_err());
        Ok(())
    }
    #[test]
    fn active_imports_block_moves_and_pending_reconciliation_blocks_writes() -> Result<()> {
        let (_tmp, jobs, store) = setup();
        let source = jobs.root().join("source");
        let parent = jobs.root().join("target");
        fs::create_dir(&source)?;
        fs::create_dir(&parent)?;
        jobs.db.lock().unwrap().execute(
            "INSERT INTO imports(id,library_id,manifest) VALUES('batch','lib',?1)",
            [json!({"targetPath":source,"finished":false}).to_string()],
        )?;
        assert!(
            move_directory(
                &jobs,
                &store,
                "lib",
                source.to_str().unwrap(),
                parent.to_str().unwrap(),
                &uuid::Uuid::new_v4().to_string(),
                None
            )
            .is_err()
        );
        assert!(source.exists());
        jobs.db.lock().unwrap().execute("INSERT INTO directory_moves(id,library_id,source,destination) VALUES('pending','lib',?1,?2)",params![source.to_str().unwrap(),parent.join("source").to_str().unwrap()])?;
        assert!(ensure_reconciled(&jobs).is_err());
        recover(&jobs, &store)?;
        ensure_reconciled(&jobs)?;
        Ok(())
    }

    #[test]
    fn resumes_after_filesystem_move_and_after_catalog_commit() -> Result<()> {
        for catalog_committed in [false, true] {
            let (_tmp, jobs, store) = setup();
            let source = jobs.root().join("source");
            let dest = jobs.root().join("dest");
            fs::create_dir(&source)?;
            let folder = jobs.add_folder("lib", source.to_str().unwrap())?;
            let id = uuid::Uuid::new_v4().to_string();
            let s = source.to_str().unwrap();
            let d = dest.to_str().unwrap();
            jobs.db.lock().unwrap().execute("INSERT INTO directory_moves(id,library_id,source,destination) VALUES(?1,'lib',?2,?3)",params![id,s,d])?;
            rename_exclusive(&source, &dest)?;
            if catalog_committed {
                let mut db = store.lock()?;
                let tx = db.transaction()?;
                catalog(&tx, "lib", s, d)?;
                tx.commit()?;
            }
            recover(&jobs, &store)?;
            recover(&jobs, &store)?;
            assert_eq!(
                jobs.folders()?
                    .into_iter()
                    .find(|f| f.id == folder.id)
                    .unwrap()
                    .path,
                d
            );
            assert!(dest.exists());
        }
        Ok(())
    }
    #[test]
    fn failed_navigation_publication_remains_recoverable() -> Result<()> {
        let (_tmp, jobs, store) = setup();
        let source = jobs.root().join("source");
        let dest = jobs.root().join("dest");
        fs::create_dir(&source)?;
        crate::sync_navigation::refresh(&store, &jobs, "lib")?;
        let id = uuid::Uuid::new_v4().to_string();
        jobs.db.lock().unwrap().execute(
            "INSERT INTO directory_moves(id,library_id,source,destination) VALUES(?1,'lib',?2,?3)",
            params![id, source.to_str(), dest.to_str()],
        )?;
        rename_exclusive(&source, &dest)?;
        store.lock()?.execute_batch("CREATE TRIGGER fail_navigation BEFORE INSERT ON catalog_sync_navigation BEGIN SELECT RAISE(ABORT,'fixture projection failure'); END;")?;
        let error = recover(&jobs, &store).unwrap_err();
        assert!(format!("{error:#}").contains("fixture projection failure"));
        assert!(ensure_reconciled(&jobs).is_err());
        store
            .lock()?
            .execute_batch("DROP TRIGGER fail_navigation")?;
        recover(&jobs, &store)?;
        ensure_reconciled(&jobs)?;
        let pages = crate::sync_navigation::pages(&store.read()?, "lib")?;
        assert!(pages.contains_key(dest.to_str().unwrap()));
        assert!(!pages.contains_key(source.to_str().unwrap()));
        Ok(())
    }
}
