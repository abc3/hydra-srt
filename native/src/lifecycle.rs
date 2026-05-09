use std::sync::atomic::{AtomicU8, Ordering};
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

impl StopReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::Shutdown => "shutdown",
            Self::Eos => "eos",
            Self::Failure => "failure",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FailureReason {
    Startup,
    RuntimeError,
}

impl FailureReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::Startup => "startup",
            Self::RuntimeError => "runtime_error",
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
    current: Arc<AtomicU8>,
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
            current: Arc::new(AtomicU8::new(0)),
        }
    }

    pub fn emit_starting(&self) -> Result<bool> {
        self.emit_transition(PipelineStatus::Starting, None)
    }

    pub fn emit_processing(&self) -> Result<bool> {
        if self.current.load(Ordering::Relaxed) == encode_status(Some(PipelineStatus::Processing)) {
            return Ok(false);
        }

        self.emit_transition(PipelineStatus::Processing, None)
    }

    pub fn emit_reconnecting(&self) -> Result<bool> {
        self.emit_transition(PipelineStatus::Reconnecting, None)
    }

    pub fn emit_failed(&self, reason: FailureReason) -> Result<bool> {
        self.emit_transition(PipelineStatus::Failed, Some(reason.as_str()))
    }

    pub fn emit_stopped(&self, reason: StopReason) -> Result<bool> {
        self.emit_transition(PipelineStatus::Stopped, Some(reason.as_str()))
    }

    pub fn current_status(&self) -> Result<Option<PipelineStatus>> {
        Ok(decode_status(self.current.load(Ordering::Relaxed)))
    }

    fn emit_transition(&self, next: PipelineStatus, reason: Option<&str>) -> Result<bool> {
        let payload = status_payload(next, reason);

        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow!("lifecycle state mutex poisoned"))?;

        if state.current == Some(next) {
            return Ok(false);
        }

        if !is_valid_transition(state.current, next) {
            return Ok(false);
        }

        self.writer
            .lock()
            .map_err(|_| anyhow!("writer mutex poisoned"))?
            .send_message(&payload)?;

        state.current = Some(next);
        self.current
            .store(encode_status(Some(next)), Ordering::Relaxed);
        Ok(true)
    }
}

fn status_payload(status: PipelineStatus, reason: Option<&str>) -> &'static str {
    match (status, reason) {
        (PipelineStatus::Starting, None) => r#"{"event":"pipeline_status","status":"starting"}"#,
        (PipelineStatus::Processing, None) => {
            r#"{"event":"pipeline_status","status":"processing"}"#
        }
        (PipelineStatus::Reconnecting, None) => {
            r#"{"event":"pipeline_status","status":"reconnecting"}"#
        }
        (PipelineStatus::Failed, Some("startup")) => {
            r#"{"event":"pipeline_status","status":"failed","reason":"startup"}"#
        }
        (PipelineStatus::Failed, Some("runtime_error")) => {
            r#"{"event":"pipeline_status","status":"failed","reason":"runtime_error"}"#
        }
        (PipelineStatus::Stopped, Some("shutdown")) => {
            r#"{"event":"pipeline_status","status":"stopped","reason":"shutdown"}"#
        }
        (PipelineStatus::Stopped, Some("eos")) => {
            r#"{"event":"pipeline_status","status":"stopped","reason":"eos"}"#
        }
        (PipelineStatus::Stopped, Some("failure")) => {
            r#"{"event":"pipeline_status","status":"stopped","reason":"failure"}"#
        }
        _ => unreachable!("unsupported lifecycle payload"),
    }
}

fn is_valid_transition(current: Option<PipelineStatus>, next: PipelineStatus) -> bool {
    match (current, next) {
        (
            None,
            PipelineStatus::Starting
            | PipelineStatus::Processing
            | PipelineStatus::Failed
            | PipelineStatus::Stopped,
        ) => true,
        (
            Some(PipelineStatus::Starting),
            PipelineStatus::Processing | PipelineStatus::Failed | PipelineStatus::Stopped,
        ) => true,
        (
            Some(PipelineStatus::Processing),
            PipelineStatus::Reconnecting | PipelineStatus::Failed | PipelineStatus::Stopped,
        ) => true,
        (
            Some(PipelineStatus::Reconnecting),
            PipelineStatus::Processing | PipelineStatus::Failed | PipelineStatus::Stopped,
        ) => true,
        (Some(PipelineStatus::Failed), PipelineStatus::Stopped) => true,
        _ => false,
    }
}

fn encode_status(status: Option<PipelineStatus>) -> u8 {
    match status {
        None => 0,
        Some(PipelineStatus::Starting) => 1,
        Some(PipelineStatus::Failed) => 2,
        Some(PipelineStatus::Processing) => 3,
        Some(PipelineStatus::Reconnecting) => 4,
        Some(PipelineStatus::Stopped) => 5,
    }
}

fn decode_status(raw: u8) -> Option<PipelineStatus> {
    match raw {
        1 => Some(PipelineStatus::Starting),
        2 => Some(PipelineStatus::Failed),
        3 => Some(PipelineStatus::Processing),
        4 => Some(PipelineStatus::Reconnecting),
        5 => Some(PipelineStatus::Stopped),
        _ => None,
    }
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

        assert!(emitter.emit_processing().expect("processing before starting"));
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
        assert!(!emitter.emit_processing().expect("duplicate processing suppressed by fast path"));

        assert!(emitter.emit_reconnecting().expect("reconnecting"));
        assert!(emitter.emit_processing().expect("processing after reconnect — rearmed"));
        assert!(!emitter.emit_processing().expect("duplicate processing suppressed again"));

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
