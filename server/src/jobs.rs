//! Durable scan scheduling and incremental file state. Originals are never mutated.
use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;
use std::{
    path::{Component, Path},
    sync::{Mutex, RwLock},
};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Folder {
    pub id: String,
    #[serde(rename = "libraryID")]
    pub library_id: String,
    pub path: String,
    pub active: bool,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    #[serde(rename = "folderID")]
    pub folder_id: String,
    #[serde(rename = "libraryID")]
    pub library_id: String,
    pub path: String,
    pub scope_kind: String,
    pub work_class: String,
    pub refresh_metadata: bool,
    pub path_sync: bool,
    pub wait_for_quiet: bool,
    pub status: String,
    pub error: Option<String>,
    pub processed: i64,
    pub skipped: i64,
    pub failed: i64,
    pub current_path: Option<String>,
    pub started_at: Option<i64>,
    pub finished_at: Option<i64>,
}
#[derive(Debug, Clone)]
pub struct FileState {
    pub metadata_stamp: String,
    pub size: i64,
    pub mtime_ns: i64,
    pub asset_id: String,
    pub version: String,
    pub error: Option<String>,
}
pub struct Jobs {
    pub(crate) directory_mutation: RwLock<()>,
    pub(crate) import_mutation: Mutex<()>,
    pub(crate) db: crate::database::Database,
    pub(crate) trash_db: Mutex<Connection>,
    root: std::path::PathBuf,
}

fn folder(row: &rusqlite::Row<'_>) -> rusqlite::Result<Folder> {
    Ok(Folder {
        id: row.get(0)?,
        library_id: row.get(1)?,
        path: row.get(2)?,
        active: row.get(3)?,
    })
}
fn job(row: &rusqlite::Row<'_>) -> rusqlite::Result<Job> {
    Ok(Job {
        id: row.get(0)?,
        folder_id: row.get(1)?,
        library_id: row.get(2)?,
        path: row.get(3)?,
        status: row.get(4)?,
        error: row.get(5)?,
        processed: row.get(6)?,
        skipped: row.get(7)?,
        failed: row.get(8)?,
        current_path: row.get(9)?,
        started_at: row.get(10)?,
        finished_at: row.get(11)?,
        refresh_metadata: row.get(12)?,
        wait_for_quiet: row.get(13)?,
        path_sync: row.get(14)?,
        scope_kind: row.get(15)?,
        work_class: row.get(16)?,
    })
}
const JOB_SELECT: &str = "SELECT j.id,j.folder_id,f.library_id,COALESCE(j.scope_path,f.path),j.status,j.error,j.processed,j.skipped,j.failed,j.current_path,j.started_at,j.finished_at,j.refresh_metadata,j.wait_for_quiet,j.path_sync,j.scope_kind,j.work_class FROM jobs j JOIN folders f ON f.id=j.folder_id";

fn covers(parent: &Job, child: &Job) -> bool {
    if parent.folder_id != child.folder_id || parent.work_class != child.work_class {
        return false;
    }
    let parent_path = Path::new(&parent.path);
    let child_path = Path::new(&child.path);
    match parent.scope_kind.as_str() {
        // Precise events stay ahead of a pending full scan instead of inheriting its cost.
        "recursive" => child.scope_kind == "recursive" && child_path.starts_with(parent_path),
        "directory" => child.scope_kind == "directory" && child_path == parent_path,
        "file" => child.scope_kind == "file" && child_path == parent_path,
        _ => false,
    }
}

fn validate_work_class(work_class: &str) -> Result<()> {
    if !matches!(work_class, "automatic" | "manual" | "reconcile") {
        bail!("invalid work class");
    }
    Ok(())
}
fn job_priority(job: &Job) -> (u8, u8, bool, bool) {
    (
        match job.work_class.as_str() {
            "automatic" => 2,
            "manual" => 1,
            _ => 0,
        },
        match job.scope_kind.as_str() {
            "file" => 2,
            "directory" => 1,
            _ => 0,
        },
        job.path_sync,
        !job.path_sync && job.refresh_metadata,
    )
}

impl Jobs {
    pub fn root(&self) -> &Path {
        &self.root
    }
    pub fn job(&self, id: &str) -> Result<Option<Job>> {
        Ok(self
            .db
            .lock()
            .unwrap()
            .query_row(&format!("{JOB_SELECT} WHERE j.id=?1"), [id], job)
            .optional()?)
    }
    pub fn jobs_for_library(&self, library: &str, limit: usize) -> Result<Vec<Job>> {
        let db = self.db.lock().unwrap();
        Ok(db.prepare(&format!("{JOB_SELECT} WHERE f.library_id=?1 ORDER BY CASE j.status WHEN 'running' THEN 0 WHEN 'pending' THEN 1 ELSE 2 END,j.created_at DESC,j.rowid DESC LIMIT ?2"))?.query_map(params![library,limit.min(1000) as i64],job)?.collect::<rusqlite::Result<_>>()?)
    }

    pub fn open(path: &Path, original_root: &Path) -> Result<Self> {
        let root = original_root
            .canonicalize()
            .context("resolve originals root")?;
        if !root.is_dir() {
            bail!("originals root must be a directory");
        }
        let mut db = Connection::open(path)?;
        // Progress uses another WAL connection; reserve writes before a queue read can go stale.
        db.set_transaction_behavior(rusqlite::TransactionBehavior::Immediate);
        db.busy_timeout(std::time::Duration::from_secs(30))?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
          CREATE TABLE IF NOT EXISTS worker_activity(id INTEGER PRIMARY KEY CHECK(id=1),library_id TEXT NOT NULL,work_class TEXT NOT NULL,current_photo TEXT,last_error TEXT,active INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS worker_photo_files(path TEXT PRIMARY KEY);
          CREATE TABLE IF NOT EXISTS imports(id TEXT PRIMARY KEY,library_id TEXT NOT NULL,manifest TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS folders(id TEXT PRIMARY KEY,library_id TEXT NOT NULL,path TEXT NOT NULL,active INTEGER NOT NULL DEFAULT 1,UNIQUE(library_id,path));
          CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,folder_id TEXT NOT NULL REFERENCES folders(id),status TEXT NOT NULL,error TEXT,processed INTEGER NOT NULL DEFAULT 0,skipped INTEGER NOT NULL DEFAULT 0,failed INTEGER NOT NULL DEFAULT 0,current_path TEXT,started_at INTEGER,finished_at INTEGER,created_at INTEGER NOT NULL DEFAULT(unixepoch()),updated_at INTEGER NOT NULL DEFAULT(unixepoch()));
          CREATE TABLE IF NOT EXISTS files(folder_id TEXT NOT NULL REFERENCES folders(id),path TEXT NOT NULL,size INTEGER NOT NULL,mtime_ns INTEGER NOT NULL,asset_id TEXT NOT NULL,version TEXT NOT NULL,error TEXT,PRIMARY KEY(folder_id,path));
          UPDATE jobs SET status='pending',updated_at=unixepoch() WHERE status='running';")?;
        let columns: Vec<String> = db
            .prepare("PRAGMA table_info(jobs)")?
            .query_map([], |row| row.get(1))?
            .collect::<rusqlite::Result<_>>()?;
        for (name, definition) in [
            ("work_class", "TEXT NOT NULL DEFAULT 'automatic'"),
            ("scope_path", "TEXT"),
            ("scope_kind", "TEXT NOT NULL DEFAULT 'recursive'"),
            ("checkpoint", "TEXT"),
            ("refresh_metadata", "INTEGER NOT NULL DEFAULT 0"),
            ("path_sync", "INTEGER NOT NULL DEFAULT 0"),
            ("wait_for_quiet", "INTEGER NOT NULL DEFAULT 1"),
            ("rerun", "INTEGER NOT NULL DEFAULT 0"),
            ("available_at", "INTEGER NOT NULL DEFAULT 0"),
            ("attempts", "INTEGER NOT NULL DEFAULT 0"),
        ] {
            if !columns.iter().any(|column| column == name) {
                db.execute_batch(&format!("ALTER TABLE jobs ADD COLUMN {name} {definition}"))?;
            }
        }
        if !columns.iter().any(|column| column == "path_sync") {
            // Existing scoped discovery jobs are the pending directory moves that
            // metadata refresh used to starve. Root periodic scans stay background.
            db.execute_batch("UPDATE jobs SET path_sync=1 WHERE status='pending' AND refresh_metadata=0 AND scope_path<>(SELECT path FROM folders WHERE id=jobs.folder_id)")?;
        }
        if !columns.iter().any(|column| column == "work_class") {
            db.execute_batch("UPDATE jobs SET work_class=CASE WHEN wait_for_quiet=0 THEN 'manual' WHEN scope_kind='recursive' AND COALESCE(scope_path,(SELECT path FROM folders WHERE id=jobs.folder_id))=(SELECT path FROM folders WHERE id=jobs.folder_id) THEN 'reconcile' ELSE 'automatic' END")?;
        }
        let file_columns: Vec<String> = db
            .prepare("PRAGMA table_info(files)")?
            .query_map([], |row| row.get(1))?
            .collect::<rusqlite::Result<_>>()?;
        if !file_columns.iter().any(|column| column == "metadata_stamp") {
            db.execute_batch(
                "ALTER TABLE files ADD COLUMN metadata_stamp TEXT NOT NULL DEFAULT ''",
            )?;
        }
        for (name, definition) in [
            ("identity_status", "TEXT NOT NULL DEFAULT 'pending'"),
            ("identity_error", "TEXT"),
        ] {
            if !file_columns.iter().any(|column| column == name) {
                db.execute_batch(&format!("ALTER TABLE files ADD COLUMN {name} {definition}"))?;
            }
        }
        db.execute_batch(
            "CREATE INDEX IF NOT EXISTS files_identity_pending ON files(identity_status)",
        )?;
        db.execute_batch("DROP INDEX IF EXISTS jobs_live;
            UPDATE jobs SET scope_path=(SELECT path FROM folders WHERE id=jobs.folder_id) WHERE scope_path IS NULL;
            DROP INDEX IF EXISTS jobs_live_scope;
            CREATE UNIQUE INDEX jobs_live_scope ON jobs(folder_id,scope_path,scope_kind,work_class) WHERE status IN ('pending','running');")?;
        crate::directory_move::initialize(&db)?;
        let trash_db = Connection::open(path)?;
        trash_db.busy_timeout(std::time::Duration::from_secs(5))?;
        crate::directory_trash::initialize(&trash_db)?;
        crate::rejected_trash::initialize(&trash_db)?;
        let jobs = Self {
            trash_db: Mutex::new(trash_db),
            directory_mutation: RwLock::new(()),
            import_mutation: Mutex::new(()),
            db: crate::database::Database::new(db),
            root,
        };
        jobs.coalesce_pending()?;
        Ok(jobs)
    }
    pub fn validate_path(&self, path: &Path) -> Result<std::path::PathBuf> {
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.root.join(path)
        };
        let relative = absolute
            .strip_prefix(&self.root)
            .context("folder must be under originals root")?;
        let mut cursor = self.root.clone();
        for component in relative.components() {
            match component {
                Component::Normal(name) => {
                    let name_text = name.to_string_lossy();
                    if name_text.starts_with('.')
                        || name_text == "@eaDir"
                        || name_text == "#recycle"
                    {
                        bail!("excluded folder component");
                    }
                    cursor.push(name);
                    if std::fs::symlink_metadata(&cursor)?.file_type().is_symlink() {
                        bail!("symlinks are not allowed");
                    }
                }
                Component::CurDir => {}
                _ => bail!("invalid folder component"),
            }
        }
        let resolved = absolute.canonicalize()?;
        if !resolved.starts_with(&self.root) || !resolved.is_dir() {
            bail!("folder must be a directory under originals root");
        }
        Ok(resolved)
    }
    pub fn add_folder(&self, library_id: &str, path: &str) -> Result<Folder> {
        if library_id.trim().is_empty() {
            bail!("libraryID is required");
        }
        let path = self.validate_path(Path::new(path))?;
        let path = path.to_str().context("folder path must be UTF-8")?;
        let db = self.db.lock().unwrap();
        db.execute("INSERT INTO folders(id,library_id,path) VALUES(?1,?2,?3) ON CONFLICT(library_id,path) DO UPDATE SET active=1",params![Uuid::new_v4().to_string(),library_id,path])?;
        Ok(db.query_row(
            "SELECT id,library_id,path,active FROM folders WHERE library_id=?1 AND path=?2",
            params![library_id, path],
            folder,
        )?)
    }
    pub fn folders(&self) -> Result<Vec<Folder>> {
        let db = self.db.lock().unwrap();
        Ok(db
            .prepare("SELECT id,library_id,path,active FROM folders ORDER BY path")?
            .query_map([], folder)?
            .collect::<rusqlite::Result<_>>()?)
    }
    pub fn remove_folder(&self, id: &str) -> Result<bool> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        let found = tx.execute("UPDATE folders SET active=0 WHERE id=?1", [id])? > 0;
        tx.execute("UPDATE jobs SET status='cancelled',finished_at=unixepoch(),updated_at=unixepoch() WHERE folder_id=?1 AND status IN ('pending','running')",[id])?;
        tx.commit()?;
        Ok(found)
    }
    pub fn cancel_automatic_full_scans(&self) -> Result<usize> {
        // Retire queued reconciliation from deployments that scanned on startup.
        Ok(self.db.lock().unwrap().execute(
            "UPDATE jobs SET status='cancelled',rerun=0,finished_at=unixepoch(),updated_at=unixepoch() WHERE status IN ('pending','running') AND work_class<>'manual' AND scope_kind='recursive' AND scope_path=?1",
            [self.root.to_str().context("originals root must be UTF-8")?],
        )?)
    }
    pub fn enqueue_scan(&self, folder_id: &str) -> Result<Job> {
        self.enqueue_scan_with_quiet(folder_id, false)
    }
    pub fn enqueue_external_scan(&self, folder_id: &str) -> Result<Job> {
        self.enqueue_scan_with_quiet(folder_id, true)
    }
    fn enqueue_scan_with_quiet(&self, folder_id: &str, wait_for_quiet: bool) -> Result<Job> {
        let path = self.db.lock().unwrap().query_row(
            "SELECT path FROM folders WHERE id=?1",
            [folder_id],
            |r| r.get::<_, String>(0),
        )?;
        self.enqueue_scope(
            folder_id,
            Path::new(&path),
            0,
            false,
            wait_for_quiet,
            false,
            "recursive",
            if wait_for_quiet {
                "reconcile"
            } else {
                "manual"
            },
        )
    }
    /// A running scan receives another pass instead of swallowing a concurrent event.
    pub fn enqueue_change(
        &self,
        folder_id: &str,
        path: &Path,
        debounce_seconds: i64,
    ) -> Result<Job> {
        self.enqueue_scope(
            folder_id,
            path,
            debounce_seconds,
            true,
            true,
            false,
            "recursive",
            "automatic",
        )
    }
    pub fn enqueue_reconcile_scope(&self, folder_id: &str, path: &Path) -> Result<Job> {
        self.enqueue_scope(
            folder_id,
            path,
            0,
            false,
            false,
            false,
            "recursive",
            "manual",
        )
    }
    pub fn enqueue_external_reconcile_scope(&self, folder_id: &str, path: &Path) -> Result<Job> {
        let tracked: String = self.db.lock().unwrap().query_row(
            "SELECT path FROM folders WHERE id=?1",
            [folder_id],
            |row| row.get(0),
        )?;
        let class = if self.validate_scan_path(path, "recursive")? == Path::new(&tracked) {
            "reconcile"
        } else {
            "automatic"
        };
        self.enqueue_scope(folder_id, path, 0, false, true, true, "recursive", class)
    }
    pub fn enqueue_path_change(
        &self,
        folder_id: &str,
        path: &Path,
        debounce_seconds: i64,
    ) -> Result<Job> {
        self.enqueue_scope(
            folder_id,
            path,
            debounce_seconds,
            false,
            true,
            true,
            "recursive",
            "automatic",
        )
    }
    pub fn enqueue_file_change(&self, folder_id: &str, path: &Path, delay: i64) -> Result<Job> {
        self.enqueue_scope(
            folder_id,
            path,
            delay,
            false,
            true,
            true,
            "file",
            "automatic",
        )
    }
    pub fn enqueue_manual_file(&self, folder_id: &str, path: &Path) -> Result<Job> {
        self.enqueue_scope(folder_id, path, 0, true, false, true, "file", "manual")
    }
    pub fn ensure_file_retry(&self, folder_id: &str, path: &Path) -> Result<Option<Job>> {
        let path = self.validate_scan_path(path, "file")?;
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        let tracked: Option<String> = tx
            .query_row(
                "SELECT path FROM folders WHERE id=?1 AND active=1",
                [folder_id],
                |r| r.get(0),
            )
            .optional()?;
        let tracked = tracked.context("folder is missing or inactive")?;
        if !path.starts_with(&tracked) {
            bail!("scan scope must be within tracked folder");
        }
        let scope = path.to_str().context("scan scope must be UTF-8")?;
        let id = Uuid::new_v4().to_string();
        let inserted = tx.execute(
            "INSERT INTO jobs(id,folder_id,scope_path,scope_kind,status,available_at,wait_for_quiet,path_sync)
             SELECT ?1,?2,?3,'file','pending',0,1,1 WHERE NOT EXISTS(
             SELECT 1 FROM jobs WHERE folder_id=?2 AND scope_path=?3 AND scope_kind='file' AND status IN ('pending','running','failed'))",
            params![id,folder_id,scope],
        )?;
        let result = if inserted == 0 {
            None
        } else {
            Some(tx.query_row(&format!("{JOB_SELECT} WHERE j.id=?1"), [&id], job)?)
        };
        tx.commit()?;
        Ok(result)
    }
    pub fn enqueue_manual_directory(&self, folder_id: &str, path: &Path) -> Result<Job> {
        self.enqueue_scope(
            folder_id,
            path,
            0,
            false,
            false,
            true,
            "directory",
            "manual",
        )
    }
    pub fn enqueue_manual_metadata_refresh(&self, folder_id: &str, path: &Path) -> Result<Job> {
        self.enqueue_scope(
            folder_id,
            path,
            0,
            true,
            false,
            false,
            "recursive",
            "manual",
        )
    }
    pub fn enqueue_directory_change(
        &self,
        folder_id: &str,
        path: &Path,
        delay: i64,
    ) -> Result<Job> {
        self.enqueue_scope(
            folder_id,
            path,
            delay,
            false,
            true,
            true,
            "directory",
            "automatic",
        )
    }
    pub fn enqueue_removed_directory(
        &self,
        folder_id: &str,
        path: &Path,
        delay: i64,
    ) -> Result<Job> {
        self.enqueue_scope(
            folder_id,
            path,
            delay,
            false,
            true,
            true,
            "recursive",
            "automatic",
        )
    }
    pub fn validate_scan_path(&self, path: &Path, scope_kind: &str) -> Result<std::path::PathBuf> {
        if !matches!(scope_kind, "recursive" | "directory" | "file") {
            bail!("invalid scan scope kind");
        }
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            self.root.join(path)
        };
        let relative = absolute
            .strip_prefix(&self.root)
            .context("scan scope must be under originals root")?;
        let mut resolved = self.root.clone();
        for component in relative.components() {
            match component {
                Component::Normal(name) => {
                    let name = name.to_str().context("scan path must be UTF-8")?;
                    if name.starts_with('.') || name == "@eaDir" || name == "#recycle" {
                        bail!("excluded scan component");
                    }
                    resolved.push(name);
                    match std::fs::symlink_metadata(&resolved) {
                        Ok(metadata) if metadata.file_type().is_symlink() => {
                            bail!("symlinks are not allowed")
                        }
                        Ok(_) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                        Err(error) => return Err(error.into()),
                    }
                }
                Component::CurDir => {}
                _ => bail!("invalid scan component"),
            }
        }
        match std::fs::symlink_metadata(&resolved) {
            Ok(metadata) if scope_kind == "file" && !metadata.is_file() => {
                bail!("file scope must be a regular file")
            }
            Ok(metadata) if scope_kind != "file" && !metadata.is_dir() => {
                bail!("directory scope must be a directory")
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        Ok(resolved)
    }
    #[allow(clippy::too_many_arguments)]
    fn enqueue_scope(
        &self,
        folder_id: &str,
        path: &Path,
        debounce_seconds: i64,
        refresh_metadata: bool,
        wait_for_quiet: bool,
        path_sync: bool,
        scope_kind: &str,
        work_class: &str,
    ) -> Result<Job> {
        let path = self.validate_scan_path(path, scope_kind)?;
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        let tracked: Option<String> = tx
            .query_row(
                "SELECT path FROM folders WHERE id=?1 AND active=1",
                [folder_id],
                |r| r.get(0),
            )
            .optional()?;
        let tracked = tracked.context("folder is missing or inactive")?;
        if !path.starts_with(&tracked) {
            bail!("scan scope must be within tracked folder");
        }
        let scope = path.to_str().context("scan scope must be UTF-8")?;
        let available = chrono::Utc::now().timestamp() + debounce_seconds.max(0);
        tx.execute("INSERT OR IGNORE INTO jobs(id,folder_id,scope_path,scope_kind,status,available_at,wait_for_quiet,work_class) VALUES(?1,?2,?3,?4,'pending',?5,?6,?7)",
            params![Uuid::new_v4().to_string(), folder_id, scope, scope_kind, available, wait_for_quiet, work_class])?;
        tx.execute("UPDATE jobs SET path_sync=MAX(path_sync,?6),refresh_metadata=MAX(refresh_metadata,?4),wait_for_quiet=MAX(wait_for_quiet,?5),rerun=CASE WHEN status='running' OR checkpoint IS NOT NULL THEN 1 ELSE rerun END,available_at=MAX(available_at,?3),updated_at=unixepoch() WHERE folder_id=?1 AND scope_path=?2 AND scope_kind=?7 AND work_class=?8 AND status IN ('pending','running')", params![folder_id,scope,available,refresh_metadata,wait_for_quiet,path_sync,scope_kind,work_class])?;
        let original = tx.query_row(&format!("{JOB_SELECT} WHERE j.folder_id=?1 AND j.scope_path=?2 AND j.scope_kind=?3 AND j.work_class=?4 AND j.status IN ('pending','running')"), params![folder_id,scope,scope_kind,work_class],job)?;
        Self::coalesce_transaction(&tx)?;
        let result = if tx.query_row("SELECT status FROM jobs WHERE id=?", [&original.id], |r| {
            r.get::<_, String>(0)
        })? == "cancelled"
        {
            tx.prepare(&format!(
                "{JOB_SELECT} WHERE j.folder_id=?1 AND j.status='pending' AND j.checkpoint IS NULL"
            ))?
            .query_map([folder_id], job)?
            .collect::<rusqlite::Result<Vec<_>>>()?
            .into_iter()
            .find(|candidate| covers(candidate, &original))
            .context("merged job must retain covering scope")?
        } else {
            tx.query_row(&format!("{JOB_SELECT} WHERE j.id=?1"), [&original.id], job)?
        };
        tx.commit()?;
        Ok(result)
    }
    pub fn coalesce_pending(&self) -> Result<()> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        Self::coalesce_transaction(&tx)?;
        tx.commit()?;
        Ok(())
    }
    fn coalesce_transaction(tx: &rusqlite::Transaction<'_>) -> Result<()> {
        let pending = tx.prepare(&format!("{JOB_SELECT} WHERE j.status='pending' AND j.checkpoint IS NULL ORDER BY length(j.scope_path),CASE j.scope_kind WHEN 'recursive' THEN 0 WHEN 'directory' THEN 1 ELSE 2 END,j.rowid"))?
            .query_map([], job)?.collect::<rusqlite::Result<Vec<_>>>()?;
        let mut retained: Vec<Job> = Vec::new();
        for candidate in pending {
            if let Some(parent) = retained.iter().find(|parent| covers(parent, &candidate)) {
                tx.execute("UPDATE jobs SET refresh_metadata=MAX(refresh_metadata,(SELECT refresh_metadata FROM jobs WHERE id=?2)),path_sync=MAX(path_sync,(SELECT path_sync FROM jobs WHERE id=?2)),wait_for_quiet=MAX(wait_for_quiet,(SELECT wait_for_quiet FROM jobs WHERE id=?2)),available_at=MAX(available_at,(SELECT available_at FROM jobs WHERE id=?2)),rerun=MAX(rerun,(SELECT rerun FROM jobs WHERE id=?2)),updated_at=unixepoch() WHERE id=?1", params![parent.id,candidate.id])?;
                tx.execute("UPDATE jobs SET status='cancelled',finished_at=unixepoch(),updated_at=unixepoch() WHERE id=?1", [&candidate.id])?;
            } else if candidate.scope_kind != "file" {
                // The unique index already deduplicates files; only directories can cover another job.
                retained.push(candidate);
            }
        }
        Ok(())
    }
    pub fn load_checkpoint(&self, id: &str) -> Result<Option<String>> {
        Ok(self.db.lock().unwrap().query_row(
            "SELECT checkpoint FROM jobs WHERE id=?1",
            [id],
            |r| r.get(0),
        )?)
    }
    pub fn save_checkpoint(&self, id: &str, checkpoint: &str) -> Result<()> {
        self.db.lock().unwrap().execute(
            "UPDATE jobs SET checkpoint=?2,updated_at=unixepoch() WHERE id=?1 AND status='running'",
            params![id, checkpoint],
        )?;
        Ok(())
    }
    pub fn save_scan_progress(
        &self,
        id: &str,
        checkpoint: &str,
        processed: i64,
        skipped: i64,
        failed: i64,
    ) -> Result<()> {
        self.db.lock().unwrap().execute(
            "UPDATE jobs SET checkpoint=?2,processed=?3,skipped=?4,failed=?5,current_path=NULL,updated_at=unixepoch() WHERE id=?1 AND status='running'",
            params![id, checkpoint, processed, skipped, failed],
        )?;
        Ok(())
    }
    pub fn jobs(&self, limit: usize) -> Result<Vec<Job>> {
        let db = self.db.lock().unwrap();
        Ok(db
            .prepare(&format!(
                "{JOB_SELECT} ORDER BY j.created_at DESC,j.rowid DESC LIMIT ?1"
            ))?
            .query_map([limit.min(1000) as i64], job)?
            .collect::<rusqlite::Result<_>>()?)
    }
    pub fn retry(&self, id: &str) -> Result<Job> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        let failed = tx
            .query_row(
                &format!("{JOB_SELECT} WHERE j.id=?1 AND j.status='failed' AND f.active=1"),
                [id],
                job,
            )
            .optional()?
            .context("only failed jobs of active folders can be retried")?;
        let existing: Option<String> = tx.query_row("SELECT id FROM jobs WHERE folder_id=?1 AND scope_path=?2 AND scope_kind=?3 AND work_class='manual' AND status IN ('pending','running')", params![failed.folder_id, failed.path, failed.scope_kind], |row| row.get(0)).optional()?;
        let retry_id = if let Some(existing) = existing {
            tx.execute("UPDATE jobs SET attempts=0,available_at=0,error=NULL,path_sync=MAX(path_sync,?2),refresh_metadata=MAX(refresh_metadata,?3),rerun=CASE WHEN status='running' OR checkpoint IS NOT NULL THEN 1 ELSE rerun END,updated_at=unixepoch() WHERE id=?1", params![existing,failed.path_sync,failed.refresh_metadata])?;
            tx.execute("UPDATE jobs SET status='cancelled',finished_at=unixepoch(),updated_at=unixepoch() WHERE id=?1", [id])?;
            existing
        } else {
            tx.execute("UPDATE jobs SET work_class='manual',wait_for_quiet=0,status='pending',attempts=0,available_at=0,error=NULL,checkpoint=NULL,rerun=0,processed=0,skipped=0,failed=0,current_path=NULL,started_at=NULL,finished_at=NULL,updated_at=unixepoch() WHERE id=?1",[id])?;
            id.to_owned()
        };
        let result = tx.query_row(&format!("{JOB_SELECT} WHERE j.id=?1"), [&retry_id], job)?;
        tx.commit()?;
        Ok(result)
    }
    pub fn has_pending_changes(&self, excluding_id: &str) -> Result<bool> {
        Ok(self.db.lock().unwrap().query_row("SELECT EXISTS(SELECT 1 FROM jobs j JOIN folders f ON f.id=j.folder_id WHERE j.refresh_metadata=1 AND j.available_at<=unixepoch() AND f.active=1 AND ((j.id<>?1 AND j.status='pending') OR (j.id=?1 AND j.status='running' AND j.rerun=1)))", [excluding_id], |row| row.get(0))?)
    }
    pub fn directory_scan_pending(&self, library: &str, source: &Path) -> Result<bool> {
        let parent = source.parent().context("cache source has no parent")?;
        let db = self.db.lock().unwrap();
        let mut query = db.prepare("SELECT COALESCE(j.scope_path,f.path),j.scope_kind FROM jobs j JOIN folders f ON f.id=j.folder_id WHERE f.library_id=? AND f.active=1 AND j.work_class='automatic' AND j.status IN ('pending','running')")?;
        let scopes = query.query_map([library], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        for scope in scopes {
            let (path, kind) = scope?;
            let path = Path::new(&path);
            if match kind.as_str() {
                "file" => path.parent() == Some(parent),
                "recursive" => parent.starts_with(path),
                _ => parent == path,
            } {
                return Ok(true);
            }
        }
        Ok(false)
    }
    pub fn path_sync_pending(&self, library: &str, path: &Path) -> Result<bool> {
        let text = path.to_str().context("asset path must be UTF-8")?;
        Ok(self.db.lock().unwrap().query_row("SELECT EXISTS(SELECT 1 FROM jobs j JOIN folders f ON f.id=j.folder_id WHERE f.library_id=?1 AND f.active=1 AND j.path_sync=1 AND j.status IN ('pending','running') AND (?2=j.scope_path OR (j.scope_kind<>'file' AND substr(?2,1,length(rtrim(j.scope_path,'/'))+1)=rtrim(j.scope_path,'/')||'/' AND (j.scope_kind='recursive' OR instr(substr(?2,length(rtrim(j.scope_path,'/'))+2),'/')=0))))", params![library,text], |r| r.get(0))?)
    }
    pub fn should_yield(&self, current: &Job) -> Result<bool> {
        let db = self.db.lock().unwrap();
        let pending = db.prepare(&format!("{JOB_SELECT} WHERE f.active=1 AND j.status='pending' AND j.id<>?1 AND j.available_at<=unixepoch()"))?
            .query_map([&current.id], job)?.collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(pending
            .iter()
            .any(|candidate| job_priority(candidate) > job_priority(current)))
    }
    pub fn has_due_class(&self, work_class: &str) -> Result<bool> {
        validate_work_class(work_class)?;
        Ok(self.db.lock().unwrap().query_row("SELECT EXISTS(SELECT 1 FROM jobs j JOIN folders f ON f.id=j.folder_id WHERE j.work_class=?1 AND j.status='pending' AND j.available_at<=unixepoch() AND f.active=1)", [work_class], |row| row.get(0))?)
    }
    pub fn claim_class(&self, work_class: &str) -> Result<Option<Job>> {
        validate_work_class(work_class)?;
        self.claim(Some(work_class), false)
    }
    pub fn claim_next(&self) -> Result<Option<Job>> {
        self.claim(None, false)
    }
    pub fn claim_automatic_file(&self) -> Result<Option<Job>> {
        self.claim(Some("automatic"), true)
    }
    fn claim(&self, work_class: Option<&str>, file_only: bool) -> Result<Option<Job>> {
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction()?;
        let next = tx.query_row(&format!("{JOB_SELECT} WHERE j.status='pending' AND j.available_at<=unixepoch() AND f.active=1 AND (?1 IS NULL OR j.work_class=?1) AND (?2=0 OR j.scope_kind='file') ORDER BY CASE j.work_class WHEN 'automatic' THEN 2 WHEN 'manual' THEN 1 ELSE 0 END DESC,CASE j.scope_kind WHEN 'file' THEN 2 WHEN 'directory' THEN 1 ELSE 0 END DESC,j.path_sync DESC,CASE WHEN j.path_sync=0 THEN j.refresh_metadata ELSE 0 END DESC,j.created_at,j.rowid LIMIT 1"),params![work_class,file_only],job).optional()?;
        let Some(mut next) = next else {
            return Ok(None);
        };
        tx.execute("UPDATE jobs SET status='running',rerun=CASE WHEN checkpoint IS NULL THEN 0 ELSE rerun END,processed=CASE WHEN checkpoint IS NULL THEN 0 ELSE processed END,skipped=CASE WHEN checkpoint IS NULL THEN 0 ELSE skipped END,failed=CASE WHEN checkpoint IS NULL THEN 0 ELSE failed END,current_path=CASE WHEN checkpoint IS NULL THEN NULL ELSE current_path END,started_at=CASE WHEN checkpoint IS NULL THEN unixepoch() ELSE started_at END,finished_at=NULL,updated_at=unixepoch() WHERE id=?1",[&next.id])?;
        next = tx.query_row(&format!("{JOB_SELECT} WHERE j.id=?1"), [&next.id], job)?;
        tx.commit()?;
        Ok(Some(next))
    }
    pub fn yield_job(&self, id: &str) -> Result<()> {
        self.db.lock().unwrap().execute("UPDATE jobs SET status='pending',updated_at=unixepoch() WHERE id=?1 AND status='running'", [id])?;
        Ok(())
    }
    pub fn finish(&self, id: &str, error: Option<&str>) -> Result<()> {
        self.db.lock().unwrap().execute("UPDATE jobs SET
            status=CASE WHEN rerun=1 OR (?2 IS NOT NULL AND attempts<3) THEN 'pending' WHEN ?2 IS NOT NULL THEN 'failed' ELSE 'completed' END,
            available_at=CASE WHEN ?2 IS NOT NULL THEN MAX(available_at,unixepoch() + 5 * (1 << attempts)) ELSE available_at END,
            attempts=CASE WHEN rerun=1 OR ?2 IS NULL THEN 0 ELSE attempts+1 END,
            checkpoint=NULL,
            processed=CASE WHEN rerun=1 OR (?2 IS NOT NULL AND attempts<3) THEN 0 ELSE processed END,
            skipped=CASE WHEN rerun=1 OR (?2 IS NOT NULL AND attempts<3) THEN 0 ELSE skipped END,
            failed=CASE WHEN rerun=1 OR (?2 IS NOT NULL AND attempts<3) THEN 0 ELSE failed END,
            error=?2,current_path=NULL,finished_at=unixepoch(),updated_at=unixepoch()
            WHERE id=?1 AND status='running'",params![id,error])?;
        Ok(())
    }
    pub fn update_progress(
        &self,
        id: &str,
        processed: i64,
        skipped: i64,
        failed: i64,
        current_path: Option<&str>,
    ) -> Result<()> {
        self.db.lock().unwrap().execute("UPDATE jobs SET processed=?2,skipped=?3,failed=?4,current_path=?5,updated_at=unixepoch() WHERE id=?1 AND status='running'",params![id,processed,skipped,failed,current_path])?;
        Ok(())
    }
    pub fn is_active(&self, folder_id: &str) -> Result<bool> {
        Ok(self
            .db
            .lock()
            .unwrap()
            .query_row("SELECT active FROM folders WHERE id=?1", [folder_id], |r| {
                r.get(0)
            })
            .optional()?
            .unwrap_or(false))
    }
    pub fn file_state(&self, folder_id: &str, path: &str) -> Result<Option<FileState>> {
        Ok(self.db.lock().unwrap().query_row("SELECT size,mtime_ns,asset_id,version,error,metadata_stamp FROM files WHERE folder_id=?1 AND path=?2",params![folder_id,path],|r|Ok(FileState {size:r.get(0)?,mtime_ns:r.get(1)?,asset_id:r.get(2)?,version:r.get(3)?,error:r.get(4)?,metadata_stamp:r.get(5)?})).optional()?)
    }
    pub fn has_path_sync(&self) -> Result<bool> {
        Ok(self.db.lock().unwrap().query_row("SELECT EXISTS(SELECT 1 FROM jobs j JOIN folders f ON f.id=j.folder_id WHERE f.active=1 AND j.path_sync=1 AND j.status IN ('pending','running'))",[],|r|r.get(0))?)
    }
    pub fn pending_identities(&self, limit: usize) -> Result<Vec<(Folder, String)>> {
        let db = self.db.lock().unwrap();
        Ok(db.prepare("SELECT f.id,f.library_id,f.path,f.active,p.path FROM files p JOIN folders f ON f.id=p.folder_id WHERE p.identity_status='pending' AND p.error IS NULL AND f.active=1 LIMIT ?")?.query_map([limit as i64], |r| Ok((folder(r)?,r.get(4)?)))?.collect::<rusqlite::Result<_>>()?)
    }
    pub fn identity_missing(&self, folder_id: &str, path: &str) -> Result<()> {
        self.db.lock().unwrap().execute("UPDATE files SET identity_status='missing',identity_error=NULL WHERE folder_id=? AND path=?",params![folder_id,path])?;
        Ok(())
    }
    pub fn identity_pending(&self, folder_id: &str, path: &str) -> Result<()> {
        self.db.lock().unwrap().execute("UPDATE files SET identity_status='pending',identity_error=NULL WHERE folder_id=? AND path=?",params![folder_id,path])?;
        Ok(())
    }
    pub fn identity_result(&self, folder_id: &str, path: &str, error: Option<&str>) -> Result<()> {
        self.db.lock().unwrap().execute(
            "UPDATE files SET identity_status=?,identity_error=? WHERE folder_id=? AND path=?",
            params![
                if error.is_some() { "failed" } else { "ready" },
                error,
                folder_id,
                path
            ],
        )?;
        Ok(())
    }
    pub fn identity_status(&self, library: &str) -> Result<serde_json::Value> {
        let db = self.db.lock().unwrap();
        let mut counts = serde_json::json!({"pending":0,"ready":0,"failed":0,"batchLimit":1});
        for row in db.prepare("SELECT identity_status,count(*) FROM files p JOIN folders f ON f.id=p.folder_id WHERE f.library_id=? AND f.active=1 GROUP BY identity_status")?.query_map([library], |r| Ok((r.get::<_,String>(0)?,r.get::<_,i64>(1)?)))? {
            let (status,count)=row?;counts[status]=serde_json::json!(count);
        }
        let errors = db.prepare("SELECT p.path,p.identity_error FROM files p JOIN folders f ON f.id=p.folder_id WHERE f.library_id=? AND f.active=1 AND p.identity_status='failed' LIMIT 20")?.query_map([library], |r| Ok(serde_json::json!({"path":r.get::<_,String>(0)?,"error":r.get::<_,String>(1)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
        counts["errors"] = serde_json::json!(errors);
        Ok(counts)
    }
    pub fn record_metadata_stamp(&self, folder_id: &str, path: &str, stamp: &str) -> Result<()> {
        let changed = self.db.lock().unwrap().execute(
            "UPDATE files SET metadata_stamp=?3 WHERE folder_id=?1 AND path=?2",
            params![folder_id, path, stamp],
        )?;
        if changed == 0 {
            bail!("file must be recorded before its metadata stamp");
        }
        Ok(())
    }
    #[allow(clippy::too_many_arguments)]
    pub fn record_file(
        &self,
        folder_id: &str,
        path: &str,
        size: i64,
        mtime_ns: i64,
        asset_id: &str,
        version: &str,
        error: Option<&str>,
    ) -> Result<()> {
        self.db.lock().unwrap().execute("INSERT INTO files(folder_id,path,size,mtime_ns,asset_id,version,error) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(folder_id,path) DO UPDATE SET size=excluded.size,mtime_ns=excluded.mtime_ns,asset_id=excluded.asset_id,version=excluded.version,error=excluded.error",params![folder_id,path,size,mtime_ns,asset_id,version,error])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn manual_only_full_scans_cancel_legacy_work_and_preserve_incremental_jobs() {
        let (dir, jobs, folder) = setup();
        std::fs::create_dir(jobs.root().join("child")).unwrap();
        let legacy = jobs.enqueue_external_scan(&folder.id).unwrap();
        let manual = jobs.enqueue_scan(&folder.id).unwrap();
        let child = jobs
            .enqueue_removed_directory(&folder.id, &jobs.root().join("child"), 0)
            .unwrap();
        let file = jobs
            .enqueue_file_change(&folder.id, &jobs.root().join("new.jpg"), 0)
            .unwrap();
        assert_eq!(jobs.cancel_automatic_full_scans().unwrap(), 1);
        assert_eq!(jobs.job(&legacy.id).unwrap().unwrap().status, "cancelled");
        for id in [&manual.id, &child.id, &file.id] {
            assert_eq!(jobs.job(id).unwrap().unwrap().status, "pending");
        }
        let root = jobs.root().to_path_buf();
        drop(jobs);
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap();
        assert_eq!(jobs.cancel_automatic_full_scans().unwrap(), 0);
        assert_eq!(jobs.job(&manual.id).unwrap().unwrap().status, "pending");
    }

    fn setup() -> (tempfile::TempDir, Jobs, Folder) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("originals");
        std::fs::create_dir(&root).unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap();
        let folder = jobs.add_folder("library", ".").unwrap();
        (dir, jobs, folder)
    }
    #[test]
    fn foreground_file_claim_defers_scans_without_losing_checkpoints() {
        let (_dir, jobs, folder) = setup();
        let recursive = jobs
            .enqueue_path_change(&folder.id, jobs.root(), 0)
            .unwrap();
        let directory = jobs
            .enqueue_directory_change(&folder.id, jobs.root(), 0)
            .unwrap();
        let manual = jobs
            .enqueue_manual_file(&folder.id, &jobs.root().join("manual.jpg"))
            .unwrap();
        let reconcile = jobs.enqueue_external_scan(&folder.id).unwrap();
        let file = jobs
            .enqueue_file_change(&folder.id, &jobs.root().join("changed.jpg"), 0)
            .unwrap();
        jobs.db
            .lock()
            .unwrap()
            .execute(
                "UPDATE jobs SET checkpoint='scan-cursor',processed=17 WHERE id=?",
                [&recursive.id],
            )
            .unwrap();
        assert_eq!(jobs.claim_automatic_file().unwrap().unwrap().id, file.id);
        jobs.finish(&file.id, None).unwrap();
        assert_eq!(jobs.claim_class("manual").unwrap().unwrap().id, manual.id);
        jobs.finish(&manual.id, None).unwrap();
        // The worker can keep generating browse images while only background scans remain.
        for _ in 0..25 {
            assert!(jobs.claim_automatic_file().unwrap().is_none());
            assert!(jobs.claim_class("manual").unwrap().is_none());
        }
        let checkpoint: (String, i64, String, String) = jobs
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT checkpoint,processed,status,work_class FROM jobs WHERE id=?",
                [&recursive.id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert_eq!(
            checkpoint,
            (
                "scan-cursor".into(),
                17,
                "pending".into(),
                "automatic".into()
            )
        );
        let changed = jobs
            .enqueue_file_change(&folder.id, &jobs.root().join("another.jpg"), 0)
            .unwrap();
        assert_eq!(jobs.claim_automatic_file().unwrap().unwrap().id, changed.id);
        jobs.finish(&changed.id, None).unwrap();
        assert_eq!(
            jobs.claim_class("automatic").unwrap().unwrap().id,
            directory.id
        );
        jobs.finish(&directory.id, None).unwrap();
        let resumed = jobs.claim_class("automatic").unwrap().unwrap();
        assert_eq!(resumed.id, recursive.id);
        assert_eq!(resumed.processed, 17);
        assert_eq!(jobs.job(&reconcile.id).unwrap().unwrap().status, "pending");
    }

    #[test]
    fn classes_are_independent_and_reconcile_is_last() {
        let (_dir, jobs, folder) = setup();
        let reconcile = jobs.enqueue_external_scan(&folder.id).unwrap();
        let manual = jobs.enqueue_scan(&folder.id).unwrap();
        let automatic = jobs
            .enqueue_directory_change(&folder.id, jobs.root(), 0)
            .unwrap();
        assert_ne!(reconcile.id, manual.id);
        assert!(
            !jobs
                .directory_scan_pending("other", &jobs.root().join("a.jpg"))
                .unwrap()
        );
        assert!(jobs.claim_class("invalid").is_err());
        assert_eq!(jobs.claim_class("manual").unwrap().unwrap().id, manual.id);
        jobs.yield_job(&manual.id).unwrap();
        for expected in [&automatic.id, &manual.id, &reconcile.id] {
            let next = jobs.claim_next().unwrap().unwrap();
            assert_eq!(&next.id, expected);
            jobs.finish(&next.id, None).unwrap();
        }
        assert!(!jobs.has_due_class("automatic").unwrap());
    }
    #[test]
    fn legacy_class_migration_preserves_checkpoint_and_runs_once() {
        let (dir, jobs, folder) = setup();
        let manual = jobs
            .enqueue_manual_directory(&folder.id, jobs.root())
            .unwrap();
        let reconcile = jobs.enqueue_external_scan(&folder.id).unwrap();
        jobs.claim_class("reconcile").unwrap().unwrap();
        jobs.save_scan_progress(&reconcile.id, "saved-frontier", 7, 2, 0)
            .unwrap();
        let automatic = jobs
            .enqueue_file_change(&folder.id, &jobs.root().join("a.jpg"), 0)
            .unwrap();
        jobs.db
            .lock()
            .unwrap()
            .execute_batch("DROP INDEX jobs_live_scope; ALTER TABLE jobs DROP COLUMN work_class;")
            .unwrap();
        drop(jobs);
        let jobs = Jobs::open(
            &dir.path().join("jobs.sqlite"),
            &dir.path().join("originals"),
        )
        .unwrap();
        assert_eq!(jobs.job(&manual.id).unwrap().unwrap().work_class, "manual");
        assert_eq!(
            jobs.job(&automatic.id).unwrap().unwrap().work_class,
            "automatic"
        );
        let resumed = jobs.claim_class("reconcile").unwrap().unwrap();
        assert_eq!(resumed.id, reconcile.id);
        assert_eq!(resumed.processed, 7);
        assert_eq!(
            jobs.load_checkpoint(&reconcile.id).unwrap().as_deref(),
            Some("saved-frontier")
        );
        assert!(
            !jobs
                .directory_scan_pending("library", &jobs.root().join("child/a.jpg"))
                .unwrap()
        );
        jobs.db
            .lock()
            .unwrap()
            .execute(
                "UPDATE jobs SET wait_for_quiet=0 WHERE id=?1",
                [&reconcile.id],
            )
            .unwrap();
        drop(jobs);
        let jobs = Jobs::open(
            &dir.path().join("jobs.sqlite"),
            &dir.path().join("originals"),
        )
        .unwrap();
        assert_eq!(
            jobs.job(&reconcile.id).unwrap().unwrap().work_class,
            "reconcile"
        );
    }
    #[test]
    fn explicit_retry_becomes_manual_and_reuses_a_live_manual_scope() {
        let (_dir, jobs, folder) = setup();
        let path = jobs.root().join("a.jpg");
        let automatic = jobs.enqueue_file_change(&folder.id, &path, 0).unwrap();
        jobs.db
            .lock()
            .unwrap()
            .execute(
                "UPDATE jobs SET status='failed',checkpoint='obsolete',processed=4 WHERE id=?1",
                [&automatic.id],
            )
            .unwrap();
        let retry = jobs.retry(&automatic.id).unwrap();
        assert_eq!(retry.work_class, "manual");
        assert!(!retry.wait_for_quiet);
        assert_eq!(retry.processed, 0);
        assert!(jobs.load_checkpoint(&retry.id).unwrap().is_none());
        assert!(jobs.ensure_file_retry(&folder.id, &path).unwrap().is_none());
        jobs.claim_class("manual").unwrap().unwrap();
        let another = jobs.enqueue_file_change(&folder.id, &path, 0).unwrap();
        jobs.db
            .lock()
            .unwrap()
            .execute("UPDATE jobs SET status='failed' WHERE id=?1", [&another.id])
            .unwrap();
        assert_eq!(jobs.retry(&another.id).unwrap().id, retry.id);
        assert_eq!(jobs.job(&another.id).unwrap().unwrap().status, "cancelled");
        jobs.finish(&retry.id, None).unwrap();
        assert_eq!(jobs.claim_class("manual").unwrap().unwrap().id, retry.id);
        jobs.finish(&retry.id, None).unwrap();
        assert!(!jobs.has_due_class("manual").unwrap());
    }
    #[test]
    fn manual_file_rebuild_stays_separate_from_automatic_update() {
        let (_dir, jobs, folder) = setup();
        let path = jobs.root().join("a.jpg");
        let automatic = jobs.enqueue_file_change(&folder.id, &path, 0).unwrap();
        let manual = jobs.enqueue_manual_file(&folder.id, &path).unwrap();
        assert_ne!(manual.id, automatic.id);
        assert_eq!(manual.work_class, "manual");
        assert!(!manual.wait_for_quiet);
        assert_eq!(
            jobs.enqueue_manual_file(&folder.id, &path).unwrap().id,
            manual.id
        );
    }
    #[test]
    fn historical_error_gets_only_one_file_retry_until_completed() {
        let (_dir, jobs, folder) = setup();
        let path = jobs.root().join("bad.jpg");
        let retry = jobs.ensure_file_retry(&folder.id, &path).unwrap().unwrap();
        assert_eq!(retry.scope_kind, "file");
        assert!(jobs.ensure_file_retry(&folder.id, &path).unwrap().is_none());
        assert_eq!(jobs.claim_next().unwrap().unwrap().id, retry.id);
        assert!(jobs.ensure_file_retry(&folder.id, &path).unwrap().is_none());
        jobs.db
            .lock()
            .unwrap()
            .execute("UPDATE jobs SET attempts=3 WHERE id=?1", [&retry.id])
            .unwrap();
        jobs.finish(&retry.id, Some("invalid photo")).unwrap();
        assert!(jobs.ensure_file_retry(&folder.id, &path).unwrap().is_none());
        jobs.retry(&retry.id).unwrap();
        jobs.claim_next().unwrap().unwrap();
        jobs.finish(&retry.id, None).unwrap();
        assert!(jobs.ensure_file_retry(&folder.id, &path).unwrap().is_some());
    }
    #[test]
    fn manual_scopes_do_not_absorb_automatic_events() {
        let (_dir, jobs, folder) = setup();
        let child = jobs.root().join("child");
        std::fs::create_dir(&child).unwrap();
        let nested = jobs.enqueue_path_change(&folder.id, &child, 30).unwrap();
        let root = jobs.enqueue_scan(&folder.id).unwrap();
        assert_eq!(jobs.job(&nested.id).unwrap().unwrap().status, "pending");
        assert_eq!(nested.work_class, "automatic");
        assert_eq!(root.work_class, "manual");
        assert!(!root.wait_for_quiet);
        assert!(!jobs.has_due_class("automatic").unwrap());
        assert!(jobs.has_due_class("manual").unwrap());
        assert_eq!(
            jobs.enqueue_reconcile_scope(&folder.id, &child).unwrap().id,
            root.id
        );
    }
    #[test]
    fn precise_events_stay_separate_and_run_before_pending_recursive_scan() {
        let (_dir, jobs, folder) = setup();
        let root = jobs
            .enqueue_external_reconcile_scope(&folder.id, jobs.root())
            .unwrap();
        let directory = jobs
            .enqueue_directory_change(&folder.id, &jobs.root().join("child"), 0)
            .unwrap();
        let file = jobs
            .enqueue_file_change(&folder.id, &jobs.root().join("a.jpg"), 0)
            .unwrap();
        assert_ne!(root.id, directory.id);
        assert_ne!(root.id, file.id);
        for expected in [&file.id, &directory.id, &root.id] {
            let next = jobs.claim_next().unwrap().unwrap();
            assert_eq!(&next.id, expected);
            assert!(!jobs.should_yield(&next).unwrap());
            jobs.finish(&next.id, None).unwrap();
        }
        assert!(jobs.claim_next().unwrap().is_none());
    }
    #[test]
    fn precise_event_preempts_recursive_path_sync_and_preserves_its_checkpoint() {
        let (_dir, jobs, folder) = setup();
        let root = jobs
            .enqueue_external_reconcile_scope(&folder.id, jobs.root())
            .unwrap();
        let running = jobs.claim_next().unwrap().unwrap();
        jobs.save_checkpoint(&root.id, "frontier").unwrap();
        let directory = jobs
            .enqueue_directory_change(&folder.id, &jobs.root().join("child"), 0)
            .unwrap();
        assert!(jobs.should_yield(&running).unwrap());
        jobs.yield_job(&root.id).unwrap();
        let shallow = jobs.claim_next().unwrap().unwrap();
        assert_eq!(shallow.id, directory.id);
        let file = jobs
            .enqueue_file_change(&folder.id, &jobs.root().join("a.jpg"), 0)
            .unwrap();
        assert!(jobs.should_yield(&shallow).unwrap());
        jobs.yield_job(&shallow.id).unwrap();
        let precise = jobs.claim_next().unwrap().unwrap();
        assert_eq!(precise.id, file.id);
        jobs.enqueue_file_change(&folder.id, &jobs.root().join("b.jpg"), 0)
            .unwrap();
        assert!(!jobs.should_yield(&precise).unwrap());
        assert_eq!(
            jobs.load_checkpoint(&root.id).unwrap().as_deref(),
            Some("frontier")
        );
    }
    #[test]
    fn cache_scan_gate_covers_siblings_and_recursive_ancestors_only() {
        let (_dir, jobs, folder) = setup();
        let child = jobs.root().join("child");
        std::fs::create_dir(&child).unwrap();
        jobs.enqueue_file_change(&folder.id, &jobs.root().join("a.3fr"), 0)
            .unwrap();
        assert!(
            jobs.directory_scan_pending("library", &jobs.root().join("a.heic"))
                .unwrap()
        );
        assert!(
            !jobs
                .directory_scan_pending("library", &child.join("a.heic"))
                .unwrap()
        );
        assert!(
            !jobs
                .directory_scan_pending("other", &jobs.root().join("a.heic"))
                .unwrap()
        );
        jobs.claim_next().unwrap().unwrap();
        assert!(
            jobs.directory_scan_pending("library", &jobs.root().join("b.heic"))
                .unwrap()
        );
        jobs.enqueue_scan(&folder.id).unwrap();
        assert!(
            !jobs
                .directory_scan_pending("library", &child.join("a.heic"))
                .unwrap()
        );
    }
    #[test]
    fn shallow_scope_never_absorbs_recursive_child_and_file_does_not_block_descendants() {
        let (_dir, jobs, folder) = setup();
        let child = jobs.root().join("child");
        std::fs::create_dir(&child).unwrap();
        let file = jobs
            .enqueue_file_change(&folder.id, &jobs.root().join("a.jpg"), 0)
            .unwrap();
        assert!(
            !jobs
                .path_sync_pending("library", &jobs.root().join("a.jpg/child"))
                .unwrap()
        );
        let shallow = jobs
            .enqueue_directory_change(&folder.id, jobs.root(), 0)
            .unwrap();
        assert_eq!(jobs.job(&file.id).unwrap().unwrap().status, "pending");
        assert!(
            !jobs
                .path_sync_pending("library", &child.join("a.jpg"))
                .unwrap()
        );
        let recursive = jobs.enqueue_reconcile_scope(&folder.id, &child).unwrap();
        assert_ne!(shallow.id, recursive.id);
        assert_eq!(jobs.job(&shallow.id).unwrap().unwrap().status, "pending");
    }
    #[test]
    fn scan_progress_commits_counters_with_the_resume_cursor() {
        let (_dir, jobs, folder) = setup();
        let queued = jobs.enqueue_scan(&folder.id).unwrap();
        jobs.claim_next().unwrap().unwrap();
        jobs.update_progress(&queued.id, 0, 0, 0, Some("a.jpg"))
            .unwrap();
        jobs.save_scan_progress(&queued.id, "next-entry", 1, 2, 3)
            .unwrap();
        jobs.yield_job(&queued.id).unwrap();
        let resumed = jobs.claim_next().unwrap().unwrap();
        assert_eq!(
            (resumed.processed, resumed.skipped, resumed.failed),
            (1, 2, 3)
        );
        assert!(resumed.current_path.is_none());
        assert_eq!(
            jobs.load_checkpoint(&queued.id).unwrap().as_deref(),
            Some("next-entry")
        );
    }
    #[test]
    fn checkpoint_survives_yield_restart_and_concurrent_event_gets_fresh_pass() {
        let (dir, jobs, folder) = setup();
        let queued = jobs.enqueue_scan(&folder.id).unwrap();
        jobs.claim_next().unwrap().unwrap();
        jobs.update_progress(&queued.id, 2, 7, 0, Some("previous.jpg"))
            .unwrap();
        jobs.save_checkpoint(&queued.id, "frontier").unwrap();
        jobs.yield_job(&queued.id).unwrap();
        jobs.enqueue_scan(&folder.id).unwrap();
        drop(jobs);
        let jobs = Jobs::open(
            &dir.path().join("jobs.sqlite"),
            &dir.path().join("originals"),
        )
        .unwrap();
        let resumed = jobs.claim_next().unwrap().unwrap();
        assert_eq!((resumed.processed, resumed.skipped), (2, 7));
        assert_eq!(resumed.current_path.as_deref(), Some("previous.jpg"));
        assert_eq!(
            jobs.load_checkpoint(&queued.id).unwrap().as_deref(),
            Some("frontier")
        );
        jobs.finish(&queued.id, None).unwrap();
        assert!(jobs.load_checkpoint(&queued.id).unwrap().is_none());
        let rerun = jobs.claim_next().unwrap().unwrap();
        assert_eq!((rerun.processed, rerun.skipped), (0, 0));
        jobs.finish(&rerun.id, None).unwrap();
        assert!(jobs.claim_next().unwrap().is_none());
    }
    #[test]
    fn running_or_resumable_ancestor_does_not_absorb_later_file_event() {
        let (_dir, jobs, folder) = setup();
        let root = jobs.enqueue_scan(&folder.id).unwrap();
        jobs.claim_next().unwrap().unwrap();
        jobs.save_checkpoint(&root.id, "frontier").unwrap();
        let file = jobs
            .enqueue_file_change(&folder.id, &jobs.root().join("a.jpg"), 0)
            .unwrap();
        jobs.yield_job(&root.id).unwrap();
        jobs.coalesce_pending().unwrap();
        assert_eq!(jobs.job(&file.id).unwrap().unwrap().status, "pending");
        assert_eq!(jobs.claim_next().unwrap().unwrap().id, file.id);
    }
    #[test]
    fn deleted_paths_are_safe_and_symlinks_remain_forbidden() {
        let (_dir, jobs, folder) = setup();
        assert!(
            jobs.enqueue_file_change(&folder.id, &jobs.root().join("gone/nested/a.jpg"), 0)
                .is_ok()
        );
        assert!(
            jobs.enqueue_removed_directory(&folder.id, &jobs.root().join("gone"), 0)
                .is_ok()
        );
        for path in ["../escape", ".hidden/a.jpg", "gone/../../escape"] {
            assert!(jobs.validate_scan_path(Path::new(path), "file").is_err());
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(jobs.root().join("missing"), jobs.root().join("link"))
                .unwrap();
            assert!(
                jobs.validate_scan_path(&jobs.root().join("link/a.jpg"), "file")
                    .is_err()
            );
        }
    }
    #[test]
    fn library_job_limit_keeps_old_running_job_before_newer_queue_and_history() {
        let (_dir, jobs, folder) = setup();
        let other = jobs.add_folder("other-library", ".").unwrap();
        {
            let db = jobs.db.lock().unwrap();
            for (id, status, created_at) in [
                ("running", "running", 1),
                ("pending-old", "pending", 2),
                ("pending-new-first", "pending", 3),
                ("pending-new-last", "pending", 3),
                ("completed", "completed", 4),
            ] {
                db.execute(
                    "INSERT INTO jobs(id,folder_id,scope_path,status,created_at) VALUES(?1,?2,?1,?3,?4)",
                    params![id, folder.id, status, created_at],
                )
                .unwrap();
            }
            db.execute(
                "INSERT INTO jobs(id,folder_id,scope_path,status,created_at) VALUES('other-running',?1,'other','running',5)",
                [&other.id],
            )
            .unwrap();
        }
        assert_eq!(
            jobs.jobs_for_library("library", 1).unwrap()[0].id,
            "running"
        );
        let ids: Vec<_> = jobs
            .jobs_for_library("library", 5)
            .unwrap()
            .into_iter()
            .map(|job| job.id)
            .collect();
        assert_eq!(
            ids,
            [
                "running",
                "pending-new-last",
                "pending-new-first",
                "pending-old",
                "completed"
            ]
        );
    }
    #[test]
    fn path_changes_preempt_metadata_and_only_block_their_scope() {
        let (dir, jobs, folder) = setup();
        let moved = jobs.root().join("moved");
        std::fs::create_dir(&moved).unwrap();
        let metadata = jobs
            .enqueue_change(&folder.id, Path::new(&folder.path), 0)
            .unwrap();
        let running = jobs.claim_next().unwrap().unwrap();
        let path_job = jobs
            .enqueue_external_reconcile_scope(&folder.id, &moved)
            .unwrap();
        assert!(jobs.should_yield(&running).unwrap());
        assert!(
            jobs.path_sync_pending("library", &moved.join("a.raw"))
                .unwrap()
        );
        assert!(
            !jobs
                .path_sync_pending("library", &jobs.root().join("moved-other/a.raw"))
                .unwrap()
        );
        assert!(
            !jobs
                .path_sync_pending("other", &moved.join("a.raw"))
                .unwrap()
        );
        jobs.yield_job(&metadata.id).unwrap();
        let priority = jobs.claim_next().unwrap().unwrap();
        assert_eq!(priority.id, path_job.id);
        assert!(!jobs.should_yield(&priority).unwrap());
        jobs.finish(&priority.id, None).unwrap();
        assert!(
            !jobs
                .path_sync_pending("library", &moved.join("a.raw"))
                .unwrap()
        );
        assert_eq!(jobs.claim_next().unwrap().unwrap().id, metadata.id);
        drop(jobs);
        let jobs = Jobs::open(
            &dir.path().join("jobs.sqlite"),
            &dir.path().join("originals"),
        )
        .unwrap();
        assert!(
            !jobs
                .path_sync_pending("library", &moved.join("a.raw"))
                .unwrap()
        );
    }
    #[test]
    fn path_sync_does_not_yield_to_another_path_sync_with_metadata() {
        let (_dir, jobs, folder) = setup();
        let first = jobs.root().join("first");
        let second = jobs.root().join("second");
        std::fs::create_dir(&first).unwrap();
        std::fs::create_dir(&second).unwrap();
        let initial = jobs.enqueue_path_change(&folder.id, &first, 0).unwrap();
        let running = jobs.claim_next().unwrap().unwrap();
        jobs.enqueue_path_change(&folder.id, &second, 0).unwrap();
        jobs.enqueue_change(&folder.id, &second, 0).unwrap();
        assert!(!jobs.should_yield(&running).unwrap());
        jobs.yield_job(&running.id).unwrap();
        assert_eq!(jobs.claim_next().unwrap().unwrap().id, initial.id);
    }
    #[test]
    fn legacy_scoped_discovery_is_promoted_but_periodic_root_is_not() {
        let (dir, jobs, folder) = setup();
        jobs.enqueue_external_scan(&folder.id).unwrap();
        let child = jobs.root().join("child");
        std::fs::create_dir(&child).unwrap();
        let scoped = jobs
            .enqueue_external_reconcile_scope(&folder.id, &child)
            .unwrap();
        jobs.db
            .lock()
            .unwrap()
            .execute_batch("ALTER TABLE jobs DROP COLUMN path_sync")
            .unwrap();
        drop(jobs);
        let jobs = Jobs::open(
            &dir.path().join("jobs.sqlite"),
            &dir.path().join("originals"),
        )
        .unwrap();
        assert_eq!(jobs.claim_next().unwrap().unwrap().id, scoped.id);
        assert!(
            !jobs
                .path_sync_pending("library", &jobs.root().join("elsewhere.raw"))
                .unwrap()
        );
    }
    #[test]
    fn revision_source_is_sticky_across_merges_yields_and_restart() {
        let (dir, jobs, folder) = setup();
        let manual = jobs.enqueue_scan(&folder.id).unwrap();
        assert!(!manual.wait_for_quiet);
        assert!(!manual.refresh_metadata);
        let external = jobs.enqueue_external_scan(&folder.id).unwrap();
        assert_ne!(external.id, manual.id);
        assert_eq!(external.work_class, "reconcile");
        assert!(external.wait_for_quiet);
        assert!(!external.refresh_metadata);
        assert!(!jobs.enqueue_scan(&folder.id).unwrap().wait_for_quiet);
        let running = jobs.claim_next().unwrap().unwrap();
        jobs.yield_job(&running.id).unwrap();
        assert_eq!(jobs.job(&running.id).unwrap().unwrap().status, "pending");
        drop(jobs);
        let jobs = Jobs::open(
            &dir.path().join("jobs.sqlite"),
            &dir.path().join("originals"),
        )
        .unwrap();
        let recovered = jobs.claim_next().unwrap().unwrap();
        assert_eq!(recovered.id, manual.id);
        assert!(!recovered.wait_for_quiet);
        assert_eq!(recovered.work_class, "manual");
        jobs.finish(&recovered.id, None).unwrap();
        let manual = jobs
            .enqueue_reconcile_scope(&folder.id, Path::new(&folder.path))
            .unwrap();
        assert!(!manual.wait_for_quiet);
        assert!(
            jobs.enqueue_external_reconcile_scope(&folder.id, Path::new(&folder.path))
                .unwrap()
                .wait_for_quiet
        );
        assert!(
            jobs.enqueue_change(&folder.id, Path::new(&folder.path), 0)
                .unwrap()
                .wait_for_quiet
        );
    }
    #[test]
    fn legacy_jobs_default_to_quiet_waiting() {
        let (dir, jobs, folder) = setup();
        let queued = jobs.enqueue_scan(&folder.id).unwrap();
        jobs.db
            .lock()
            .unwrap()
            .execute_batch("ALTER TABLE jobs DROP COLUMN wait_for_quiet")
            .unwrap();
        drop(jobs);
        let jobs = Jobs::open(
            &dir.path().join("jobs.sqlite"),
            &dir.path().join("originals"),
        )
        .unwrap();
        assert!(jobs.job(&queued.id).unwrap().unwrap().wait_for_quiet);
    }
    #[test]
    fn queue_deduplicates_and_recovers_after_restart() {
        let (dir, jobs, folder) = setup();
        let a = jobs.enqueue_scan(&folder.id).unwrap();
        assert_eq!(a.id, jobs.enqueue_scan(&folder.id).unwrap().id);
        assert_eq!(jobs.claim_next().unwrap().unwrap().id, a.id);
        assert!(jobs.claim_next().unwrap().is_none());
        drop(jobs);
        let jobs = Jobs::open(
            &dir.path().join("jobs.sqlite"),
            &dir.path().join("originals"),
        )
        .unwrap();
        assert_eq!(jobs.claim_next().unwrap().unwrap().id, a.id);
        jobs.finish(&a.id, None).unwrap();
        assert_eq!(jobs.jobs(10).unwrap()[0].status, "completed");
        assert_ne!(jobs.enqueue_scan(&folder.id).unwrap().id, a.id);
    }
    #[test]
    fn change_during_scan_gets_another_pass_and_scopes_survive_restart() {
        let (dir, jobs, folder) = setup();
        let scope = jobs.root().join("child");
        std::fs::create_dir(&scope).unwrap();
        let queued = jobs.enqueue_change(&folder.id, &scope, 0).unwrap();
        let running = jobs.claim_next().unwrap().unwrap();
        assert_eq!(running.path, scope.to_str().unwrap());
        assert_eq!(
            jobs.enqueue_change(&folder.id, &scope, 0).unwrap().id,
            queued.id
        );
        jobs.finish(&running.id, None).unwrap();
        drop(jobs);
        let jobs = Jobs::open(
            &dir.path().join("jobs.sqlite"),
            &dir.path().join("originals"),
        )
        .unwrap();
        let rerun = jobs.claim_next().unwrap().unwrap();
        assert_eq!(rerun.path, scope.to_str().unwrap());
        jobs.finish(&rerun.id, None).unwrap();
        assert!(jobs.claim_next().unwrap().is_none());
        jobs.enqueue_change(&folder.id, &scope, 60).unwrap();
        assert!(jobs.claim_next().unwrap().is_none());
        jobs.remove_folder(&folder.id).unwrap();
        assert!(jobs.claim_next().unwrap().is_none());
    }
    #[test]
    fn root_change_interrupts_incremental_scan_and_preserves_refresh() {
        let (_dir, jobs, folder) = setup();
        let initial = jobs.enqueue_scan(&folder.id).unwrap();
        let running = jobs.claim_next().unwrap().unwrap();
        assert!(!running.refresh_metadata);
        assert!(!jobs.has_pending_changes(&running.id).unwrap());
        jobs.enqueue_change(&folder.id, Path::new(&folder.path), 0)
            .unwrap();
        assert!(jobs.has_pending_changes(&running.id).unwrap());
        jobs.enqueue_scan(&folder.id).unwrap();
        jobs.finish(&initial.id, None).unwrap();
        assert!(jobs.claim_next().unwrap().unwrap().refresh_metadata);
    }
    #[test]
    fn removal_cancels_without_touching_originals() {
        let (dir, jobs, folder) = setup();
        let original = dir.path().join("originals/a.jpg");
        std::fs::write(&original, b"original").unwrap();
        let a = jobs.enqueue_scan(&folder.id).unwrap();
        jobs.claim_next().unwrap();
        jobs.remove_folder(&folder.id).unwrap();
        jobs.finish(&a.id, None).unwrap();
        assert_eq!(jobs.jobs(10).unwrap()[0].status, "cancelled");
        assert!(!jobs.is_active(&folder.id).unwrap());
        assert!(jobs.enqueue_scan(&folder.id).is_err());
        assert_eq!(std::fs::read(&original).unwrap(), b"original");
    }
    #[test]
    fn failed_jobs_retry_and_file_changes_are_persisted() {
        let (_dir, jobs, folder) = setup();
        let a = jobs.enqueue_scan(&folder.id).unwrap();
        jobs.claim_next().unwrap();
        jobs.update_progress(&a.id, 1, 2, 3, Some("a.jpg")).unwrap();
        jobs.finish(&a.id, Some("decoder failed")).unwrap();
        for _ in 0..3 {
            jobs.db
                .lock()
                .unwrap()
                .execute("UPDATE jobs SET available_at=0", [])
                .unwrap();
            jobs.claim_next().unwrap().unwrap();
            jobs.update_progress(&a.id, 1, 2, 3, Some("a.jpg")).unwrap();
            jobs.finish(&a.id, Some("decoder failed")).unwrap();
        }
        let failed = jobs.jobs(1).unwrap().remove(0);
        assert_eq!((failed.processed, failed.skipped, failed.failed), (1, 2, 3));
        assert!(failed.finished_at.is_some());
        assert_eq!(jobs.retry(&a.id).unwrap().status, "pending");
        assert!(jobs.retry(&a.id).is_err());
        jobs.record_file(&folder.id, "a.jpg", 10, 100, "asset", "hash1", None)
            .unwrap();
        assert_eq!(
            jobs.file_state(&folder.id, "a.jpg")
                .unwrap()
                .unwrap()
                .metadata_stamp,
            ""
        );
        jobs.record_metadata_stamp(&folder.id, "a.jpg", "sidecar:10:100")
            .unwrap();
        let before = jobs.file_state(&folder.id, "a.jpg").unwrap().unwrap();
        jobs.record_file(
            &folder.id,
            "a.jpg",
            20,
            200,
            "asset",
            "hash2",
            Some("error"),
        )
        .unwrap();
        let after = jobs.file_state(&folder.id, "a.jpg").unwrap().unwrap();
        assert_ne!((before.size, before.mtime_ns), (after.size, after.mtime_ns));
        assert_eq!(after.metadata_stamp, "sidecar:10:100");
        assert_eq!(after.version, "hash2");
        assert_eq!(after.asset_id, "asset");
        assert_eq!(after.error.as_deref(), Some("error"));
    }
    #[test]
    fn queue_transactions_reserve_writer_before_reading_to_avoid_stale_wal_snapshot() -> Result<()>
    {
        let (_tmp, jobs, folder) = setup();
        let mut db = jobs.db.lock().unwrap();
        let tx = db.transaction()?;
        let _: String = tx.query_row(
            "SELECT path FROM folders WHERE id=?1",
            [&folder.id],
            |row| row.get(0),
        )?;
        let progress = jobs.trash_db.lock().unwrap();
        progress.busy_timeout(std::time::Duration::ZERO)?;
        let competing_write =
            progress.execute("UPDATE folders SET active=active WHERE id=?1", [&folder.id]);
        assert!(
            competing_write.is_err(),
            "a progress commit must not invalidate a queue transaction's read snapshot"
        );
        tx.execute("UPDATE folders SET active=active WHERE id=?1", [&folder.id])?;
        tx.commit()?;
        progress.execute("UPDATE folders SET active=active WHERE id=?1", [&folder.id])?;
        Ok(())
    }

    #[test]
    fn paths_cannot_escape_or_enter_excluded_directories() {
        let (dir, jobs, _folder) = setup();
        for name in [".hidden", "@eaDir", "#recycle"] {
            std::fs::create_dir(dir.path().join("originals").join(name)).unwrap();
            assert!(jobs.add_folder("library", name).is_err());
        }
        assert!(jobs.add_folder("library", "..").is_err());
        assert!(
            jobs.add_folder("library", dir.path().to_str().unwrap())
                .is_err()
        );
        assert!(jobs.add_folder("library", "missing").is_err());
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(dir.path(), dir.path().join("originals/link")).unwrap();
            assert!(jobs.add_folder("library", "link").is_err());
        }
    }
}
