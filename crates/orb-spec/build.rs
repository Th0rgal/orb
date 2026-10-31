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

fn kernel_backend() -> String {
    println!("cargo:rerun-if-env-changed=ORB_KERNEL_BACKEND");
    match env::var("ORB_KERNEL_BACKEND").as_deref() {
        Ok("leannative") => "leannative".to_string(),
        Ok("stock-c") | Err(_) => "stock-c".to_string(),
        Ok(other) => panic!("ORB_KERNEL_BACKEND must be stock-c or leannative, got {other}"),
    }
}

fn resolve_leannative_archive(root: &Path, archive: &Path) -> PathBuf {
    let candidate = if archive.is_absolute() || archive.is_file() {
        archive.to_path_buf()
    } else {
        let from_root = root.join(archive);
        if from_root.is_file() {
            from_root
        } else {
            archive.to_path_buf()
        }
    };
    fs::canonicalize(&candidate).unwrap_or_else(|e| {
        panic!(
            "ORB_LEANNATIVE_ARCHIVE does not exist or cannot be canonicalized ({}): {e}",
            archive.display()
        )
    })
}

fn build_leannative_object(root: &Path, out_dir: &Path, archive: &Path) -> PathBuf {
    println!("cargo:rerun-if-env-changed=ORB_LEANNATIVE_ARCHIVE");
    let archive = resolve_leannative_archive(root, archive);
    println!("cargo:rerun-if-changed={}", archive.display());
    let members = out_dir.join("leannative-members");
    let _ = fs::remove_dir_all(&members);
    fs::create_dir_all(&members)
        .unwrap_or_else(|e| panic!("failed to create {}: {e}", members.display()));
    let extracted = Command::new("ar")
        .arg("x")
        .arg(&archive)
        .current_dir(&members)
        .status()
        .unwrap_or_else(|e| panic!("failed to extract {}: {e}", archive.display()));
    assert!(
        extracted.success(),
        "ar could not extract {}",
        archive.display()
    );
    let mut objects: Vec<_> = fs::read_dir(&members)
        .unwrap()
        .filter_map(|entry| entry.ok().map(|item| item.path()))
        .filter(|path| path.extension().map(|ext| ext == "o").unwrap_or(false))
        .collect();
    assert!(
        objects.len() == 1,
        "LeanNative archive must contain exactly one object"
    );
    let native = objects.pop().unwrap();
    let shim_c = root.join("shared/orb-spec/cabi/orb_kernel_leannative_shim.c");
    println!("cargo:rerun-if-changed={}", shim_c.display());
    let shim_o = out_dir.join("orb_kernel_leannative_shim.o");
    let compiled = Command::new("cc")
        .args(["-O3", "-fPIC", "-Wall", "-Wextra", "-Werror", "-I"])
        .arg(root.join("shared/orb-spec/cabi"))
        .arg("-c")
        .arg(&shim_c)
        .arg("-o")
        .arg(&shim_o)
        .status()
        .unwrap_or_else(|e| panic!("failed to compile LeanNative shim: {e}"));
    assert!(compiled.success(), "LeanNative ABI shim failed to compile");
    let rebound = out_dir.join("orb_kernel_leannative_rebound.o");
    let redefined = Command::new("objcopy")
        .args([
            "--redefine-sym",
            "malloc=__orb_leannative_unreachable_malloc",
            "--redefine-sym",
            "memcpy=__orb_leannative_unreachable_memcpy",
        ])
        .arg(&native)
        .arg(&rebound)
        .status()
        .unwrap_or_else(|e| panic!("objcopy failed: {e}"));
    assert!(
        redefined.success(),
        "could not quarantine LeanNative malloc/memcpy imports"
    );
    let merged = out_dir.join("orb_kernel_leannative.o");
    let linked = Command::new("ld")
        .args(["-r"])
        .arg(&shim_o)
        .arg(&rebound)
        .arg("-o")
        .arg(&merged)
        .status()
        .unwrap_or_else(|e| panic!("ld -r failed: {e}"));
    assert!(linked.success(), "could not link LeanNative scalar shim");
    let mut keep = Command::new("objcopy");
    for name in artifact_symbols::EXPORTS {
        keep.arg(format!("--keep-global-symbol={name}"));
    }
    let hidden = keep
        .arg(&merged)
        .status()
        .unwrap_or_else(|e| panic!("objcopy failed: {e}"));
    assert!(hidden.success(), "could not hide LeanNative probe symbols");
    merged
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
    if kernel_backend() == "leannative" {
        let archive = env::var_os("ORB_LEANNATIVE_ARCHIVE")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                panic!("ORB_LEANNATIVE_ARCHIVE is required for ORB_KERNEL_BACKEND=leannative")
            });
        let native = build_leannative_object(root, out_dir, &archive);
        fs::copy(&native, &obj_path)
            .unwrap_or_else(|e| panic!("failed to stage LeanNative object: {e}"));
        artifact_symbols::verify_artifact(&obj_path, macos)
            .unwrap_or_else(|e| panic!("LeanNative object symbol verification failed: {e}"));
        archive_object(&obj_path, &lib_path);
        artifact_symbols::verify_artifact(&lib_path, macos)
            .unwrap_or_else(|e| panic!("LeanNative archive symbol verification failed: {e}"));
        println!("cargo:rustc-link-search=native={}", out_dir.display());
        println!("cargo:rustc-link-lib=static=orb_spec_cabi");
        return;
    }

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

    archive_object(&obj_path, &lib_path);
    artifact_symbols::verify_artifact(&lib_path, macos)
        .unwrap_or_else(|e| panic!("C-ABI archive symbol verification failed: {e}"));
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=orb_spec_cabi");
}

fn archive_object(obj_path: &Path, lib_path: &Path) {
    let _ = fs::remove_file(lib_path);
    let mut archived = false;
    for ar_tool in ["llvm-ar", "ar"] {
        if let Ok(st) = Command::new(ar_tool)
            .arg("rcs")
            .arg(lib_path)
            .arg(obj_path)
            .status()
        {
            if st.success() && lib_path.is_file() {
                archived = true;
                break;
            }
        }
    }
    assert!(archived, "failed to archive liborb_spec_cabi.a");
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
