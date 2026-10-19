//! The app's own record of slowness and of its native events, in
//! `~/.orb/logs/orb-<date>.jsonl`.
//!
//! Native code logs through `orb_log!`: one JSON line per event with its
//! level, event name, and the mission, harness, pid and generation it is
//! about. Values are structural (counts, flags, codes); never prompts,
//! secrets or environment values.
//!
//! The page reports stalls, slow requests and its load. A page that is frozen
//! cannot report, so a watchdog here notes when the page goes silent and when
//! the window's own thread stops answering, with the machine's memory state.

use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

const MAX_FILE_BYTES: u64 = 20 * 1024 * 1024;
const KEPT_FILES: usize = 7;
const MAX_LINE_BYTES: usize = 16 * 1024;
/// The page reports every 5 s.
const PAGE_SILENT: Duration = Duration::from_secs(12);
const WINDOW_SLOW: Duration = Duration::from_millis(500);
const CHECK_EVERY: Duration = Duration::from_secs(2);

static WRITER: Mutex<()> = Mutex::new(());
/// The log directory could not be created or a file opened; said once.
static FAILURE_REPORTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static STARTED: OnceLock<Instant> = OnceLock::new();
/// Milliseconds since `STARTED` of the page's last report; 0 before the first.
static PAGE_SEEN: AtomicU64 = AtomicU64::new(0);

fn elapsed_ms() -> u64 {
    STARTED.get_or_init(Instant::now).elapsed().as_millis() as u64
}

pub(crate) fn directory() -> Option<PathBuf> {
    // Tests never write into the user's own log.
    if cfg!(test) {
        return Some(std::env::temp_dir().join("orb-test-logs"));
    }
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".orb").join("logs"))
}

/// The log is best effort, but a log that silently never appears hides
/// every other failure: say so on stderr, once per process.
fn report_failure(what: &str, path: &std::path::Path, error: &std::io::Error) {
    if !FAILURE_REPORTED.swap(true, Ordering::Relaxed) {
        eprintln!(
            "orb: diagnostics log disabled: cannot {what} {}: {error}",
            path.display()
        );
    }
}

fn append(lines: &[String]) {
    let Some(directory) = directory() else { return };
    append_in(&directory, lines);
}

fn append_in(directory: &std::path::Path, lines: &[String]) {
    let _guard = WRITER.lock().unwrap_or_else(|e| e.into_inner());
    if let Err(error) = std::fs::create_dir_all(directory) {
        report_failure("create", directory, &error);
        return;
    }
    let path = directory.join(format!(
        "orb-{}.jsonl",
        chrono::Local::now().format("%Y-%m-%d")
    ));
    let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    if size == 0 {
        forget_old_files(directory);
    }
    if size >= MAX_FILE_BYTES {
        return;
    }
    let mut file = match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        Ok(file) => file,
        Err(error) => {
            report_failure("open", &path, &error);
            return;
        }
    };
    for line in lines {
        if line.len() <= MAX_LINE_BYTES && !line.contains('\n') {
            let _ = writeln!(file, "{line}");
        }
    }
}

fn forget_old_files(directory: &std::path::Path) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    let mut logs: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("orb-") && name.ends_with(".jsonl"))
        })
        .collect();
    logs.sort();
    let excess = logs.len().saturating_sub(KEPT_FILES - 1);
    for path in logs.into_iter().take(excess) {
        let _ = std::fs::remove_file(path);
    }
}

fn record(kind: &str, mut data: serde_json::Value) {
    data["at"] = chrono::Utc::now()
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
        .into();
    data["kind"] = kind.into();
    data["source"] = "native".into();
    append(&[data.to_string()]);
}

/// Write one native log event. Use `orb_log!`, which builds `fields`.
pub(crate) fn log(level: &str, event: &str, fields: serde_json::Map<String, serde_json::Value>) {
    let mut data = serde_json::Value::Object(fields);
    data["level"] = level.into();
    data["event"] = event.into();
    // Warnings and errors still reach a terminal that runs Orb.
    if matches!(level, "warn" | "error") {
        eprintln!("orb {level} {event}: {data}");
    }
    record("log", data);
}

/// One `orb_log!` field: `extra` objects are merged, null values dropped.
pub(crate) fn log_field(
    fields: &mut serde_json::Map<String, serde_json::Value>,
    key: &str,
    value: serde_json::Value,
) {
    match (key, value) {
        (_, serde_json::Value::Null) => {}
        ("extra", serde_json::Value::Object(extra)) => fields.extend(extra),
        (key, value) => {
            fields.insert(key.into(), value);
        }
    }
}

/// `orb_log!(level, "event", mission = id, harness = h, pid = p,
/// generation = g, extra = json!({...}))`; every field is optional.
#[macro_export]
macro_rules! orb_log {
    // A level computed at run time: `orb_log!(("warn"), ...)`.
    (($level:expr), $event:expr $(, $key:ident = $value:expr)* $(,)?) => {{
        #[allow(unused_mut)]
        let mut fields = serde_json::Map::new();
        $( $crate::diagnostics::log_field(&mut fields, stringify!($key), serde_json::json!($value)); )*
        $crate::diagnostics::log($level, $event, fields);
    }};
    ($level:ident, $event:expr $(, $key:ident = $value:expr)* $(,)?) => {
        $crate::orb_log!((stringify!($level)), $event $(, $key = $value)*)
    };
}

/// Memory of the machine and of this process, in MiB. Heavy swapping freezes
/// the page whatever the page does.
fn machine() -> serde_json::Value {
    use sysinfo::{Pid, ProcessesToUpdate, System};
    const MIB: u64 = 1024 * 1024;
    let mut system = System::new();
    system.refresh_memory();
    let own = Pid::from_u32(std::process::id());
    system.refresh_processes(ProcessesToUpdate::Some(&[own]), true);
    serde_json::json!({
        "memory_free_mib": system.available_memory() / MIB,
        "memory_total_mib": system.total_memory() / MIB,
        "swap_used_mib": system.used_swap() / MIB,
        "app_memory_mib": system.process(own).map(|process| process.memory() / MIB),
    })
}

/// Open Orb's log folder in the file manager.
#[tauri::command]
pub fn reveal_logs() -> Result<(), String> {
    let directory = directory().ok_or("no home directory")?;
    std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    #[cfg(target_os = "macos")]
    let status = std::process::Command::new("open").arg(&directory).status();
    #[cfg(target_os = "windows")]
    let status = std::process::Command::new("explorer")
        .arg(&directory)
        .status();
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let status = std::process::Command::new("xdg-open")
        .arg(&directory)
        .status();
    match status {
        // Explorer reports a failure status even when it opened the folder.
        Ok(status) if status.success() || cfg!(target_os = "windows") => Ok(()),
        Ok(status) => Err(format!("Could not open the log folder ({status})")),
        Err(error) => Err(format!("Could not open the log folder: {error}")),
    }
}

#[tauri::command]
pub fn diagnostics_append(lines: Vec<String>) {
    PAGE_SEEN.store(elapsed_ms().max(1), Ordering::Relaxed);
    if !lines.is_empty() {
        append(&lines);
    }
}

pub fn start(app: tauri::AppHandle) {
    elapsed_ms();
    record("native-started", machine());
    std::thread::Builder::new()
        .name("orb-diagnostics".into())
        .spawn(move || watch(app))
        .ok();
}

fn watch(app: tauri::AppHandle) {
    let mut page_silent = false;
    let mut last_machine = Instant::now();
    loop {
        std::thread::sleep(CHECK_EVERY);

        let seen = PAGE_SEEN.load(Ordering::Relaxed);
        if seen > 0 {
            let silence = Duration::from_millis(elapsed_ms().saturating_sub(seen));
            if silence >= PAGE_SILENT && !page_silent {
                page_silent = true;
                record(
                    "page-silent",
                    serde_json::json!({ "seconds": silence.as_secs(), "machine": machine() }),
                );
            } else if silence < PAGE_SILENT && page_silent {
                page_silent = false;
                record("page-back", serde_json::json!({}));
            }
        }

        // How long the window's thread takes to run a no-op.
        let answered = Arc::new(Mutex::new(None::<Instant>));
        let asked = Instant::now();
        let slot = answered.clone();
        if app
            .run_on_main_thread(move || {
                *slot.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now())
            })
            .is_err()
        {
            return;
        }
        let deadline = asked + Duration::from_secs(30);
        let waited = loop {
            if let Some(at) = *answered.lock().unwrap_or_else(|e| e.into_inner()) {
                break at.duration_since(asked);
            }
            if Instant::now() >= deadline {
                break deadline.duration_since(asked);
            }
            std::thread::sleep(Duration::from_millis(50));
        };
        if waited >= WINDOW_SLOW {
            record(
                "window-stall",
                serde_json::json!({ "ms": waited.as_millis() as u64, "machine": machine() }),
            );
        }

        if last_machine.elapsed() >= Duration::from_secs(60) {
            last_machine = Instant::now();
            record("machine", machine());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotation_keeps_the_newest_files_and_ignores_others() {
        let dir = tempfile::tempdir().unwrap();
        for day in 1..=9 {
            std::fs::write(dir.path().join(format!("orb-2026-01-0{day}.jsonl")), "{}\n").unwrap();
        }
        std::fs::write(dir.path().join("notes.txt"), "keep").unwrap();
        forget_old_files(dir.path());
        let mut left: Vec<String> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        // Room for today's new file: KEPT_FILES - 1 old ones remain.
        assert_eq!(left.len(), KEPT_FILES - 1 + 1);
        assert!(left.contains(&"notes.txt".to_string()));
        assert!(!left.contains(&"orb-2026-01-03.jsonl".to_string()));
        assert!(left.contains(&"orb-2026-01-09.jsonl".to_string()));
    }

    #[test]
    fn oversized_or_multiline_lines_are_dropped() {
        let dir = tempfile::tempdir().unwrap();
        append_in(
            dir.path(),
            &[
                "{\"ok\":1}".into(),
                "a\nb".into(),
                "x".repeat(MAX_LINE_BYTES + 1),
            ],
        );
        let file = std::fs::read_dir(dir.path())
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        assert_eq!(std::fs::read_to_string(file).unwrap(), "{\"ok\":1}\n");
    }

    #[test]
    fn log_fields_merge_extra_and_drop_nulls() {
        let mut fields = serde_json::Map::new();
        log_field(&mut fields, "mission", serde_json::json!("m"));
        log_field(&mut fields, "pid", serde_json::Value::Null);
        log_field(&mut fields, "extra", serde_json::json!({"code": 3}));
        assert_eq!(
            serde_json::Value::Object(fields),
            serde_json::json!({"mission":"m","code":3})
        );
    }
}
