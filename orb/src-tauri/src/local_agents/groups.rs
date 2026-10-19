//! Process groups Orb launched, persisted so a later Orb (after a crash or a
//! restart) can stop exactly those groups and nothing else.
//!
//! A pid alone is not an identity: once a process is reaped its pid can be
//! recycled by an unrelated program. Each record therefore keeps the leader's
//! start time, and a group is only signalled while a live process with that
//! pid still reports the same start time.

use super::*;

/// One process Orb owns: the leader of a group Orb created, or a descendant
/// seen while stopping a run (a wrapper may put the CLI in its own group).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Owned {
    pub(crate) mission: String,
    pub(crate) pid: i32,
    /// The group to signal: `pid` when the process leads its own group,
    /// otherwise `None` and only the process itself is signalled.
    pub(crate) pgid: Option<i32>,
    /// Start time in microseconds since the epoch, as the kernel reports it.
    pub(crate) start: u64,
}

/// Microseconds since the epoch at which `pid` started, or `None` when no
/// such process exists (or it is a zombie whose details are gone).
#[cfg(target_os = "macos")]
pub(crate) fn start_time(pid: i32) -> Option<u64> {
    if pid <= 0 {
        return None;
    }
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let read = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            &mut info as *mut _ as *mut libc::c_void,
            size,
        )
    };
    (read == size).then(|| info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
}

/// Linux: field 22 of `/proc/<pid>/stat`, in clock ticks since boot.
#[cfg(all(unix, not(target_os = "macos")))]
pub(crate) fn start_time(pid: i32) -> Option<u64> {
    if pid <= 0 {
        return None;
    }
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // The command name may contain spaces and parentheses: split after it.
    let rest = &stat[stat.rfind(')')? + 2..];
    rest.split_whitespace().nth(19)?.parse().ok()
}

#[cfg(not(unix))]
pub(crate) fn start_time(_pid: i32) -> Option<u64> {
    None
}

/// Describe a live process Orb just spawned. Its group is only recorded when
/// it leads that group (spawned with `process_group(0)`), never Orb's own.
#[cfg(unix)]
pub(crate) fn describe(mission: &str, pid: i32) -> Option<Owned> {
    let start = start_time(pid)?;
    let group = unsafe { libc::getpgid(pid) };
    let pgid = (group == pid && group != unsafe { libc::getpgrp() }).then_some(group);
    Some(Owned {
        mission: mission.to_owned(),
        pid,
        pgid,
        start,
    })
}

#[cfg(not(unix))]
pub(crate) fn describe(_mission: &str, _pid: i32) -> Option<Owned> {
    None
}

impl Owned {
    /// True while the recorded process is still the one Orb launched.
    pub(crate) fn alive(&self) -> bool {
        start_time(self.pid) == Some(self.start)
    }
    /// Signal the recorded group (or the process alone) only when the pid
    /// still names the recorded process. Returns whether a signal was sent.
    #[cfg(unix)]
    pub(crate) fn signal(&self, signal: i32) -> bool {
        if !self.alive() {
            return false;
        }
        unsafe {
            match self.pgid {
                Some(group) => libc::kill(-group, signal) == 0,
                None => libc::kill(self.pid, signal) == 0,
            }
        }
    }
    #[cfg(not(unix))]
    pub(crate) fn signal(&self, _signal: i32) -> bool {
        false
    }
}

fn store_path() -> PathBuf {
    #[cfg(test)]
    {
        std::env::temp_dir().join(format!(
            "orb-test-process-groups-{}.json",
            std::process::id()
        ))
    }
    #[cfg(not(test))]
    {
        match std::env::var_os("HOME") {
            Some(home) => PathBuf::from(home).join(".orb").join("process-groups.json"),
            None => std::env::temp_dir().join("orb-process-groups.json"),
        }
    }
}

fn store() -> &'static Mutex<()> {
    static STORE: OnceLock<Mutex<()>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(()))
}

fn read_all() -> Vec<Owned> {
    std::fs::read(store_path())
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn write_all(all: &[Owned]) {
    let path = store_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let tmp = path.with_extension("json.tmp");
    let written = serde_json::to_vec(all)
        .map_err(|e| e.to_string())
        .and_then(|bytes| std::fs::write(&tmp, bytes).map_err(|e| e.to_string()))
        .and_then(|()| std::fs::rename(&tmp, &path).map_err(|e| e.to_string()));
    if let Err(error) = written {
        crate::orb_log!(
            warn,
            "process_groups_write_failed",
            extra = json!({"error": error})
        );
    }
}

/// Remember processes Orb owns. Entries that are no longer alive are
/// dropped on every write so the file stays small.
pub(crate) fn record(entries: &[Owned]) {
    if entries.is_empty() {
        return;
    }
    let _guard = crate::sync_util::lock(store());
    let mut all = read_all();
    all.retain(Owned::alive);
    for entry in entries {
        if !all.contains(entry) {
            all.push(entry.clone());
        }
    }
    write_all(&all);
}

/// Forget one process once Orb has reaped it.
pub(crate) fn forget(entry: &Owned) {
    let _guard = crate::sync_util::lock(store());
    let mut all = read_all();
    let before = all.len();
    all.retain(|owned| owned != entry && owned.alive());
    if all.len() != before {
        write_all(&all);
    }
}

/// The live processes Orb recorded for a mission.
pub(crate) fn owned_by(mission: &str) -> Vec<Owned> {
    let _guard = crate::sync_util::lock(store());
    read_all()
        .into_iter()
        .filter(|owned| owned.mission == mission && owned.alive())
        .collect()
}

/// Every live descendant of `root`, described with its start time. Used
/// while stopping a run, when its tree is known to belong to Orb.
pub(crate) fn descendants(mission: &str, root: u32) -> Vec<Owned> {
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System};
    let mut system = System::new();
    system.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::new());
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    for (pid, process) in system.processes() {
        if let Some(parent) = process.parent() {
            children
                .entry(parent.as_u32())
                .or_default()
                .push(pid.as_u32());
        }
    }
    let mut found = Vec::new();
    let mut queue = vec![root];
    while let Some(pid) = queue.pop() {
        for &child in children.get(&pid).into_iter().flatten() {
            if child == std::process::id() || found.iter().any(|o: &Owned| o.pid == child as i32) {
                continue;
            }
            if let Some(owned) = describe(mission, child as i32) {
                found.push(owned);
            }
            queue.push(child);
        }
    }
    found
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::process::CommandExt;

    #[test]
    fn a_recycled_pid_is_never_signalled() {
        let mut child = Command::new("/bin/sh")
            .args(["-c", "sleep 30"])
            .process_group(0)
            .spawn()
            .unwrap();
        let pid = child.id() as i32;
        let owned = describe("recycled", pid).expect("a live child is described");
        assert_eq!(owned.pgid, Some(pid));
        assert!(owned.alive());
        // Same pid, another start time: what a recycled pid looks like.
        let impostor = Owned {
            start: owned.start + 1,
            ..owned.clone()
        };
        assert!(!impostor.alive());
        assert!(!impostor.signal(libc::SIGKILL));
        assert!(
            child.try_wait().unwrap().is_none(),
            "the impostor signal hit"
        );
        assert!(owned.signal(libc::SIGKILL));
        child.wait().unwrap();
        assert!(!owned.alive(), "a reaped process is no longer owned");
        assert!(!owned.signal(libc::SIGKILL));
    }

    #[test]
    fn a_process_in_orbs_group_is_signalled_alone() {
        let mut child = Command::new("/bin/sh")
            .args(["-c", "sleep 30"])
            .spawn()
            .unwrap();
        let owned = describe("same-group", child.id() as i32).unwrap();
        assert_eq!(owned.pgid, None, "Orb's own group is never recorded");
        assert!(owned.signal(libc::SIGKILL));
        child.wait().unwrap();
    }

    #[test]
    fn records_survive_and_are_scoped_to_their_mission() {
        let mission = format!("record-{}", uuid::Uuid::new_v4());
        let mut child = Command::new("/bin/sh")
            .args(["-c", "sleep 30"])
            .process_group(0)
            .spawn()
            .unwrap();
        let owned = describe(&mission, child.id() as i32).unwrap();
        record(std::slice::from_ref(&owned));
        assert_eq!(owned_by(&mission), vec![owned.clone()]);
        assert!(owned_by("another-mission")
            .iter()
            .all(|other| other.pid != owned.pid));
        forget(&owned);
        assert!(owned_by(&mission).is_empty());
        let _ = child.kill();
        let _ = child.wait();
    }
}
