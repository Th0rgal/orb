use std::env;
use std::path::PathBuf;
use std::process::Command;

const REQUIRED_EXPORTS: &[&str] = &[
    "leanmesh_ratchet_epoch_step",
    "leanmesh_eval_route_step",
    "leanmesh_replay_window_step",
    "leanmesh_replay_window_next_max",
    "leanmesh_replay_window_next_bitmap",
    "leanmesh_endpoint_roam_step",
    "leanmesh_relay_select_step",
    "leanmesh_bunker_isolate_step",
    "leanmesh_frame_bounds_step",
    "leanmesh_overlay_ip_step",
    "leanmesh_reconcile_wg_step",
    "leanmesh_jit_lease_step",
];

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let lean_dir = manifest_dir.join("lean");
    let cabi_c = manifest_dir.join("cabi/lean_mesh_kernel_unboxed.c");
    let cabi_h = manifest_dir.join("cabi/lean_mesh_kernel.h");
    let abi_json = manifest_dir.join("cabi/kernel_abi.json");

    println!("cargo:rerun-if-changed={}", cabi_c.display());
    println!("cargo:rerun-if-changed={}", cabi_h.display());
    println!("cargo:rerun-if-changed={}", abi_json.display());
    println!(
        "cargo:rerun-if-changed={}",
        lean_dir.join("LeanMesh/Kernel.lean").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        lean_dir.join("LeanMesh/Spec.lean").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        lean_dir.join("audit/AuditSpec.lean").display()
    );
    println!("cargo:rerun-if-env-changed=LEAN_MESH_VERIFY_LEAN");

    if env::var("LEAN_MESH_VERIFY_LEAN").as_deref() == Ok("1") {
        let out_lean = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR")).join("lean_verify");
        std::fs::create_dir_all(out_lean.join("LeanMesh")).expect("mkdir lean_verify");

        let status_k = Command::new("lean")
            .current_dir(&lean_dir)
            .env("LEAN_PATH", &out_lean)
            .args([
                "-DwarningAsError=true",
                "-DautoImplicit=false",
                "LeanMesh/Kernel.lean",
                "-o",
            ])
            .arg(out_lean.join("LeanMesh/Kernel.olean"))
            .status()
            .expect("Failed to execute `lean` on LeanMesh/Kernel.lean");
        assert!(
            status_k.success(),
            "LeanMesh/Kernel.lean verification failed"
        );

        let status_s = Command::new("lean")
            .current_dir(&lean_dir)
            .env("LEAN_PATH", &out_lean)
            .args([
                "-DwarningAsError=true",
                "-DautoImplicit=false",
                "LeanMesh/Spec.lean",
                "-o",
            ])
            .arg(out_lean.join("LeanMesh/Spec.olean"))
            .status()
            .expect("Failed to execute `lean` on LeanMesh/Spec.lean");
        assert!(status_s.success(), "LeanMesh/Spec.lean verification failed");

        let status_a = Command::new("lean")
            .current_dir(&lean_dir)
            .env("LEAN_PATH", &out_lean)
            .args(["--run", "audit/AuditSpec.lean"])
            .status()
            .expect("Failed to execute `lean --run audit/AuditSpec.lean`");
        assert!(status_a.success(), "audit/AuditSpec.lean failed");
    }

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let obj_path = out_dir.join("lean_mesh_kernel_unboxed.o");
    let lib_path = out_dir.join("liblean_mesh_cabi.a");
    let cc = env::var("CC").unwrap_or_else(|_| "cc".to_string());

    let cc_status = Command::new(&cc)
        .args([
            "-O3",
            "-fPIC",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-ffunction-sections",
            "-fdata-sections",
            "-I",
        ])
        .arg(manifest_dir.join("cabi"))
        .arg("-c")
        .arg(&cabi_c)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("Failed to compile cabi/lean_mesh_kernel_unboxed.c");
    assert!(
        cc_status.success(),
        "C compiler failed on cabi/lean_mesh_kernel_unboxed.c"
    );

    let nm_undef = Command::new("nm")
        .args(["-P", "-u"])
        .arg(&obj_path)
        .output()
        .expect("Failed to run `nm -P -u`");
    assert!(nm_undef.status.success(), "`nm -P -u` failed");
    let undef_str = String::from_utf8_lossy(&nm_undef.stdout);
    let undef_syms: Vec<&str> = undef_str
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect();
    assert!(
        undef_syms.is_empty(),
        "FATAL: lean_mesh_kernel_unboxed.o has undefined external symbols: {:?}",
        undef_syms
    );

    let nm_def = Command::new("nm")
        .args(["-P", "-g"])
        .arg(&obj_path)
        .output()
        .expect("Failed to run `nm -P -g`");
    assert!(nm_def.status.success(), "`nm -P -g` failed");
    let def_str = String::from_utf8_lossy(&nm_def.stdout);
    for req in REQUIRED_EXPORTS {
        let found = def_str.lines().any(|line| {
            let parts: Vec<&str> = line.split_whitespace().collect();
            parts.len() >= 2
                && (parts[0] == *req || parts[0] == format!("_{req}"))
                && parts[1] == "T"
        });
        assert!(
            found,
            "FATAL: required C-ABI symbol `{req}` missing from lean_mesh_kernel_unboxed.o"
        );
    }

    let ar_status = Command::new("ar")
        .args(["rcs"])
        .arg(&lib_path)
        .arg(&obj_path)
        .status()
        .expect("Failed to run `ar rcs`");
    assert!(ar_status.success(), "`ar rcs` failed");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=lean_mesh_cabi");
}
