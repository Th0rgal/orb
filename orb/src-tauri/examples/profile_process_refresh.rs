//! Diagnostic microbenchmark: process enumeration only, not total app CPU.
use std::time::Instant;
use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System};
fn main() {
    let mut full = System::new();
    let mut memory = System::new();
    let mut full_ms = Vec::new();
    let mut memory_ms = Vec::new();
    for iteration in 0..13 {
        // Alternate order to avoid consistently favoring the second OS-cache reader.
        for mode in if iteration % 2 == 0 {
            [true, false]
        } else {
            [false, true]
        } {
            let start = Instant::now();
            let system = if mode { &mut full } else { &mut memory };
            if mode {
                system.refresh_processes(ProcessesToUpdate::All, true);
            } else {
                system.refresh_processes_specifics(
                    ProcessesToUpdate::All,
                    true,
                    ProcessRefreshKind::new().with_memory(),
                );
            }
            let elapsed = start.elapsed().as_secs_f64() * 1000.0;
            std::hint::black_box(
                system
                    .processes()
                    .values()
                    .map(|p| (p.parent(), p.memory()))
                    .collect::<Vec<_>>(),
            );
            if iteration > 0 {
                if mode {
                    full_ms.push(elapsed);
                } else {
                    memory_ms.push(elapsed);
                }
            }
        }
    }
    println!(
        "{}",
        serde_json::json!({"default_ms":full_ms,"memory_only_ms":memory_ms,"default_processes":full.processes().len(),"memory_processes":memory.processes().len()})
    );
}
