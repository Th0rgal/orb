use super::remote_skill_prefix;

#[test]
fn remote_skill_prefix_orders_library_around_project_skills() {
    let without = remote_skill_prefix("/src", "codex", None);
    assert!(without.contains("sandboxed-library-skills cleanup 'codex'"));
    assert!(!without.contains("sandboxed-library-skills install"));
    let archive = ("/node/uploads/x/a.tar.gz".to_string(), "ab".repeat(32));
    let with = remote_skill_prefix("/src", "codex", Some(&archive));
    let cleanup = with.find("sandboxed-library-skills cleanup").unwrap();
    let project = with.find("' orb-project-skills '").unwrap();
    let install = with.find("sandboxed-library-skills install").unwrap();
    assert!(cleanup < project && project < install);
    // Project skills stay strict; Library steps never abort the job.
    assert!(with[project..install].contains("|| exit 78"));
    assert!(!with[install..].contains("exit 78"));
    // The Python program is embedded once and referenced by variable.
    assert_eq!(
        with.matches("Install Library skills as native copies")
            .count(),
        1
    );
}
