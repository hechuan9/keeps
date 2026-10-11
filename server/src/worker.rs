use crate::{
    jobs::{Job, Jobs},
    media::{self, MediaProcessor},
    previews::PreviewStorage,
    store::Store,
    versions::VersionEvidence,
};
use anyhow::{Context, Result, bail, ensure};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant, UNIX_EPOCH},
};

/// Run on one dedicated blocking thread. A stopped in-flight job stays running so
/// Jobs::open can recover it after restart without claiming a partial scan succeeded.
pub fn run(
    store: Arc<Store>,
    jobs: Arc<Jobs>,
    previews: Arc<PreviewStorage>,
    stop: Arc<AtomicBool>,
) -> Result<()> {
    MediaProcessor::new()
        .probe()
        .context("NAS media runtime unavailable")?;
    crate::tasks::recover(&jobs)?;
    store.recover_cache()?;
    let mut prefer_manual = false;
    let mut next_maintenance = Instant::now();
    while !stop.load(Ordering::Relaxed) {
        let mut worked = false;
        if prefer_manual && let Some(job) = jobs.claim_class("manual")? {
            run_claimed(&store, &jobs, &previews, &job, &stop)?;
            prefer_manual = false;
            worked = true;
        } else if let Some(job) = jobs.claim_automatic_file()? {
            run_claimed(&store, &jobs, &previews, &job, &stop)?;
            prefer_manual = true;
            worked = true;
        } else if crate::cache_pipeline::process_next(&store, &jobs, &previews, &stop)? {
            prefer_manual = true;
            worked = true;
        } else if let Some(job) = jobs.claim_class("manual")? {
            run_claimed(&store, &jobs, &previews, &job, &stop)?;
            prefer_manual = false;
            worked = true;
        }
        if !worked && !stop.load(Ordering::Relaxed) {
            worked = crate::browse_cache::process_next(&store, &previews)?;
        }
        if !worked
            && !stop.load(Ordering::Relaxed)
            && let Some(job) = jobs.claim_class("automatic")?
        {
            run_claimed(&store, &jobs, &previews, &job, &stop)?;
            worked = true;
        }
        if !worked && !stop.load(Ordering::Relaxed) {
            if Instant::now() >= next_maintenance {
                crate::cache_pipeline::maintain(&store, &jobs, &previews, &stop)?;
                next_maintenance = Instant::now() + Duration::from_secs(60);
                continue;
            }
            if let Some(job) = jobs.claim_class("reconcile")? {
                run_claimed(&store, &jobs, &previews, &job, &stop)?;
                worked = true;
            }
        }
        maintain_revisions(&store, &jobs)?;
        if !worked {
            std::thread::sleep(Duration::from_millis(500));
        }
    }
    Ok(())
}

fn run_claimed(
    store: &Store,
    jobs: &Jobs,
    previews: &PreviewStorage,
    job: &Job,
    stop: &AtomicBool,
) -> Result<()> {
    let result = run_slice(store, jobs, previews, job, stop, 1);
    if stop.load(Ordering::Relaxed) {
        return Ok(());
    }
    match result {
        Ok(true) => jobs.finish(&job.id, None)?,
        Ok(false) => {
            if jobs.job(&job.id)?.is_some_and(|j| j.status == "running") {
                jobs.yield_job(&job.id)?;
            }
        }
        Err(error) => {
            let trace = format!("{error:#}");
            tracing::error!(job_id=%job.id,error=%trace,"NAS photo task failed");
            jobs.finish(&job.id, Some(&trace))?;
        }
    }
    Ok(())
}

/// Read durable queue state, since finish may have scheduled a retry or another pass.
pub fn maintain_revisions(store: &Store, jobs: &Jobs) -> Result<()> {
    for id in store.revision_batch_ids()? {
        match jobs.job(&id)? {
            Some(job) if matches!(job.status.as_str(), "pending" | "running") => {}
            Some(job) if job.status == "completed" => {
                store.finish_revision_batch(&id, job.wait_for_quiet)?
            }
            _ => store.finish_revision_batch(&id, true)?,
        }
    }
    store.settle_revision_updates()?;
    Ok(())
}

#[derive(Default)]
struct Progress {
    processed: i64,
    skipped: i64,
    failed: i64,
    last_error: Option<String>,
}

pub fn run_one(
    store: &Store,
    jobs: &Jobs,
    previews: &PreviewStorage,
    job: &Job,
    stop: &AtomicBool,
) -> Result<bool> {
    run_slice(store, jobs, previews, job, stop, usize::MAX)
}

fn run_slice(
    store: &Store,
    jobs: &Jobs,
    previews: &PreviewStorage,
    job: &Job,
    stop: &AtomicBool,
    limit: usize,
) -> Result<bool> {
    let _directory_guard = jobs.directory_mutation.read().unwrap();
    crate::directory_move::ensure_reconciled(jobs)?;
    let current = jobs.job(&job.id)?.context("claimed job disappeared")?;
    let job = &current;
    if stopped(jobs, job, stop)? {
        return Ok(false);
    }
    let mut units = 0;
    let root = jobs.validate_scan_path(Path::new(&job.path), &job.scope_kind)?;
    let mut progress = Progress {
        processed: job.processed,
        skipped: job.skipped,
        failed: job.failed,
        last_error: None,
    };
    if job.scope_kind == "file" {
        match fs::symlink_metadata(&root) {
            Ok(metadata) if metadata.is_file() => {
                process_entry(store, jobs, previews, job, &root, stop, &mut progress)?
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error).context("inspect changed file"),
        }
        publish(jobs, job, &progress, None)?;
    } else {
        let mut cursor: ScanCursor = match jobs.load_checkpoint(&job.id)? {
            Some(value) => serde_json::from_str(&value).context("read scan checkpoint")?,
            None => ScanCursor {
                pending: vec![root.clone()],
                current: None,
                last_name: None,
            },
        };
        loop {
            if stopped(jobs, job, stop)? {
                return Ok(false);
            }
            if cursor.current.is_none() {
                cursor.current = cursor.pending.pop();
                cursor.last_name = None;
                save_cursor(jobs, job, &cursor, &progress)?;
            }
            let Some(directory) = cursor.current.clone() else {
                break;
            };
            if !directory.try_exists()? {
                cursor.current = None;
                save_cursor(jobs, job, &cursor, &progress)?;
                continue;
            }
            jobs.validate_scan_path(&directory, "directory")?;
            let entries = match fs::read_dir(&directory) {
                Ok(entries) => entries,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    cursor.current = None;
                    save_cursor(jobs, job, &cursor, &progress)?;
                    continue;
                }
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("read directory {}", directory.display()));
                }
            };
            store.record_directory(&job.library_id, &directory)?;
            let mut entries = entries.collect::<std::io::Result<Vec<_>>>()?;
            entries.sort_by_key(|entry| entry.file_name());
            for entry in entries {
                let name = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| anyhow::anyhow!("original filename must be UTF-8"))?;
                if cursor.last_name.as_ref().is_some_and(|last| name <= *last) {
                    continue;
                }
                if stopped(jobs, job, stop)? {
                    return Ok(false);
                }
                if units >= limit || (limit == usize::MAX && jobs.should_yield(job)?) {
                    jobs.yield_job(&job.id)?;
                    return Ok(false);
                }
                if !excluded(&name) {
                    let kind = match entry.file_type() {
                        Ok(kind) => Some(kind),
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                        Err(error) => {
                            return Err(error)
                                .with_context(|| format!("read entry {}", entry.path().display()));
                        }
                    };
                    if kind.is_some_and(|kind| kind.is_dir()) && job.scope_kind == "recursive" {
                        cursor.pending.push(entry.path());
                    } else if kind.is_some_and(|kind| kind.is_file())
                        && (media::is_photo(&entry.path()) || media::is_video(&entry.path()))
                    {
                        process_entry(
                            store,
                            jobs,
                            previews,
                            job,
                            &entry.path(),
                            stop,
                            &mut progress,
                        )?;
                        units += 1;
                    }
                }
                cursor.last_name = Some(name);
                save_cursor(jobs, job, &cursor, &progress)?;
            }
            cursor.current = None;
            save_cursor(jobs, job, &cursor, &progress)?;
        }
    }
    if stopped(jobs, job, stop)? {
        return Ok(false);
    }
    if store.mark_missing_scope_with_revision(
        &job.library_id,
        &job.path,
        &job.scope_kind,
        Some(&job.id),
    )? > 0
    {
        store.reconcile_cache()?;
    }
    if job.scope_kind == "file" && progress.failed > 0 {
        bail!(
            "{} files failed; latest failure: {}",
            progress.failed,
            progress
                .last_error
                .as_deref()
                .unwrap_or("see earlier scan errors")
        );
    }
    Ok(true)
}

#[derive(Serialize, Deserialize)]
struct ScanCursor {
    pending: Vec<PathBuf>,
    current: Option<PathBuf>,
    last_name: Option<String>,
}

fn save_cursor(jobs: &Jobs, job: &Job, cursor: &ScanCursor, progress: &Progress) -> Result<()> {
    jobs.save_scan_progress(
        &job.id,
        &serde_json::to_string(cursor)?,
        progress.processed,
        progress.skipped,
        progress.failed,
    )
}

fn process_entry(
    store: &Store,
    jobs: &Jobs,
    previews: &PreviewStorage,
    job: &Job,
    path: &Path,
    _stop: &AtomicBool,
    progress: &mut Progress,
) -> Result<()> {
    publish(
        jobs,
        job,
        progress,
        Some(path.to_str().context("original path must be UTF-8")?),
    )?;
    let result = process_photo(store, jobs, previews, job, path);
    match result {
        Ok(true) => progress.processed += 1,
        Ok(false) => progress.skipped += 1,
        Err(_) if !path.try_exists()? => progress.skipped += 1,
        Err(error) => {
            let trace = format!("processing {}: {error:#}", path.display());
            tracing::error!(job_id = %job.id, error = %trace, "NAS photo processing failed");
            progress.failed += 1;
            progress.last_error = Some(trace);
            if job.scope_kind != "file" {
                let queued = jobs.enqueue_file_change(&job.folder_id, path, 0)?;
                store.note_revision_activity(&queued.library_id, &queued.id, &queued.path)?;
            }
        }
    }
    Ok(())
}

fn stopped(jobs: &Jobs, job: &Job, stop: &AtomicBool) -> Result<bool> {
    Ok(stop.load(Ordering::Relaxed) || !jobs.is_active(&job.folder_id)?)
}
fn excluded(name: &str) -> bool {
    name.starts_with('.') || name == "@eaDir" || name == "#recycle"
}
fn publish(jobs: &Jobs, job: &Job, progress: &Progress, path: Option<&str>) -> Result<()> {
    jobs.update_progress(
        &job.id,
        progress.processed,
        progress.skipped,
        progress.failed,
        path,
    )
}
fn file_stamp(path: &Path) -> Result<(i64, i64)> {
    let metadata =
        fs::symlink_metadata(path).with_context(|| format!("stat {}", path.display()))?;
    ensure!(
        metadata.file_type().is_file(),
        "original is no longer a regular file: {}",
        path.display()
    );
    let size = i64::try_from(metadata.len()).context("original size exceeds supported range")?;
    let mtime = i64::try_from(metadata.modified()?.duration_since(UNIX_EPOCH)?.as_nanos())
        .context("original modification time exceeds supported range")?;
    Ok((size, mtime))
}

fn photo_paths(store: &Store, library: &str, path: &Path) -> Result<Vec<PathBuf>> {
    let parent = path.parent().context("photo has no directory")?;
    let stem = path
        .file_stem()
        .context("photo has no filename")?
        .to_string_lossy();
    let mut paths = vec![path.to_path_buf()];
    for entry in fs::read_dir(parent)? {
        let entry = entry?;
        if entry.file_type()?.is_file()
            && media::is_photo(&entry.path())
            && entry
                .path()
                .file_stem()
                .is_some_and(|s| s.to_string_lossy().eq_ignore_ascii_case(&stem))
        {
            paths.push(entry.path());
        }
    }
    {
        let db = store.lock()?;
        let mut q=db.prepare("SELECT path FROM catalog_paths WHERE library_id=?1 AND asset_id IN (SELECT asset_id FROM catalog_paths WHERE library_id=?1 AND path=?2)")?;
        for item in q.query_map(rusqlite::params![library, path.to_str()], |r| {
            r.get::<_, String>(0)
        })? {
            let p = PathBuf::from(item?);
            if p.parent() == Some(parent) && p.is_file() {
                paths.push(p);
            }
        }
    }
    paths.sort();
    paths.dedup();
    Ok(paths)
}

fn process_photo(
    store: &Store,
    jobs: &Jobs,
    previews: &PreviewStorage,
    job: &Job,
    path: &Path,
) -> Result<bool> {
    let paths = photo_paths(store, &job.library_id, path)?;
    // Metadata writers may replace inodes. Keep the whole photo group untouched
    // until import checkpoints make every published link independently recoverable.
    if crate::imports::group_pending_publication(jobs, &job.library_id, &paths)? {
        let queued = jobs.enqueue_file_change(&job.folder_id, path, 2)?;
        store.note_revision_activity(&queued.library_id, &queued.id, &queued.path)?;
        return Ok(false);
    }
    // Wait for the whole pair to finish copying before starting a non-preemptible unit.
    for source in &paths {
        let stamp = file_stamp(source)?;
        let unchanged = jobs
            .file_state(
                &job.folder_id,
                source.to_str().context("photo path must be UTF-8")?,
            )?
            .is_some_and(|f| (f.size, f.mtime_ns) == stamp);
        if !unchanged && recently_modified(stamp.1) {
            let queued = jobs.enqueue_file_change(&job.folder_id, source, 2)?;
            store.note_revision_activity(&queued.library_id, &queued.id, &queued.path)?;
            return Ok(false);
        }
    }
    crate::tasks::begin_photo(jobs, &job.library_id, &job.work_class, path, &paths)?;
    let uninterrupted = AtomicBool::new(false);
    let result = (|| {
        let mut changed = false;
        for source in &paths {
            changed |= if job.work_class == "maintenance" {
                process_file_with_identity(
                    store,
                    jobs,
                    previews,
                    job,
                    source,
                    &uninterrupted,
                    true,
                )?
            } else {
                process_file(store, jobs, previews, job, source, &uninterrupted)?
            };
        }
        let assets = {
            let db = store.lock()?;
            let mut ids = std::collections::BTreeSet::new();
            for source in &paths {
                use rusqlite::OptionalExtension;
                if let Some(id) = db
                    .query_row(
                        "SELECT asset_id FROM catalog_paths WHERE library_id=? AND path=?",
                        rusqlite::params![job.library_id, source.to_str()],
                        |r| r.get::<_, String>(0),
                    )
                    .optional()?
                {
                    ids.insert(id);
                }
            }
            ids
        };
        for id in assets {
            store.initialize_negative(&job.library_id, &id)?;
            if job.work_class == "manual" && (job.refresh_metadata || job.scope_kind == "file") {
                store.lock()?.execute("UPDATE media_cache SET status='pending',attempts=0,available_at=0,last_error=NULL WHERE library_id=? AND asset_id=? AND status<>'processing'",rusqlite::params![job.library_id,id])?;
            }
            crate::cache_pipeline::process_asset(store, jobs, previews, &job.library_id, &id)?;
        }
        Ok(changed)
    })();
    let error = result
        .as_ref()
        .err()
        .map(|e: &anyhow::Error| format!("{e:#}"));
    crate::tasks::finish(jobs, error.as_deref())?;
    result
}

fn process_file(
    store: &Store,
    jobs: &Jobs,
    _previews: &PreviewStorage,
    job: &Job,
    path: &Path,
    stop: &AtomicBool,
) -> Result<bool> {
    process_file_with_identity(store, jobs, _previews, job, path, stop, false)
}

fn process_file_with_identity(
    store: &Store,
    jobs: &Jobs,
    _previews: &PreviewStorage,
    job: &Job,
    path: &Path,
    stop: &AtomicBool,
    backfill: bool,
) -> Result<bool> {
    jobs.validate_path(path.parent().context("original has no parent")?)?;
    let text = path.to_str().context("original path must be UTF-8")?;
    let (mut size, mut mtime) = file_stamp(path)?;
    let mut sidecars = media::sidecar_stamp(path)?;
    let previous = jobs.file_state(&job.folder_id, text)?;
    let mut asset_id = previous
        .as_ref()
        .map(|p| p.asset_id.clone())
        .unwrap_or_default();
    let mut hash = previous
        .as_ref()
        .map(|p| p.version.clone())
        .unwrap_or_default();
    let force = job.work_class == "manual" && job.refresh_metadata;
    if !backfill
        && !force
        && job.scope_kind != "file"
        && let Some(previous) = &previous
        && previous.size == size
        && previous.mtime_ns == mtime
        && previous.metadata_stamp == sidecars
        && previous.error.is_some()
    {
        if let Some(queued) = jobs.ensure_file_retry(&job.folder_id, path)? {
            store.note_revision_activity(&queued.library_id, &queued.id, &queued.path)?;
        }
        return Ok(false);
    }
    if !backfill
        && !force
        && let Some(previous) = &previous
        && previous.size == size
        && previous.mtime_ns == mtime
        && previous.metadata_stamp == sidecars
        && previous.error.is_none()
        && !previous.asset_id.is_empty()
        && store.original_is_online(&job.library_id, text, &previous.version)?
    {
        return Ok(false);
    }
    // Debouncing is normally handled by the event queue; reconciliation can also
    // discover a file during a copy, before the close/write notification arrives.
    if recently_modified(mtime) {
        let queued = jobs.enqueue_file_change(&job.folder_id, path, 2)?;
        store.note_revision_activity(&queued.library_id, &queued.id, &queued.path)?;
        return Ok(false);
    }
    let mut identity_checked = false;
    let result: Result<bool> = (|| {
        let processor = MediaProcessor::new();
        hash = media::sha256_file(path)?;
        let metadata = processor.extract(path)?;
        if stopped(jobs, job, stop)? {
            return Ok(false);
        }
        ensure!(
            file_stamp(path)? == (size, mtime),
            "original changed during metadata extraction"
        );
        let now = Utc::now().to_rfc3339();
        let mut snapshot = json!({
            "cameraMake": metadata.camera_make, "cameraModel": metadata.camera_model,
            "lensModel": metadata.lens_model, "originalFilename": path.file_name().context("original filename missing")?.to_str().context("original filename must be UTF-8")?,
            "contentFingerprint": hash, "metadataFingerprint": metadata.fingerprint(path),
            "rating": metadata.rating, "flagState":"unflagged", "tags":[], "createdAt":now, "updatedAt":now,
        });
        if let Some(capture_time) = &metadata.capture_time {
            snapshot["captureTime"] = json!(capture_time);
        }
        let existing_root = crate::identity::read(path)?;
        if let Some(root) = &existing_root {
            snapshot["originalDocumentID"] = json!(root);
        }
        let file = json!({"contentHash":hash,"sizeBytes":size,"role":if media::is_raw(path){"raw_original"}else{"jpeg_original"}});
        let evidence = VersionEvidence {
            visual_hash: media::jpeg_visual_hash(path, &metadata)?,
            width: metadata.width,
            height: metadata.height,
            edited: metadata.edited && !media::is_raw(path),
            camera_serial: metadata.camera_serial.clone(),
            capture_original: metadata.capture_original.clone(),
        };
        ensure!(
            file_stamp(path)? == (size, mtime),
            "original changed during identity extraction"
        );
        ensure!(
            media::sidecar_stamp(path)? == sidecars,
            "sidecar changed during metadata extraction"
        );
        asset_id = store.ingest_original_with_revision(
            &job.library_id,
            text,
            &file,
            &snapshot,
            &evidence,
            if backfill { None } else { Some(&job.id) },
        )?;
        if existing_root.is_some() {
            identity_checked = true;
            return Ok(true);
        }
        let root = store.root_id(&job.library_id, &asset_id)?;
        let old_hash = hash.clone();
        let updated = store.with_identity_update(&job.library_id, text, &old_hash, || {
            let written = crate::identity::ensure(path, &root)?;
            sidecars = media::sidecar_stamp(path)?;
            if written.changed && written.path == path {
                hash = media::sha256_file(path)?;
                (size, mtime) = file_stamp(path)?;
                Ok(Some((hash.clone(), size as u64, mtime.to_string())))
            } else {
                Ok(None)
            }
        })?;
        if !updated {
            return Ok(false);
        }
        identity_checked = true;
        Ok(true)
    })();
    if stopped(jobs, job, stop)? {
        return Ok(false);
    }
    match &result {
        Ok(true) => {
            jobs.record_file(&job.folder_id, text, size, mtime, &asset_id, &hash, None)?;
            jobs.record_metadata_stamp(&job.folder_id, text, &sidecars)?;
            if identity_checked {
                jobs.identity_result(&job.folder_id, text, None)?;
            }
        }
        Err(error) => {
            jobs.record_file(
                &job.folder_id,
                text,
                size,
                mtime,
                &asset_id,
                &hash,
                Some(&format!("{error:#}")),
            )?;
            jobs.record_metadata_stamp(&job.folder_id, text, &sidecars)?;
        }
        Ok(false) => {}
    }
    result
}

pub fn process_identity_batch(
    store: &Store,
    jobs: &Jobs,
    previews: &PreviewStorage,
    stop: &AtomicBool,
) -> Result<()> {
    let _directory_guard = jobs.directory_mutation.read().unwrap();
    crate::directory_move::ensure_reconciled(jobs)?;
    for (folder, text) in jobs.pending_identities(1)? {
        if stop.load(Ordering::Relaxed)
            || jobs.has_due_class("automatic")?
            || jobs.has_due_class("manual")?
        {
            break;
        }
        let path = Path::new(&text);
        if !path.try_exists()? {
            jobs.identity_missing(&folder.id, &text)?;
            continue;
        }
        let job = Job {
            id: "identity-backfill".into(),
            work_class: "maintenance".into(),
            scope_kind: "file".into(),
            folder_id: folder.id.clone(),
            library_id: folder.library_id,
            path: folder.path,
            refresh_metadata: false,
            path_sync: false,
            wait_for_quiet: false,
            status: "running".into(),
            error: None,
            processed: 0,
            skipped: 0,
            failed: 0,
            current_path: None,
            started_at: None,
            finished_at: None,
        };
        if let Err(error) = process_photo(store, jobs, previews, &job, path) {
            let trace = format!("{error:#}");
            tracing::error!(path=%text,error=%trace,"photo identity backfill failed");
            jobs.identity_result(&folder.id, &text, Some(&trace))?;
        }
    }
    Ok(())
}

fn recently_modified(mtime_ns: i64) -> bool {
    let now = Utc::now().timestamp_nanos_opt().unwrap_or(i64::MAX);
    (0..2_000_000_000).contains(&now.saturating_sub(mtime_ns))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_uncheckpointed_pair_defers_photo_group_without_touching_metadata() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir(&originals)?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs = Jobs::open(&directory.path().join("jobs.sqlite"), &originals)?;
        let path = jobs.root().join("pair.CR3");
        fs::write(&path, b"unchanged original")?;
        let previews = PreviewStorage::new(
            &directory.path().join("keeps"),
            Some(&originals),
            "http://localhost",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        let job = jobs.enqueue_manual_file(&folder.id, &path)?;
        let batch_id = uuid::Uuid::new_v4().to_string();
        let manifest = json!({"id":batch_id, "targetPath":jobs.root(), "finished":false,"jobId":null,
            "files":[{"id":uuid::Uuid::new_v4().to_string(),"relativePath":"pair.JPG", "fileName":"pair.JPG", "size":8,"uploaded":true,"published":false}]});
        jobs.db.lock().unwrap().execute(
            "INSERT INTO imports(id,library_id,manifest) VALUES(?,?,?)",
            rusqlite::params![batch_id, "library", manifest.to_string()],
        )?;
        assert!(!process_photo(&store, &jobs, &previews, &job, &path)?);
        assert_eq!(fs::read(&path)?, b"unchanged original");
        assert!(
            jobs.file_state(&folder.id, path.to_str().unwrap())?
                .is_none()
        );
        let queued = jobs.jobs(100)?;
        assert!(
            queued
                .iter()
                .any(|pending| pending.work_class == "automatic"
                    && pending.path == path.to_str().unwrap())
        );
        assert!(!crate::imports::group_pending_publication(
            &jobs,
            "library",
            &[jobs.root().join("other.CR3")]
        )?);
        assert!(!crate::imports::group_pending_publication(
            &jobs,
            "library",
            &[jobs.root().join("other/pair.CR3")]
        )?);
        jobs.db.lock().unwrap().execute("UPDATE imports SET manifest=json_set(manifest,'$.files[0].published',json('true')) WHERE id=?", [&batch_id])?;
        assert!(!crate::imports::group_pending_publication(
            &jobs,
            "library",
            &[path]
        )?);
        Ok(())
    }

    #[test]
    fn bad_file_retries_are_exact_and_do_not_restart_parent_scan() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir(&originals)?;
        let bad = originals.join("bad.jpg");
        fs::write(&bad, b"")?;
        fs::File::open(&bad)?
            .set_times(fs::FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(1)))?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs_path = directory.path().join("jobs.sqlite");
        let jobs = Jobs::open(&jobs_path, &originals)?;
        let previews = PreviewStorage::new(
            &directory.path().join("keeps"),
            Some(&originals),
            "http://localhost:2283",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        let parent = jobs.enqueue_external_scan(&folder.id)?;
        let job = jobs.claim_next()?.unwrap();
        assert!(run_one(
            &store,
            &jobs,
            &previews,
            &job,
            &AtomicBool::new(false)
        )?);
        jobs.finish(&job.id, None)?;
        let parent = jobs.job(&parent.id)?.unwrap();
        assert_eq!(parent.status, "completed");
        assert_eq!(parent.failed, 1);
        let mut failed_id = None;
        for _ in 0..4 {
            rusqlite::Connection::open(&jobs_path)?
                .execute("UPDATE jobs SET available_at=0 WHERE status='pending'", [])?;
            let exact = jobs.claim_next()?.expect("failed file has a bounded retry");
            assert_eq!(exact.scope_kind, "file");
            assert_eq!(Path::new(&exact.path), bad.canonicalize()?);
            let error =
                run_one(&store, &jobs, &previews, &exact, &AtomicBool::new(false)).unwrap_err();
            jobs.finish(&exact.id, Some(&format!("{error:#}")))?;
            failed_id = Some(exact.id);
        }
        let exact = jobs.job(&failed_id.unwrap())?.unwrap();
        assert_eq!(exact.status, "failed");
        assert!(jobs.claim_next()?.is_none());
        let error_before = jobs
            .file_state(&folder.id, bad.canonicalize()?.to_str().unwrap())?
            .unwrap()
            .error;
        jobs.enqueue_external_scan(&folder.id)?;
        let next_parent = jobs.claim_next()?.unwrap();
        assert!(run_one(
            &store,
            &jobs,
            &previews,
            &next_parent,
            &AtomicBool::new(false)
        )?);
        jobs.finish(&next_parent.id, None)?;
        let completed = jobs.job(&next_parent.id)?.unwrap();
        assert_eq!((completed.skipped, completed.failed), (1, 0));
        assert!(jobs.claim_next()?.is_none());
        assert_eq!(
            jobs.jobs(100)?
                .iter()
                .filter(|job| job.scope_kind == "file")
                .count(),
            1
        );
        assert_eq!(
            jobs.file_state(&folder.id, bad.canonicalize()?.to_str().unwrap())?
                .unwrap()
                .error,
            error_before
        );
        Ok(())
    }

    #[test]
    fn historical_unchanged_error_gets_one_exact_retry_without_parent_failure() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir(&originals)?;
        let bad = originals.join("interrupted.jpg");
        fs::write(&bad, b"")?;
        let bad = bad.canonicalize()?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs = Jobs::open(&directory.path().join("jobs.sqlite"), &originals)?;
        let previews = PreviewStorage::new(
            &directory.path().join("keeps"),
            Some(&originals),
            "http://localhost:2283",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        let (size, mtime) = file_stamp(&bad)?;
        jobs.record_file(
            &folder.id,
            bad.to_str().unwrap(),
            size,
            mtime,
            "",
            "",
            Some("external tool interrupted by SIGTERM"),
        )?;
        jobs.record_metadata_stamp(
            &folder.id,
            bad.to_str().unwrap(),
            &media::sidecar_stamp(&bad)?,
        )?;
        jobs.enqueue_external_scan(&folder.id)?;
        let parent = jobs.claim_next()?.unwrap();
        assert!(run_one(
            &store,
            &jobs,
            &previews,
            &parent,
            &AtomicBool::new(false)
        )?);
        jobs.finish(&parent.id, None)?;
        let complete = jobs.job(&parent.id)?.unwrap();
        assert_eq!(
            (complete.status.as_str(), complete.failed, complete.skipped),
            ("completed", 0, 1)
        );
        let exact = jobs
            .claim_next()?
            .expect("historical error gets an exact retry");
        assert_eq!(exact.scope_kind, "file");
        assert_eq!(exact.path, bad.to_str().unwrap());
        assert_eq!(
            jobs.file_state(&folder.id, bad.to_str().unwrap())?
                .unwrap()
                .error
                .as_deref(),
            Some("external tool interrupted by SIGTERM")
        );
        Ok(())
    }

    #[test]
    fn cancelled_media_failure_does_not_persist_file_error() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir(&originals)?;
        let bad = originals.join("bad.jpg");
        fs::write(&bad, b"")?;
        fs::File::open(&bad)?
            .set_times(fs::FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(1)))?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs = Jobs::open(&directory.path().join("jobs.sqlite"), &originals)?;
        let previews = PreviewStorage::new(
            &directory.path().join("keeps"),
            Some(&originals),
            "http://localhost:2283",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        jobs.enqueue_external_scan(&folder.id)?;
        let job = jobs.claim_next()?.unwrap();
        assert!(!process_file(
            &store,
            &jobs,
            &previews,
            &job,
            &bad.canonicalize()?,
            &AtomicBool::new(true)
        )?);
        assert!(
            jobs.file_state(&folder.id, bad.canonicalize()?.to_str().unwrap())?
                .is_none()
        );
        Ok(())
    }

    #[test]
    fn traversal_excludes_hidden_recycle_and_symlinks_without_touching_files() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir(&originals)?;
        for name in [".hidden", "@eaDir", "#recycle"] {
            fs::create_dir(originals.join(name))?;
            fs::write(
                originals.join(name).join("not-a-real-photo.jpg"),
                b"original",
            )?;
        }
        let outside = directory.path().join("outside.jpg");
        fs::write(&outside, b"outside")?;
        #[cfg(unix)]
        std::os::unix::fs::symlink(&outside, originals.join("linked.jpg"))?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs = Jobs::open(&directory.path().join("jobs.sqlite"), &originals)?;
        let previews = PreviewStorage::new(
            &directory.path().join("keeps"),
            Some(&originals),
            "http://localhost:2283",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        jobs.enqueue_external_scan(&folder.id)?;
        let job = jobs.claim_next()?.unwrap();
        run_one(&store, &jobs, &previews, &job, &AtomicBool::new(false))?;
        assert_eq!(store.counts("library", false)?["all"], 0);
        assert_eq!(fs::read(outside)?, b"outside");
        for name in [".hidden", "@eaDir", "#recycle"] {
            assert_eq!(
                fs::read(originals.join(name).join("not-a-real-photo.jpg"))?,
                b"original"
            );
        }
        Ok(())
    }

    #[test]
    fn persisted_incremental_state_skips_unchanged_original_after_restart() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir(&originals)?;
        let original = originals.join("photo.jpg");
        fs::write(&original, b"original fixture deliberately not decodable")?;
        // The worker starts from Jobs' canonical root; seed exactly that path,
        // including macOS's /var -> /private/var resolution.
        let original = original.canonicalize()?;
        let path = original.to_str().unwrap();
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs_path = directory.path().join("jobs.sqlite");
        let jobs = Jobs::open(&jobs_path, &originals)?;
        let previews = PreviewStorage::new(
            &directory.path().join("keeps"),
            Some(&originals),
            "http://localhost:2283",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        let (size, mtime) = file_stamp(&original)?;
        let hash = media::sha256_file(&original)?;
        let file = json!({"contentHash":hash,"sizeBytes":size,"role":"jpeg_original"});
        let snapshot = json!({"cameraMake":"Test","cameraModel":"Test","lensModel":"Test","originalFilename":"photo.jpg","contentFingerprint":hash,"metadataFingerprint":"fixture","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"});
        let id = store.ingest_original("library", path, &file, &snapshot)?;
        let fake_preview = directory.path().join("preview.heic");
        fs::write(&fake_preview, b"preview fixture")?;
        let object = previews.put_generated("library", &id, "preview-hash", &fake_preview)?;
        store.declare_generated_preview("library", &id, &json!({"assetID":id,"role":"preview","fileObject":{"contentHash":"preview-hash","sizeBytes":15,"role":"preview"},"objectRef":object,"pixelSize":{"width":100,"height":100}}))?;
        jobs.record_file(&folder.id, path, size, mtime, &id, &hash, None)?;
        store.reconcile_cache()?;
        store.lock()?.execute(
            "UPDATE media_cache SET status='ready',thumbnail='{}',standard='{}'",
            [],
        )?;
        jobs.enqueue_external_scan(&folder.id)?;
        let claimed = jobs.claim_next()?.unwrap();
        drop(jobs);
        let jobs = Jobs::open(&jobs_path, &originals)?;
        let mut recovered = jobs.claim_next()?.unwrap();
        recovered.refresh_metadata = true;
        assert_eq!(recovered.id, claimed.id);
        run_one(
            &store,
            &jobs,
            &previews,
            &recovered,
            &AtomicBool::new(false),
        )?;
        let progress = jobs.jobs(1)?.remove(0);
        assert_eq!(
            (progress.processed, progress.skipped, progress.failed),
            (0, 1, 0)
        );
        assert_eq!(media::sha256_file(&original)?, hash);
        Ok(())
    }

    #[test]
    fn checkpoint_resumes_after_last_entry_and_preserves_progress() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir(&originals)?;
        fs::write(
            originals.join("already.jpg"),
            b"invalid media must never be parsed",
        )?;
        fs::write(originals.join("z.txt"), b"ignored")?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs_path = directory.path().join("jobs.sqlite");
        let jobs = Jobs::open(&jobs_path, &originals)?;
        let previews = PreviewStorage::new(
            &directory.path().join("keeps"),
            Some(&originals),
            "http://localhost:2283",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        jobs.enqueue_external_scan(&folder.id)?;
        let job = jobs.claim_next()?.unwrap();
        jobs.update_progress(&job.id, 7, 11, 0, None)?;
        save_cursor(
            &jobs,
            &job,
            &ScanCursor {
                pending: vec![jobs.root().join("removed-directory")],
                current: Some(jobs.root().to_path_buf()),
                last_name: Some("already.jpg".into()),
            },
            &Progress {
                processed: 7,
                skipped: 11,
                ..Progress::default()
            },
        )?;
        drop(jobs);
        let jobs = Jobs::open(&jobs_path, &originals)?;
        let recovered = jobs.claim_next()?.unwrap();
        assert!(run_one(
            &store,
            &jobs,
            &previews,
            &recovered,
            &AtomicBool::new(false)
        )?);
        let finished = jobs.job(&job.id)?.unwrap();
        assert_eq!(
            (finished.processed, finished.skipped, finished.failed),
            (7, 11, 0)
        );
        let cursor: ScanCursor = serde_json::from_str(&jobs.load_checkpoint(&job.id)?.unwrap())?;
        assert!(cursor.current.is_none() && cursor.pending.is_empty());
        Ok(())
    }

    #[test]
    fn missing_file_task_does_not_scan_siblings_or_descendants() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir_all(originals.join("child"))?;
        fs::write(originals.join("sibling.jpg"), b"invalid media")?;
        fs::write(originals.join("child/nested.jpg"), b"invalid media")?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs = Jobs::open(&directory.path().join("jobs.sqlite"), &originals)?;
        let previews = PreviewStorage::new(
            &directory.path().join("keeps"),
            Some(&originals),
            "http://localhost:2283",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        jobs.enqueue_file_change(&folder.id, &jobs.root().join("missing.jpg"), 0)?;
        let job = jobs.claim_next()?.unwrap();
        assert!(run_one(
            &store,
            &jobs,
            &previews,
            &job,
            &AtomicBool::new(false)
        )?);
        let finished = jobs.job(&job.id)?.unwrap();
        assert_eq!(
            (finished.processed, finished.skipped, finished.failed),
            (0, 0, 0)
        );
        Ok(())
    }

    #[test]
    fn maintenance_keeps_pending_and_recovered_owners_until_terminal() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir(&originals)?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs_path = directory.path().join("jobs.sqlite");
        let jobs = Jobs::open(&jobs_path, &originals)?;
        let folder = jobs.add_folder("library", ".")?;
        let queued = jobs.enqueue_external_scan(&folder.id)?;
        store.note_revision_activity("library", &queued.id, &folder.path)?;
        jobs.claim_next()?.unwrap();
        jobs.yield_job(&queued.id)?;
        rusqlite::Connection::open(directory.path().join("catalog.sqlite"))?
            .execute("UPDATE catalog_revision_updates SET last_changed_at=0", [])?;
        maintain_revisions(&store, &jobs)?;
        assert!(store.revision_batch_ids()?.contains(&queued.id));
        jobs.claim_next()?.unwrap();
        drop(jobs);
        let jobs = Jobs::open(&jobs_path, &originals)?;
        maintain_revisions(&store, &jobs)?;
        assert_eq!(jobs.job(&queued.id)?.unwrap().status, "pending");
        assert!(store.revision_batch_ids()?.contains(&queued.id));
        jobs.claim_next()?.unwrap();
        let changed = jobs.enqueue_change(&folder.id, Path::new(&folder.path), 0)?;
        store.note_revision_activity("library", &changed.id, &folder.path)?;
        jobs.finish(&queued.id, None)?;
        maintain_revisions(&store, &jobs)?;
        assert_eq!(jobs.job(&queued.id)?.unwrap().status, "completed");
        assert!(store.revision_batch_ids()?.contains(&changed.id));
        let active = jobs.claim_next()?.unwrap();
        assert_eq!(active.id, changed.id);
        jobs.finish(&active.id, None)?;
        maintain_revisions(&store, &jobs)?;
        assert!(!store.revision_batch_ids()?.contains(&queued.id));
        Ok(())
    }

    #[test]
    fn known_completion_preserves_other_queued_owner_at_shared_root() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir_all(originals.join("child"))?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs = Jobs::open(&directory.path().join("jobs.sqlite"), &originals)?;
        let folder = jobs.add_folder("library", ".")?;
        let manual = jobs.enqueue_scan(&folder.id)?;
        jobs.claim_next()?.unwrap();
        let child = jobs.root().join("child");
        let pending = jobs.enqueue_change(&folder.id, &child, 0)?;
        store.note_revision_activity("library", &manual.id, &folder.path)?;
        store.note_revision_activity("library", &pending.id, child.to_str().unwrap())?;
        jobs.finish(&manual.id, None)?;
        maintain_revisions(&store, &jobs)?;
        assert!(!store.revision_batch_ids()?.contains(&manual.id));
        assert!(store.revision_batch_ids()?.contains(&pending.id));
        assert_eq!(
            store.catalog_revision("library", None, false)?["isUpdating"],
            true
        );
        Ok(())
    }

    #[test]
    fn failed_retries_keep_owner_and_terminal_jobs_allow_quiet_settlement() -> Result<()> {
        for cancel in [false, true] {
            let directory = tempfile::tempdir()?;
            let originals = directory.path().join("originals");
            fs::create_dir(&originals)?;
            let catalog_path = directory.path().join("catalog.sqlite");
            let store = Store::open(&catalog_path, true)?;
            let jobs_path = directory.path().join("jobs.sqlite");
            let jobs = Jobs::open(&jobs_path, &originals)?;
            let folder = jobs.add_folder("library", ".")?;
            let queued = jobs.enqueue_external_scan(&folder.id)?;
            store.note_revision_activity("library", &queued.id, &folder.path)?;
            rusqlite::Connection::open(&catalog_path)?
                .execute("UPDATE catalog_revision_updates SET last_changed_at=0", [])?;
            let queue_db = rusqlite::Connection::open(&jobs_path)?;
            for attempt in 0..4 {
                queue_db.execute("UPDATE jobs SET available_at=0", [])?;
                assert_eq!(jobs.claim_next()?.unwrap().id, queued.id);
                jobs.finish(&queued.id, Some("fixture scan failed"))?;
                maintain_revisions(&store, &jobs)?;
                if attempt < 3 {
                    assert_eq!(jobs.job(&queued.id)?.unwrap().status, "pending");
                    assert!(store.revision_batch_ids()?.contains(&queued.id));
                    assert_eq!(
                        store.catalog_revision("library", None, false)?["isUpdating"],
                        true
                    );
                }
                if cancel {
                    jobs.remove_folder(&folder.id)?;
                    maintain_revisions(&store, &jobs)?;
                    break;
                }
            }
            assert_eq!(
                jobs.job(&queued.id)?.unwrap().status,
                if cancel { "cancelled" } else { "failed" }
            );
            assert!(!store.revision_batch_ids()?.contains(&queued.id));
            assert_eq!(
                store.catalog_revision("library", None, false)?["isUpdating"],
                false
            );
        }
        Ok(())
    }

    #[test]
    fn stopped_job_does_not_inspect_media() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir(&originals)?;
        fs::write(originals.join("unprocessed.jpg"), b"original")?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let jobs = Jobs::open(&directory.path().join("jobs.sqlite"), &originals)?;
        let previews = PreviewStorage::new(
            &directory.path().join("keeps"),
            Some(&originals),
            "http://localhost:2283",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        jobs.enqueue_external_scan(&folder.id)?;
        let job = jobs.claim_next()?.unwrap();
        jobs.remove_folder(&folder.id)?;
        assert!(!run_one(
            &store,
            &jobs,
            &previews,
            &job,
            &AtomicBool::new(false)
        )?);
        assert_eq!(jobs.jobs(1)?[0].status, "cancelled");
        assert_eq!(store.counts("library", false)?["all"], 0);
        assert_eq!(fs::read(originals.join("unprocessed.jpg"))?, b"original");
        Ok(())
    }
}
