//! Bounded pipe readers shared by every harness.
//!
//! Every read here is capped: a harness that prints an endless line or a
//! flood of diagnostics costs Orb a fixed amount of memory, never more.

use super::*;
use std::io::{BufRead, BufReader, Read, Write};
use std::ops::ControlFlow;
use std::thread::JoinHandle;

/// A protocol line longer than this is cut; the rest of it is discarded.
pub(crate) const MAX_STDOUT_LINE: usize = 32 * 1024 * 1024;
/// A diagnostic line longer than this is cut.
pub(crate) const MAX_STDERR_LINE: usize = 64 * 1024;
/// How much of stderr is kept when only its start is reported.
pub(crate) const STDERR_PREFIX: usize = 16 * 1024;

/// Read one line into `line` (without its terminator), keeping at most `max`
/// bytes of it. Returns the bytes consumed from the reader; 0 at end of input.
pub(crate) fn read_bounded_line(
    reader: &mut impl BufRead,
    line: &mut Vec<u8>,
    max: usize,
) -> std::io::Result<usize> {
    line.clear();
    let mut consumed = 0;
    loop {
        let available = match reader.fill_buf() {
            Ok(available) => available,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        if available.is_empty() {
            break;
        }
        let (chunk, found) = match available.iter().position(|byte| *byte == b'\n') {
            Some(at) => (&available[..at], true),
            None => (available, false),
        };
        let room = max.saturating_sub(line.len());
        line.extend_from_slice(&chunk[..chunk.len().min(room)]);
        let used = chunk.len() + usize::from(found);
        reader.consume(used);
        consumed += used;
        if found {
            break;
        }
    }
    if line.last() == Some(&b'\r') {
        line.pop();
    }
    Ok(consumed)
}

/// What a stdout reader does with each protocol line of a harness.
pub(crate) trait LineHandler: Send + 'static {
    /// Runs on the reader thread before the first line (initial writes).
    fn start(&mut self) -> Result<(), String> {
        Ok(())
    }
    /// One line; `Break` stops reading, `Err` ends the turn with that error.
    fn line(&mut self, line: &str) -> Result<ControlFlow<()>, String>;
    /// Called once, after the last line, with how reading ended.
    fn end(self, read: Result<(), String>);
}

/// Read `stdout` line by line on a thread that holds the output's reader
/// guard until `end` has run, so a drained output means a settled turn.
pub(crate) fn spawn_line_reader(
    stdout: impl Read + Send + 'static,
    output: &Arc<Output>,
    mut handler: impl LineHandler,
) -> JoinHandle<()> {
    let guard = output.reader();
    thread::spawn(move || {
        let _guard = guard;
        let mut reader = BufReader::new(stdout);
        let mut buffer = Vec::new();
        let result = handler.start().and_then(|()| loop {
            match read_bounded_line(&mut reader, &mut buffer, MAX_STDOUT_LINE) {
                Ok(0) => break Ok(()),
                Ok(_) => match handler.line(&String::from_utf8_lossy(&buffer)) {
                    Ok(ControlFlow::Continue(())) => {}
                    Ok(ControlFlow::Break(())) => break Ok(()),
                    Err(error) => break Err(error),
                },
                Err(error) => break Err(error.to_string()),
            }
        });
        handler.end(result);
    })
}

/// How a harness's stderr is consumed. It is never published as a reply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StderrPolicy {
    /// Keep only the last structured Antigravity error marker; drop OAuth
    /// URLs and unstructured account diagnostics.
    AntigravityMarker,
    /// Keep a bounded prefix as the run's diagnostic, used only when the
    /// process actually fails.
    ClaudeDiagnostic,
    /// The start of stderr becomes the run's error unless one is set.
    ErrorHead,
    /// Each line goes to Orb's log; app-server shutdown warns after success.
    CodexLog,
}

/// Drain `stderr` completely on a thread, applying `policy`. The handle
/// yields the Antigravity marker, if that policy found one.
pub(crate) fn drain_stderr(
    stderr: impl Read + Send + 'static,
    ctx: &RunCtx,
    policy: StderrPolicy,
) -> JoinHandle<Option<crate::antigravity::ErrorMarker>> {
    // Codex's log can stay open in its children after a turn; it must not
    // hold the output open.
    let guard = (policy != StderrPolicy::CodexLog).then(|| ctx.output.reader());
    let ctx = ctx.clone();
    thread::spawn(move || {
        let _guard = guard;
        let mut reader = BufReader::new(stderr);
        match policy {
            StderrPolicy::AntigravityMarker => {
                let mut marker = None;
                each_line(&mut reader, |line| {
                    if let Some(parsed) = crate::antigravity::ErrorMarker::parse(line) {
                        marker = Some(parsed);
                    }
                });
                marker
            }
            StderrPolicy::CodexLog => {
                each_line(&mut reader, |line| {
                    eprintln!("Codex diagnostic: {}", strip_terminal_codes(line));
                });
                None
            }
            StderrPolicy::ClaudeDiagnostic => {
                let clean = read_prefix(&mut reader);
                if !clean.trim().is_empty() {
                    ctx.output
                        .set_diagnostic(clean.trim().chars().take(1000).collect());
                }
                None
            }
            StderrPolicy::ErrorHead => {
                let clean = read_prefix(&mut reader);
                let trimmed = clean.trim();
                if !trimmed.is_empty() {
                    ctx.error.set_if_none(trimmed.chars().take(500).collect());
                }
                None
            }
        }
    })
}

pub(crate) fn each_line(reader: &mut impl BufRead, mut visit: impl FnMut(&str)) {
    let mut buffer = Vec::new();
    while let Ok(n) = read_bounded_line(reader, &mut buffer, MAX_STDERR_LINE) {
        if n == 0 {
            break;
        }
        visit(&String::from_utf8_lossy(&buffer));
    }
}

/// The first `STDERR_PREFIX` bytes without terminal styling; the rest is
/// drained so the harness never blocks on a full pipe.
pub(crate) fn read_prefix(reader: &mut impl Read) -> String {
    let mut prefix = Vec::new();
    let _ = reader
        .by_ref()
        .take(STDERR_PREFIX as u64)
        .read_to_end(&mut prefix);
    let _ = std::io::copy(reader, &mut std::io::sink());
    strip_terminal_codes(&String::from_utf8_lossy(&prefix))
}

/// The native session a protocol event announces, by harness convention.
/// The first rule that matches wins.
pub(crate) fn session_id_from_event(event: &Value) -> Option<&str> {
    SESSION_RULES.iter().find_map(|(_, rule)| rule(event))
}

pub(crate) type SessionRule = fn(&Value) -> Option<&str>;

/// One row per convention: (who uses it, how to read it).
pub(crate) const SESSION_RULES: &[(&str, SessionRule)] = &[
    ("OpenCode `sessionID` (ses_*)", opencode_session),
    ("`init` event `session_id`", init_session),
    ("UUID `sessionId`", uuid_session),
];

pub(crate) fn opencode_session(event: &Value) -> Option<&str> {
    event
        .get("sessionID")
        .and_then(Value::as_str)
        .filter(|id| id.starts_with("ses_"))
}

pub(crate) fn init_session(event: &Value) -> Option<&str> {
    (event["type"] == "init")
        .then(|| event["session_id"].as_str())
        .flatten()
        .filter(|id| !id.is_empty())
}

pub(crate) fn uuid_session(event: &Value) -> Option<&str> {
    event["sessionId"]
        .as_str()
        .filter(|id| uuid::Uuid::parse_str(id).is_ok())
}

pub(crate) fn stream_plain(reader: &mut impl Read, output: &Output) {
    let mut pending = Vec::new();
    let mut bytes = [0u8; 4096];
    while let Ok(n) = reader.read(&mut bytes) {
        if n == 0 {
            break;
        }
        pending.extend_from_slice(&bytes[..n]);
        loop {
            match std::str::from_utf8(&pending) {
                Ok(text) => {
                    output.append(text);
                    pending.clear();
                    break;
                }
                Err(error) => {
                    let valid = error.valid_up_to();
                    output.append(std::str::from_utf8(&pending[..valid]).unwrap());
                    pending.drain(..valid);
                    if let Some(invalid) = error.error_len() {
                        output.append("�");
                        pending.drain(..invalid);
                    } else {
                        break;
                    }
                }
            }
        }
    }
    output.append(&String::from_utf8_lossy(&pending));
}

// Terminal styling is not meaningful inside a desktop error card.
pub(crate) fn strip_terminal_codes(text: &str) -> String {
    let mut result = String::new();
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            for code in chars.by_ref() {
                if ('@'..='~').contains(&code) {
                    break;
                }
            }
        } else {
            result.push(ch);
        }
    }
    result
}

// Consume only protocol events representing new assistant output. Recursive
// text extraction also captures user items, tool arguments and final snapshots.
pub(crate) fn extract_text(line: &str) -> Option<String> {
    let value: Value = serde_json::from_str(line).ok()?;
    let text = if let Some(method) = value["method"].as_str() {
        match method {
            "item/agentMessage/delta" => value.pointer("/params/delta")?.as_str(),
            _ => None,
        }
    } else {
        match value["type"].as_str()? {
            "stream_event" if value.pointer("/event/delta/type")?.as_str()? == "text_delta" => {
                value.pointer("/event/delta/text")?.as_str()
            }
            "text" => value
                .pointer("/part/text")
                .or_else(|| value.get("data"))?
                .as_str(), // OpenCode or Grok
            _ => None,
        }
    }?;
    (!text.is_empty()).then(|| text.to_owned())
}

pub(crate) fn write_line(stdin: &mut impl Write, line: &str) -> Result<(), String> {
    stdin
        .write_all(line.as_bytes())
        .map_err(|e| e.to_string())?;
    stdin.write_all(b"\n").map_err(|e| e.to_string())?;
    stdin.flush().map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_stream_does_not_wait_for_newlines_and_preserves_utf8() {
        struct Bytes<'a> {
            bytes: &'a [u8],
            output: &'a Output,
            index: usize,
        }
        impl Read for Bytes<'_> {
            fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
                if self.index == 1 {
                    assert_eq!(self.output.snapshot(), "A");
                }
                if self.index == self.bytes.len() {
                    return Ok(0);
                }
                buf[0] = self.bytes[self.index];
                self.index += 1;
                Ok(1)
            }
        }
        let output = Output::default();
        stream_plain(
            &mut Bytes {
                bytes: "Aé🙂".as_bytes(),
                output: &output,
                index: 0,
            },
            &output,
        );
        assert_eq!(output.snapshot(), "Aé🙂");
    }

    #[test]
    fn errors_do_not_include_terminal_color_sequences() {
        assert_eq!(
            strip_terminal_codes("\u{1b}[91m\u{1b}[1mError: \u{1b}[0mFailed query"),
            "Error: Failed query"
        );
    }

    #[test]
    fn output_excludes_user_echoes_snapshots_and_tools() {
        let events = [
            json!({"method":"item/started","params":{"item":{"type":"userMessage","content":[{"type":"text","text":"PROMPT"}]}}}),
            json!({"method":"item/completed","params":{"item":{"type":"userMessage","content":[{"type":"text","text":"PROMPT"}]}}}),
            json!({"method":"item/agentMessage/delta","params":{"delta":"Hello"}}),
            json!({"method":"item/completed","params":{"item":{"type":"agentMessage","text":"Hello"}}}),
            json!({"method":"item/commandExecution/outputDelta","params":{"delta":"TOOL"}}),
            json!({"type":"user","message":{"content":[{"type":"text","text":"PROMPT"}]}}),
            json!({"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}),
        ];
        let text: String = events
            .iter()
            .filter_map(|e| extract_text(&e.to_string()))
            .collect();
        assert_eq!(text, "Hello");
        assert_eq!(
            extract_text(r#"{"type":"text","part":{"text":"OpenCode"}}"#).as_deref(),
            Some("OpenCode")
        );
    }

    #[test]
    fn extract_text_reads_claude_deltas() {
        let line = r#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hi"}}}"#;
        assert_eq!(extract_text(line).as_deref(), Some("Hi"));
    }
}
