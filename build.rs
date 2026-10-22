use std::{env, fs, path::PathBuf, process::Command};

fn find_elan_tool(tool_name: &str) -> Option<PathBuf> {
    if let Ok(path_var) = env::var("PATH") {
        for dir in env::split_paths(&path_var) {
            let cand = dir.join(tool_name);
            if cand.is_file() {
                return Some(cand);
            }
        }
    }
    let mut roots = Vec::new();
    if let Ok(elan_home) = env::var("ELAN_HOME") {
        roots.push(PathBuf::from(elan_home));
    }
    if let Ok(home) = env::var("HOME") {
        roots.push(PathBuf::from(home).join(".elan"));
    }
    roots.push(PathBuf::from("/var/lib/sandboxed-node/caches/elan"));
    for root in roots {
        let bin_cand = root.join("bin").join(tool_name);
        if bin_cand.is_file() {
            return Some(bin_cand);
        }
        let tc_dir = root.join("toolchains");
        if let Ok(entries) = fs::read_dir(&tc_dir) {
            for entry in entries.flatten() {
                let cand = entry.path().join("bin").join(tool_name);
                if cand.is_file() {
                    return Some(cand);
                }
            }
        }
    }
    None
}

fn build_orb_spec_cabi(root: &PathBuf, out_dir: &PathBuf) {
    println!("cargo:rerun-if-changed=lean/Orb/Spec.lean");
    let spec_lean = root.join("lean/Orb/Spec.lean");
    let spec_c_path = out_dir.join("Orb_Spec_generated.c");
    if spec_lean.is_file() {
        if let Some(lean_bin) = find_elan_tool("lean") {
            let _ = Command::new(lean_bin)
                .arg(&spec_lean)
                .arg("-c")
                .arg(&spec_c_path)
                .status();
        }
    }
    let obj_path = out_dir.join("Orb_Spec.o");
    let lib_path = out_dir.join("liborb_spec_cabi.a");
    let mut compiled = false;
    if spec_c_path.is_file() {
        if let Some(leanc_bin) = find_elan_tool("leanc") {
            if let Ok(st) = Command::new(&leanc_bin)
                .args([
                    "-c",
                    "-O3",
                    "-fPIC",
                    "-ffunction-sections",
                    "-fdata-sections",
                ])
                .arg(&spec_c_path)
                .arg("-o")
                .arg(&obj_path)
                .status()
            {
                compiled = st.success() && obj_path.is_file();
            }
        }
    }
    if !compiled {
        let fallback_c = out_dir.join("Orb_Spec_fallback.c");
        let c_src = r#"
#include <stdint.h>
uint8_t orb_verify_writer_reuse(uint8_t has_cont, uint8_t cont_nonempty, uint8_t cont_matches, uint8_t has_edit, uint8_t work_changed, uint8_t id_updated) {
    if (has_cont == 1) return (cont_nonempty == 1 && cont_matches == 1 && has_edit == 0) ? 1 : 0;
    return (work_changed == 0 || id_updated == 1) ? 1 : 0;
}
uint8_t orb_verify_lease_mode(uint8_t writer_flag, uint8_t has_ro_tag, uint8_t has_wr_tag, uint8_t is_ro_intent) {
    if (writer_flag == 0 || has_ro_tag == 1) return 0;
    if (writer_flag == 1 || has_wr_tag == 1) return 1;
    return is_ro_intent == 1 ? 0 : 1;
}
uint8_t orb_verify_track_hold(uint8_t in_unresolved, uint8_t in_queued, uint8_t has_live, uint8_t native_holds) {
    return (in_unresolved == 1 || in_queued == 1 || has_live == 1 || native_holds == 1) ? 1 : 0;
}
uint8_t orb_verify_repo_disjoint(uint8_t handle_known, uint8_t target_known, uint8_t same_repo) {
    return (handle_known == 1 && target_known == 1 && same_repo == 0) ? 1 : 0;
}
uint8_t orb_verify_remote_outbox(uint8_t op_kind, uint8_t exists, uint8_t same_mission, uint8_t cancelled, uint8_t superseded, uint8_t session_ready, uint8_t pr_unsupported, uint8_t has_job, uint8_t abandonable) {
    if (op_kind == 0) {
        if (exists == 1) return (same_mission == 1 && cancelled == 0) ? 1 : 0;
        return (superseded == 0 && session_ready == 1 && pr_unsupported == 0) ? 1 : 0;
    }
    return (has_job == 0 || abandonable == 1) ? 1 : 0;
}
uint8_t orb_verify_board_slots(uint32_t max_parallel, uint32_t reserved_boss, uint32_t total_running) {
    return (reserved_boss >= 1U && reserved_boss < max_parallel && total_running < max_parallel - reserved_boss) ? 1 : 0;
}
uint8_t orb_verify_board_retry(uint32_t attempts, uint32_t max_attempts, uint8_t ext_rec, uint8_t merged, uint8_t ui_blocked) {
    return (attempts < max_attempts && max_attempts <= 2U && ext_rec == 0 && merged == 0 && ui_blocked == 0) ? 1 : 0;
}
uint8_t orb_verify_job_transition(uint8_t from_st, uint8_t to_st) {
    return ((from_st == 0 && to_st >= 1 && to_st <= 5) || (from_st == 1 && to_st >= 2 && to_st <= 5) || (from_st == 5 && to_st == 4)) ? 1 : 0;
}
uint8_t orb_verify_bundle_budget(uint8_t is_complete, uint64_t decoded_bytes, uint64_t overlay_cap, uint64_t complete_cap) {
    uint64_t limit = is_complete == 1 ? complete_cap : overlay_cap;
    return (decoded_bytes <= limit && decoded_bytes <= 52428800ULL) ? 1 : 0;
}
uint8_t orb_verify_token_rotation(uint8_t pres_nonempty, uint8_t match_curr, uint8_t prev_nonempty, uint8_t match_prev, uint8_t scope_ok) {
    return (pres_nonempty == 1 && (match_curr == 1 || (prev_nonempty == 1 && match_prev == 1)) && scope_ok == 1) ? 1 : 0;
}
uint8_t leansys_verify_log_window(uint64_t offset, uint64_t req_len, uint64_t max_chunk, uint64_t file_size, uint64_t actual_len) {
    return (offset <= file_size && req_len <= max_chunk && max_chunk <= 262144ULL && actual_len <= req_len && actual_len <= file_size - offset) ? 1 : 0;
}
uint64_t leansys_mix64_word(uint64_t acc, uint64_t word) {
    uint64_t v1 = acc + word * 0xBF58476D1CE4E5B9ULL;
    uint64_t v2 = (v1 << 31) | (v1 >> 33);
    uint64_t v3 = v2 * 0x9E3779B97F4A7C15ULL;
    return v3 ^ (v3 >> 27);
}
"#;
        fs::write(&fallback_c, c_src).unwrap();
        for compiler in ["clang", "cc", "gcc"] {
            if let Ok(st) = Command::new(compiler)
                .args(["-c", "-O3", "-fPIC"])
                .arg(&fallback_c)
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
    }
    assert!(compiled, "Failed to compile Orb.Spec C-ABI object");
    let mut archived = false;
    for ar_tool in ["llvm-ar", "ar"] {
        if let Some(ar_bin) = find_elan_tool(ar_tool).or_else(|| Some(PathBuf::from(ar_tool))) {
            let _ = fs::remove_file(&lib_path);
            if let Ok(st) = Command::new(ar_bin)
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
    }
    assert!(archived, "Failed to archive liborb_spec_cabi.a");
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=orb_spec_cabi");
}

fn main() {
    println!("cargo:rerun-if-changed=src");
    println!("cargo:rerun-if-changed=shared");
    println!("cargo:rerun-if-changed=build.rs");
    println!(
        "cargo:rustc-env=SOFTWARE_BUILD_ID={}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
    );
    println!("cargo:rerun-if-changed=catalog");
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    build_orb_spec_cabi(&root, &out_dir);
    let mut files: Vec<_> = fs::read_dir(root.join("catalog/snapshots"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .collect();
    files.sort();
    let mut generated = String::from("const BUNDLED: &[&str] = &[\n");
    for file in files {
        generated.push_str(&format!("include_str!({:?}),\n", file));
    }
    generated.push_str("];\n");
    fs::write(out_dir.join("model_snapshots.rs"), generated).unwrap();
}
