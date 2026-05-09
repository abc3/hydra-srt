use std::io::{self, Write};

use anyhow::{Context, Result};

pub trait StatsWriter: Send {
    fn send_message(&mut self, message: &str) -> Result<()>;
}

#[derive(Debug)]
pub struct StdoutWriter {
    stdout: io::Stdout,
}

impl StdoutWriter {
    pub fn new() -> Self {
        Self {
            stdout: io::stdout(),
        }
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
