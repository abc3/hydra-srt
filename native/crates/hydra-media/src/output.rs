use std::io::{self, Write};

use anyhow::{Context, Result};
use serde::Serialize;

pub trait StatsWriter: Send {
    fn send_message(&mut self, message: &str) -> Result<()>;
}

pub fn send_json_line(writer: &mut dyn StatsWriter, value: &impl Serialize) -> Result<()> {
    let line = serde_json::to_string(value).context("failed to serialize json line")?;
    writer.send_message(&line)
}

#[derive(Debug)]
pub struct StdoutWriter {
    stdout: io::Stdout,
}

impl Default for StdoutWriter {
    fn default() -> Self {
        Self::new()
    }
}

impl StdoutWriter {
    pub fn new() -> Self {
        Self {
            stdout: io::stdout(),
        }
    }
}

/// Swallows pipeline chatter so a command can own its stdout contract.
#[derive(Debug, Default)]
pub struct DiscardWriter;

impl StatsWriter for DiscardWriter {
    fn send_message(&mut self, _message: &str) -> Result<()> {
        Ok(())
    }
}

impl StatsWriter for StdoutWriter {
    fn send_message(&mut self, message: &str) -> Result<()> {
        self.stdout
            .write_all(message.as_bytes())
            .context("failed to write message to stdout")?;
        self.stdout
            .write_all(b"\n")
            .context("failed to write newline to stdout")?;
        self.stdout.flush().context("failed to flush stdout")?;
        Ok(())
    }
}
