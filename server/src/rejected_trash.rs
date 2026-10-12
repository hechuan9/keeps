//! Explicit, count-confirmed recycling of a frozen rejected-photo inventory.
use crate::{
    api::{ApiError, AppState},
    directory_trash::{self, SharedFolder},
    jobs::Jobs,
    store::{Store, StoreError},
};
use anyhow::{Context, Result, ensure};
use axum::{
    Json, Router,
    extract::{Path as RoutePath, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet, HashSet},
    fs,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    sync::Arc,
};

fn error(status: u16, message: impl Into<String>) -> anyhow::Error {
    StoreError {
        status,
        code: "rejected_trash_failed".into(),
        message: message.into(),
    }
    .into()
}

pub(crate) fn initialize(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS rejected_trash_tasks(
        id TEXT PRIMARY KEY,library_id TEXT NOT NULL,plan TEXT NOT NULL,count INTEGER NOT NULL,
        status TEXT NOT NULL,phase TEXT NOT NULL,completed_files INTEGER NOT NULL DEFAULT 0,
        inflight INTEGER NOT NULL DEFAULT 0,error TEXT,
        created_at INTEGER NOT NULL DEFAULT(unixepoch()),updated_at INTEGER NOT NULL DEFAULT(unixepoch()),finished_at INTEGER);
        CREATE TABLE IF NOT EXISTS trash_cleanup_checks(library_id TEXT PRIMARY KEY,next_check INTEGER NOT NULL);
        CREATE UNIQUE INDEX IF NOT EXISTS rejected_trash_active_library ON rejected_trash_tasks(library_id) WHERE status IN ('pending','running');")?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct File {
    path: String,
    device: u64,
    inode: u64,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}
impl File {
    fn inspect(path: &Path) -> Result<Self> {
        let m = fs::symlink_metadata(path)
            .with_context(|| format!("检查待回收文件 {}", path.display()))?;
        ensure!(
            m.is_file(),
            error(422, "只能回收普通文件，不能回收符号链接或目录")
        );
        Ok(Self {
            path: path.to_str().context("文件路径必须为 UTF-8")?.into(),
            device: m.dev(),
            inode: m.ino(),
            size: m.len(),
            modified: (m.mtime(), m.mtime_nsec()),
            changed: (m.ctime(), m.ctime_nsec()),
        })
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct Plan {
    #[serde(default)]
    keeps_trash: bool,
    #[serde(default)]
    soft_delete: bool,
    #[serde(default)]
    cutoff: Option<i64>,
    #[serde(default)]
    asset_files: BTreeMap<String, Vec<String>>,
    assets: Vec<String>,
    files: Vec<File>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    id: String,
    count: usize,
    status: String,
    phase: String,
    completed_files: usize,
    total_files: usize,
    error: Option<String>,
    created_at: i64,
    updated_at: i64,
    finished_at: Option<i64>,
}
fn normalize_id(id: &str) -> Result<String> {
    Ok(uuid::Uuid::parse_str(id)
        .map_err(|_| error(422, "无效的回收任务 ID"))?
        .to_string())
}
fn load(jobs: &Jobs, library: &str, id: &str) -> Result<(Task, Plan, bool)> {
    let id = normalize_id(id)?;
    let row = jobs.trash_db.lock().unwrap().query_row(
        "SELECT count,status,phase,completed_files,error,created_at,updated_at,finished_at,plan,inflight FROM rejected_trash_tasks WHERE id=?1 AND library_id=?2", params![id,library],
        |r| Ok((Task { id: id.clone(),count:r.get::<_,i64>(0)? as usize,status:r.get(1)?,phase:r.get(2)?,completed_files:r.get::<_,i64>(3)? as usize,total_files:0,error:r.get(4)?,created_at:r.get(5)?,updated_at:r.get(6)?,finished_at:r.get(7)? },r.get::<_,String>(8)?,r.get::<_,bool>(9)?)))
        .optional()?.ok_or_else(||error(404,"找不到回收任务"))?;
    let plan: Plan = serde_json::from_str(&row.1)?;
    let mut task = row.0;
    task.total_files = plan.files.len();
    Ok((task, plan, row.2))
}
fn validate_paths(jobs: &Jobs, library: &str, paths: &BTreeSet<PathBuf>) -> Result<()> {
    let folders = jobs.folders()?;
    for path in paths {
        ensure!(
            jobs.validate_scan_path(path, "file")? == *path,
            error(422, "回收文件路径必须是规范路径，不能包含符号链接")
        );
        ensure!(
            folders
                .iter()
                .any(|f| f.active && f.library_id == library && path.starts_with(&f.path)),
            error(409, "待回收文件已不在当前图库的追踪范围内")
        );
        ensure!(
            !folders
                .iter()
                .any(|f| f.active && f.library_id != library && path.starts_with(&f.path)),
            error(409, "待回收文件同时属于其他图库")
        );
    }
    Ok(())
}
#[cfg(test)]
fn inventory(jobs: &Jobs, store: &Store, library: &str) -> Result<Plan> {
    inventory_scope(jobs, store, library, false, None)
}
fn inventory_scope(
    jobs: &Jobs,
    store: &Store,
    library: &str,
    keeps_trash: bool,
    cutoff: Option<i64>,
) -> Result<Plan> {
    let (assets, originals) = {
        let db = store.lock()?;
        let assets=db.prepare("SELECT id FROM catalog_assets a WHERE library_id=?1 AND ((?2=0 AND flag='rejected' AND trashed=0) OR (?2=1 AND trashed=1 AND (?3 IS NULL OR EXISTS(SELECT 1 FROM catalog_trash_entries t WHERE t.library_id=a.library_id AND t.asset_id=a.id AND t.trashed_at<=?3)))) AND (?2=1 OR EXISTS(SELECT 1 FROM catalog_paths p WHERE p.library_id=a.library_id AND p.asset_id=a.id)) ORDER BY id")?
            .query_map(params![library,keeps_trash,cutoff],|r|r.get::<_,String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let mut originals = BTreeMap::new();
        let mut query=db.prepare("SELECT path FROM catalog_paths WHERE library_id=?1 AND asset_id=?2 UNION SELECT path FROM catalog_version_paths WHERE library_id=?1 AND asset_id=?2 AND (available=1 OR ?3=1)")?;
        for id in &assets {
            originals.insert(
                id.clone(),
                query
                    .query_map(params![library, id, keeps_trash], |r| r.get::<_, String>(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?,
            );
        }
        (assets, originals)
    };
    let mut paths = BTreeSet::new();
    let mut asset_files = BTreeMap::new();
    for (id, originals) in originals {
        let mut files = BTreeSet::new();
        let mut associated = BTreeSet::new();
        for original in originals {
            let path = PathBuf::from(original);
            associated.insert(path.clone());
            if !keeps_trash || path.try_exists()? {
                files.insert(path.clone());
            }
            for sidecar in crate::media::sidecars(&path)? {
                files.insert(sidecar.canonicalize()?);
            }
        }
        associated.extend(files.iter().cloned());
        validate_paths(jobs, library, &associated)?;
        paths.extend(files.iter().cloned());
        asset_files.insert(
            id,
            associated
                .iter()
                .map(|p| p.to_string_lossy().into_owned())
                .collect(),
        );
    }
    validate_paths(jobs, library, &paths)?;
    validate_ownership(store, library, &assets, &paths)?;
    Ok(Plan {
        keeps_trash,
        soft_delete: false,
        cutoff,
        asset_files,
        assets,
        files: paths
            .iter()
            .map(|p| File::inspect(p))
            .collect::<Result<_>>()?,
    })
}

fn validate_ownership(
    store: &Store,
    library: &str,
    assets: &[String],
    paths: &BTreeSet<PathBuf>,
) -> Result<()> {
    // Stem-based sidecars can also belong to a retained or not-yet-indexed photo.
    let sidecars: HashSet<_> = paths
        .iter()
        .filter(|p| p.extension().is_some_and(|s| s.eq_ignore_ascii_case("xmp")))
        .collect();
    for parent in paths
        .iter()
        .filter_map(|p| p.parent())
        .collect::<BTreeSet<_>>()
    {
        for entry in fs::read_dir(parent)? {
            let path = entry?.path();
            if paths.contains(&path)
                || !path.is_file()
                || !(crate::media::is_photo(&path) || crate::media::is_video(&path))
            {
                continue;
            }
            ensure!(
                !crate::media::sidecars(&path)?
                    .iter()
                    .any(|p| p.canonicalize().is_ok_and(|p| sidecars.contains(&p))),
                error(409, "弃用照片与保留照片共用 XMP 文件，请先整理关联关系")
            );
        }
    }
    let selected: HashSet<_> = assets.iter().collect();
    let db = store.lock()?;
    let libraries = db
        .prepare("SELECT DISTINCT library_id FROM catalog_assets")?
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut query = db.prepare("SELECT asset_id FROM catalog_paths WHERE library_id=?1 AND path=?2 UNION SELECT asset_id FROM catalog_version_paths WHERE library_id=?1 AND path=?2 AND available=1")?;
    for path in paths {
        for owner_library in &libraries {
            for owner in query.query_map(
                params![
                    owner_library,
                    path.to_str().context("文件路径必须为 UTF-8")?
                ],
                |r| r.get::<_, String>(0),
            )? {
                let owner = owner?;
                ensure!(
                    owner_library == library && selected.contains(&owner),
                    error(409, "文件还关联着未弃用的照片，不能回收")
                );
            }
        }
    }
    drop(query);
    drop(db);
    Ok(())
}
#[cfg(test)]
fn preview(jobs: &Jobs, store: &Store, library: &str) -> Result<Task> {
    let _guard = jobs.directory_mutation.read().unwrap();
    crate::directory_move::ensure_reconciled(jobs)?;
    let plan = inventory(jobs, store, library)?;
    save_preview(jobs, library, &plan)
}
fn save_preview(jobs: &Jobs, library: &str, plan: &Plan) -> Result<Task> {
    let id = uuid::Uuid::new_v4().to_string();
    jobs.trash_db.lock().unwrap().execute("INSERT INTO rejected_trash_tasks(id,library_id,plan,count,status,phase) VALUES(?1,?2,?3,?4,'draft','confirmation')",params![id,library,serde_json::to_string(&plan)?,plan.assets.len() as i64])?;
    Ok(load(jobs, library, &id)?.0)
}
fn submit(jobs: &Jobs, store: &Store, library: &str, id: &str, count: usize) -> Result<Task> {
    let _guard = jobs.directory_mutation.write().unwrap();
    let (task, plan, _) = load(jobs, library, id)?;
    ensure!(
        count > 0 && count == task.count,
        error(422, "输入的照片数量必须与确认窗口完全一致")
    );
    if task.status != "draft" {
        return Ok(task);
    }
    ensure!(
        current_inventory(jobs, store, library, &plan)? == plan,
        error(409, "弃用照片或文件已变化，请关闭窗口后重新确认数量")
    );
    let db = jobs.trash_db.lock().unwrap();
    let busy:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM rejected_trash_tasks WHERE library_id=?1 AND status IN ('pending','running'))",[library],|r|r.get(0))?;
    ensure!(!busy, error(409, "已有照片回收任务，请等待完成"));
    db.execute("UPDATE rejected_trash_tasks SET status='pending',phase='waiting',updated_at=unixepoch() WHERE id=?1",[&task.id])?;
    drop(db);
    Ok(load(jobs, library, &task.id)?.0)
}
fn transition(jobs: &Jobs, id: &str, phase: &str, message: Option<&str>) -> Result<()> {
    let status = if ["completed", "failed"].contains(&phase) {
        phase
    } else {
        "running"
    };
    jobs.trash_db.lock().unwrap().execute("UPDATE rejected_trash_tasks SET status=?2,phase=?3,error=?4,updated_at=unixepoch(),finished_at=CASE WHEN ?2 IN ('completed','failed') THEN unixepoch() ELSE NULL END WHERE id=?1",params![id,status,phase,message])?;
    Ok(())
}
fn reconcile(jobs: &Jobs, store: &Store, library: &str, plan: &Plan) -> Result<()> {
    if plan.keeps_trash {
        store.enqueue_recycled_asset_caches(library, &plan.assets)?;
    }
    let mut paths: BTreeSet<String> = plan.files.iter().map(|f| f.path.clone()).collect();
    paths.extend(plan.asset_files.values().flatten().cloned());
    for path in paths {
        jobs.validate_scan_path(Path::new(&path), "file")?;
        store.mark_missing_scope_with_revision(library, &path, "file", None)?;
        if !Path::new(&path).try_exists()? {
            jobs.db.lock().unwrap().execute("DELETE FROM files WHERE path=?1 AND folder_id IN (SELECT id FROM folders WHERE library_id=?2)",params![path,library])?;
        }
    }
    store.reconcile_cache()?;
    if plan.keeps_trash {
        let mut finished = Vec::new();
        for asset in &plan.assets {
            let files = plan
                .asset_files
                .get(asset)
                .cloned()
                .unwrap_or_else(|| plan.files.iter().map(|f| f.path.clone()).collect());
            if files
                .iter()
                .map(|p| Path::new(p).try_exists())
                .collect::<std::io::Result<Vec<_>>>()?
                .iter()
                .all(|exists| !exists)
            {
                finished.push(asset.clone());
            }
        }
        store.purge_recycled_assets(library, &finished)?;
        if plan.cutoff.is_none() && finished.len() == plan.assets.len() {
            jobs.trash_db.lock().unwrap().execute(
                "DELETE FROM trash_cleanup_checks WHERE library_id=?",
                [library],
            )?;
        }
    }
    Ok(())
}
fn recycle_plan(
    jobs: &Jobs,
    store: &Store,
    library: &str,
    task: &Task,
    plan: &Plan,
    config: &str,
    mut recycle: impl FnMut(&SharedFolder, &Path) -> Result<()>,
) -> Result<()> {
    let inflight: bool = jobs.trash_db.lock().unwrap().query_row(
        "SELECT inflight FROM rejected_trash_tasks WHERE id=?1",
        [&task.id],
        |r| r.get(0),
    )?;
    let mut next = task.completed_files;
    if inflight {
        let file = plan.files.get(next).context("回收任务进度无效")?;
        ensure!(
            !Path::new(&file.path).try_exists()?,
            error(
                409,
                "服务器在文件回收期间重启；请检查 NAS 回收站和原目录。为避免误删，不重复执行该文件的回收"
            )
        );
        next += 1;
        jobs.trash_db.lock().unwrap().execute(
            "UPDATE rejected_trash_tasks SET completed_files=?2,inflight=0 WHERE id=?1",
            params![task.id, next as i64],
        )?;
    }
    let remaining: BTreeSet<_> = plan.files[next..]
        .iter()
        .map(|f| PathBuf::from(&f.path))
        .collect();
    validate_paths(jobs, library, &remaining)?;
    validate_ownership(store, library, &plan.assets, &remaining)?;
    // Validate all remaining files and DSM shares before the first native operation.
    let shares = plan.files[next..]
        .iter()
        .map(|file| {
            ensure!(
                File::inspect(Path::new(&file.path))? == *file,
                error(409, "待回收文件已变化，请重新确认")
            );
            directory_trash::recycle_share(config, Path::new(&file.path))
        })
        .collect::<Result<Vec<_>>>()?;
    for (file, share) in plan.files[next..].iter().zip(shares) {
        ensure!(
            File::inspect(Path::new(&file.path))? == *file,
            error(409, "待回收文件已变化，已停止回收")
        );
        jobs.trash_db.lock().unwrap().execute("UPDATE rejected_trash_tasks SET phase='recycling',inflight=1,updated_at=unixepoch() WHERE id=?1",[&task.id])?;
        recycle(&share, Path::new(&file.path))?;
        ensure!(
            !Path::new(&file.path).try_exists()?,
            error(500, "NAS 返回成功，但原文件仍存在")
        );
        next += 1;
        jobs.trash_db.lock().unwrap().execute("UPDATE rejected_trash_tasks SET completed_files=?2,inflight=0,updated_at=unixepoch() WHERE id=?1",params![task.id,next as i64])?;
    }
    Ok(())
}
fn process(
    jobs: &Jobs,
    store: &Store,
    library: &str,
    id: &str,
    config: impl FnOnce() -> Result<String>,
    recycle: impl FnMut(&SharedFolder, &Path) -> Result<()>,
) -> Result<()> {
    let _guard = jobs.directory_mutation.write().unwrap();
    let (task, plan, _) = load(jobs, library, id)?;
    if task.phase == "reconciling" {
        reconcile(jobs, store, library, &plan)?;
        return transition(
            jobs,
            id,
            if task.error.is_some() {
                "failed"
            } else {
                "completed"
            },
            task.error.as_deref(),
        );
    }
    if plan.soft_delete {
        return match store.trash_rejected_ids(library, &plan.assets) {
            Ok(()) => transition(jobs, id, "completed", None),
            Err(e) => transition(jobs, id, "failed", Some(&format!("{e:#}"))),
        };
    }
    let mut native_started = false;
    let work = (|| -> Result<()> {
        crate::directory_move::ensure_reconciled(jobs)?;
        if task.phase == "waiting" || task.phase == "validating" {
            transition(jobs, id, "validating", None)?;
            ensure!(
                current_inventory(jobs, store, library, &plan)? == plan,
                error(409, "弃用照片或文件已变化，请重新确认")
            );
        }
        if plan.cutoff.is_some() {
            let policy = settings(store, library)?;
            ensure!(policy.enabled, error(409, "自动清理已关闭，已停止回收"));
            let cutoff = chrono::Utc::now().timestamp() - policy.retention_days * 86400;
            let db = store.lock()?;
            for asset in &plan.assets {
                let due:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM catalog_trash_entries WHERE library_id=?1 AND asset_id=?2 AND trashed_at<=?3)",params![library,asset,cutoff],|r|r.get(0))?;
                ensure!(due, error(409, "保留期限已变更，照片尚未到期"));
            }
        }
        // Metadata mutations use the same directory lock; recheck flags when resuming.
        let db = store.lock()?;
        for asset in &plan.assets {
            let rejected:bool=db.query_row("SELECT EXISTS(SELECT 1 FROM catalog_assets WHERE library_id=?1 AND id=?2 AND ((?3=0 AND flag='rejected' AND trashed=0) OR (?3=1 AND trashed=1 AND (?4 IS NULL OR EXISTS(SELECT 1 FROM catalog_trash_entries t WHERE t.library_id=?1 AND t.asset_id=?2 AND t.trashed_at<=?4)))))",params![library,asset,plan.keeps_trash,plan.cutoff],|r|r.get(0))?;
            ensure!(rejected, error(409, "照片已不再是弃用状态，已停止回收"));
        }
        drop(db);
        let importing: bool = jobs.db.lock().unwrap().query_row(
            "SELECT EXISTS(SELECT 1 FROM imports WHERE json_extract(manifest,'$.finished')=0)",
            [],
            |r| r.get(0),
        )?;
        ensure!(!importing, error(409, "请先完成正在进行的导入，再回收照片"));
        let config = config()?;
        native_started = true;
        recycle_plan(jobs, store, library, &task, &plan, &config, recycle)
    })();
    let message = work
        .err()
        .map(|e| format!("{e:#}。部分文件可能已移入 NAS 回收站，请检查 File Station。"));
    if plan.cutoff.is_some() && message.is_some() && native_started {
        jobs.trash_db.lock().unwrap().execute("INSERT INTO trash_cleanup_checks VALUES(?1,?2) ON CONFLICT(library_id) DO UPDATE SET next_check=excluded.next_check",params![library,i64::MAX])?;
    }
    transition(jobs, id, "reconciling", message.as_deref())?;
    reconcile(jobs, store, library, &plan)?;
    transition(
        jobs,
        id,
        if message.is_some() {
            "failed"
        } else {
            "completed"
        },
        message.as_deref(),
    )
}
pub(crate) fn process_next(jobs: &Jobs, store: &Store) -> Result<bool> {
    let next=jobs.trash_db.lock().unwrap().query_row("SELECT id,library_id FROM rejected_trash_tasks WHERE status IN ('pending','running') ORDER BY created_at,id LIMIT 1",[],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?))).optional()?;
    let Some((id, library)) = next else {
        return Ok(false);
    };
    if let Err(e) = process(
        jobs,
        store,
        &library,
        &id,
        || fs::read_to_string("/etc/samba/smb.share.conf").context("无法读取 DSM 回收站配置"),
        directory_trash::recycle_file,
    ) {
        tracing::error!(task=%id,error=%format!("{e:#}"),"Photo recycling reconciliation failed; task remains resumable");
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
    Ok(true)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TrashSettings {
    pub enabled: bool,
    pub retention_days: i64,
}
fn settings(store: &Store, library: &str) -> Result<TrashSettings> {
    Ok(store
        .lock()?
        .query_row(
            "SELECT enabled,retention_days FROM trash_settings WHERE library_id=?",
            [library],
            |r| {
                Ok(TrashSettings {
                    enabled: r.get(0)?,
                    retention_days: r.get(1)?,
                })
            },
        )
        .optional()?
        .unwrap_or(TrashSettings {
            enabled: true,
            retention_days: 30,
        }))
}
fn rejected_ids(store: &Store, library: &str) -> Result<Vec<String>> {
    Ok(store.lock()?.prepare("SELECT id FROM catalog_assets a WHERE library_id=? AND flag='rejected' AND trashed=0 AND EXISTS(SELECT 1 FROM catalog_paths p WHERE p.library_id=a.library_id AND p.asset_id=a.id) ORDER BY id")?.query_map([library], |r|r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?)
}
fn current_inventory(jobs: &Jobs, store: &Store, library: &str, plan: &Plan) -> Result<Plan> {
    if plan.soft_delete {
        Ok(Plan {
            keeps_trash: false,
            soft_delete: true,
            cutoff: None,
            asset_files: BTreeMap::new(),
            assets: rejected_ids(store, library)?,
            files: vec![],
        })
    } else {
        inventory_scope(jobs, store, library, plan.keeps_trash, plan.cutoff)
    }
}
fn soft_preview(jobs: &Jobs, store: &Store, library: &str) -> Result<Task> {
    let _guard = jobs.directory_mutation.read().unwrap();
    let plan = Plan {
        keeps_trash: false,
        soft_delete: true,
        cutoff: None,
        asset_files: BTreeMap::new(),
        assets: rejected_ids(store, library)?,
        files: vec![],
    };
    save_preview(jobs, library, &plan)
}
fn trash_preview(jobs: &Jobs, store: &Store, library: &str) -> Result<Task> {
    let _guard = jobs.directory_mutation.read().unwrap();
    crate::directory_move::ensure_reconciled(jobs)?;
    save_preview(
        jobs,
        library,
        &inventory_scope(jobs, store, library, true, None)?,
    )
}
// Persist the next check before inspecting files: a blocked/failed inventory must not spin.
pub(crate) fn schedule_expired(jobs: &Jobs, store: &Store, now: i64) -> Result<()> {
    let _guard = jobs.directory_mutation.write().unwrap();
    let libraries = store
        .lock()?
        .prepare("SELECT DISTINCT library_id FROM catalog_trash_entries")?
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for library in libraries {
        let policy = settings(store, &library)?;
        if !policy.enabled {
            continue;
        }
        let db = jobs.trash_db.lock().unwrap();
        let due: bool = db.query_row("SELECT NOT EXISTS(SELECT 1 FROM trash_cleanup_checks WHERE library_id=?1 AND next_check>?2) AND NOT EXISTS(SELECT 1 FROM rejected_trash_tasks WHERE library_id=?1 AND status IN ('pending','running'))", params![library,now], |r|r.get(0))?;
        if !due {
            continue;
        }
        db.execute("INSERT INTO trash_cleanup_checks(library_id,next_check) VALUES(?1,?2) ON CONFLICT(library_id) DO UPDATE SET next_check=excluded.next_check",params![library,now+3600])?;
        drop(db);
        let cutoff = now - policy.retention_days * 86400;
        let work = (|| -> Result<()> {
            crate::directory_move::ensure_reconciled(jobs)?;
            let plan = inventory_scope(jobs, store, &library, true, Some(cutoff))?;
            if plan.assets.is_empty() {
                return Ok(());
            }
            let task = save_preview(jobs, &library, &plan)?;
            jobs.trash_db.lock().unwrap().execute(
                "UPDATE rejected_trash_tasks SET status='pending',phase='waiting' WHERE id=?",
                [task.id],
            )?;
            Ok(())
        })();
        if let Err(e) = work {
            tracing::error!(library=%library,error=%format!("{e:#}"),"Automatic trash cleanup scheduling failed");
        }
    }
    Ok(())
}
async fn trash_preview_api(
    State(s): State<Arc<AppState>>,
    RoutePath(lib): RoutePath<String>,
) -> Result<Response, ApiError> {
    run(
        move || trash_preview(&s.jobs, &s.store, &lib),
        StatusCode::OK,
    )
    .await
}
async fn settings_api(
    State(s): State<Arc<AppState>>,
    RoutePath(lib): RoutePath<String>,
) -> Result<Response, ApiError> {
    let value = tokio::task::spawn_blocking(move || settings(&s.store, &lib))
        .await
        .map_err(anyhow::Error::from)??;
    Ok(Json(value).into_response())
}
async fn set_settings_api(
    State(s): State<Arc<AppState>>,
    RoutePath(lib): RoutePath<String>,
    Json(value): Json<TrashSettings>,
) -> Result<Response, ApiError> {
    let value=tokio::task::spawn_blocking(move || -> Result<TrashSettings> {
        ensure!((1..=3650).contains(&value.retention_days),error(422,"保留期限须为 1–3650 天"));
        let _guard=s.jobs.directory_mutation.write().unwrap();
        s.store.lock()?.execute("INSERT INTO trash_settings VALUES(?1,?2,?3) ON CONFLICT(library_id) DO UPDATE SET enabled=excluded.enabled,retention_days=excluded.retention_days",params![lib,value.enabled,value.retention_days])?;
        s.jobs.trash_db.lock().unwrap().execute("DELETE FROM trash_cleanup_checks WHERE library_id=?",[lib])?;
        Ok(value)
    }).await.map_err(anyhow::Error::from)??;
    Ok(Json(value).into_response())
}

pub(crate) fn cleanup_status(jobs: &Jobs, library: &str) -> Result<Option<serde_json::Value>> {
    let row=jobs.trash_db.lock().unwrap().query_row("SELECT status,error FROM rejected_trash_tasks WHERE library_id=?1 AND json_extract(plan,'$.keeps_trash')=1 AND status IN ('pending','running','failed','completed') ORDER BY CASE WHEN status IN ('pending','running') THEN 0 ELSE 1 END,rowid DESC LIMIT 1",[library],|r|Ok((r.get::<_,String>(0)?,r.get::<_,Option<String>>(1)?))).optional()?;
    Ok(row.filter(|(status,_)|status!="completed").map(|(status,error)|serde_json::json!({"status":status,"kind":"trash","error":error,"path":null,"currentPhoto":null,"processed":null,"failed":null})))
}

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route(
            "/libraries/{library}/trash/settings",
            get(settings_api).put(set_settings_api),
        )
        .route(
            "/libraries/{library}/trash/preview",
            post(trash_preview_api),
        )
        .route(
            "/libraries/{library}/trash/{id}",
            get(status_api).post(submit_api),
        )
        .route(
            "/libraries/{library}/rejected-trash/preview",
            post(preview_api),
        )
        .route(
            "/libraries/{library}/rejected-trash/{id}",
            get(status_api).post(submit_api),
        )
}
async fn run(
    f: impl FnOnce() -> Result<Task> + Send + 'static,
    status: StatusCode,
) -> Result<Response, ApiError> {
    let task = tokio::task::spawn_blocking(f)
        .await
        .map_err(anyhow::Error::from)??;
    Ok((status, Json(task)).into_response())
}
async fn preview_api(
    State(s): State<Arc<AppState>>,
    RoutePath(lib): RoutePath<String>,
) -> Result<Response, ApiError> {
    run(
        move || soft_preview(&s.jobs, &s.store, &lib),
        StatusCode::OK,
    )
    .await
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Confirmation {
    confirmation_count: usize,
}
async fn submit_api(
    State(s): State<Arc<AppState>>,
    RoutePath((lib, id)): RoutePath<(String, String)>,
    Json(body): Json<Confirmation>,
) -> Result<Response, ApiError> {
    run(
        move || submit(&s.jobs, &s.store, &lib, &id, body.confirmation_count),
        StatusCode::ACCEPTED,
    )
    .await
}
async fn status_api(
    State(s): State<Arc<AppState>>,
    RoutePath((lib, id)): RoutePath<(String, String)>,
) -> Result<Response, ApiError> {
    run(move || Ok(load(&s.jobs, &lib, &id)?.0), StatusCode::OK).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn setup() -> Result<(tempfile::TempDir, Jobs, Store, String)> {
        let tmp = tempfile::tempdir()?;
        fs::create_dir_all(tmp.path().join("photos/#recycle"))?;
        let jobs = Jobs::open(&tmp.path().join("jobs.sqlite"), &tmp.path().join("photos"))?;
        jobs.add_folder("lib", jobs.root().to_str().unwrap())?;
        let store = Store::open(&tmp.path().join("catalog.sqlite"), true)?;
        let config = format!(
            "[photo]\npath={}\nenable recycle bin=yes\n",
            jobs.root().display()
        );
        Ok((tmp, jobs, store, config))
    }
    fn photo(store: &Store, path: &Path, hash: &str, identity: Option<&str>) -> Result<String> {
        fs::create_dir_all(path.parent().unwrap())?;
        fs::write(path, b"original")?;
        store.ingest_original("lib",path.to_str().unwrap(),&json!({"contentHash":hash,"sizeBytes":8,"role":"jpeg_original"}),&json!({"originalDocumentID":identity,"contentFingerprint":hash,"metadataFingerprint":"metadata","createdAt":"2024-01-01T00:00:00Z","updatedAt":"2024-01-01T00:00:00Z","originalFilename":path.file_name().unwrap().to_str().unwrap(),"rating":0,"flagState":"unflagged","tags":[]}))?;
        let id: String = store.lock()?.query_row(
            "SELECT asset_id FROM catalog_paths WHERE library_id='lib' AND path=?",
            [path.to_str().unwrap()],
            |r| r.get(0),
        )?;
        store.patch_asset("lib", &id, &json!({"flagState":"rejected"}))?;
        Ok(id)
    }
    fn simulated_recycle(root: &Path, path: &Path) -> Result<()> {
        let target = root.join("#recycle").join(path.strip_prefix(root)?);
        fs::create_dir_all(target.parent().unwrap())?;
        fs::rename(path, target)?;
        Ok(())
    }
    #[test]
    fn rejected_delete_enters_keeps_without_touching_files_and_retries_after_restart() -> Result<()>
    {
        let (_tmp, jobs, store, _) = setup()?;
        let file = jobs.root().join("soft.jpg");
        let id = photo(&store, &file, "soft", None)?;
        let task = soft_preview(&jobs, &store, "lib")?;
        assert_eq!(task.total_files, 0);
        submit(&jobs, &store, "lib", &task.id, 1)?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || panic!("no DSM call"),
            |_, _| panic!("no file operation"),
        )?;
        assert!(file.exists());
        assert_eq!(store.counts("lib", true)?["trashed"], 1);
        let entered: i64 = store.lock()?.query_row(
            "SELECT trashed_at FROM catalog_trash_entries WHERE asset_id=?",
            [&id],
            |r| r.get(0),
        )?;
        // Recover a crash after the catalog commit and before the jobs receipt.
        jobs.trash_db.lock().unwrap().execute(
            "UPDATE rejected_trash_tasks SET status='pending',phase='waiting' WHERE id=?",
            [&task.id],
        )?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || panic!("no DSM call"),
            |_, _| panic!("no file operation"),
        )?;
        assert_eq!(load(&jobs, "lib", &task.id)?.0.status, "completed");
        assert_eq!(
            store.lock()?.query_row(
                "SELECT trashed_at FROM catalog_trash_entries WHERE asset_id=?",
                [&id],
                |r| r.get::<_, i64>(0)
            )?,
            entered
        );
        store.set_trashed("lib", &id, false)?;
        assert_eq!(
            store
                .lock()?
                .query_row("SELECT count(*) FROM catalog_trash_entries", [], |r| r
                    .get::<_, i64>(0))?,
            0
        );
        Ok(())
    }
    #[test]
    fn emptying_keeps_recycles_all_versions_and_purges_catalog_only_after_success() -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let file = jobs.root().join("empty.jpg");
        let id = photo(&store, &file, "empty", None)?;
        fs::write(file.with_extension("xmp"), b"sidecar")?;
        store.set_trashed("lib", &id, true)?;
        let task = trash_preview(&jobs, &store, "lib")?;
        assert_eq!(task.count, 1);
        assert_eq!(task.total_files, 2);
        submit(&jobs, &store, "lib", &task.id, 1)?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || Ok(config),
            |_, p| simulated_recycle(jobs.root(), p),
        )?;
        assert_eq!(load(&jobs, "lib", &task.id)?.0.status, "completed");
        assert!(jobs.root().join("#recycle/empty.jpg").exists());
        assert_eq!(
            store.lock()?.query_row(
                "SELECT count(*) FROM catalog_assets WHERE id=?",
                [&id],
                |r| r.get::<_, i64>(0)
            )?,
            0
        );
        assert_eq!(store.counts("lib", true)?["trashed"], 0);
        Ok(())
    }
    #[test]
    fn restored_photo_prevents_emptying_and_failure_keeps_catalog() -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let file = jobs.root().join("restore.jpg");
        let id = photo(&store, &file, "restore", None)?;
        store.set_trashed("lib", &id, true)?;
        let task = trash_preview(&jobs, &store, "lib")?;
        submit(&jobs, &store, "lib", &task.id, 1)?;
        store.set_trashed("lib", &id, false)?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || Ok(config),
            |_, _| panic!("restored original must remain"),
        )?;
        assert_eq!(load(&jobs, "lib", &task.id)?.0.status, "failed");
        assert!(file.exists());
        assert_eq!(store.counts("lib", true)?["all"], 1);
        Ok(())
    }
    #[test]
    fn retention_only_schedules_expired_photos_and_respects_disable_and_changed_policy()
    -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let now = chrono::Utc::now().timestamp();
        let old = photo(&store, &jobs.root().join("old.jpg"), "old", None)?;
        let young = photo(&store, &jobs.root().join("young.jpg"), "young", None)?;
        store.set_trashed("lib", &old, true)?;
        store.set_trashed("lib", &young, true)?;
        store.lock()?.execute(
            "UPDATE catalog_trash_entries SET trashed_at=? WHERE asset_id=?",
            params![now - 30 * 86400, &old],
        )?;
        assert_eq!(
            settings(&store, "lib")?,
            TrashSettings {
                enabled: true,
                retention_days: 30
            }
        );
        store
            .lock()?
            .execute("INSERT INTO trash_settings VALUES('lib',0,30)", [])?;
        schedule_expired(&jobs, &store, now)?;
        assert_eq!(
            jobs.trash_db.lock().unwrap().query_row(
                "SELECT count(*) FROM rejected_trash_tasks",
                [],
                |r| r.get::<_, i64>(0)
            )?,
            0
        );
        store
            .lock()?
            .execute("UPDATE trash_settings SET enabled=1", [])?;
        schedule_expired(&jobs, &store, now)?;
        let id: String = jobs.trash_db.lock().unwrap().query_row(
            "SELECT id FROM rejected_trash_tasks",
            [],
            |r| r.get(0),
        )?;
        assert_eq!(load(&jobs, "lib", &id)?.1.assets, vec![old.clone()]);
        // A longer retention period cancels already queued automatic work.
        store
            .lock()?
            .execute("UPDATE trash_settings SET retention_days=60", [])?;
        process(
            &jobs,
            &store,
            "lib",
            &id,
            || Ok(config),
            |_, _| panic!("new retention has not expired"),
        )?;
        assert_eq!(load(&jobs, "lib", &id)?.0.status, "failed");
        assert!(jobs.root().join("old.jpg").exists());
        assert!(jobs.root().join("young.jpg").exists());
        schedule_expired(&jobs, &store, now + 31 * 86400)?;
        assert_eq!(
            jobs.trash_db.lock().unwrap().query_row(
                "SELECT count(*) FROM rejected_trash_tasks",
                [],
                |r| r.get::<_, i64>(0)
            )?,
            2
        );
        Ok(())
    }
    #[test]
    fn automatic_cleanup_is_durable_and_failure_pauses_until_user_action() -> Result<()> {
        let (tmp, jobs, store, config) = setup()?;
        let now = chrono::Utc::now().timestamp();
        let file = jobs.root().join("expired.jpg");
        let id = photo(&store, &file, "expired", None)?;
        store.set_trashed("lib", &id, true)?;
        store.lock()?.execute(
            "UPDATE catalog_trash_entries SET trashed_at=? WHERE asset_id=?",
            params![now - 31 * 86400, &id],
        )?;
        schedule_expired(&jobs, &store, now)?;
        let task: String = jobs.trash_db.lock().unwrap().query_row(
            "SELECT id FROM rejected_trash_tasks",
            [],
            |r| r.get(0),
        )?;
        drop(jobs);
        let jobs = Jobs::open(&tmp.path().join("jobs.sqlite"), &tmp.path().join("photos"))?;
        process(
            &jobs,
            &store,
            "lib",
            &task,
            || Ok(config),
            |_, _| anyhow::bail!("simulated native failure"),
        )?;
        assert_eq!(load(&jobs, "lib", &task)?.0.status, "failed");
        assert!(file.exists());
        assert_eq!(cleanup_status(&jobs, "lib")?.unwrap()["status"], "failed");
        schedule_expired(&jobs, &store, now + 86400)?;
        assert_eq!(
            jobs.trash_db.lock().unwrap().query_row(
                "SELECT count(*) FROM rejected_trash_tasks",
                [],
                |r| r.get::<_, i64>(0)
            )?,
            1
        );
        Ok(())
    }
    #[test]
    fn cleanup_retires_generated_caches_and_removes_edit_history() -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let id = photo(&store, &jobs.root().join("cached.jpg"), "cached", None)?;
        let key = format!("libraries/lib/assets/{id}/derivatives/thumbnail/cache.heic");
        store.lock()?.execute("INSERT INTO derivative_objects VALUES('lib',?1,'preview','{}','keeps-previews',?2,NULL,64,64,'now')",params![id,key])?;
        store.lock()?.execute(
            "INSERT INTO photo_edit_decisions VALUES('lib',?1,'{}')",
            [&id],
        )?;
        store.set_trashed("lib", &id, true)?;
        let task = trash_preview(&jobs, &store, "lib")?;
        submit(&jobs, &store, "lib", &task.id, 1)?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || Ok(config),
            |_, p| simulated_recycle(jobs.root(), p),
        )?;
        assert_eq!(load(&jobs, "lib", &task.id)?.0.status, "completed");
        let db = store.lock()?;
        assert_eq!(
            db.query_row("SELECT count(*) FROM derivative_objects", [], |r| r
                .get::<_, i64>(0))?,
            0
        );
        assert_eq!(
            db.query_row("SELECT count(*) FROM photo_edit_decisions", [], |r| r
                .get::<_, i64>(0))?,
            0
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM media_cache_gc WHERE object_key=?",
                [key],
                |r| r.get::<_, i64>(0)
            )?,
            1
        );
        Ok(())
    }
    #[test]
    fn partial_batch_purges_finished_photo_and_next_clear_handles_only_remaining_photo()
    -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let a = jobs.root().join("a.jpg");
        let b = jobs.root().join("b.jpg");
        let aid = photo(&store, &a, "a", None)?;
        let bid = photo(&store, &b, "b", None)?;
        store.set_trashed("lib", &aid, true)?;
        store.set_trashed("lib", &bid, true)?;
        let task = trash_preview(&jobs, &store, "lib")?;
        submit(&jobs, &store, "lib", &task.id, 2)?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || Ok(config.clone()),
            |_, p| {
                if p == b {
                    anyhow::bail!("simulated failure");
                }
                simulated_recycle(jobs.root(), p)
            },
        )?;
        assert_eq!(load(&jobs, "lib", &task.id)?.0.status, "failed");
        assert_eq!(
            store.lock()?.query_row(
                "SELECT count(*) FROM catalog_assets WHERE id=?",
                [&aid],
                |r| r.get::<_, i64>(0)
            )?,
            0
        );
        assert!(b.exists());
        let retry = trash_preview(&jobs, &store, "lib")?;
        assert_eq!(retry.count, 1);
        submit(&jobs, &store, "lib", &retry.id, 1)?;
        process(
            &jobs,
            &store,
            "lib",
            &retry.id,
            || Ok(config),
            |_, p| simulated_recycle(jobs.root(), p),
        )?;
        assert_eq!(store.counts("lib", true)?["trashed"], 0);
        Ok(())
    }
    #[test]
    fn orphan_sidecar_after_native_failure_remains_in_next_clear_inventory() -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let raw = jobs.root().join("a.jpg");
        let sidecar = raw.with_extension("xmp");
        let id = photo(&store, &raw, "a", None)?;
        fs::write(&sidecar, b"metadata")?;
        store.set_trashed("lib", &id, true)?;
        let task = trash_preview(&jobs, &store, "lib")?;
        submit(&jobs, &store, "lib", &task.id, 1)?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || Ok(config.clone()),
            |_, p| {
                if p == sidecar {
                    anyhow::bail!("simulated sidecar failure");
                }
                simulated_recycle(jobs.root(), p)
            },
        )?;
        assert!(!raw.exists());
        assert!(sidecar.exists());
        let retry = trash_preview(&jobs, &store, "lib")?;
        assert_eq!(retry.count, 1);
        assert_eq!(retry.total_files, 1);
        submit(&jobs, &store, "lib", &retry.id, 1)?;
        process(
            &jobs,
            &store,
            "lib",
            &retry.id,
            || Ok(config),
            |_, p| simulated_recycle(jobs.root(), p),
        )?;
        assert!(!sidecar.exists());
        assert_eq!(
            store.lock()?.query_row(
                "SELECT count(*) FROM catalog_assets WHERE id=?",
                [id],
                |r| r.get::<_, i64>(0)
            )?,
            0
        );
        Ok(())
    }
    #[test]
    fn migration_starts_old_trash_retention_now_and_rejects_invalid_policy() -> Result<()> {
        let (_tmp, jobs, store, _) = setup()?;
        let id = photo(
            &store,
            &jobs.root().join("historical.jpg"),
            "historical",
            None,
        )?;
        store.set_trashed("lib", &id, true)?;
        let before = chrono::Utc::now().timestamp();
        store.lock()?.execute_batch("DROP TRIGGER catalog_trash_enter; DROP TRIGGER catalog_trash_restore; DROP TRIGGER catalog_trash_insert; DROP TRIGGER catalog_trash_remove; DROP TABLE catalog_trash_entries; DROP TABLE trash_settings; PRAGMA user_version=15;")?;
        let mut db = store.lock()?;
        crate::catalog::ensure_schema(&mut db, true)?;
        let entered: i64 = db.query_row(
            "SELECT trashed_at FROM catalog_trash_entries WHERE asset_id=?",
            [id],
            |r| r.get(0),
        )?;
        assert!(entered >= before);
        assert!(
            db.execute("INSERT INTO trash_settings VALUES('lib',1,0)", [])
                .is_err()
        );
        assert!(
            db.execute("INSERT INTO trash_settings VALUES('lib',1,3651)", [])
                .is_err()
        );
        Ok(())
    }
    #[test]
    fn count_is_photos_including_hidden_and_all_versions_recycle_with_sidecars() -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let raw = jobs.root().join("hidden/a.raw");
        let id = photo(&store, &raw, "raw", None)?;
        photo(&store, &jobs.root().join("hidden/a.jpg"), "jpg", Some(&id))?;
        fs::write(raw.with_extension("xmp"), b"sidecar")?;
        store.set_hidden_directory("lib", raw.parent().unwrap().to_str().unwrap(), true)?;
        let kept = jobs.root().join("kept.jpg");
        let kept_id = photo(&store, &kept, "kept", None)?;
        store.patch_asset("lib", &kept_id, &json!({"flagState":"picked"}))?;
        let task = preview(&jobs, &store, "lib")?;
        assert_eq!(task.count, 1);
        assert_eq!(task.total_files, 3);
        assert!(raw.exists());
        assert!(submit(&jobs, &store, "lib", &task.id, 0).is_err());
        assert!(submit(&jobs, &store, "lib", &task.id, 2).is_err());
        assert!(load(&jobs, "other", &task.id).is_err());
        assert_eq!(submit(&jobs, &store, "lib", &task.id, 1)?.status, "pending");
        assert_eq!(submit(&jobs, &store, "lib", &task.id, 1)?.status, "pending");
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || Ok(config),
            |_, p| simulated_recycle(jobs.root(), p),
        )?;
        let finished = load(&jobs, "lib", &task.id)?.0;
        assert_eq!(finished.status, "completed", "{:?}", finished);
        assert_eq!(finished.completed_files, 3);
        assert!(kept.exists());
        assert!(!raw.exists());
        assert_eq!(store.counts("lib", true)?["all"], 1);
        assert_eq!(
            submit(&jobs, &store, "lib", &task.id, 1)?.status,
            "completed"
        );
        Ok(())
    }
    #[test]
    fn same_count_different_photos_and_file_replacements_require_new_confirmation() -> Result<()> {
        let (_tmp, jobs, store, _) = setup()?;
        let first = jobs.root().join("a.jpg");
        let id = photo(&store, &first, "a", None)?;
        let task = preview(&jobs, &store, "lib")?;
        store.patch_asset("lib", &id, &json!({"flagState":"picked"}))?;
        photo(&store, &jobs.root().join("b.jpg"), "b", None)?;
        assert!(submit(&jobs, &store, "lib", &task.id, 1).is_err());
        let task = preview(&jobs, &store, "lib")?;
        fs::write(jobs.root().join("b.jpg"), b"replacement file")?;
        assert!(submit(&jobs, &store, "lib", &task.id, 1).is_err());
        assert!(first.exists());
        Ok(())
    }
    #[test]
    fn newly_retained_photo_after_submission_prevents_any_recycling() -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let file = jobs.root().join("a.jpg");
        let id = photo(&store, &file, "a", None)?;
        let task = preview(&jobs, &store, "lib")?;
        submit(&jobs, &store, "lib", &task.id, 1)?;
        store.patch_asset("lib", &id, &json!({"flagState":"picked"}))?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || Ok(config),
            |_, _| panic!("must not recycle changed selection"),
        )?;
        assert_eq!(load(&jobs, "lib", &task.id)?.0.status, "failed");
        assert!(file.exists());
        Ok(())
    }
    #[test]
    fn disabled_recycle_and_shared_sidecars_are_rejected_before_file_operations() -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let file = jobs.root().join("a.jpg");
        photo(&store, &file, "a", None)?;
        let task = preview(&jobs, &store, "lib")?;
        submit(&jobs, &store, "lib", &task.id, 1)?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || Ok(config.replace("=yes", "=no")),
            |_, _| panic!("disabled recycle"),
        )?;
        assert_eq!(load(&jobs, "lib", &task.id)?.0.status, "failed");
        fs::write(file.with_extension("raw"), b"unindexed photo")?;
        fs::write(file.with_extension("xmp"), b"shared sidecar")?;
        assert!(preview(&jobs, &store, "lib").is_err());
        assert!(file.exists());
        Ok(())
    }
    #[test]
    fn interrupted_native_call_is_not_replayed_and_completed_file_resumes() -> Result<()> {
        for moved in [false, true] {
            let (tmp, jobs, store, config) = setup()?;
            let a = jobs.root().join("a.jpg");
            let b = jobs.root().join("b.jpg");
            photo(&store, &a, "a", None)?;
            photo(&store, &b, "b", None)?;
            let task = preview(&jobs, &store, "lib")?;
            submit(&jobs, &store, "lib", &task.id, 2)?;
            jobs.trash_db.lock().unwrap().execute("UPDATE rejected_trash_tasks SET status='running',phase='recycling',inflight=1 WHERE id=?",[&task.id])?;
            if moved {
                simulated_recycle(jobs.root(), &a)?;
            }
            drop(jobs);
            let jobs = Jobs::open(&tmp.path().join("jobs.sqlite"), &tmp.path().join("photos"))?;
            let mut calls = 0;
            process(
                &jobs,
                &store,
                "lib",
                &task.id,
                || Ok(config),
                |_, p| {
                    assert_eq!(p, b);
                    calls += 1;
                    simulated_recycle(jobs.root(), p)
                },
            )?;
            let done = load(&jobs, "lib", &task.id)?.0;
            assert_eq!(
                done.status,
                if moved { "completed" } else { "failed" },
                "{done:?}"
            );
            assert_eq!(calls, usize::from(moved));
        }
        Ok(())
    }
    #[test]
    fn partial_failure_reconciles_only_absent_paths_and_never_retries_failed_task() -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let a = jobs.root().join("a.jpg");
        let b = jobs.root().join("b.jpg");
        photo(&store, &a, "a", None)?;
        photo(&store, &b, "b", None)?;
        let task = preview(&jobs, &store, "lib")?;
        submit(&jobs, &store, "lib", &task.id, 2)?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || Ok(config),
            |_, p| {
                if p == b {
                    anyhow::bail!("native failure")
                };
                simulated_recycle(jobs.root(), p)
            },
        )?;
        let done = load(&jobs, "lib", &task.id)?.0;
        assert_eq!(done.status, "failed");
        assert_eq!(done.completed_files, 1);
        assert!(b.exists());
        assert!(!a.exists());
        assert_eq!(store.counts("lib", true)?["all"], 1);
        assert_eq!(submit(&jobs, &store, "lib", &task.id, 2)?.status, "failed");
        Ok(())
    }
    #[test]
    fn empty_library_cannot_be_submitted_and_foreign_tracking_is_rejected() -> Result<()> {
        let (_tmp, jobs, store, _) = setup()?;
        let task = preview(&jobs, &store, "lib")?;
        assert_eq!(task.count, 0);
        assert!(submit(&jobs, &store, "lib", &task.id, 0).is_err());
        let file = jobs.root().join("other/a.jpg");
        photo(&store, &file, "a", None)?;
        jobs.add_folder("other", file.parent().unwrap().to_str().unwrap())?;
        assert!(preview(&jobs, &store, "lib").is_err());
        Ok(())
    }
    #[test]
    fn resumed_task_preserves_sidecar_shared_with_new_retained_photo() -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let file = jobs.root().join("a.jpg");
        photo(&store, &file, "a", None)?;
        fs::write(file.with_extension("xmp"), b"shared")?;
        let task = preview(&jobs, &store, "lib")?;
        submit(&jobs, &store, "lib", &task.id, 1)?;
        simulated_recycle(jobs.root(), &file)?;
        jobs.trash_db.lock().unwrap().execute("UPDATE rejected_trash_tasks SET status='running',phase='recycling',inflight=0,completed_files=1 WHERE id=?",[&task.id])?;
        fs::write(file.with_extension("raw"), b"new retained photo")?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || Ok(config),
            |_, _| panic!("shared sidecar must remain"),
        )?;
        assert_eq!(load(&jobs, "lib", &task.id)?.0.status, "failed");
        assert!(file.with_extension("xmp").exists());
        Ok(())
    }
    #[test]
    fn reconciliation_failure_resumes_without_replaying_native_recycle() -> Result<()> {
        let (_tmp, jobs, store, config) = setup()?;
        let file = jobs.root().join("a.jpg");
        photo(&store, &file, "a", None)?;
        let task = preview(&jobs, &store, "lib")?;
        submit(&jobs, &store, "lib", &task.id, 1)?;
        store.lock()?.execute_batch("CREATE TRIGGER fail_reconcile BEFORE DELETE ON catalog_paths BEGIN SELECT RAISE(ABORT,'simulate reconcile failure'); END")?;
        assert!(
            process(
                &jobs,
                &store,
                "lib",
                &task.id,
                || Ok(config),
                |_, p| simulated_recycle(jobs.root(), p)
            )
            .is_err()
        );
        assert_eq!(load(&jobs, "lib", &task.id)?.0.phase, "reconciling");
        assert!(!file.exists());
        store.lock()?.execute_batch("DROP TRIGGER fail_reconcile")?;
        process(
            &jobs,
            &store,
            "lib",
            &task.id,
            || panic!("no config needed"),
            |_, _| panic!("never replay"),
        )?;
        assert_eq!(load(&jobs, "lib", &task.id)?.0.status, "completed");
        assert_eq!(store.counts("lib", true)?["all"], 0);
        Ok(())
    }
}
