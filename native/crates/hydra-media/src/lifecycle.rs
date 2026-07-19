use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Result};

use crate::output::StatsWriter;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PipelineStatus {
    Starting,
    Failed,
    Processing,
    Reconnecting,
    Stopped,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopReason {
    Shutdown,
    Eos,
    Failure,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailureReason {
    Startup,
    RuntimeError,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StatusPayload {
    Starting,
    Processing,
    Reconnecting,
    Failed(FailureReason),
    Stopped(StopReason),
}

impl StatusPayload {
    fn status(self) -> PipelineStatus {
        match self {
            Self::Starting => PipelineStatus::Starting,
            Self::Processing => PipelineStatus::Processing,
            Self::Reconnecting => PipelineStatus::Reconnecting,
            Self::Failed(_) => PipelineStatus::Failed,
            Self::Stopped(_) => PipelineStatus::Stopped,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Starting => r#"{"event":"pipeline_status","status":"starting"}"#,
            Self::Processing => r#"{"event":"pipeline_status","status":"processing"}"#,
            Self::Reconnecting => r#"{"event":"pipeline_status","status":"reconnecting"}"#,
            Self::Failed(FailureReason::Startup) => {
                r#"{"event":"pipeline_status","status":"failed","reason":"startup"}"#
            }
            Self::Failed(FailureReason::RuntimeError) => {
                r#"{"event":"pipeline_status","status":"failed","reason":"runtime_error"}"#
            }
            Self::Stopped(StopReason::Shutdown) => {
                r#"{"event":"pipeline_status","status":"stopped","reason":"shutdown"}"#
            }
            Self::Stopped(StopReason::Eos) => {
                r#"{"event":"pipeline_status","status":"stopped","reason":"eos"}"#
            }
            Self::Stopped(StopReason::Failure) => {
                r#"{"event":"pipeline_status","status":"stopped","reason":"failure"}"#
            }
        }
    }
}

#[derive(Debug, Default)]
struct LifecycleState {
    current: Option<PipelineStatus>,
}

#[derive(Clone)]
pub struct PipelineLifecycleEmitter {
    writer: Arc<Mutex<Box<dyn StatsWriter>>>,
    state: Arc<Mutex<LifecycleState>>,
}

impl std::fmt::Debug for PipelineLifecycleEmitter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PipelineLifecycleEmitter")
            .finish_non_exhaustive()
    }
}

impl PipelineLifecycleEmitter {
    pub fn new(writer: Arc<Mutex<Box<dyn StatsWriter>>>) -> Self {
        Self {
            writer,
            state: Arc::new(Mutex::new(LifecycleState::default())),
        }
    }

    pub fn emit_starting(&self) -> Result<bool> {
        self.emit_transition(StatusPayload::Starting)
    }

    pub fn emit_processing(&self) -> Result<bool> {
        self.emit_transition(StatusPayload::Processing)
    }

    pub fn emit_reconnecting(&self) -> Result<bool> {
        self.emit_transition(StatusPayload::Reconnecting)
    }

    pub fn emit_failed(&self, reason: FailureReason) -> Result<bool> {
        self.emit_transition(StatusPayload::Failed(reason))
    }

    pub fn emit_stopped(&self, reason: StopReason) -> Result<bool> {
        self.emit_transition(StatusPayload::Stopped(reason))
    }

    pub fn current_status(&self) -> Result<Option<PipelineStatus>> {
        Ok(self
            .state
            .lock()
            .map_err(|_| anyhow!("lifecycle state mutex poisoned"))?
            .current)
    }

    fn emit_transition(&self, next: StatusPayload) -> Result<bool> {
        let next_status = next.status();
        let payload = next.as_str();

        // Validate without mutating — write-then-commit keeps in-memory status
        // aligned with the wire on every failure path (including lock poison).
        {
            let state = self
                .state
                .lock()
                .map_err(|_| anyhow!("lifecycle state mutex poisoned"))?;

            if state.current == Some(next_status) {
                return Ok(false);
            }

            if !is_valid_transition(state.current, next_status) {
                return Ok(false);
            }
        }

        self.writer
            .lock()
            .map_err(|_| anyhow!("writer mutex poisoned"))?
            .send_message(payload)?;

        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow!("lifecycle state mutex poisoned"))?;

        if state.current == Some(next_status) {
            return Ok(false);
        }

        if !is_valid_transition(state.current, next_status) {
            // A concurrent transition won the race; keep memory consistent with
            // the winner rather than forcing a stale status.
            return Ok(false);
        }

        state.current = Some(next_status);
        Ok(true)
    }
}

fn is_valid_transition(current: Option<PipelineStatus>, next: PipelineStatus) -> bool {
    matches!(
        (current, next),
        (
            None,
            PipelineStatus::Starting
                | PipelineStatus::Processing
                | PipelineStatus::Failed
                | PipelineStatus::Stopped,
        ) | (
            Some(PipelineStatus::Starting),
            PipelineStatus::Processing | PipelineStatus::Failed | PipelineStatus::Stopped,
        ) | (
            Some(PipelineStatus::Processing),
            PipelineStatus::Reconnecting | PipelineStatus::Failed | PipelineStatus::Stopped,
        ) | (
            Some(PipelineStatus::Reconnecting),
            PipelineStatus::Processing | PipelineStatus::Failed | PipelineStatus::Stopped,
        ) | (Some(PipelineStatus::Failed), PipelineStatus::Stopped)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[derive(Debug, Default)]
    struct MemoryWriter {
        messages: Arc<Mutex<Vec<String>>>,
    }

    impl StatsWriter for MemoryWriter {
        fn send_message(&mut self, message: &str) -> Result<()> {
            self.messages
                .lock()
                .expect("messages lock")
                .push(message.to_string());
            Ok(())
        }
    }

    fn build_emitter() -> (PipelineLifecycleEmitter, Arc<Mutex<Vec<String>>>) {
        let messages = Arc::new(Mutex::new(Vec::new()));
        let writer: Arc<Mutex<Box<dyn StatsWriter>>> =
            Arc::new(Mutex::new(Box::new(MemoryWriter {
                messages: messages.clone(),
            })));

        (PipelineLifecycleEmitter::new(writer), messages)
    }

    #[test]
    fn status_payloads_are_byte_exact() {
        assert_eq!(
            StatusPayload::Starting.as_str(),
            r#"{"event":"pipeline_status","status":"starting"}"#
        );
        assert_eq!(
            StatusPayload::Processing.as_str(),
            r#"{"event":"pipeline_status","status":"processing"}"#
        );
        assert_eq!(
            StatusPayload::Reconnecting.as_str(),
            r#"{"event":"pipeline_status","status":"reconnecting"}"#
        );
        assert_eq!(
            StatusPayload::Failed(FailureReason::Startup).as_str(),
            r#"{"event":"pipeline_status","status":"failed","reason":"startup"}"#
        );
        assert_eq!(
            StatusPayload::Failed(FailureReason::RuntimeError).as_str(),
            r#"{"event":"pipeline_status","status":"failed","reason":"runtime_error"}"#
        );
        assert_eq!(
            StatusPayload::Stopped(StopReason::Shutdown).as_str(),
            r#"{"event":"pipeline_status","status":"stopped","reason":"shutdown"}"#
        );
        assert_eq!(
            StatusPayload::Stopped(StopReason::Eos).as_str(),
            r#"{"event":"pipeline_status","status":"stopped","reason":"eos"}"#
        );
        assert_eq!(
            StatusPayload::Stopped(StopReason::Failure).as_str(),
            r#"{"event":"pipeline_status","status":"stopped","reason":"failure"}"#
        );
    }

    #[test]
    fn emits_expected_status_sequence_without_duplicates() {
        let (emitter, messages) = build_emitter();

        assert!(emitter.emit_starting().expect("starting"));
        assert!(!emitter.emit_starting().expect("duplicate starting"));
        assert!(emitter.emit_processing().expect("processing"));
        assert!(!emitter.emit_processing().expect("duplicate processing"));
        assert!(emitter.emit_reconnecting().expect("reconnecting"));
        assert!(emitter
            .emit_processing()
            .expect("processing after reconnect"));
        assert!(emitter.emit_stopped(StopReason::Shutdown).expect("stopped"));

        let messages = messages.lock().expect("messages lock");
        assert_eq!(
            messages.as_slice(),
            [
                r#"{"event":"pipeline_status","status":"starting"}"#,
                r#"{"event":"pipeline_status","status":"processing"}"#,
                r#"{"event":"pipeline_status","status":"reconnecting"}"#,
                r#"{"event":"pipeline_status","status":"processing"}"#,
                r#"{"event":"pipeline_status","status":"stopped","reason":"shutdown"}"#,
            ]
        );
    }

    #[test]
    fn ignores_illegal_state_jumps() {
        let (emitter, messages) = build_emitter();

        assert!(emitter.emit_starting().expect("starting"));
        assert!(!emitter
            .emit_reconnecting()
            .expect("reconnecting before processing"));
        assert!(emitter
            .emit_failed(FailureReason::RuntimeError)
            .expect("failed"));
        assert!(!emitter.emit_processing().expect("processing after failed"));
        assert!(emitter.emit_stopped(StopReason::Failure).expect("stopped"));
        assert!(!emitter.emit_starting().expect("starting after stopped"));

        let messages = messages.lock().expect("messages lock");
        assert_eq!(
            messages.as_slice(),
            [
                r#"{"event":"pipeline_status","status":"starting"}"#,
                r#"{"event":"pipeline_status","status":"failed","reason":"runtime_error"}"#,
                r#"{"event":"pipeline_status","status":"stopped","reason":"failure"}"#,
            ]
        );
    }

    #[test]
    fn allows_failure_before_startup_completes() {
        let (emitter, messages) = build_emitter();

        assert!(emitter
            .emit_failed(FailureReason::Startup)
            .expect("startup failure"));
        assert!(emitter.emit_stopped(StopReason::Failure).expect("stopped"));

        let messages = messages.lock().expect("messages lock");
        assert_eq!(
            messages.as_slice(),
            [
                r#"{"event":"pipeline_status","status":"failed","reason":"startup"}"#,
                r#"{"event":"pipeline_status","status":"stopped","reason":"failure"}"#,
            ]
        );
    }

    #[test]
    fn allows_processing_as_startup_fallback() {
        let (emitter, messages) = build_emitter();

        assert!(emitter
            .emit_processing()
            .expect("processing before starting"));
        assert!(!emitter.emit_processing().expect("duplicate processing"));

        let messages = messages.lock().expect("messages lock");
        assert_eq!(
            messages.as_slice(),
            [r#"{"event":"pipeline_status","status":"processing"}"#,]
        );
    }

    #[test]
    fn only_emits_processing_when_rearmed() {
        let (emitter, messages) = build_emitter();

        assert!(emitter.emit_starting().expect("starting"));
        assert!(emitter.emit_processing().expect("processing"));
        assert!(!emitter
            .emit_processing()
            .expect("duplicate processing suppressed"));

        assert!(emitter.emit_reconnecting().expect("reconnecting"));
        assert!(emitter
            .emit_processing()
            .expect("processing after reconnect — rearmed"));
        assert!(!emitter
            .emit_processing()
            .expect("duplicate processing suppressed again"));

        let messages = messages.lock().expect("messages lock");
        assert_eq!(
            messages.as_slice(),
            [
                r#"{"event":"pipeline_status","status":"starting"}"#,
                r#"{"event":"pipeline_status","status":"processing"}"#,
                r#"{"event":"pipeline_status","status":"reconnecting"}"#,
                r#"{"event":"pipeline_status","status":"processing"}"#,
            ]
        );
    }
}
