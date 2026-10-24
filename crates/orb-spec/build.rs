use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

/// `leanprover/lean4:v4.31.0` -> `4.31.0`.
fn pinned_lean_version(lean_dir: &Path) -> String {
    let path = lean_dir.join("lean-toolchain");
    let raw = fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
    raw.trim()
        .rsplit(':')
        .next()
        .map(|v| v.trim_start_matches('v').to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| panic!("unparseable {}: {raw:?}", path.display()))
}

/// True when `lean --version` (run from `lean_dir`, so an elan shim resolves
/// `lean-toolchain`) reports exactly `version`.
fn lean_matches(lean: &Path, lean_dir: &Path, version: &str) -> bool {
    Command::new(lean)
        .current_dir(lean_dir)
        .arg("--version")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .is_some_and(|o| {
            String::from_utf8_lossy(&o.stdout).contains(&format!("version {version},"))
        })
}

/// Finds a `lean` binary whose version matches `lean/lean-toolchain`.
/// Candidates: `$ORB_LEAN`, `$PATH`, then elan homes (`bin/` shim and
/// `toolchains/*` whose directory name ends in the pinned version).
fn find_lean(lean_dir: &Path, version: &str) -> Option<PathBuf> {
    let mut cands = Vec::new();
    if let Ok(explicit) = env::var("ORB_LEAN") {
        cands.push(PathBuf::from(explicit));
    }
    if let Ok(path_var) = env::var("PATH") {
        cands.extend(env::split_paths(&path_var).map(|d| d.join("lean")));
    }
    let mut roots = Vec::new();
    if let Ok(elan_home) = env::var("ELAN_HOME") {
        roots.push(PathBuf::from(elan_home));
    }
    if let Ok(home) = env::var("HOME") {
        roots.push(PathBuf::from(home).join(".elan"));
    }
    roots.push(PathBuf::from("/var/lib/sandboxed-node/caches/elan"));
    let tc_suffix = format!("v{version}");
    for root in roots {
        cands.push(root.join("bin").join("lean"));
        if let Ok(entries) = fs::read_dir(root.join("toolchains")) {
            for entry in entries.flatten() {
                if entry.file_name().to_string_lossy().ends_with(&tc_suffix) {
                    cands.push(entry.path().join("bin").join("lean"));
                }
            }
        }
    }
    cands
        .into_iter()
        .find(|c| c.is_file() && lean_matches(c, lean_dir, version))
}

const ORB_EXPORTS: &[&str] = &[
    "orb_verify_writer_reuse",
    "orb_verify_lease_mode",
    "orb_verify_track_hold",
    "orb_verify_repo_disjoint",
    "orb_verify_remote_outbox",
    "orb_verify_board_slots",
    "orb_verify_board_retry",
    "orb_verify_job_transition",
    "orb_verify_bundle_budget",
    "orb_verify_token_rotation",
    "orb_verify_log_window",
    "orb_mix64_word",
    "orb_proxy_step",
    "orb_stream_deadlines",
    "orb_breaker_step",
    "orb_mission_step",
    "orb_reconcile_step",
    "orb_queue_step",
    "orb_vm_step",
    "orb_access_step",
    "orb_workfold_step",
    "orb_taskcard_step",
    "orb_sidebar_visibility",
    "orb_admission_step",
    "orb_account_cooldown_secs",
    "orb_cost_cents_step",
    "orb_stream_loop_step",
    "orb_job_ledger_step",
    "orb_proc_liveness_step",
    "orb_pr_gate_step",
    "orb_turn_summary_step",
    "orb_usage_limit_status",
    "orb_relative_time_bucket",
    "orb_transcript_patch_step",
    "orb_attribution_step",
    "orb_schedule_step",
    "orb_stats_settle_step",
];

fn build_orb_spec_cabi(root: &Path, out_dir: &Path) {
    let lean_dir = root.join("lean");
    println!(
        "cargo:rerun-if-changed={}",
        lean_dir.join("Orb/Kernel.lean").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        lean_dir.join("Orb/Spec.lean").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        lean_dir.join("lakefile.lean").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        lean_dir.join("lean-toolchain").display()
    );
    let kernel_lean = lean_dir.join("Orb/Kernel.lean");
    let spec_lean = lean_dir.join("Orb/Spec.lean");
    let out_orb_dir = out_dir.join("Orb");
    fs::create_dir_all(&out_orb_dir)
        .unwrap_or_else(|e| panic!("failed to create {}: {e}", out_orb_dir.display()));
    let kernel_olean = out_orb_dir.join("Kernel.olean");
    let spec_olean = out_orb_dir.join("Spec.olean");
    let spec_c_path = out_dir.join("Orb_Kernel.c");
    let obj_path = out_dir.join("Orb_Kernel.o");
    let gc_obj_path = out_dir.join("Orb_Kernel_gc.o");
    let lib_path = out_dir.join("liborb_spec_cabi.a");

    let version = pinned_lean_version(&lean_dir);
    let lean_bin = find_lean(&lean_dir, &version).unwrap_or_else(|| {
        panic!(
            "no lean {version} found (lean/lean-toolchain); set ORB_LEAN or run \
             `elan toolchain install leanprover/lean4:v{version}`"
        )
    });

    let kernel_status = Command::new(&lean_bin)
        .current_dir(&lean_dir)
        // `declaration uses 'sorry'` is only a warning; make it fatal.
        .arg("-DwarningAsError=true")
        .arg("Orb/Kernel.lean")
        .arg("-o")
        .arg(&kernel_olean)
        .arg("-c")
        .arg(&spec_c_path)
        .status()
        .unwrap_or_else(|e| panic!("failed to run lean on Orb/Kernel.lean: {e}"));
    assert!(
        kernel_status.success() && spec_c_path.is_file(),
        "lean failed to compile Orb/Kernel.lean to C (warnings, incl. sorry, are errors)"
    );

    let spec_status = Command::new(&lean_bin)
        .current_dir(&lean_dir)
        .env("LEAN_PATH", out_dir)
        .arg("-DwarningAsError=true")
        .arg("Orb/Spec.lean")
        .arg("-o")
        .arg(&spec_olean)
        .status()
        .unwrap_or_else(|e| panic!("failed to run lean on Orb/Spec.lean: {e}"));
    assert!(
        spec_status.success() && spec_olean.is_file(),
        "lean failed to typecheck Orb/Spec.lean (warnings, incl. sorry, are errors)"
    );

    let lean_prefix = Command::new(&lean_bin)
        .current_dir(&lean_dir)
        .arg("--print-prefix")
        .output()
        .unwrap_or_else(|e| panic!("lean --print-prefix failed: {e}"));
    assert!(lean_prefix.status.success(), "lean --print-prefix failed");
    let prefix = String::from_utf8_lossy(&lean_prefix.stdout)
        .trim()
        .to_string();
    let include = PathBuf::from(&prefix).join("include");

    let macos = env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos");
    let compile_c_path = if macos {
        let src = fs::read_to_string(&spec_c_path).expect("read Orb_Kernel.c");
        let mut c = String::with_capacity(src.len());
        for line in src.lines() {
            let name = line
                .strip_prefix("LEAN_EXPORT ")
                .and_then(|rest| rest.split('(').next())
                .and_then(|head| {
                    head.rsplit(|ch: char| !(ch.is_alphanumeric() || ch == '_'))
                        .next()
                });
            match name {
                Some(n) if !ORB_EXPORTS.contains(&n) => {
                    c.push_str("static ");
                    c.push_str(&line["LEAN_EXPORT ".len()..]);
                }
                _ => c.push_str(line),
            }
            c.push('\n');
        }
        let path = out_dir.join("Orb_Kernel_macos.c");
        fs::write(&path, c).expect("write Orb_Kernel_macos.c");
        path
    } else {
        spec_c_path.clone()
    };

    let mut compiled = false;
    for compiler in ["cc", "clang", "gcc"] {
        if let Ok(st) = Command::new(compiler)
            .args([
                "-O3",
                "-fPIC",
                "-ffunction-sections",
                "-fdata-sections",
                "-c",
            ])
            .arg(format!("-I{}", include.display()))
            .arg(&compile_c_path)
            .arg("-o")
            .arg(&obj_path)
            .status()
        {
            if st.success() && obj_path.is_file() {
                compiled = true;
                break;
            }
        }
    }
    assert!(compiled, "failed to compile Orb/Kernel.c");

    if macos {
        fs::copy(&obj_path, &gc_obj_path).expect("copy Orb_Kernel.o");
        let _ = Command::new("strip").arg("-x").arg(&gc_obj_path).status();
    } else {
        let mut ld_args = vec!["-r".to_string(), "--gc-sections".to_string()];
        for sym in ORB_EXPORTS {
            ld_args.push("-u".to_string());
            ld_args.push((*sym).to_string());
        }
        ld_args.push(obj_path.display().to_string());
        ld_args.push("-o".to_string());
        ld_args.push(gc_obj_path.display().to_string());
        let ld_status = Command::new("ld")
            .args(&ld_args)
            .status()
            .unwrap_or_else(|e| panic!("ld --gc-sections failed: {e}"));
        assert!(
            ld_status.success() && gc_obj_path.is_file(),
            "ld --gc-sections failed"
        );
        let _ = Command::new("strip")
            .args(["--strip-unneeded"])
            .arg(&gc_obj_path)
            .status();
    }

    let nm_out = Command::new("nm")
        .args(["-P", "-u"])
        .arg(&gc_obj_path)
        .output()
        .unwrap_or_else(|e| panic!("nm failed: {e}"));
    let undefined = String::from_utf8_lossy(&nm_out.stdout);
    assert!(
        undefined.trim().is_empty(),
        "Orb C-ABI object has undefined symbols:\n{undefined}"
    );
    let defined = Command::new("nm")
        .args(["-P"])
        .arg(&gc_obj_path)
        .output()
        .unwrap_or_else(|e| panic!("nm failed: {e}"));
    let defined_text = String::from_utf8_lossy(&defined.stdout);
    for sym in ORB_EXPORTS {
        assert!(
            defined_text.lines().any(|line| {
                let mut parts = line.split_whitespace();
                let name = parts.next().map(|n| {
                    if macos {
                        n.strip_prefix('_').unwrap_or(n)
                    } else {
                        n
                    }
                });
                name == Some(*sym) && parts.next() == Some("T")
            }),
            "missing defined export {sym}"
        );
    }

    let mut archived = false;
    for ar_tool in ["llvm-ar", "ar"] {
        if let Ok(st) = Command::new(ar_tool)
            .arg("rcs")
            .arg(&lib_path)
            .arg(&gc_obj_path)
            .status()
        {
            if st.success() && lib_path.is_file() {
                archived = true;
                break;
            }
        }
    }
    assert!(archived, "failed to archive liborb_spec_cabi.a");
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=orb_spec_cabi");
    let _ = (kernel_lean, spec_lean);
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/lib.rs");
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let root = manifest_dir
        .parent()
        .and_then(|p| p.parent())
        .expect("crates/orb-spec sits two levels below workspace root");
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    build_orb_spec_cabi(root, &out_dir);
}
