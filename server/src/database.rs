//! Short interactive transactions take the next turn before queued background work.
use anyhow::{Result, anyhow};
use rusqlite::Connection;
use std::{
    cell::Cell,
    ops::{Deref, DerefMut},
    sync::{Condvar, Mutex, MutexGuard},
};

thread_local! { static INTERACTIVE: Cell<bool> = const { Cell::new(false) }; }

pub(crate) fn interactive<T>(operation: impl FnOnce() -> T) -> T {
    struct Reset(bool);
    impl Drop for Reset {
        fn drop(&mut self) {
            INTERACTIVE.set(self.0);
        }
    }
    let _reset = Reset(INTERACTIVE.replace(true));
    operation()
}

#[derive(Default)]
struct Queue {
    occupied: bool,
    interactive: usize,
}

pub(crate) struct Database {
    connection: Mutex<Connection>,
    queue: Mutex<Queue>,
    available: Condvar,
}
impl Database {
    pub(crate) fn new(connection: Connection) -> Self {
        Self {
            connection: Mutex::new(connection),
            queue: Mutex::new(Queue::default()),
            available: Condvar::new(),
        }
    }
    pub(crate) fn lock(&self) -> Result<Guard<'_>> {
        let interactive = INTERACTIVE.get();
        let mut queue = self
            .queue
            .lock()
            .map_err(|_| anyhow!("database queue poisoned"))?;
        if interactive {
            queue.interactive += 1;
        }
        while queue.occupied || (!interactive && queue.interactive > 0) {
            queue = self
                .available
                .wait(queue)
                .map_err(|_| anyhow!("database queue poisoned"))?;
        }
        if interactive {
            queue.interactive -= 1;
        }
        let connection = self.connection.lock().map_err(|_| {
            self.available.notify_all();
            anyhow!("database mutex poisoned")
        })?;
        queue.occupied = true;
        Ok(Guard {
            database: self,
            connection: Some(connection),
        })
    }
}
pub(crate) struct Guard<'a> {
    database: &'a Database,
    connection: Option<MutexGuard<'a, Connection>>,
}
impl Deref for Guard<'_> {
    type Target = Connection;
    fn deref(&self) -> &Connection {
        self.connection.as_ref().unwrap()
    }
}
impl DerefMut for Guard<'_> {
    fn deref_mut(&mut self) -> &mut Connection {
        self.connection.as_mut().unwrap()
    }
}
impl Drop for Guard<'_> {
    fn drop(&mut self) {
        drop(self.connection.take());
        let mut queue = self.database.queue.lock().unwrap();
        queue.occupied = false;
        self.database.available.notify_all();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::{Arc, mpsc},
        time::{Duration, Instant},
    };
    #[test]
    fn interactive_transaction_precedes_waiting_background_work() -> Result<()> {
        let db = Arc::new(Database::new(Connection::open_in_memory()?));
        let held = db.lock()?;
        let (sent, received) = mpsc::channel();
        let background = {
            let db = db.clone();
            let sent = sent.clone();
            std::thread::spawn(move || {
                let _guard = db.lock().unwrap();
                sent.send("background").unwrap();
            })
        };
        let foreground = {
            let db = db.clone();
            std::thread::spawn(move || {
                interactive(|| {
                    let _guard = db.lock().unwrap();
                    sent.send("interactive").unwrap();
                })
            })
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        while db.queue.lock().unwrap().interactive == 0 {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        drop(held);
        assert_eq!(
            received.recv_timeout(Duration::from_secs(5))?,
            "interactive"
        );
        assert_eq!(received.recv_timeout(Duration::from_secs(5))?, "background");
        foreground.join().unwrap();
        background.join().unwrap();
        assert!(!INTERACTIVE.get());
        Ok(())
    }
}
