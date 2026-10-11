//! Explicit folder deletion through DSM's native recycle program.
use crate::{
    jobs::Jobs,
    store::{Store, StoreError},
};
use anyhow::{Context, Result, ensure};
#[cfg(test)]
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
};

fn error(status: u16, message: impl Into<String>) -> anyhow::Error {
    StoreError {
        status,
        code: "directory_trash_failed".into(),
        message: message.into(),
    }
    .into()
}

#[derive(Debug)]
pub(crate) struct SharedFolder {
    name: String,
    path: PathBuf,
}

pub(crate) fn recycle_share(config: &str, source: &Path) -> Result<SharedFolder> {
    let mut shares = Vec::new();
    let mut path = None;
    let mut name = String::new();
    let mut enabled = false;
    for line in config.lines().chain(std::iter::once("[end]")) {
        let line = line.trim();
        if line.starts_with('[') && line.ends_with(']') {
            if let Some(path) = path.take() {
                shares.push((
                    SharedFolder {
                        name: name.clone(),
                        path,
                    },
                    enabled,
                ));
            }
            name = line[1..line.len() - 1].to_owned();
            enabled = false;
        } else if let Some((key, value)) = line.split_once('=') {
            match key.trim() {
                "path" => path = Some(PathBuf::from(value.trim())),
                "enable recycle bin" => enabled = value.trim() == "yes",
                _ => {}
            }
        }
    }
    let (share, enabled) = shares
        .into_iter()
        .filter(|(share, _)| source.starts_with(&share.path))
        .max_by_key(|(share, _)| share.path.components().count())
        .context(error(
            503,
            "No DSM shared folder configuration for this directory",
        ))?;
    ensure!(
        enabled,
        error(503, "NAS recycle bin is disabled for this shared folder")
    );
    ensure!(
        source != share.path,
        error(422, "A NAS shared-folder root cannot be deleted")
    );
    let recycle = share.path.join("#recycle");
    let metadata = fs::symlink_metadata(&recycle)
        .with_context(|| error(503, "NAS recycle bin is unavailable"))?;
    ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        error(
            503,
            "NAS recycle bin must be an existing directory, not a symbolic link"
        )
    );
    ensure!(
        recycle.canonicalize()? == recycle,
        error(503, "NAS recycle bin path cannot contain symbolic links")
    );
    ensure!(
        !source.starts_with(&recycle),
        error(422, "Cannot delete the recycle bin")
    );
    Ok(share)
}

fn recycle_command(
    share: &SharedFolder,
    source: &Path,
    operation: &str,
) -> Result<std::process::Command> {
    let relative = source
        .strip_prefix(&share.path)?
        .to_str()
        .context("path must be UTF-8")?;
    let mut command = std::process::Command::new("/usr/syno/bin/synorecycle");
    command.args([
        operation,
        &format!("share={}", share.name),
        &format!("rpath={relative}"),
    ]);
    Ok(command)
}

fn recycle_native(share: &SharedFolder, source: &Path) -> Result<()> {
    recycle_native_operation(share, source, "--rmdir")
}

pub(crate) fn recycle_file(share: &SharedFolder, source: &Path) -> Result<()> {
    recycle_native_operation(share, source, "--unlink")
}

fn recycle_native_operation(share: &SharedFolder, source: &Path, operation: &str) -> Result<()> {
    let output = recycle_command(share, source, operation)?
        .output()
        .context(error(
            503,
            "DSM native recycle program is unavailable; no fallback deletion was attempted",
        ))?;
    ensure!(
        output.status.success(),
        error(
            500,
            format!(
                "DSM recycle failed ({}): {} {}. Check NAS recycle bin for any partially processed contents",
                output.status,
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr),
            )
        )
    );
    ensure!(
        !source.try_exists()?,
        error(
            500,
            "DSM recycle returned success but the source path still exists"
        )
    );
    Ok(())
}

fn validate(jobs: &Jobs, library: &str, path: &str, confirmation: &str) -> Result<PathBuf> {
    let source = jobs
        .validate_path(Path::new(path))
        .map_err(|e| error(422, format!("{e:#}")))?;
    ensure!(
        source != jobs.root(),
        error(422, "The originals root cannot be deleted")
    );
    let name = source
        .file_name()
        .and_then(|s| s.to_str())
        .context("folder name must be UTF-8")?;
    ensure!(
        confirmation == name,
        error(422, "Confirmation must exactly match the folder name")
    );
    let folders = jobs.folders()?;
    ensure!(
        folders
            .iter()
            .any(|f| f.active && f.library_id == library && source.starts_with(&f.path)),
        error(404, "Directory is not tracked in this library")
    );
    ensure!(
        !folders.iter().any(|f| f.active
            && f.library_id != library
            && (source.starts_with(&f.path) || Path::new(&f.path).starts_with(&source))),
        error(409, "Directory overlaps another library's tracking roots")
    );
    Ok(source)
}

fn reconcile(jobs: &Jobs, store: &Store, library: &str, source: &Path) -> Result<()> {
    // Native recursive deletion can partially succeed; reconcile absent paths even on failure.
    let folders = jobs.folders()?;
    (|| -> Result<()> {
        store.mark_missing_under(library, source.to_str().context("path must be UTF-8")?)?;
        for folder in folders.iter().filter(|f| {
            f.active && f.library_id == library && Path::new(&f.path).starts_with(source)
        }) {
            if !Path::new(&folder.path).try_exists()? {
                jobs.remove_folder(&folder.id)?;
            }
        }
        let text = source.to_str().context("path must be UTF-8")?;
        if !source.try_exists()? {
            jobs.db.lock().unwrap().execute("UPDATE jobs SET status='cancelled',finished_at=unixepoch(),updated_at=unixepoch() WHERE folder_id IN (SELECT id FROM folders WHERE library_id=?1) AND (scope_path=?2 OR (scope_path>=?3 AND scope_path<?4)) AND status IN ('pending','running')", rusqlite::params![library, text, format!("{text}/"), format!("{text}0")])?;
        }
        store.reconcile_cache()?;
        Ok(())
    })()?;
    Ok(())
}

#[cfg(test)]
fn trash_with_config(
    jobs: &Jobs,
    store: &Store,
    library: &str,
    path: &str,
    confirmation: &str,
    config: impl FnOnce() -> Result<String>,
    recycle: impl FnOnce(&SharedFolder, &Path) -> Result<()>,
) -> Result<Value> {
    let _guard = jobs.directory_mutation.write().unwrap();
    crate::directory_move::ensure_reconciled(jobs)?;
    let source = validate(jobs, library, path, confirmation)?;
    let share = recycle_share(&config()?, &source)?;
    let recycle_result = recycle(&share, &source);
    reconcile(jobs, store, library, &source)?;
    recycle_result?;
    Ok(json!({"path":source}))
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TrashTask {
    pub id: String,
    pub path: String,
    pub status: String,
    pub phase: String,
    pub error: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
    pub finished_at: Option<i64>,
}

pub(crate) fn initialize(db: &rusqlite::Connection) -> Result<()> {
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS directory_trash_tasks(
        id TEXT PRIMARY KEY, library_id TEXT NOT NULL, path TEXT NOT NULL,
        confirmation TEXT NOT NULL, status TEXT NOT NULL, phase TEXT NOT NULL,
        error TEXT, created_at INTEGER NOT NULL DEFAULT(unixepoch()),
        updated_at INTEGER NOT NULL DEFAULT(unixepoch()), finished_at INTEGER);
        CREATE UNIQUE INDEX IF NOT EXISTS directory_trash_active_library
        ON directory_trash_tasks(library_id) WHERE status IN ('pending','running');",
    )?;
    Ok(())
}

fn task(row: &rusqlite::Row<'_>) -> rusqlite::Result<TrashTask> {
    Ok(TrashTask {
        id: row.get(0)?,
        path: row.get(1)?,
        status: row.get(2)?,
        phase: row.get(3)?,
        error: row.get(4)?,
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
        finished_at: row.get(7)?,
    })
}
const TASK_SELECT: &str = "SELECT id,path,status,phase,error,created_at,updated_at,finished_at FROM directory_trash_tasks";

pub(crate) fn get(jobs: &Jobs, library: &str, id: &str) -> Result<TrashTask> {
    use rusqlite::OptionalExtension;
    let id = uuid::Uuid::parse_str(id)
        .map_err(|_| error(422, "requestID must be a UUID"))?
        .to_string();
    jobs.trash_db
        .lock()
        .unwrap()
        .query_row(
            &format!("{TASK_SELECT} WHERE id=?1 AND library_id=?2"),
            rusqlite::params![id, library],
            task,
        )
        .optional()?
        .ok_or_else(|| error(404, "Directory deletion task not found"))
}

pub(crate) fn submit(
    jobs: &Jobs,
    library: &str,
    path: &str,
    confirmation: &str,
    id: &str,
) -> Result<TrashTask> {
    use rusqlite::OptionalExtension;
    let id = uuid::Uuid::parse_str(id)
        .map_err(|_| {
            error(
                422,
                "requestID must be a UUID; update the client to use asynchronous folder deletion",
            )
        })?
        .to_string();
    // Check durable identity before filesystem validation: the source may already be recycled.
    {
        let db = jobs.trash_db.lock().unwrap();
        let existing: Option<(String, String, String)> = db
            .query_row(
                "SELECT library_id,path,confirmation FROM directory_trash_tasks WHERE id=?1",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        if let Some((old_library, old_path, old_confirmation)) = existing {
            ensure!(
                old_library == library && old_path == path && old_confirmation == confirmation,
                error(
                    409,
                    "requestID already belongs to a different deletion request"
                )
            );
            drop(db);
            return get(jobs, library, &id);
        }
    }
    let source = validate(jobs, library, path, confirmation)?;
    // Require canonical absolute input so retries compare the same persisted request.
    ensure!(
        source.to_str() == Some(path),
        error(422, "Directory path must be canonical and absolute")
    );
    let db = jobs.trash_db.lock().unwrap();
    let inserted = db.execute("INSERT OR IGNORE INTO directory_trash_tasks(id,library_id,path,confirmation,status,phase) VALUES(?1,?2,?3,?4,'pending','waiting')",rusqlite::params![id,library,path,confirmation])?;
    drop(db);
    if inserted == 0 {
        if let Ok(existing) = get(jobs, library, &id) {
            ensure!(
                existing.path == path,
                error(
                    409,
                    "requestID already belongs to a different deletion request"
                )
            );
            return Ok(existing);
        }
        return Err(error(
            409,
            "Another folder deletion is active in this library",
        ));
    }
    get(jobs, library, &id)
}

fn transition(jobs: &Jobs, id: &str, phase: &str, message: Option<&str>) -> Result<()> {
    let status = match phase {
        "completed" => "completed",
        "failed" => "failed",
        _ => "running",
    };
    jobs.trash_db.lock().unwrap().execute("UPDATE directory_trash_tasks SET status=?2,phase=?3,error=?4,updated_at=unixepoch(),finished_at=CASE WHEN ?2 IN ('completed','failed') THEN unixepoch() ELSE NULL END WHERE id=?1",rusqlite::params![id,status,phase,message])?;
    Ok(())
}

fn process(
    jobs: &Jobs,
    store: &Store,
    library: &str,
    current: &TrashTask,
    confirmation: &str,
    config: impl FnOnce() -> Result<String>,
    recycle: impl FnOnce(&SharedFolder, &Path) -> Result<()>,
) -> Result<()> {
    let _guard = jobs.directory_mutation.write().unwrap();
    crate::directory_move::ensure_reconciled(jobs)?;
    let source = Path::new(&current.path);
    let mut native_error = current.error.clone();
    match current.phase.as_str() {
        "waiting" => {
            let source = validate(jobs, library, &current.path, confirmation)?;
            let share = recycle_share(&config()?, &source)?;
            transition(jobs, &current.id, "recycling", None)?;
            native_error = recycle(&share, &source).err().map(|e| {
                format!("{e:#}. Check NAS recycle bin for any partially processed contents")
            });
        }
        "recycling" => {
            jobs.validate_scan_path(source, "recursive")?;
            if source.try_exists()? {
                native_error=Some("Server restarted during NAS recycling. Some contents may already be recycled; inspect the source and NAS recycle bin before submitting a new request. The native operation was not replayed".into());
            }
        }
        "reconciling" => {
            jobs.validate_scan_path(source, "recursive")?;
        }
        other => anyhow::bail!("unexpected deletion phase {other}"),
    }
    transition(jobs, &current.id, "reconciling", native_error.as_deref())?;
    reconcile(jobs, store, library, source).context(
        "NAS recycling may have completed; catalog reconciliation failed. Inspect NAS recycle bin",
    )?;
    transition(
        jobs,
        &current.id,
        if native_error.is_some() {
            "failed"
        } else {
            "completed"
        },
        native_error.as_deref(),
    )
}

pub fn run(
    jobs: std::sync::Arc<Jobs>,
    store: std::sync::Arc<Store>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
) -> Result<()> {
    use rusqlite::OptionalExtension;
    while !stop.load(std::sync::atomic::Ordering::Relaxed) {
        let next = {
            let db = jobs.trash_db.lock().unwrap();
            db.query_row("SELECT id,path,status,phase,error,created_at,updated_at,finished_at,library_id,confirmation FROM directory_trash_tasks WHERE status IN ('pending','running') ORDER BY created_at,id LIMIT 1",[],|row|Ok((task(row)?,row.get::<_,String>(8)?,row.get::<_,String>(9)?))).optional()?
        };
        if let Some((current, library, confirmation)) = next {
            let result = process(
                &jobs,
                &store,
                &library,
                &current,
                &confirmation,
                || {
                    fs::read_to_string("/etc/samba/smb.share.conf")
                        .context("DSM shared-folder recycle configuration is unavailable")
                },
                recycle_native,
            );
            if let Err(failure) = result {
                tracing::error!(id=%current.id,error=%format!("{failure:#}"),"Directory recycling task failed");
                transition(&jobs, &current.id, "failed", Some(&format!("{failure:#}")))?;
            }
        } else if !crate::rejected_trash::process_next(&jobs, &store)? {
            std::thread::sleep(std::time::Duration::from_millis(250));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> (tempfile::TempDir, Jobs, Store, String) {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("photos");
        fs::create_dir_all(root.join("#recycle")).unwrap();
        let jobs = Jobs::open(&tmp.path().join("jobs.sqlite"), &root).unwrap();
        jobs.add_folder("lib", jobs.root().to_str().unwrap())
            .unwrap();
        let store = Store::open(&tmp.path().join("catalog.sqlite"), true).unwrap();
        let config = format!(
            "[photo]\npath={}\nenable recycle bin=yes\n",
            jobs.root().display()
        );
        (tmp, jobs, store, config)
    }

    // This stand-in exercises catalog reconciliation; DSM semantics are checked on the NAS.
    fn simulate_removal(share: &SharedFolder, source: &Path) -> Result<()> {
        fs::rename(
            source,
            share
                .path
                .join("#recycle")
                .join(source.file_name().unwrap()),
        )?;
        Ok(())
    }

    #[test]
    fn async_request_is_durable_idempotent_and_excludes_another_active_task() -> Result<()> {
        let (tmp, jobs, store, config) = setup();
        let source = jobs.root().join("folder");
        fs::create_dir(&source)?;
        let path = source.to_str().unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let queued = submit(&jobs, "lib", path, "folder", &id)?;
        assert_eq!(
            (queued.status.as_str(), queued.phase.as_str()),
            ("pending", "waiting")
        );
        assert_eq!(submit(&jobs, "lib", path, "folder", &id)?.id, id);
        assert!(submit(&jobs, "lib", path, "folder ", &id).is_err());
        assert!(submit(&jobs, "other", path, "folder", &id).is_err());
        assert!(
            submit(
                &jobs,
                "lib",
                path,
                "folder",
                &uuid::Uuid::new_v4().to_string()
            )
            .is_err()
        );
        assert!(get(&jobs, "other", &id).is_err());
        drop(jobs);
        let jobs = Jobs::open(&tmp.path().join("jobs.sqlite"), &tmp.path().join("photos"))?;
        let recovered = get(&jobs, "lib", &id.to_uppercase())?;
        process(
            &jobs,
            &store,
            "lib",
            &recovered,
            "folder",
            || Ok(config),
            |share, source| {
                assert_eq!(get(&jobs, "lib", &id)?.phase, "recycling");
                simulate_removal(share, source)
            },
        )?;
        let completed = get(&jobs, "lib", &id)?;
        assert_eq!(completed.phase, "completed");
        assert!(completed.finished_at.is_some());
        assert!(!source.exists());
        assert_eq!(
            submit(&jobs, "lib", path, "folder", &id)?.status,
            "completed"
        );
        Ok(())
    }

    #[test]
    fn restart_during_recycling_never_replays_native_operation() -> Result<()> {
        for disappeared in [false, true] {
            let (tmp, jobs, store, _config) = setup();
            let source = jobs.root().join("folder");
            fs::create_dir(&source)?;
            let id = uuid::Uuid::new_v4().to_string();
            submit(&jobs, "lib", source.to_str().unwrap(), "folder", &id)?;
            transition(&jobs, &id, "recycling", None)?;
            if disappeared {
                fs::rename(&source, jobs.root().join("#recycle/folder"))?;
            }
            drop(jobs);
            let jobs = Jobs::open(&tmp.path().join("jobs.sqlite"), &tmp.path().join("photos"))?;
            let current = get(&jobs, "lib", &id)?;
            process(
                &jobs,
                &store,
                "lib",
                &current,
                "folder",
                || panic!("must not reload native config"),
                |_, _| panic!("must not replay recycle"),
            )?;
            let finished = get(&jobs, "lib", &id)?;
            assert_eq!(
                finished.status,
                if disappeared { "completed" } else { "failed" }
            );
            if !disappeared {
                assert!(finished.error.unwrap().contains("may already be recycled"));
            }
        }
        Ok(())
    }

    #[test]
    fn reconciliation_resume_retains_native_failure() -> Result<()> {
        let (_tmp, jobs, store, _) = setup();
        let source = jobs.root().join("folder");
        fs::create_dir(&source)?;
        let id = uuid::Uuid::new_v4().to_string();
        submit(&jobs, "lib", source.to_str().unwrap(), "folder", &id)?;
        transition(&jobs, &id, "reconciling", Some("partial native failure"))?;
        process(
            &jobs,
            &store,
            "lib",
            &get(&jobs, "lib", &id)?,
            "folder",
            || panic!("no config"),
            |_, _| panic!("no recycle"),
        )?;
        let result = get(&jobs, "lib", &id)?;
        assert_eq!(result.status, "failed");
        assert_eq!(result.error.as_deref(), Some("partial native failure"));
        Ok(())
    }

    #[test]
    fn status_does_not_wait_for_directory_lock_or_scan_database_transaction() -> Result<()> {
        let (_tmp, jobs, _store, _) = setup();
        let source = jobs.root().join("folder");
        fs::create_dir(&source)?;
        let id = uuid::Uuid::new_v4().to_string();
        submit(&jobs, "lib", source.to_str().unwrap(), "folder", &id)?;
        let _guard = jobs.directory_mutation.write().unwrap();
        let db = jobs.db.lock().unwrap();
        db.execute_batch("BEGIN IMMEDIATE; UPDATE folders SET active=active")?;
        assert_eq!(get(&jobs, "lib", &id)?.phase, "waiting");
        db.execute_batch("ROLLBACK")?;
        Ok(())
    }

    #[test]
    fn native_command_passes_exact_share_and_relative_path_without_shell() -> Result<()> {
        let share = SharedFolder {
            name: "photo".into(),
            path: "/volume2/photo".into(),
        };
        let command = recycle_command(
            &share,
            Path::new("/volume2/photo/家庭/旅行 & RAW $(test)"),
            "--rmdir",
        )?;
        assert_eq!(command.get_program(), "/usr/syno/bin/synorecycle");
        assert_eq!(
            command.get_args().collect::<Vec<_>>(),
            ["--rmdir", "share=photo", "rpath=家庭/旅行 & RAW $(test)"]
        );
        Ok(())
    }

    #[test]
    fn file_recycle_uses_native_unlink_with_literal_arguments() -> Result<()> {
        let share = SharedFolder {
            name: "photo".into(),
            path: "/volume2/photo".into(),
        };
        let command = recycle_command(
            &share,
            Path::new("/volume2/photo/family/a & b.raw"),
            "--unlink",
        )?;
        assert_eq!(command.get_program(), "/usr/syno/bin/synorecycle");
        assert_eq!(
            command.get_args().collect::<Vec<_>>(),
            ["--unlink", "share=photo", "rpath=family/a & b.raw"]
        );
        Ok(())
    }

    #[test]
    fn refuses_mismatch_roots_disabled_missing_and_symlink_recycle_before_execution() -> Result<()>
    {
        let (_tmp, jobs, store, config) = setup();
        let source = jobs.root().join("folder");
        fs::create_dir(&source)?;
        let run = |path: &Path, name: &str, config: &str| {
            trash_with_config(
                &jobs,
                &store,
                "lib",
                path.to_str().unwrap(),
                name,
                || Ok(config.to_owned()),
                |_, _| panic!("invalid request must never invoke DSM deletion"),
            )
        };
        assert!(run(&source, "folder ", &config).is_err());
        assert!(run(jobs.root(), "photos", &config).is_err());
        assert!(run(&source, "folder", &config.replace("=yes", "=no")).is_err());
        fs::rename(
            jobs.root().join("#recycle"),
            jobs.root().join("recycle-old"),
        )?;
        assert!(run(&source, "folder", &config).is_err());
        std::os::unix::fs::symlink(
            jobs.root().join("recycle-old"),
            jobs.root().join("#recycle"),
        )?;
        assert!(run(&source, "folder", &config).is_err());
        assert!(source.exists());
        Ok(())
    }

    #[test]
    fn native_failure_keeps_originals_and_tracking_without_fallback() -> Result<()> {
        let (_tmp, jobs, store, config) = setup();
        let source = jobs.root().join("folder");
        fs::create_dir(&source)?;
        fs::write(source.join("photo.raw"), b"original")?;
        let folder = jobs.add_folder("lib", source.to_str().unwrap())?;
        let result = trash_with_config(
            &jobs,
            &store,
            "lib",
            source.to_str().unwrap(),
            "folder",
            || Ok(config),
            |_, _| anyhow::bail!("native permission denied"),
        );
        assert!(format!("{:#}", result.unwrap_err()).contains("native permission denied"));
        assert_eq!(fs::read(source.join("photo.raw"))?, b"original");
        assert!(
            jobs.folders()?
                .iter()
                .find(|f| f.id == folder.id)
                .unwrap()
                .active
        );
        assert_eq!(fs::read_dir(jobs.root().join("#recycle"))?.count(), 0);
        Ok(())
    }

    #[test]
    fn catalog_reconciles_native_deletion_and_retains_other_locations() -> Result<()> {
        for retain_other in [false, true] {
            let (_tmp, jobs, store, config) = setup();
            let source = jobs.root().join("folder");
            fs::create_dir(&source)?;
            let folder = jobs.add_folder("lib", source.to_str().unwrap())?;
            let file = json!({"contentHash":"hash", "sizeBytes":8, "role":"jpeg_original"});
            let snapshot = json!({"contentFingerprint":"hash", "metadataFingerprint":"metadata", "createdAt":"2024-01-01T00:00:00Z", "updatedAt":"2024-01-01T00:00:00Z", "originalFilename":"photo.jpg", "rating":0, "flagState":"unflagged", "tags":[]});
            let photo = source.join("photo.jpg");
            fs::write(&photo, b"original")?;
            store.ingest_original("lib", photo.to_str().unwrap(), &file, &snapshot)?;
            if retain_other {
                let other = jobs.root().join("retained.jpg");
                fs::write(&other, b"original")?;
                store.ingest_original("lib", other.to_str().unwrap(), &file, &snapshot)?;
            }
            let before = store.library_revision("lib")?;
            let result = trash_with_config(
                &jobs,
                &store,
                "lib",
                source.to_str().unwrap(),
                "folder",
                || Ok(config),
                simulate_removal,
            )?;
            assert_eq!(result, json!({"path": source}));
            assert_ne!(store.library_revision("lib")?, before);
            assert_eq!(
                store.directory_photo_counts("lib", &[source.to_string_lossy().into_owned()])?,
                vec![(0, 0)]
            );
            assert_eq!(store.counts("lib", false)?["all"], i32::from(retain_other));
            assert_eq!(
                store.query_assets("lib", &Default::default())?["total"],
                i32::from(retain_other)
            );
            assert!(
                !jobs
                    .folders()?
                    .iter()
                    .find(|f| f.id == folder.id)
                    .unwrap()
                    .active
            );
        }
        Ok(())
    }

    #[test]
    fn partial_native_failure_reconciles_only_missing_contents() -> Result<()> {
        let (_tmp, jobs, store, config) = setup();
        let source = jobs.root().join("folder");
        fs::create_dir(&source)?;
        let folder = jobs.add_folder("lib", source.to_str().unwrap())?;
        for name in ["removed.jpg", "retained.jpg"] {
            let path = source.join(name);
            fs::write(&path, name)?;
            store.ingest_original("lib", path.to_str().unwrap(),
                &json!({"contentHash":name,"sizeBytes":12,"role":"jpeg_original"}),
                &json!({"contentFingerprint":name,"metadataFingerprint":name,"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","originalFilename":name,"rating":0,"flagState":"unflagged","tags":[]}))?;
        }
        let result = trash_with_config(
            &jobs,
            &store,
            "lib",
            source.to_str().unwrap(),
            "folder",
            || Ok(config),
            |share, source| {
                fs::rename(
                    source.join("removed.jpg"),
                    share.path.join("#recycle/removed.jpg"),
                )?;
                anyhow::bail!("native operation partially completed")
            },
        );
        assert!(result.is_err());
        assert_eq!(store.counts("lib", false)?["all"], 1);
        assert_eq!(
            store.directory_photo_counts("lib", &[source.to_string_lossy().into_owned()])?,
            vec![(1, 1)]
        );
        assert!(source.join("retained.jpg").exists());
        assert!(
            jobs.folders()?
                .iter()
                .find(|f| f.id == folder.id)
                .unwrap()
                .active
        );
        Ok(())
    }

    #[test]
    fn longest_share_boundary_and_other_library_are_protected() -> Result<()> {
        let (_tmp, jobs, store, config) = setup();
        let source = jobs.root().join("folder");
        fs::create_dir(&source)?;
        let nested_config = format!(
            "{config}[nested]\npath={}\nenable recycle bin=no\n",
            source.display()
        );
        assert!(recycle_share(&nested_config, &source.join("child")).is_err());
        jobs.add_folder("other", source.to_str().unwrap())?;
        assert!(
            trash_with_config(
                &jobs,
                &store,
                "lib",
                source.to_str().unwrap(),
                "folder",
                || Ok(config),
                |_, _| panic!("cross-library delete must be rejected")
            )
            .is_err()
        );
        assert!(source.exists());
        Ok(())
    }
}
