//! Long jobs run on dedicated threads so their scheduling policy cannot leak
//! into Tokio's reusable HTTP blocking threads.
use anyhow::{Context, Result};
use tokio::sync::oneshot;

pub fn spawn<T: Send + 'static>(
    name: &str,
    operation: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<oneshot::Receiver<Result<T>>> {
    let (sender, receiver) = oneshot::channel();
    std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            let result = lower_priority().and_then(|()| operation());
            if let Err(error) = &result {
                tracing::error!(error=?error, "background task failed");
            }
            let _ = sender.send(result);
        })
        .context("start background thread")?;
    Ok(receiver)
}

fn lower_priority() -> Result<()> {
    #[cfg(target_os = "linux")]
    {
        // Linux applies these calls to the calling thread; children inherit them.
        let result = unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, 10) };
        if result != 0 {
            return Err(std::io::Error::last_os_error()).context("set background CPU priority");
        }
        let result = unsafe { libc::syscall(libc::SYS_ioprio_set, 1, 0, (2 << 13) | 7) };
        if result != 0 {
            return Err(std::io::Error::last_os_error()).context("set background I/O priority");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn background_thread_is_separate_and_returns_errors() -> Result<()> {
        let calling = std::thread::current().id();
        let background = spawn("test-background", || Ok(std::thread::current().id()))?.await??;
        assert_ne!(calling, background);
        let error = spawn("test-background-error", || -> Result<()> {
            anyhow::bail!("test failure")
        })?
        .await?
        .unwrap_err();
        assert_eq!(error.to_string(), "test failure");
        Ok(())
    }
}
