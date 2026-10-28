//! Symbol-table checks only: these do not establish signatures or target qualification.
use std::{collections::BTreeSet, path::Path, process::Command};

include!("../../shared/orb-spec/cabi/orb_kernel_exports.rs");

pub fn verify_listing(text: &str, macos: bool) -> Result<(), String> {
    let expected: BTreeSet<_> = EXPORTS.iter().copied().collect();
    let mut seen = BTreeSet::new();
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        let fields: Vec<_> = line.split_whitespace().collect();
        // POSIX nm emits a standalone archive-member heading before its rows.
        if fields.len() == 1 && line.ends_with(':') {
            continue;
        }
        if fields.len() < 2 {
            return Err(format!("unrecognized nm row: {line}"));
        }
        let name = if macos {
            fields[0].strip_prefix('_').unwrap_or(fields[0])
        } else {
            fields[0]
        };
        if fields[1] != "T" || !expected.contains(name) || !seen.insert(name) {
            return Err(format!(
                "unexpected, imported, non-text or duplicate symbol: {line}"
            ));
        }
    }
    if seen != expected {
        return Err(format!(
            "missing manifest exports: {:?}",
            expected.difference(&seen)
        ));
    }
    Ok(())
}

pub fn verify_artifact(path: &Path, macos: bool) -> Result<(), String> {
    let output = Command::new("nm")
        .args(["-g", "-P"])
        .arg(path)
        .output()
        .map_err(|e| format!("nm could not inspect {}: {e}", path.display()))?;
    if !output.status.success() {
        return Err(format!(
            "nm failed on {}: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    let text =
        std::str::from_utf8(&output.stdout).map_err(|e| format!("invalid nm output: {e}"))?;
    verify_listing(text, macos)
}
