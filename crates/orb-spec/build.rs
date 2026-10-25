use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

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

const LEANSYS_EXPORTS: &[&str] = &[
    "leansys_verify_slice_bounds",
    "leansys_verify_wal_frame",
    "leansys_verify_cas_digest",
    "leansys_check_http_bounds",
    "leansys_verify_jsonl_tape",
    "leansys_verify_ring_cursor",
    "leansys_verify_sst_block",
    "leansys_verify_poll_interest",
    "leansys_verify_rlimit_budget",
    "leansys_mix64_word",
    "leansys_verify_composite_key_order",
    "leansys_verify_token_auth",
    "leansys_verify_log_window",
    "leansys_verify_jsonrpc_frame",
    "leansys_gate_admit",
    "leansys_verify_mmap_seqlock",
    "leansys_verify_proc_stat_fields",
    "leansys_sse_frame_scan",
    "leansys_gfm_pipe_scan",
    "leansys_tag_scan",
    "leansys_transcript_index",
];

fn verify_lean_sources_if_requested(root: &Path, out_dir: &Path) {
    println!("cargo:rerun-if-env-changed=ORB_VERIFY_LEAN");
    println!("cargo:rerun-if-env-changed=TURBO_LEAN_BIN");
    println!("cargo:rerun-if-env-changed=ORB_LEAN");
    if env::var("ORB_VERIFY_LEAN").as_deref() != Ok("1") {
        return;
    }
    let lean_dir = root.join("lean");
    if let Ok(turbo) = env::var("TURBO_LEAN_BIN") {
        let st = Command::new(&turbo)
            .args(["build", "--project-dir"])
            .arg(&lean_dir)
            .status()
            .unwrap_or_else(|e| panic!("failed to run {turbo} on {}: {e}", lean_dir.display()));
        assert!(st.success(), "turbo-lean build failed on lean/");
        return;
    }
    if let Ok(st) = Command::new("turbo-lean")
        .args(["build", "--project-dir"])
        .arg(&lean_dir)
        .status()
    {
        assert!(st.success(), "turbo-lean build failed on lean/");
        return;
    }
    let lean_bin = env::var("ORB_LEAN").unwrap_or_else(|_| "lean".to_string());
    let out_orb_dir = out_dir.join("Orb");
    fs::create_dir_all(&out_orb_dir)
        .unwrap_or_else(|e| panic!("failed to create {}: {e}", out_orb_dir.display()));
    let kernel_olean = out_orb_dir.join("Kernel.olean");
    let spec_olean = out_orb_dir.join("Spec.olean");
    let st_k = Command::new(&lean_bin)
        .current_dir(&lean_dir)
        .args([
            "-DwarningAsError=true",
            "-DautoImplicit=false",
            "Orb/Kernel.lean",
            "-o",
        ])
        .arg(&kernel_olean)
        .status()
        .unwrap_or_else(|e| panic!("failed to run {lean_bin} on Orb/Kernel.lean: {e}"));
    assert!(
        st_k.success() && kernel_olean.is_file(),
        "lean failed on Orb/Kernel.lean"
    );
    let st_s = Command::new(&lean_bin)
        .current_dir(&lean_dir)
        .env("LEAN_PATH", out_dir)
        .args([
            "-DwarningAsError=true",
            "-DautoImplicit=false",
            "Orb/Spec.lean",
            "-o",
        ])
        .arg(&spec_olean)
        .status()
        .unwrap_or_else(|e| panic!("failed to run {lean_bin} on Orb/Spec.lean: {e}"));
    assert!(
        st_s.success() && spec_olean.is_file(),
        "lean failed on Orb/Spec.lean"
    );
}

fn build_orb_spec_cabi(root: &Path, out_dir: &Path) {
    let cabi_dir = root.join("shared/orb-spec/cabi");
    let unboxed_c = cabi_dir.join("orb_kernel_unboxed.c");
    let header_h = cabi_dir.join("orb_kernel.h");
    println!("cargo:rerun-if-changed={}", unboxed_c.display());
    println!("cargo:rerun-if-changed={}", header_h.display());
    println!(
        "cargo:rerun-if-changed={}",
        root.join("shared/orb-spec/kernel_abi.json").display()
    );

    verify_lean_sources_if_requested(root, out_dir);

    let obj_path = out_dir.join("orb_kernel_unboxed.o");
    let lib_path = out_dir.join("liborb_spec_cabi.a");
    let macos = env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos");

    let mut compiled = false;
    for compiler in ["cc", "clang", "gcc"] {
        if let Ok(st) = Command::new(compiler)
            .args([
                "-O3",
                "-fPIC",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-Wno-unused-label",
                "-Wno-unused-parameter",
                "-Wno-unused-variable",
                "-ffunction-sections",
                "-fdata-sections",
                "-c",
            ])
            .arg(format!("-I{}", cabi_dir.display()))
            .arg(&unboxed_c)
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
    assert!(compiled, "failed to compile {}", unboxed_c.display());

    let nm_out = Command::new("nm")
        .args(["-P", "-u"])
        .arg(&obj_path)
        .output()
        .unwrap_or_else(|e| panic!("nm failed: {e}"));
    let undefined = String::from_utf8_lossy(&nm_out.stdout);
    assert!(
        undefined.trim().is_empty(),
        "Orb/LeanSys unboxed C-ABI object has undefined symbols:\n{undefined}"
    );

    let defined = Command::new("nm")
        .args(["-P"])
        .arg(&obj_path)
        .output()
        .unwrap_or_else(|e| panic!("nm failed: {e}"));
    let defined_text = String::from_utf8_lossy(&defined.stdout);
    for sym in ORB_EXPORTS.iter().chain(LEANSYS_EXPORTS.iter()) {
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
            "missing defined C-ABI export {sym}"
        );
    }

    let _ = fs::remove_file(&lib_path);
    let mut archived = false;
    for ar_tool in ["llvm-ar", "ar"] {
        if let Ok(st) = Command::new(ar_tool)
            .arg("rcs")
            .arg(&lib_path)
            .arg(&obj_path)
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
