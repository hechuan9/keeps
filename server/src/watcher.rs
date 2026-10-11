//! Filesystem events drive scoped work; full-library scans require a manual request.
use crate::{
    jobs::{Folder, Jobs},
    media,
    store::Store,
    worker::maintain_revisions,
};
use anyhow::{Context, Result};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

/// Rebuild watches at startup, then adjust only changed subtrees.
pub fn run(
    jobs: Arc<Jobs>,
    store: Arc<Store>,
    stop: Arc<AtomicBool>,
    mut ready: Option<tokio::sync::oneshot::Sender<()>>,
) -> Result<()> {
    let (sender, receiver) = mpsc::sync_channel(4096);
    let overflow = Arc::new(AtomicBool::new(false));
    let callback_overflow = overflow.clone();
    let mut watcher = notify::recommended_watcher(move |event| {
        forward_event(&sender, &callback_overflow, event);
    })
    .context("initialize filesystem watcher")?;
    let mut watched = HashSet::new();
    let mut folders: Vec<Folder> = Vec::new();
    let mut structure_changed = true;
    let mut refresh = Instant::now();
    while !stop.load(Ordering::Relaxed) {
        if Instant::now() >= refresh {
            maintain_revisions(&store, &jobs)?;
            let active: Vec<_> = jobs.folders()?.into_iter().filter(|f| f.active).collect();
            let changed = active.iter().map(|f| (&f.id, &f.path)).collect::<Vec<_>>()
                != folders.iter().map(|f| (&f.id, &f.path)).collect::<Vec<_>>();
            folders = active;
            if changed || structure_changed {
                if structure_changed {
                    invalidate_watches(&mut watcher, &mut watched, jobs.root());
                }
                synchronize(&jobs, &mut watcher, &mut watched, &folders)?;
                structure_changed = false;
                if let Some(ready) = ready.take() {
                    let _ = ready.send(());
                }
            }
            refresh = Instant::now() + Duration::from_secs(5);
        }
        if overflow.swap(false, Ordering::Relaxed) {
            tracing::warn!(
                "filesystem event queue overflowed; run a manual scan to recover missed changes"
            );
            structure_changed = true;
            refresh = Instant::now();
        }
        match receiver.recv_timeout(Duration::from_millis(250)) {
            Ok(Ok(event)) => {
                if event.need_rescan() {
                    tracing::warn!(
                        "filesystem events were lost; run a manual scan to recover missed changes"
                    );
                    structure_changed = true;
                    refresh = Instant::now();
                } else if meaningful_event(&event.kind) {
                    for path in &event.paths {
                        let directory = watched.contains(path)
                            || path.is_dir()
                            || matches!(
                                event.kind,
                                EventKind::Create(notify::event::CreateKind::Folder)
                                    | EventKind::Remove(notify::event::RemoveKind::Folder)
                            );
                        if directory
                            && !matches!(
                                event.kind,
                                EventKind::Create(_)
                                    | EventKind::Remove(_)
                                    | EventKind::Modify(notify::event::ModifyKind::Name(_))
                                    | EventKind::Any
                                    | EventKind::Other
                            )
                        {
                            continue;
                        }
                        if directory
                            && matches!(
                                event.kind,
                                EventKind::Remove(_)
                                    | EventKind::Modify(notify::event::ModifyKind::Name(_))
                            )
                        {
                            invalidate_watches(&mut watcher, &mut watched, path);
                        }
                        queue_event_path(&store, &jobs, &folders, path, directory)?;
                        if directory && !excluded_path(jobs.root(), path) {
                            update_subtree(&jobs, &mut watcher, &mut watched, &folders, path)?;
                        }
                    }
                }
            }

            Ok(Err(error)) => {
                tracing::error!(error = %error, "filesystem watch failed; run a manual scan to recover missed changes");
                structure_changed = true;
                refresh = Instant::now();
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(error) => return Err(error).context("filesystem watcher disconnected"),
        }
    }
    Ok(())
}

fn forward_event(
    sender: &mpsc::SyncSender<notify::Result<notify::Event>>,
    overflow: &AtomicBool,
    event: notify::Result<notify::Event>,
) {
    if event
        .as_ref()
        .is_ok_and(|event| !event.need_rescan() && !meaningful_event(&event.kind))
    {
        return;
    }
    if sender.try_send(event).is_err() {
        overflow.store(true, Ordering::Relaxed);
    }
}

fn meaningful_event(kind: &EventKind) -> bool {
    !matches!(
        kind,
        EventKind::Access(_)
            | EventKind::Modify(notify::event::ModifyKind::Metadata(
                notify::event::MetadataKind::AccessTime
            ))
    )
}

fn queue_event_path(
    store: &Store,
    jobs: &Jobs,
    _folders: &[Folder],
    path: &Path,
    directory: bool,
) -> Result<()> {
    let _guard = jobs.directory_mutation.read().unwrap();
    crate::directory_move::ensure_reconciled(jobs)?;
    let folders = jobs.folders()?;
    if excluded_path(jobs.root(), path) {
        return Ok(());
    }
    let sidecar = path
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("xmp"));
    if !directory && !sidecar && !media::is_photo(path) && !media::is_video(path) {
        return Ok(());
    }
    for folder in folders
        .iter()
        .filter(|folder| folder.active && path.starts_with(&folder.path))
    {
        let queued = if directory && path == jobs.root() {
            jobs.enqueue_directory_change(&folder.id, path, 2)
        } else if directory {
            jobs.enqueue_removed_directory(&folder.id, path, 2)
        } else if sidecar {
            // A stem XMP can describe multiple same-stem originals in this directory.
            jobs.enqueue_directory_change(&folder.id, path.parent().unwrap(), 2)
        } else {
            jobs.enqueue_file_change(&folder.id, path, 2)
        };
        match queued {
            Ok(job) => store.note_revision_activity(&job.library_id, &job.id, &job.path)?,
            Err(error) if jobs.is_active(&folder.id)? => {
                tracing::error!(path=%path.display(), error=%format!("{error:#}"), "could not queue filesystem change");
            }
            Err(_) => {}
        }
    }
    Ok(())
}

fn invalidate_watches(
    watcher: &mut RecommendedWatcher,
    watched: &mut HashSet<PathBuf>,
    path: &Path,
) {
    for old in watched
        .iter()
        .filter(|p| p.starts_with(path))
        .cloned()
        .collect::<Vec<_>>()
    {
        if let Err(error) = watcher.unwatch(&old) {
            tracing::debug!(path=%old.display(), error=%error, "directory watch already unavailable");
        }
        watched.remove(&old);
    }
}

fn update_subtree(
    jobs: &Jobs,
    watcher: &mut RecommendedWatcher,
    watched: &mut HashSet<PathBuf>,
    folders: &[Folder],
    path: &Path,
) -> Result<()> {
    if path.is_dir() {
        let scopes: Vec<_> = folders
            .iter()
            .filter(|f| path.starts_with(&f.path))
            .map(|f| Folder {
                path: path.to_string_lossy().into_owned(),
                ..f.clone()
            })
            .collect();
        add_watches(jobs, watcher, watched, &scopes)?;
    } else {
        invalidate_watches(watcher, watched, path);
    }
    Ok(())
}

fn excluded_path(root: &Path, path: &Path) -> bool {
    let Ok(relative) = path.strip_prefix(root) else {
        return true;
    };
    let mut cursor = root.to_path_buf();
    for part in relative.components() {
        let std::path::Component::Normal(name) = part else {
            return true;
        };
        let name = name.to_string_lossy();
        if name.starts_with('.') || name == "@eaDir" || name == "#recycle" {
            return true;
        }
        cursor.push(part);
        if std::fs::symlink_metadata(&cursor).is_ok_and(|m| m.file_type().is_symlink()) {
            return true;
        }
    }
    false
}

fn synchronize(
    jobs: &Jobs,
    watcher: &mut RecommendedWatcher,
    watched: &mut HashSet<PathBuf>,
    folders: &[Folder],
) -> Result<()> {
    for path in watched
        .iter()
        .filter(|path| !folders.iter().any(|f| path.starts_with(&f.path)))
        .cloned()
        .collect::<Vec<_>>()
    {
        watcher
            .unwatch(&path)
            .with_context(|| format!("remove watch {}", path.display()))?;
        watched.remove(&path);
    }
    add_watches(jobs, watcher, watched, folders)
}

fn add_watches(
    jobs: &Jobs,
    watcher: &mut RecommendedWatcher,
    watched: &mut HashSet<PathBuf>,
    folders: &[Folder],
) -> Result<()> {
    let mut visited = HashSet::new();
    let mut pending: Vec<PathBuf> = folders.iter().map(|f| PathBuf::from(&f.path)).collect();
    while let Some(path) = pending.pop() {
        if excluded_path(jobs.root(), &path) || !path.is_dir() || !visited.insert(path.clone()) {
            continue;
        }
        // Register before enumeration so new children are observed during initialization.
        if !watched.contains(&path) {
            match watcher.watch(&path, RecursiveMode::NonRecursive) {
                Ok(()) => {}
                Err(error) if matches!(&error.kind, notify::ErrorKind::Io(io) if io.kind() == std::io::ErrorKind::NotFound) =>
                {
                    continue;
                }
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("register filesystem watch {}", path.display()));
                }
            }
            watched.insert(path.clone());
        }
        let entries = match std::fs::read_dir(&path) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("enumerate watch directory {}", path.display()));
            }
        };
        for entry in entries {
            let entry =
                entry.with_context(|| format!("read watch directory entry {}", path.display()))?;
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => pending.push(entry.path()),
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!("inspect watch entry {}", entry.path().display())
                    });
                }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installing_watches_does_not_scan_existing_photos() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("originals");
        std::fs::create_dir_all(root.join("child")).unwrap();
        std::fs::write(root.join("child/existing.jpg"), b"existing photo").unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap();
        let folder = jobs.add_folder("library", ".").unwrap();
        let mut watcher = notify::recommended_watcher(|_| {}).unwrap();
        let mut watched = HashSet::new();
        for _ in 0..2 {
            synchronize(
                &jobs,
                &mut watcher,
                &mut watched,
                std::slice::from_ref(&folder),
            )
            .unwrap();
            assert!(jobs.jobs(10).unwrap().is_empty());
            invalidate_watches(&mut watcher, &mut watched, jobs.root());
        }
        let manual = jobs.enqueue_scan(&folder.id).unwrap();
        assert_eq!(manual.work_class, "manual");
        assert_eq!(manual.scope_kind, "recursive");
    }

    #[test]
    fn root_directory_event_only_scans_the_direct_layer() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("originals");
        std::fs::create_dir_all(&root).unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap();
        let store = Store::open(&dir.path().join("catalog.sqlite"), true).unwrap();
        let folder = jobs.add_folder("library", ".").unwrap();
        queue_event_path(&store, &jobs, &[folder], jobs.root(), true).unwrap();
        let job = jobs.jobs(10).unwrap().remove(0);
        assert_eq!(job.work_class, "automatic");
        assert_eq!(job.scope_kind, "directory");
    }

    #[test]
    fn self_generated_access_events_cannot_overflow_the_change_queue() {
        let (sender, receiver) = mpsc::sync_channel(1);
        let overflow = AtomicBool::new(false);
        for _ in 0..5000 {
            forward_event(
                &sender,
                &overflow,
                Ok(notify::Event::new(EventKind::Access(
                    notify::event::AccessKind::Read,
                ))),
            );
        }
        assert!(receiver.try_recv().is_err());
        assert!(!overflow.load(Ordering::Relaxed));
        forward_event(
            &sender,
            &overflow,
            Ok(notify::Event::new(EventKind::Create(
                notify::event::CreateKind::File,
            ))),
        );
        assert!(receiver.try_recv().is_ok());
        assert!(!overflow.load(Ordering::Relaxed));
    }

    #[test]
    fn event_paths_ignore_hidden_and_symlink_targets_and_queue_deleted_parent() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("originals");
        std::fs::create_dir(&root).unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap();
        let store = Store::open(&dir.path().join("catalog.sqlite"), true).unwrap();
        let folder = jobs.add_folder("library", ".").unwrap();
        let root = jobs.root().to_path_buf();
        queue_event_path(
            &store,
            &jobs,
            std::slice::from_ref(&folder),
            &root.join("@eaDir/a.jpg"),
            false,
        )
        .unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(dir.path(), root.join("link")).unwrap();
            queue_event_path(
                &store,
                &jobs,
                std::slice::from_ref(&folder),
                &root.join("link/outside.jpg"),
                false,
            )
            .unwrap();
        }
        assert!(jobs.jobs(10).unwrap().is_empty());
        queue_event_path(&store, &jobs, &[folder], &root.join("deleted.jpg"), false).unwrap();
        assert_eq!(
            jobs.jobs(10).unwrap()[0].path,
            root.join("deleted.jpg").to_str().unwrap()
        );
        assert_eq!(jobs.jobs(10).unwrap()[0].scope_kind, "file");
        assert!(jobs.jobs(10).unwrap()[0].path_sync);
        assert!(
            jobs.path_sync_pending("library", &root.join("deleted.jpg"))
                .unwrap()
        );
    }

    #[test]
    fn file_events_are_exact_and_sidecars_only_scan_their_directory() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("originals");
        std::fs::create_dir_all(root.join("child")).unwrap();
        let jobs = Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap();
        let store = Store::open(&dir.path().join("catalog.sqlite"), true).unwrap();
        let folder = jobs.add_folder("library", ".").unwrap();
        let root = jobs.root().to_path_buf();
        let target = root.join("child/a.dng");
        queue_event_path(&store, &jobs, std::slice::from_ref(&folder), &target, false).unwrap();
        let file = jobs.jobs(10).unwrap().remove(0);
        assert_eq!(file.path, target.to_str().unwrap());
        assert_eq!(file.scope_kind, "file");
        assert!(!file.refresh_metadata);
        queue_event_path(&store, &jobs, &[folder], &root.join("child/a.xmp"), false).unwrap();
        let live: Vec<_> = jobs
            .jobs(10)
            .unwrap()
            .into_iter()
            .filter(|j| j.status == "pending")
            .collect();
        assert_eq!(live.len(), 2);
        assert!(
            live.iter()
                .any(|job| job.id == file.id && job.scope_kind == "file")
        );
        let directory = live
            .iter()
            .find(|job| job.scope_kind == "directory")
            .unwrap();
        assert_eq!(directory.path, root.join("child").to_str().unwrap());
        assert!(!meaningful_event(&EventKind::Access(
            notify::event::AccessKind::Read
        )));
        assert!(!meaningful_event(&EventKind::Modify(
            notify::event::ModifyKind::Metadata(notify::event::MetadataKind::AccessTime)
        )));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn recreated_directory_receives_new_file_events() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("originals");
        let child = root.join("child");
        std::fs::create_dir_all(&child).unwrap();
        let jobs = Arc::new(Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap());
        jobs.add_folder("library", ".").unwrap();
        let store = Arc::new(Store::open(&dir.path().join("catalog.sqlite"), true).unwrap());
        let stop = Arc::new(AtomicBool::new(false));
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
        let handle = {
            let jobs = jobs.clone();
            let stop = stop.clone();
            std::thread::spawn(move || run(jobs, store, stop, Some(ready_tx)))
        };
        ready_rx.blocking_recv().unwrap();
        std::fs::remove_dir(&child).unwrap();
        std::fs::create_dir(&child).unwrap();
        std::thread::sleep(Duration::from_millis(400));
        let new_file = child.join("new.jpg");
        std::fs::write(&new_file, b"synthetic event fixture").unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !jobs
            .jobs(100)
            .unwrap()
            .iter()
            .any(|j| j.scope_kind == "file" && j.path == new_file.to_str().unwrap())
        {
            if Instant::now() >= deadline {
                stop.store(true, Ordering::Relaxed);
                handle.join().unwrap().unwrap();
                panic!("recreated directory did not receive a new file event");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        stop.store(true, Ordering::Relaxed);
        handle.join().unwrap().unwrap();
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_watcher_observes_file_written_after_start() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("originals");
        std::fs::create_dir(&root).unwrap();
        let jobs = Arc::new(Jobs::open(&dir.path().join("jobs.sqlite"), &root).unwrap());
        jobs.add_folder("library", ".").unwrap();
        let root = jobs.root().to_path_buf();
        let stop = Arc::new(AtomicBool::new(false));
        let worker_jobs = jobs.clone();
        let worker_stop = stop.clone();
        let store = Arc::new(Store::open(&dir.path().join("catalog.sqlite"), true).unwrap());
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
        let handle =
            std::thread::spawn(move || run(worker_jobs, store, worker_stop, Some(ready_tx)));
        ready_rx.blocking_recv().unwrap();
        assert!(jobs.jobs(10).unwrap().is_empty());
        let new_file = root.join("new.jpg");
        std::fs::write(&new_file, b"sample").unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while !jobs
            .jobs(10)
            .unwrap()
            .iter()
            .any(|job| job.scope_kind == "file" && job.path == new_file.to_str().unwrap())
        {
            if Instant::now() >= deadline {
                stop.store(true, Ordering::Relaxed);
                handle.join().unwrap().unwrap();
                panic!("watcher did not receive the new file event");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        stop.store(true, Ordering::Relaxed);
        handle.join().unwrap().unwrap();
    }
}
