//! The app's own record of slowness, in `~/.orb/logs/orb-<date>.jsonl`.
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
static STARTED: OnceLock<Instant> = OnceLock::new();
/// Milliseconds since `STARTED` of the page's last report; 0 before the first.
static PAGE_SEEN: AtomicU64 = AtomicU64::new(0);

fn elapsed_ms() -> u64 {
    STARTED.get_or_init(Instant::now).elapsed().as_millis() as u64
}

fn directory() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".orb").join("logs"))
}

fn append(lines: &[String]) {
    let Some(directory) = directory() else { return };
    let _guard = WRITER.lock().unwrap_or_else(|e| e.into_inner());
    if std::fs::create_dir_all(&directory).is_err() {
        return;
    }
    let path = directory.join(format!(
        "orb-{}.jsonl",
        chrono::Local::now().format("%Y-%m-%d")
    ));
    let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    if size == 0 {
        forget_old_files(&directory);
    }
    if size >= MAX_FILE_BYTES {
        return;
    }
    let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    else {
        return;
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
