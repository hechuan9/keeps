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
    time::UNIX_EPOCH,
};

/// User-submitted work runs on one low-priority thread and resumes persisted scan checkpoints.
pub fn run(
    store: Arc<Store>,
    jobs: Arc<Jobs>,
    previews: Arc<PreviewStorage>,
    stop: Arc<AtomicBool>,
) -> Result<()> {
    MediaProcessor::new()
        .probe()
        .context("NAS media runtime unavailable")?;
    while !stop.load(Ordering::Relaxed) {
        if let Some(job) = jobs.claim_class("manual")? {
            run_claimed(&store, &jobs, &previews, &job, &stop)?;
        } else {
            jobs.wait_for_scan_work(jobs.scan_wait_duration()?);
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
    jobs.set_phase(&job.id, "scanning")?;
    let mut result = run_slice(store, jobs, previews, job, stop, 1);
    let terminal = !matches!(result, Ok(false))
        || stop.load(Ordering::Relaxed)
        || jobs
            .job(&job.id)?
            .is_some_and(|job| !matches!(job.status.as_str(), "pending" | "running"));
    if terminal {
        let publication = (|| -> Result<()> {
            if matches!(result, Ok(true)) && !stop.load(Ordering::Relaxed) {
                jobs.set_phase(&job.id, "publishing")?;
            }
            let _directory_guard = jobs.directory_mutation.write().unwrap();
            if job.scope_kind == "file" {
                crate::sync_navigation::refresh_file(
                    store,
                    jobs,
                    &job.library_id,
                    Path::new(&job.path),
                )?;
            } else {
                crate::sync_navigation::refresh(store, jobs, &job.library_id)?;
            }
            store.finish_revision_batch(&job.id, false)
        })();
        if let Err(error) = publication {
            result = Err(match result {
                Err(original) => {
                    original.context(format!("publish directory projection: {error:#}"))
                }
                Ok(_) => error,
            });
        }
    }
    if stop.load(Ordering::Relaxed) {
        return result.map(|_| ());
    }
    match result {
        Ok(true) => {
            jobs.finish(&job.id, None)?;
        }
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
    if jobs
        .job(&job.id)?
        .is_some_and(|j| !matches!(j.status.as_str(), "pending" | "running"))
    {
        store.finish_revision_batch(&job.id, false)?;
    }
    Ok(())
}

/// Startup-only finalization of owners whose recorded tasks are no longer active.
pub fn maintain_revisions(store: &Store, jobs: &Jobs) -> Result<()> {
    for id in store.revision_batch_ids()? {
        match jobs.job(&id)? {
            Some(job) if matches!(job.status.as_str(), "pending" | "running") => {}
            Some(job) if job.status == "completed" => store.finish_revision_batch(&id, false)?,
            _ => store.finish_revision_batch(&id, false)?,
        }
    }
    store.lock()?.execute(
        "UPDATE catalog_revision_updates SET last_changed_at=0 WHERE owner=''",
        [],
    )?;
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
            publish(
                jobs,
                job,
                progress,
                Some(path.to_str().context("photo path must be UTF-8")?),
            )?;
            return Err(error).with_context(|| format!("processing {}", path.display()));
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
        bail!("照片组尚未完成发布，请完成导入后重试：{}", path.display());
    }
    crate::tasks::begin_photo(jobs, &job.library_id, &job.work_class, path, &paths)?;
    let uninterrupted = AtomicBool::new(false);
    let result = (|| {
        let mut changed = false;
        jobs.set_phase(&job.id, "indexing")?;
        for source in &paths {
            changed |= process_file(store, jobs, previews, job, source, &uninterrupted)?;
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
            jobs.set_phase(&job.id, "media")?;
            changed |= crate::cache_pipeline::process_asset_with_override(
                store,
                jobs,
                previews,
                &job.library_id,
                &id,
                job.media_operation_id.as_deref(),
            )?;
            jobs.set_phase(&job.id, "cleanup")?;
            store.collect_asset_cache_garbage(previews, &job.library_id, &id)?;
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
    jobs.validate_path(path.parent().context("original has no parent")?)?;
    let text = path.to_str().context("original path must be UTF-8")?;
    let (size, mtime) = file_stamp(path)?;
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
    if let Some(previous) = &previous
        && (!force
            || (job.metadata_operation_id.is_some()
                && previous.metadata_operation_id == job.metadata_operation_id))
        && previous.size == size
        && previous.mtime_ns == mtime
        && previous.metadata_stamp == sidecars
        && previous.error.is_none()
        && !previous.asset_id.is_empty()
        && store.original_is_online(&job.library_id, text, &previous.version)?
        && crate::identity::standard_sidecar_photo_id(path)?.as_deref()
            == Some(store.root_id(&job.library_id, &previous.asset_id)?.as_str())
    {
        return Ok(false);
    }
    let mut identity_checked = false;
    let result: Result<bool> = (|| {
        let processor = MediaProcessor::new();
        let started = std::time::Instant::now();
        hash = crate::imports::file_digest(jobs, &job.library_id, path)?;
        let digest_ms = started.elapsed().as_millis();
        let extracted = std::time::Instant::now();
        let metadata = processor.extract(path)?;
        let metadata_ms = extracted.elapsed().as_millis();
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
            "lensModel": metadata.lens_model, "originalFilename": metadata.original_filename.as_deref().unwrap_or(path.file_name().context("original filename missing")?.to_str().context("original filename must be UTF-8")?),
            "contentFingerprint": hash, "metadataFingerprint": metadata.fingerprint(path),
            "rating": metadata.rating, "flagState":"unflagged", "tags":[], "createdAt":now, "updatedAt":now,
        });
        if let Some(capture_time) = &metadata.capture_time {
            snapshot["captureTime"] = json!(capture_time);
        }
        if let Some(id) = &metadata.photo_id {
            snapshot["photoID"] = json!(id);
        }
        if let Some(id) = &metadata.camera_image_id {
            snapshot["cameraImageID"] = json!(id);
        }
        if let Some(id) = &metadata.document_id {
            snapshot["documentID"] = json!(id);
        }
        if let Some(id) = &metadata.original_document_id {
            snapshot["originalDocumentID"] = json!(id);
        }
        let file = json!({"contentHash":hash,"sizeBytes":size,"role":if media::is_raw(path){"raw_original"}else{"jpeg_original"}});
        let evidence = VersionEvidence {
            visual_hash: None,
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
        let ingested = std::time::Instant::now();
        asset_id = store.ingest_original_with_revision(
            &job.library_id,
            text,
            &file,
            &snapshot,
            &evidence,
            Some(&job.id),
        )?;
        let ingest_ms = ingested.elapsed().as_millis();
        let root = store.root_id(&job.library_id, &asset_id)?;
        if crate::identity::standard_sidecar_photo_id(path)?.as_deref() == Some(root.as_str()) {
            tracing::info!(
                path = text,
                digest_ms,
                metadata_ms,
                ingest_ms,
                total_ms = started.elapsed().as_millis(),
                "indexed photo metadata"
            );
            identity_checked = true;
            return Ok(true);
        }
        let updated = store.with_identity_update(&job.library_id, text, &hash, || {
            crate::identity::ensure_metadata(path, &root, &metadata)?;
            sidecars = media::sidecar_stamp(path)?;
            Ok(())
        })?;
        if !updated {
            return Ok(false);
        }
        tracing::info!(
            path = text,
            digest_ms,
            metadata_ms,
            ingest_ms,
            total_ms = started.elapsed().as_millis(),
            "indexed photo metadata"
        );
        identity_checked = true;
        Ok(true)
    })();
    if stopped(jobs, job, stop)? {
        return Ok(false);
    }
    match &result {
        Ok(true) => {
            jobs.record_metadata_result(
                &job.folder_id,
                text,
                &crate::jobs::FileState {
                    size,
                    mtime_ns: mtime,
                    asset_id: asset_id.clone(),
                    version: hash.clone(),
                    error: None,
                    metadata_stamp: sidecars.clone(),
                    metadata_operation_id: if force {
                        job.metadata_operation_id.clone()
                    } else {
                        None
                    },
                },
            )?;
            if identity_checked {
                jobs.identity_result(&job.folder_id, text, None)?;
            }
        }
        Err(error) => {
            jobs.record_metadata_result(
                &job.folder_id,
                text,
                &crate::jobs::FileState {
                    size,
                    mtime_ns: mtime,
                    asset_id: asset_id.clone(),
                    version: hash.clone(),
                    error: Some(format!("{error:#}")),
                    metadata_stamp: sidecars.clone(),
                    metadata_operation_id: None,
                },
            )?;
        }
        Ok(false) => {}
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn ordinary_file_reuses_index_but_metadata_override_reextracts() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let originals = temp.path().join("originals");
        fs::create_dir(&originals)?;
        let jobs = Jobs::open(&temp.path().join("jobs.sqlite"), &originals)?;
        let store = Store::open(&temp.path().join("catalog.sqlite"), true)?;
        let previews = PreviewStorage::new(
            &temp.path().join("keeps"),
            Some(&originals),
            "http://localhost",
            "test",
        )?;
        let path = jobs.root().join("photo.jpg");
        fs::write(
            &path,
            b"fixture must not be decoded when its index is current",
        )?;
        let hash = media::sha256_file(&path)?;
        let (size, mtime) = file_stamp(&path)?;
        let id = store.ingest_original(
            "library",
            path.to_str().unwrap(),
            &json!({"contentHash":hash,"sizeBytes":size,"role":"jpeg_original"}),
            &json!({"originalFilename":"photo.jpg","contentFingerprint":hash,"metadataFingerprint":"fixture","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"}),
        )?;
        crate::identity::ensure_known(&path, &store.root_id("library", &id)?)?;
        let folder = jobs.add_folder("library", ".")?;
        jobs.record_file(
            &folder.id,
            path.to_str().unwrap(),
            size,
            mtime,
            &id,
            &hash,
            None,
        )?;
        jobs.record_metadata_stamp(
            &folder.id,
            path.to_str().unwrap(),
            &media::sidecar_stamp(&path)?,
        )?;
        let mut job = jobs.enqueue_manual_file(&folder.id, &path)?;
        let stop = AtomicBool::new(false);
        assert!(!process_file(&store, &jobs, &previews, &job, &path, &stop)?);
        job.rebuild_media = true;
        assert!(!process_file(&store, &jobs, &previews, &job, &path, &stop)?);
        job.refresh_metadata = true;
        assert!(process_file(&store, &jobs, &previews, &job, &path, &stop).is_err());
        assert_eq!(media::sha256_file(&path)?, hash);
        Ok(())
    }

    #[test]
    fn metadata_override_resumes_same_generation_and_reprocesses_changed_input() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let originals = temp.path().join("originals");
        fs::create_dir(&originals)?;
        let jobs_path = temp.path().join("jobs.sqlite");
        let jobs = Jobs::open(&jobs_path, &originals)?;
        let store = Store::open(&temp.path().join("catalog.sqlite"), true)?;
        let previews = PreviewStorage::new(
            &temp.path().join("keeps"),
            Some(&originals),
            "http://localhost",
            "test",
        )?;
        let path = jobs.root().join("photo.png");
        fs::write(
            &path,
            [
                137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0,
                3, 8, 2, 0, 0, 0, 54, 136, 73, 214, 0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 99, 96,
                192, 2, 0, 0, 21, 0, 1, 170, 101, 151, 196, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66,
                96, 130,
            ],
        )?;
        let hash = media::sha256_file(&path)?;
        let folder = jobs.add_folder("library", ".")?;
        let initial = jobs.enqueue_manual_metadata_refresh(&folder.id, jobs.root())?;
        let job = jobs.claim_next()?.unwrap();
        let stop = AtomicBool::new(false);
        assert!(process_file(&store, &jobs, &previews, &job, &path, &stop)?);
        assert_eq!(
            jobs.file_state(&folder.id, path.to_str().unwrap())?
                .unwrap()
                .metadata_operation_id,
            initial.metadata_operation_id
        );
        drop(jobs);
        let jobs = Jobs::open(&jobs_path, &originals)?;
        let resumed = jobs.claim_next()?.unwrap();
        assert!(resumed.refresh_metadata);
        assert_eq!(resumed.metadata_operation_id, initial.metadata_operation_id);
        assert!(!process_file(
            &store, &jobs, &previews, &resumed, &path, &stop
        )?);
        let next = jobs.enqueue_manual_metadata_refresh(&folder.id, jobs.root())?;
        assert_ne!(next.metadata_operation_id, resumed.metadata_operation_id);
        assert!(process_file(&store, &jobs, &previews, &next, &path, &stop)?);
        assert!(!process_file(
            &store, &jobs, &previews, &next, &path, &stop
        )?);
        assert_eq!(media::sha256_file(&path)?, hash);
        let sidecar = crate::identity::sidecar_path(&path);
        let mut xmp = fs::read_to_string(&sidecar)?;
        xmp.push('\n');
        fs::write(&sidecar, xmp)?;
        assert!(process_file(&store, &jobs, &previews, &next, &path, &stop)?);
        assert!(!process_file(
            &store, &jobs, &previews, &next, &path, &stop
        )?);
        fs::write(&path, b"changed invalid source must be inspected")?;
        assert!(process_file(&store, &jobs, &previews, &next, &path, &stop).is_err());
        assert!(
            jobs.file_state(&folder.id, path.to_str().unwrap())?
                .unwrap()
                .metadata_operation_id
                .is_none()
        );
        Ok(())
    }

    #[test]
    fn import_uncheckpointed_pair_fails_without_touching_metadata() -> Result<()> {
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
        assert!(
            process_photo(&store, &jobs, &previews, &job, &path)
                .unwrap_err()
                .to_string()
                .contains("尚未完成发布")
        );
        assert_eq!(fs::read(&path)?, b"unchanged original");
        assert!(
            jobs.file_state(&folder.id, path.to_str().unwrap())?
                .is_none()
        );
        let queued = jobs.jobs(100)?;
        assert!(queued.iter().any(
            |pending| pending.work_class == "manual" && pending.path == path.to_str().unwrap()
        ));
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
    fn bad_file_fails_parent_without_automatic_child_retry() -> Result<()> {
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
        let error = run_one(&store, &jobs, &previews, &job, &AtomicBool::new(false)).unwrap_err();
        jobs.finish(&job.id, Some(&format!("{error:#}")))?;
        let parent = jobs.job(&parent.id)?.unwrap();
        assert_eq!(parent.status, "failed");
        assert!(parent.error.as_deref().unwrap().contains("bad.jpg"));
        assert!(jobs.claim_next()?.is_none());
        assert_eq!(jobs.jobs(100)?.len(), 1);
        assert!(
            jobs.file_state(&folder.id, bad.canonicalize()?.to_str().unwrap())?
                .unwrap()
                .error
                .is_some()
        );
        jobs.retry(&parent.id)?;
        let retry = jobs.claim_next()?.unwrap();
        assert_eq!(retry.id, parent.id);
        let error = run_one(&store, &jobs, &previews, &retry, &AtomicBool::new(false)).unwrap_err();
        jobs.finish(&retry.id, Some(&format!("{error:#}")))?;
        assert_eq!(jobs.job(&parent.id)?.unwrap().status, "failed");
        assert!(jobs.claim_next()?.is_none());
        Ok(())
    }

    #[test]
    fn historical_error_fails_explicit_scan_without_background_compensation() -> Result<()> {
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
        let error =
            run_one(&store, &jobs, &previews, &parent, &AtomicBool::new(false)).unwrap_err();
        jobs.finish(&parent.id, Some(&format!("{error:#}")))?;
        assert_eq!(jobs.job(&parent.id)?.unwrap().status, "failed");
        assert!(jobs.claim_next()?.is_none());
        assert_eq!(jobs.jobs(100)?.len(), 1);
        assert!(
            jobs.file_state(&folder.id, bad.to_str().unwrap())?
                .unwrap()
                .error
                .is_some()
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
    fn restart_keeps_indexed_file_state_and_resumes_scan() -> Result<()> {
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
        assert_eq!(jobs.claim_next()?.unwrap().id, claimed.id);
        assert_eq!(jobs.job(&claimed.id)?.unwrap().status, "running");
        assert_eq!(jobs.file_state(&folder.id, path)?.unwrap().version, hash);
        assert_eq!(media::sha256_file(&original)?, hash);
        Ok(())
    }

    #[test]
    #[ignore = "requires the Linux media runtime (ExifTool and ImageMagick)"]
    fn manual_recursive_refresh_reloads_unchanged_metadata_in_nested_directory() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let originals = directory.path().join("originals");
        fs::create_dir_all(originals.join("selected/nested"))?;
        let jobs = Jobs::open(&directory.path().join("jobs.sqlite"), &originals)?;
        let path = jobs.root().join("selected/nested/photo.jpg");
        media::run(
            std::process::Command::new("convert")
                .args(["-size", "8x8", "xc:red"])
                .arg(&path),
        )?;
        media::run(
            std::process::Command::new("exiftool")
                .args([
                    "-overwrite_original",
                    "-Make=ActualCamera",
                    "-Model=ActualModel",
                    "-XMP-xmpMM:OriginalDocumentID=xmp.did:metadata-refresh-fixture",
                ])
                .arg(&path),
        )?;
        fs::File::open(&path)?.set_modified(
            std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000),
        )?;
        let store = Store::open(&directory.path().join("catalog.sqlite"), true)?;
        let previews = PreviewStorage::new(
            &directory.path().join("keeps"),
            Some(&originals),
            "http://localhost",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        let (size, mtime) = file_stamp(&path)?;
        let hash = media::sha256_file(&path)?;
        let file = json!({"contentHash":hash,"sizeBytes":size,"role":"jpeg_original"});
        let snapshot = json!({"cameraMake":"StaleCamera","cameraModel":"StaleModel","originalFilename":"photo.jpg","contentFingerprint":hash,"metadataFingerprint":"stale","rating":0,"flagState":"unflagged","tags":[],"createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z"});
        let id = store.ingest_original("library", path.to_str().unwrap(), &file, &snapshot)?;
        jobs.record_file(
            &folder.id,
            path.to_str().unwrap(),
            size,
            mtime,
            &id,
            &hash,
            None,
        )?;
        jobs.record_metadata_stamp(
            &folder.id,
            path.to_str().unwrap(),
            &media::sidecar_stamp(&path)?,
        )?;
        jobs.enqueue_manual_metadata_refresh(&folder.id, &jobs.root().join("selected"))?;
        let job = jobs.claim_class("manual")?.unwrap();
        run_one(&store, &jobs, &previews, &job, &AtomicBool::new(false))?;
        assert!(store.browse_descriptor("library", &id)?.is_some());
        let refreshed = store.asset("library", &id)?;
        assert_eq!(refreshed["cameraMake"], "ActualCamera");
        assert_eq!(refreshed["cameraModel"], "ActualModel");
        let progress = jobs.job(&job.id)?.unwrap();
        assert_eq!(
            (progress.processed, progress.skipped, progress.failed),
            (1, 0, 0)
        );
        assert_eq!(media::sha256_file(&path)?, hash);
        assert_eq!(file_stamp(&path)?, (size, mtime));
        Ok(())
    }

    #[test]
    fn restart_resumes_checkpoint_without_reprocessing_completed_files() -> Result<()> {
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
        let resumed = jobs.claim_next()?.unwrap();
        assert_eq!(resumed.id, job.id);
        assert_eq!((resumed.processed, resumed.skipped), (7, 11));
        let cursor: ScanCursor = serde_json::from_str(&jobs.load_checkpoint(&job.id)?.unwrap())?;
        assert_eq!(cursor.last_name.as_deref(), Some("already.jpg"));
        assert!(run_one(
            &store,
            &jobs,
            &previews,
            &resumed,
            &AtomicBool::new(false)
        )?);
        jobs.finish(&job.id, None)?;
        let completed = jobs.job(&job.id)?.unwrap();
        assert_eq!(completed.status, "completed");
        assert_eq!(completed.processed, 7);
        assert_eq!(completed.failed, 0);
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
    fn startup_preserves_resumed_owner_until_task_completes() -> Result<()> {
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
        assert_eq!(
            store.catalog_revision("library", None, false)?["isUpdating"],
            true
        );
        let resumed = jobs.claim_next()?.unwrap();
        assert_eq!(resumed.id, queued.id);
        jobs.finish(&resumed.id, None)?;
        maintain_revisions(&store, &jobs)?;
        assert!(!store.revision_batch_ids()?.contains(&queued.id));
        assert!(jobs.claim_next()?.is_none());
        assert_eq!(
            store.catalog_revision("library", None, false)?["isUpdating"],
            false
        );
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
    fn failed_and_cancelled_jobs_settle_immediately_without_retry() -> Result<()> {
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
            assert_eq!(jobs.claim_next()?.unwrap().id, queued.id);
            if cancel {
                jobs.remove_folder(&folder.id)?;
            } else {
                jobs.finish(&queued.id, Some("fixture scan failed"))?;
            }
            maintain_revisions(&store, &jobs)?;
            assert!(jobs.claim_next()?.is_none());
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
    fn terminal_file_job_publishes_only_its_directory_branch() -> Result<()> {
        let fixture = tempfile::tempdir()?;
        let originals = fixture.path().join("originals");
        fs::create_dir_all(originals.join("unrelated/child/deep"))?;
        let jobs = Jobs::open(&fixture.path().join("jobs.sqlite"), &originals)?;
        let store = Store::open(&fixture.path().join("catalog.sqlite"), true)?;
        let previews = PreviewStorage::new(
            &fixture.path().join("keeps"),
            Some(&originals),
            "http://localhost:2283",
            "test-key",
        )?;
        let folder = jobs.add_folder("library", ".")?;
        crate::sync_navigation::refresh(&store, &jobs, "library")?;
        let unrelated_path = jobs.root().join("unrelated/child/deep");
        let unrelated = crate::sync_navigation::pages(&store.read()?, "library")?
            [unrelated_path.to_str().unwrap()]
        .clone();
        fs::create_dir(unrelated_path.join("new"))?;
        let file = jobs.root().join("2024/trip/gone.ARW");
        fs::create_dir_all(file.parent().unwrap())?;
        let queued = jobs.enqueue_manual_file(&folder.id, &file)?;
        store.note_revision_activity("library", &queued.id, file.to_str().unwrap())?;
        let job = jobs.claim_next()?.unwrap();
        run_claimed(&store, &jobs, &previews, &job, &AtomicBool::new(false))?;
        assert_eq!(jobs.job(&job.id)?.unwrap().status, "completed");
        assert!(
            crate::sync_navigation::pages(&store.read()?, "library")?
                .contains_key(file.parent().unwrap().to_str().unwrap())
        );
        assert_eq!(
            crate::sync_navigation::pages(&store.read()?, "library")?
                [unrelated_path.to_str().unwrap()],
            unrelated
        );
        assert!(!store.revision_batch_ids()?.contains(&job.id));
        Ok(())
    }

    #[test]
    fn terminal_scan_publishes_new_directories_after_failure_cancel_or_shutdown() -> Result<()> {
        for outcome in ["failed", "cancelled", "shutdown"] {
            let fixture = tempfile::tempdir()?;
            let originals = fixture.path().join("originals");
            fs::create_dir(&originals)?;
            let jobs = Jobs::open(&fixture.path().join("jobs.sqlite"), &originals)?;
            let store = Store::open(&fixture.path().join("catalog.sqlite"), true)?;
            let previews = PreviewStorage::new(
                &fixture.path().join("keeps"),
                Some(&originals),
                "http://localhost:2283",
                "test-key",
            )?;
            let folder = jobs.add_folder("library", ".")?;
            crate::sync_navigation::refresh(&store, &jobs, "library")?;
            let child = jobs.root().join("discovered");
            fs::create_dir(&child)?;
            jobs.enqueue_scan(&folder.id)?;
            let job = jobs.claim_next()?.unwrap();
            if outcome == "cancelled" {
                jobs.db
                    .lock()
                    .unwrap()
                    .execute("UPDATE jobs SET status='cancelled' WHERE id=?", [&job.id])?;
            } else if outcome == "failed" {
                jobs.db.lock().unwrap().execute(
                    "UPDATE jobs SET scope_path=?1 WHERE id=?2",
                    rusqlite::params![fixture.path().join("outside").to_str(), job.id],
                )?;
            }
            run_claimed(
                &store,
                &jobs,
                &previews,
                &job,
                &AtomicBool::new(outcome == "shutdown"),
            )?;
            assert!(
                crate::sync_navigation::pages(&store.read()?, "library")?
                    .contains_key(child.to_str().unwrap())
            );
            if outcome != "shutdown" {
                assert_eq!(jobs.job(&job.id)?.unwrap().status, outcome);
            }
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
