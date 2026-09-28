use serde::Serialize;
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};
use sysinfo::{Disks, Pid, ProcessRefreshKind, ProcessesToUpdate, System};

#[derive(Clone, Serialize)]
pub struct Consumer {
    label: &'static str,
    memory: u64,
    processes: usize,
}
#[derive(Clone, Serialize)]
pub struct Snapshot {
    cpu_percent: Option<f32>,
    gpu_percent: Option<f32>,
    memory_used: u64,
    memory_total: u64,
    disk_used: u64,
    disk_total: u64,
    consumers: Vec<Consumer>,
    timings_ms: serde_json::Value,
}

fn category(pid: Pid, system: &System, voice: Option<u32>, agents: &[u32]) -> Option<usize> {
    let mut current = Some(pid);
    for _ in 0..64 {
        let p = current?;
        if voice == Some(p.as_u32()) {
            return Some(1);
        }
        if agents.contains(&p.as_u32()) {
            return Some(2);
        }
        if p.as_u32() == std::process::id() {
            return Some(0);
        }
        current = system.process(p).and_then(|p| p.parent());
    }
    None
}

#[derive(Clone, Serialize)]
pub struct Sample {
    time: u64,
    cpu: Option<f32>,
    gpu: Option<f32>,
    memory: Option<f64>,
}
#[derive(Clone, Serialize)]
pub struct CachedSnapshot {
    #[serde(flatten)]
    snapshot: Snapshot,
    history: Vec<Sample>,
    sampled_at: u64,
}
static DETAILS_UNTIL: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
fn seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
static CACHE: OnceLock<Mutex<Option<CachedSnapshot>>> = OnceLock::new();

static DEMAND: OnceLock<(Mutex<Option<Instant>>, Condvar)> = OnceLock::new();
fn demand() -> &'static (Mutex<Option<Instant>>, Condvar) {
    DEMAND.get_or_init(|| (Mutex::new(None), Condvar::new()))
}
fn lease_active(last: Option<Instant>, now: Instant) -> bool {
    last.is_some_and(|last| now.saturating_duration_since(last) < Duration::from_secs(10))
}
/// Reads renew a lease; a closed/hidden/crashed webview cannot leave sampling active.
pub fn start(voice: crate::voice::VoiceState) {
    static STARTED: std::sync::Once = std::sync::Once::new();
    STARTED.call_once(|| {
        std::thread::spawn(move || loop {
            let (lock, wake) = demand();
            let Ok(mut last) = lock.lock() else {
                return;
            };
            while !lease_active(*last, Instant::now()) {
                let Ok(next) = wake.wait(last) else {
                    return;
                };
                last = next;
            }
            drop(last);
            if let Ok(snapshot) = collect(
                voice.worker_pid(),
                voice.worker_shared(),
                crate::local_agents::active_pids(),
            ) {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64;
                if let Ok(mut cache) = CACHE.get_or_init(|| Mutex::new(None)).lock() {
                    let mut history = cache
                        .as_ref()
                        .map(|s| s.history.clone())
                        .unwrap_or_default();
                    history.retain(|s| s.time >= now.saturating_sub(60_000));
                    history.push(Sample {
                        time: now,
                        cpu: snapshot.cpu_percent,
                        gpu: snapshot.gpu_percent,
                        memory: (snapshot.memory_total > 0).then(|| {
                            snapshot.memory_used as f64 / snapshot.memory_total as f64 * 100.0
                        }),
                    });
                    *cache = Some(CachedSnapshot {
                        snapshot,
                        history,
                        sampled_at: now,
                    });
                }
            }
            std::thread::sleep(std::time::Duration::from_secs(3));
        });
    });
}
#[tauri::command]
pub fn local_machine_metrics(details: Option<bool>) -> Result<CachedSnapshot, String> {
    if details == Some(true) {
        DETAILS_UNTIL.store(seconds() + 6, std::sync::atomic::Ordering::Relaxed);
    }
    let (lock, wake) = demand();
    if let Ok(mut last) = lock.lock() {
        *last = Some(Instant::now());
        wake.notify_one();
    }
    CACHE
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map_err(|e| e.to_string())?
        .clone()
        .ok_or_else(|| "Local metrics are warming up".to_string())
}

fn collect(
    voice_pid: Option<u32>,
    voice_shared: bool,
    agents: Vec<u32>,
) -> Result<Snapshot, String> {
    static SYSTEM: OnceLock<Mutex<(System, bool)>> = OnceLock::new();
    let mut state = SYSTEM
        .get_or_init(|| Mutex::new((System::new(), false)))
        .lock()
        .map_err(|e| e.to_string())?;
    let (system, initialized) = &mut *state;
    let started = std::time::Instant::now();
    system.refresh_cpu_usage();
    system.refresh_memory();
    let aggregates_ms = started.elapsed().as_secs_f64() * 1000.0;
    let process_start = std::time::Instant::now();
    let details = seconds() < DETAILS_UNTIL.load(std::sync::atomic::Ordering::Relaxed);
    if details {
        system.refresh_processes_specifics(
            ProcessesToUpdate::All,
            true,
            ProcessRefreshKind::new().with_memory(),
        );
    }
    let processes_ms = process_start.elapsed().as_secs_f64() * 1000.0;
    let disks_start = std::time::Instant::now();
    let cpu_percent = initialized.then(|| system.global_cpu_usage());
    *initialized = true;
    let (disk_used, disk_total) = disk_usage();
    let disks_ms = disks_start.elapsed().as_secs_f64() * 1000.0;
    let classify_start = std::time::Instant::now();
    let mut consumers = vec![
        Consumer {
            label: "Orb · native process tree",
            memory: 0,
            processes: 0,
        },
        Consumer {
            label: if voice_shared {
                "Cohere · shared speech engine"
            } else {
                "Cohere · speech to text"
            },
            memory: 0,
            processes: 0,
        },
        Consumer {
            label: "Local harnesses · started by Orb",
            memory: 0,
            processes: 0,
        },
    ];
    for (pid, process) in system.processes().iter().filter(|_| details) {
        if let Some(index) = category(*pid, system, voice_pid, &agents) {
            consumers[index].memory += process.memory();
            consumers[index].processes += 1;
        }
    }
    let classification_ms = classify_start.elapsed().as_secs_f64() * 1000.0;
    let gpu_start = std::time::Instant::now();
    let gpu_percent = if details { apple_gpu_usage() } else { None };
    let gpu_ms = gpu_start.elapsed().as_secs_f64() * 1000.0;
    Ok(Snapshot {
        cpu_percent,
        gpu_percent,
        memory_used: system.used_memory(),
        memory_total: system.total_memory(),
        disk_used,
        disk_total,
        consumers,
        timings_ms: serde_json::json!({"aggregates":aggregates_ms,"processes":processes_ms,"disks":disks_ms,"classification":classification_ms,"gpu":gpu_ms,"total":started.elapsed().as_secs_f64()*1000.0,"details":details}),
    })
}

fn disk_usage() -> (u64, u64) {
    static DISKS: OnceLock<Mutex<Option<(Instant, u64, u64)>>> = OnceLock::new();
    let Ok(mut cached) = DISKS.get_or_init(|| Mutex::new(None)).lock() else {
        return (0, 0);
    };
    if let Some((time, used, total)) = *cached {
        if time.elapsed() < Duration::from_secs(60) {
            return (used, total);
        }
    }
    let disks = Disks::new_with_refreshed_list();
    let disk = disks
        .iter()
        .find(|d| d.mount_point() == std::path::Path::new("/System/Volumes/Data"))
        .or_else(|| {
            disks
                .iter()
                .find(|d| d.mount_point() == std::path::Path::new("/"))
        });
    let result = disk
        .map(|d| {
            (
                d.total_space().saturating_sub(d.available_space()),
                d.total_space(),
            )
        })
        .unwrap_or_default();
    *cached = Some((Instant::now(), result.0, result.1));
    result
}

fn apple_gpu_usage() -> Option<f32> {
    #[cfg(target_os = "macos")]
    {
        let output = std::process::Command::new("/usr/sbin/ioreg")
            .args(["-r", "-c", "IOAccelerator", "-l"])
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        let value = text
            .split("\"Device Utilization %\"=")
            .nth(1)?
            .split(|c: char| !c.is_ascii_digit())
            .next()?
            .parse::<f32>()
            .ok()?;
        return (0.0..=100.0).contains(&value).then_some(value);
    }
    #[cfg(not(target_os = "macos"))]
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sampling_lease_expires_without_a_reader() {
        let now = Instant::now();
        assert!(!lease_active(None, now));
        assert!(lease_active(Some(now), now + Duration::from_secs(9)));
        assert!(!lease_active(Some(now), now + Duration::from_secs(10)));
    }
    #[test]
    fn native_collector_reads_host_resources() {
        let sample = collect(None, false, Vec::new()).expect("native system collector");
        assert!(sample.memory_total > 0);
        assert!(sample.memory_used <= sample.memory_total);
        if let Some(gpu) = sample.gpu_percent {
            assert!((0.0..=100.0).contains(&gpu));
        }
        println!("Native GPU utilization: {:?}", sample.gpu_percent);
    }
    #[test]
    fn specialized_consumers_are_not_counted_as_orb() {
        let system = System::new();
        let pid = Pid::from_u32(std::process::id());
        assert_eq!(category(pid, &system, None, &[]), Some(0));
        assert_eq!(category(pid, &system, Some(pid.as_u32()), &[]), Some(1));
        assert_eq!(category(pid, &system, None, &[pid.as_u32()]), Some(2));
    }
    #[test]
    fn unrelated_process_is_not_attributed() {
        assert_eq!(category(Pid::from_u32(0), &System::new(), None, &[]), None);
    }
}
