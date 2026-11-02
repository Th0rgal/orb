use super::{evict_node_library_skill_uploads, remote_skill_prefix, REMOTE_LIBRARY_SKILL_UPLOADS};
use std::time::{Duration, Instant};

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

#[test]
fn library_skill_upload_cache_evicts_by_node_and_respects_ttl() {
    let node_a = "managed-test-a".to_string();
    let node_b = "ashur".to_string();
    let sha = "cd".repeat(32);
    {
        let mut cache = REMOTE_LIBRARY_SKILL_UPLOADS.lock().unwrap();
        cache.insert(
            (node_a.clone(), sha.clone()),
            ("/uploads/1/a.tar.gz".into(), Instant::now()),
        );
        cache.insert(
            (node_b.clone(), sha.clone()),
            (
                "/uploads/2/b.tar.gz".into(),
                Instant::now() - Duration::from_secs(crate::uploads::BATCH_OPEN_SECS),
            ),
        );
    }
    evict_node_library_skill_uploads(&node_a);
    let mut cache = REMOTE_LIBRARY_SKILL_UPLOADS.lock().unwrap();
    assert!(!cache.contains_key(&(node_a, sha.clone())));
    let ttl = Duration::from_secs(crate::uploads::BATCH_OPEN_SECS / 2);
    let (_, uploaded_at) = cache.get(&(node_b.clone(), sha.clone())).unwrap();
    assert!(uploaded_at.elapsed() >= ttl);
    cache.remove(&(node_b, sha));
}
