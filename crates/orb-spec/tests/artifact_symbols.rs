#[path = "../artifact_symbols.rs"]
mod symbols;

use std::{fs, process::Command};

fn listing() -> String {
    symbols::EXPORTS
        .iter()
        .map(|name| format!("{name} T 0 1\n"))
        .collect()
}

#[test]
fn missing_extra_duplicate_nontext_and_imported_symbols_fail() {
    let valid = listing();
    symbols::verify_listing(&valid, false).unwrap();
    symbols::verify_listing(&format!("archive[member]:\n{valid}"), false).unwrap();
    symbols::verify_listing(
        &format!("archive with spaces[member with spaces]:\n{valid}"),
        false,
    )
    .unwrap();
    symbols::verify_listing(
        &format!("archive with spaces(member with spaces):\n{valid}"),
        false,
    )
    .unwrap();
    for invalid in [
        valid.lines().skip(1).collect::<Vec<_>>().join("\n"),
        format!("{valid}injected T 0 1\n"),
        format!("{valid}{} T 0 1\n", symbols::EXPORTS[0]),
        valid.replacen(" T ", " D ", 1),
        format!("{valid}runtime_import U\n"),
        format!("{valid}optional_import w\n"),
        String::new(),
    ] {
        assert!(
            symbols::verify_listing(&invalid, false).is_err(),
            "{invalid}"
        );
    }
    let apple = symbols::EXPORTS
        .iter()
        .map(|name| format!("_{name} T 0 1\n"))
        .collect::<String>();
    symbols::verify_listing(&apple, true).unwrap();
    symbols::verify_listing(&format!("\norb_kernel_unboxed.o:\n{apple}"), true).unwrap();
    assert!(symbols::verify_listing(&apple, false).is_err());
}

#[test]
fn real_object_and_archive_mutations_are_rejected() {
    // Separate artifacts in an isolated directory; no fake engine is counted as conformance.
    let dir = std::env::temp_dir().join(format!("orb symbol test {}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let source = root.join("../../shared/orb-spec/cabi/orb_kernel_unboxed.c");
    let object = dir.join("kernel.o");
    let archive = dir.join("kernel.a");
    let compile = |src: &std::path::Path, obj: &std::path::Path| {
        assert!(Command::new("cc")
            .args(["-O2", "-c"])
            .arg("-I")
            .arg(source.parent().unwrap())
            .arg(src)
            .arg("-o")
            .arg(obj)
            .status()
            .unwrap()
            .success());
    };
    compile(&source, &object);
    let macos = cfg!(target_os = "macos");
    symbols::verify_artifact(&object, macos).unwrap();
    assert!(Command::new("ar")
        .arg("rcs")
        .arg(&archive)
        .arg(&object)
        .status()
        .unwrap()
        .success());
    symbols::verify_artifact(&archive, macos).unwrap();
    let modified = dir.join("modified.c");
    for text in [
        fs::read_to_string(&source).unwrap().replace("orb_mission_control_step", "missing_export"),
        format!("extern void external_runtime(void);\n{}", fs::read_to_string(&source).unwrap().replacen("{", "{ external_runtime();", 1)),
        format!("{}\nextern unsigned external_runtime(unsigned);\nunsigned injected(unsigned x) {{ return external_runtime(x); }}\n", fs::read_to_string(&source).unwrap()),
    ] {
        fs::write(&modified, text).unwrap();
        compile(&modified, &object);
        assert!(symbols::verify_artifact(&object, macos).is_err());
    }
    // A second complete owner in the archive must fail even when every name exists.
    compile(&source, &dir.join("second.o"));
    assert!(Command::new("ar")
        .arg("rcs")
        .arg(&archive)
        .arg(dir.join("second.o"))
        .status()
        .unwrap()
        .success());
    assert!(symbols::verify_artifact(&archive, macos).is_err());
    fs::write(&object, b"not an object").unwrap();
    assert!(symbols::verify_artifact(&object, macos).is_err());
    fs::remove_dir_all(dir).unwrap();
}
