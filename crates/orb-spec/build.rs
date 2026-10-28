use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

mod artifact_symbols;

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

    artifact_symbols::verify_artifact(&obj_path, macos)
        .unwrap_or_else(|e| panic!("C-ABI object symbol verification failed: {e}"));

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
    artifact_symbols::verify_artifact(&lib_path, macos)
        .unwrap_or_else(|e| panic!("C-ABI archive symbol verification failed: {e}"));
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=orb_spec_cabi");
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=artifact_symbols.rs");
    println!("cargo:rerun-if-changed=../../shared/orb-spec/cabi/orb_kernel_exports.rs");
    println!("cargo:rerun-if-changed=src/lib.rs");
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let root = manifest_dir
        .parent()
        .and_then(|p| p.parent())
        .expect("crates/orb-spec sits two levels below workspace root");
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    build_orb_spec_cabi(root, &out_dir);
}
