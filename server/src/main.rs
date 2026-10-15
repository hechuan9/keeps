use anyhow::{Context, Result, bail};
use keeps_server::{
    api::{AppState, router},
    jobs::Jobs,
    media::MediaProcessor,
    previews::PreviewStorage,
    store::Store,
};
use std::{
    env,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "keeps_server=info,tower_http=info".into()),
        )
        .init();
    let root = PathBuf::from(env::var("KEEPS_ROOT").context("KEEPS_ROOT is required")?);
    let migrate = match env::args().nth(1).as_deref() {
        None => false,
        Some("migrate") => true,
        Some(other) => bail!("unknown command {other}; use keeps-server [migrate]"),
    };
    let database = root.join("db/control_plane.sqlite");
    if migrate {
        Store::open(&database, true)?;
        tracing::info!("database migration complete");
        return Ok(());
    }
    let original = PathBuf::from(env::var("ORIGINAL_ROOT").context("ORIGINAL_ROOT is required")?);
    let access_token = env::var("KEEPS_ACCESS_TOKEN").context("KEEPS_ACCESS_TOKEN is required")?;
    if access_token.len() < 32 {
        bail!("KEEPS_ACCESS_TOKEN must be at least 32 bytes");
    }
    let base_url = env::var("CONTROL_PLANE_PUBLIC_BASE_URL")
        .context("CONTROL_PLANE_PUBLIC_BASE_URL is required")?;
    let previews = Arc::new(PreviewStorage::new(
        &root,
        Some(&original),
        &base_url,
        &access_token,
    )?);
    let auto_create = match env::var("CONTROL_PLANE_AUTO_CREATE_SCHEMA").as_deref() {
        Ok("1") => true,
        Ok("0") | Err(_) => false,
        Ok(_) => bail!("CONTROL_PLANE_AUTO_CREATE_SCHEMA must be 0 or 1"),
    };
    let store = Arc::new(Store::open(&database, auto_create)?);
    let jobs = Arc::new(Jobs::open(&root.join("db/jobs.sqlite"), &original)?);
    let cancelled = jobs.cancel_automatic_scans()?;
    if cancelled > 0 {
        tracing::info!(
            cancelled,
            "cancelled automatic scans; scans require an explicit request"
        );
    }
    keeps_server::directory_move::recover(&jobs, &store)?;
    keeps_server::directory_move::interrupt_pending(&jobs)?;
    keeps_server::imports::interrupt_pending(&jobs)?;
    keeps_server::video_trim::interrupt_pending(&jobs)?;
    keeps_server::directory_trash::interrupt_pending(&jobs, &store)?;
    keeps_server::rejected_trash::interrupt_pending(&jobs, &store)?;
    keeps_server::tasks::recover(&jobs)?;
    store.recover_cache()?;
    keeps_server::worker::maintain_revisions(&store, &jobs)?;
    let original_root_names = keeps_server::navigation::parse_root_names(
        jobs.root(),
        env::var("KEEPS_ORIGINAL_ROOT_SOURCES").ok().as_deref(),
    )?;
    let library_id = env::var("KEEPS_LIBRARY_ID").unwrap_or_else(|_| "local-library".into());
    if let Ok(library) = env::var("KEEPS_LIBRARY_ID") {
        if library.trim().is_empty() {
            bail!("KEEPS_LIBRARY_ID cannot be empty");
        }
        if jobs.folders()?.iter().all(|f| f.library_id != library) {
            jobs.add_folder(&library, ".")?;
        }
    }
    MediaProcessor::new().probe().context("NAS media runtime")?;
    let address = env::var("KEEPS_LISTEN_ADDR").unwrap_or_else(|_| "0.0.0.0:2283".into());
    let listener = tokio::net::TcpListener::bind(&address).await?;
    let stop = Arc::new(AtomicBool::new(false));
    let mut worker = keeps_server::background::spawn("worker", {
        let (store, jobs, previews, stop) =
            (store.clone(), jobs.clone(), previews.clone(), stop.clone());
        move || keeps_server::worker::run(store, jobs, previews, stop)
    })?;
    let mut directory_trash = keeps_server::background::spawn("directory_trash", {
        let (store, jobs, previews, stop) =
            (store.clone(), jobs.clone(), previews.clone(), stop.clone());
        move || keeps_server::directory_trash::run(jobs, store, previews, stop)
    })?;
    let mut directory_move = keeps_server::background::spawn("directory_move", {
        let (store, jobs, stop) = (store.clone(), jobs.clone(), stop.clone());
        move || keeps_server::directory_move::run(jobs, store, stop)
    })?;
    let mut imports = keeps_server::background::spawn("imports", {
        let (jobs, stop) = (jobs.clone(), stop.clone());
        move || keeps_server::imports::run(jobs, stop)
    })?;
    let mut video_trim = keeps_server::background::spawn("video_trim", {
        let (jobs, store, stop) = (jobs.clone(), store.clone(), stop.clone());
        move || keeps_server::video_trim::run(jobs, store, stop)
    })?;
    tracing::info!(%address, "Keeps Rust server started");
    let http = axum::serve(
        listener,
        router(Arc::new(AppState {
            store,
            previews,
            jobs: jobs.clone(),
            access_token,
            library_id,
            original_root_names,
        })),
    )
    .with_graceful_shutdown({
        let stop = stop.clone();
        let jobs = jobs.clone();
        async move {
            shutdown().await;
            stop.store(true, Ordering::Relaxed);
            jobs.wake_scan_worker();
        }
    });
    tokio::select! {
        result=http=>{stop.store(true,Ordering::Relaxed);jobs.wake_scan_worker();result?;worker.await??;directory_trash.await??;directory_move.await??;imports.await??;video_trim.await??;}
        result=&mut worker=>{let stopping=stop.swap(true,Ordering::Relaxed);jobs.wake_scan_worker();result??;directory_trash.await??;directory_move.await??;imports.await??;video_trim.await??;if !stopping {bail!("NAS worker exited unexpectedly");}}
        result=&mut directory_trash=>{let stopping=stop.swap(true,Ordering::Relaxed);jobs.wake_scan_worker();result??;worker.await??;directory_move.await??;imports.await??;video_trim.await??;if !stopping {bail!("Directory recycling worker exited unexpectedly");}}
        result=&mut directory_move=>{let stopping=stop.swap(true,Ordering::Relaxed);jobs.wake_scan_worker();result??;worker.await??;directory_trash.await??;imports.await??;video_trim.await??;if !stopping {bail!("Directory move worker exited unexpectedly");}}
        result=&mut video_trim=>{let stopping=stop.swap(true,Ordering::Relaxed);jobs.wake_scan_worker();result??;worker.await??;directory_trash.await??;directory_move.await??;imports.await??;if !stopping {bail!("Video trim worker exited unexpectedly");}}
        result=&mut imports=>{let stopping=stop.swap(true,Ordering::Relaxed);jobs.wake_scan_worker();result??;worker.await??;directory_trash.await??;directory_move.await??;video_trim.await??;if !stopping {bail!("Import worker exited unexpectedly");}}
    }
    Ok(())
}
async fn shutdown() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("install SIGTERM handler");
        tokio::select! { _ = tokio::signal::ctrl_c() => {}, _ = terminate.recv() => {} }
    }
    #[cfg(not(unix))]
    tokio::signal::ctrl_c()
        .await
        .expect("install interrupt handler");
}
