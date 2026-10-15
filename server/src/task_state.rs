//! One-shot task transitions; persistence belongs to the caller's SQLite transaction.
use anyhow::{Result, bail};
use statig::prelude::*;

pub(crate) struct TaskState;

#[derive(Debug)]
pub(crate) enum Event {
    Start,
    Yield,
    Complete,
    Fail,
    Interrupt,
    Retry,
}

#[state_machine(initial = "State::pending()")]
impl TaskState {
    #[state]
    fn pending(event: &Event) -> Outcome<State> {
        match event {
            Event::Start => Transition(State::running()),
            Event::Interrupt => Transition(State::failed()),
            _ => Handled,
        }
    }

    #[state]
    fn running(event: &Event) -> Outcome<State> {
        match event {
            Event::Yield => Transition(State::pending()),
            Event::Complete => Transition(State::completed()),
            Event::Fail | Event::Interrupt => Transition(State::failed()),
            _ => Handled,
        }
    }

    #[state]
    fn completed() -> Outcome<State> {
        Handled
    }

    #[state]
    fn failed(event: &Event) -> Outcome<State> {
        match event {
            Event::Retry => Transition(State::pending()),
            _ => Handled,
        }
    }
}

pub(crate) fn transition(status: &str, event: Event) -> Result<&'static str> {
    let mut machine = TaskState.uninitialized_state_machine();
    *machine.state_mut() = match status {
        "pending" => State::pending(),
        "running" => State::running(),
        "completed" => State::completed(),
        "failed" => State::failed(),
        _ => bail!("unknown task state: {status}"),
    };
    let mut machine = machine.init();
    machine.handle(&event);
    let next = match machine.state() {
        State::Pending {} => "pending",
        State::Running {} => "running",
        State::Completed {} => "completed",
        State::Failed {} => "failed",
    };
    if next == status {
        bail!("invalid task transition: {status} / {event:?}");
    }
    Ok(next)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failure_requires_explicit_retry() {
        assert_eq!(transition("running", Event::Fail).unwrap(), "failed");
        assert!(transition("failed", Event::Start).is_err());
        assert!(transition("failed", Event::Complete).is_err());
        assert_eq!(transition("failed", Event::Retry).unwrap(), "pending");
    }

    #[test]
    fn interruption_stops_queued_and_running_tasks() {
        for status in ["pending", "running"] {
            assert_eq!(transition(status, Event::Interrupt).unwrap(), "failed");
        }
    }
}
