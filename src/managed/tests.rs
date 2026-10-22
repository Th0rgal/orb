use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

fn settings() -> ManagedSettings {
    ManagedSettings {
        enabled: true,
        provider: "boat".into(),
        daily_cap_usd: 1.0,
        max_concurrent: 2,
        default_ttl_minutes: 120,
        max_ttl_minutes: 720,
        default_size: "small".into(),
        max_size: "xlarge".into(),
        image: "orb-node-base".into(),
        allowed_images: vec!["orb-node-base".into()],
        core_url: Some("https://core.example".into()),
        idle_minutes: 30,
        reconcile_secs: 300,
    }
}

#[derive(Default)]
struct FakeProvider {
    created: AtomicUsize,
    destroyed: std::sync::Mutex<Vec<String>>,
    listed: std::sync::Mutex<Vec<ProviderMachine>>,
}

#[async_trait]
impl ManagedProvider for FakeProvider {
    fn name(&self) -> &'static str {
        "fake"
    }
    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let n = self.created.fetch_add(1, Ordering::SeqCst);
        Ok(ProviderMachine {
            provider_id: format!("bx_fake{n}"),
            state: "ready".into(),
            name: spec.name.clone(),
        })
    }
    async fn get(&self, provider_id: &str) -> Result<ProviderMachine, String> {
        Ok(ProviderMachine {
            provider_id: provider_id.into(),
            state: "ready".into(),
            name: String::new(),
        })
    }
    async fn list(&self) -> Result<Vec<ProviderMachine>, String> {
        Ok(self.listed.lock().unwrap().clone())
    }
    async fn destroy(&self, provider_id: &str) -> Result<(), String> {
        self.destroyed.lock().unwrap().push(provider_id.into());
        Ok(())
    }
    async fn extend(&self, _: &str, _: u64) -> Result<(), String> {
        Ok(())
    }
    async fn write_file(&self, _: &str, _: &str, _: &str) -> Result<(), String> {
        Ok(())
    }
    async fn exec(&self, _: &str, _: &str, _: u64) -> Result<Value, String> {
        Ok(Value::Null)
    }
    async fn usage(&self, _: &str) -> Result<ProviderUsage, String> {
        Ok(ProviderUsage {
            dollars: 0.0012,
            seconds: 240,
            running: false,
        })
    }
}

#[test]
fn plan_picks_default_and_smallest_fitting_size() {
    let s = settings();
    let (spec, ttl) = ManagedManager::plan(&s, &SpawnRequest::default()).unwrap();
    assert_eq!((spec.size, ttl), ("small", 120));
    let req = SpawnRequest {
        cpu: Some(6),
        ram_gb: Some(10),
        ..Default::default()
    };
    assert_eq!(ManagedManager::plan(&s, &req).unwrap().0.size, "large");
    let req = SpawnRequest {
        ram_gb: Some(64),
        ..Default::default()
    };
    assert_eq!(
        ManagedManager::plan(&s, &req).unwrap_err().error,
        "invalid_size"
    );
    let req = SpawnRequest {
        size: Some("small".into()),
        cpu: Some(4),
        ..Default::default()
    };
    assert_eq!(
        ManagedManager::plan(&s, &req).unwrap_err().error,
        "invalid_size"
    );
}

#[test]
fn plan_enforces_max_size_and_ttl_bounds() {
    let mut s = settings();
    s.max_size = "default".into();
    let req = SpawnRequest {
        size: Some("xlarge".into()),
        ..Default::default()
    };
    assert_eq!(
        ManagedManager::plan(&s, &req).unwrap_err().error,
        "size_not_allowed"
    );
    let req = SpawnRequest {
        ttl_minutes: Some(10_000),
        ..Default::default()
    };
    assert_eq!(ManagedManager::plan(&s, &req).unwrap().1, 720);
    let req = SpawnRequest {
        ttl_minutes: Some(1),
        ..Default::default()
    };
    assert_eq!(ManagedManager::plan(&s, &req).unwrap().1, 5);
}

fn manager(dir: &std::path::Path, s: ManagedSettings) -> (Arc<ManagedManager>, Arc<FakeProvider>) {
    let fake = Arc::new(FakeProvider::default());
    let m = Arc::new(ManagedManager::new(
        s,
        Some(fake.clone() as Arc<dyn ManagedProvider>),
        dir,
        3999,
    ));
    (m, fake)
}

#[tokio::test]
async fn budget_and_concurrency_are_hard_refusals() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    // xlarge for 12 h = $2.40 > $1 cap.
    let e = m
        .spawn(SpawnRequest {
            size: Some("xlarge".into()),
            ttl_minutes: Some(720),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(e.error, "budget_exceeded");
    for _ in 0..2 {
        m.spawn(SpawnRequest {
            wait: Some(false),
            ttl_minutes: Some(30),
            ..Default::default()
        })
        .await
        .unwrap();
    }
    let e = m
        .spawn(SpawnRequest {
            wait: Some(false),
            ttl_minutes: Some(30),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(e.error, "quota_exceeded");
}

#[tokio::test]
async fn enrollment_token_is_single_use_and_destroy_closes_ledger() {
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    let machine = m
        .spawn(SpawnRequest {
            wait: Some(false),
            ttl_minutes: Some(30),
            ..Default::default()
        })
        .await
        .unwrap();
    // Wait for provision() to mint its own token, then plant a known one.
    for _ in 0..100 {
        if m.get(&machine.id).await.unwrap().state == MachineState::Enrolling {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    {
        let mut secrets = m.secrets.lock().await;
        let e = secrets.entry(machine.id.clone()).or_default();
        e.enroll_token_sha256 = Some(sha256_hex("tok"));
        e.enroll_expires_at = Some(Utc::now() + chrono::Duration::minutes(10));
        e.enroll_used = false;
    }
    assert!(m.enroll(&machine.id, "wrong").await.is_err());
    let (node_id, token) = m.enroll(&machine.id, "tok").await.unwrap();
    assert_eq!(node_id, format!("managed-{}", machine.id));
    assert!(m.enroll(&machine.id, "tok").await.is_err(), "single use");
    assert!(node_config(&node_id).is_some());
    assert_eq!(
        node_token(&node_config(&node_id).unwrap().token_env).as_deref(),
        Some(token.as_str())
    );
    assert!(m.machine_for_token(&machine.id, &token).await.is_some());

    // Let the background provision task record a provider id.
    for _ in 0..50 {
        if m.get(&machine.id).await.unwrap().provider_id.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let done = m.destroy(&machine.id, "test").await.unwrap();
    assert_eq!(done.state, MachineState::Destroyed);
    assert!(done.ledger_closed);
    assert!((done.cost_usd - 0.0012).abs() < 1e-9);
    assert!(node_config(&node_id).is_none());
    assert!(m.machine_for_token(&machine.id, &token).await.is_none());
    assert!(!fake.destroyed.lock().unwrap().is_empty());

    // Persisted and reloadable; secrets file is separate.
    let reloaded = ManagedManager::new(settings(), None, dir.path(), 3999);
    reloaded.load().await;
    assert_eq!(
        reloaded.get(&machine.id).await.unwrap().state,
        MachineState::Destroyed
    );
    let public =
        std::fs::read_to_string(dir.path().join(".sandboxed-sh/managed_machines.json")).unwrap();
    assert!(!public.contains(&token));
}

#[tokio::test]
async fn reconcile_stops_tagged_orphans_only() {
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    *fake.listed.lock().unwrap() = vec![
        ProviderMachine {
            provider_id: "bx_orphan1".into(),
            state: "ready".into(),
            name: "orb-managed-mmzzzz".into(),
        },
        ProviderMachine {
            provider_id: "bx_research".into(),
            state: "ready".into(),
            name: "autoresearch run".into(),
        },
        ProviderMachine {
            provider_id: "bx_old".into(),
            state: "archived".into(),
            name: "orb-managed-mmold".into(),
        },
    ];
    let report = m.reconcile_once().await.unwrap();
    assert_eq!(report["orphans_stopped"], serde_json::json!(["bx_orphan1"]));
    assert_eq!(
        *fake.destroyed.lock().unwrap(),
        vec!["bx_orphan1".to_string()]
    );
}

#[tokio::test]
async fn ttl_expiry_destroys() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let machine = m
        .spawn(SpawnRequest {
            wait: Some(false),
            ttl_minutes: Some(30),
            ..Default::default()
        })
        .await
        .unwrap();
    m.update(&machine.id, |m| {
        m.expires_at = Utc::now() - chrono::Duration::seconds(1)
    })
    .await;
    m.reap_once().await;
    let after = m.get(&machine.id).await.unwrap();
    assert!(!after.state.is_live());
    assert_eq!(after.destroy_reason.as_deref(), Some("ttl_expired"));
}

#[tokio::test]
async fn relay_round_trip() {
    let hub = relay::RelayHub::default();
    let hub = Arc::new(hub);
    // Not connected yet: refused like a TCP connect.
    let req = relay::RelayRequest {
        id: "r1".into(),
        method: "GET".into(),
        path: "/heartbeat".into(),
        headers: vec![],
        body_b64: String::new(),
        timeout_secs: 0,
    };
    assert!(matches!(
        hub.call("mm1", req.clone(), Duration::from_secs(1)).await,
        Err(relay::RelayError::NodeNotConnected)
    ));
    assert!(hub
        .poll("mm1", Duration::from_millis(10), 8)
        .await
        .is_empty());
    let h2 = Arc::clone(&hub);
    let node = tokio::spawn(async move {
        let reqs = h2.poll("mm1", Duration::from_secs(5), 8).await;
        assert_eq!(reqs.len(), 1);
        h2.respond(
            "mm1",
            relay::RelayResponse {
                id: reqs[0].id.clone(),
                status: 200,
                headers: vec![],
                body_b64: "e30=".into(),
            },
        )
        .await
    });
    let resp = match hub.call("mm1", req, Duration::from_secs(5)).await {
        Ok(r) => r,
        Err(_) => panic!("relay call failed"),
    };
    assert_eq!(resp.status, 200);
    assert!(node.await.unwrap());
}

/// Real boat.dev round trip, gated: `BOAT_E2E=1 BOAT_API_KEY=… cargo test --lib managed::tests::boat_e2e`.
/// Spawns a `small` sandbox (noEnv, 15 min TTL), execs, writes a file,
/// destroys it and checks the usage ledger closes. Cost < $0.001.
#[tokio::test]
async fn boat_e2e_provider_round_trip() {
    if std::env::var("BOAT_E2E").ok().as_deref() != Some("1") {
        eprintln!("skipped: set BOAT_E2E=1");
        return;
    }
    let provider = boat::BoatProvider::from_env().expect("BOAT_API_KEY");
    let tag = format!("{SANDBOX_NAME_PREFIX}e2e{}", random_id());
    let spec = SpawnSpec {
        size: "small".into(),
        ttl_seconds: 900,
        image: None,
        name: tag.clone(),
        idempotency_key: tag.clone(),
    };
    let created = provider.spawn(&spec).await.expect("spawn");
    let id = created.provider_id.clone();
    let mut ready = false;
    for _ in 0..90 {
        if boat::is_ready_state(&provider.get(&id).await.expect("get").state) {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    let result = async {
        assert!(ready, "sandbox never became ready");
        provider
            .write_file(&id, "/home/user/.orb/e2e.txt", "hello")
            .await?;
        let out = provider
            .exec(&id, "cat /home/user/.orb/e2e.txt && nproc", 60)
            .await?;
        assert!(out.to_string().contains("hello"), "{out}");
        let listed = provider.list().await?;
        assert!(listed.iter().any(|m| m.provider_id == id && m.name == tag));
        Ok::<_, String>(())
    }
    .await;
    provider.destroy(&id).await.expect("destroy");
    result.expect("round trip");
    let mut closed = false;
    for _ in 0..30 {
        let usage = provider.usage(&id).await.expect("usage");
        if !usage.running {
            closed = true;
            assert!(usage.dollars < 0.01);
            break;
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    assert!(closed, "usage still running after destroy");
    let still = provider.get(&id).await.map(|m| m.state).unwrap_or_default();
    assert!(
        boat::is_stopped_state(&still) || still.is_empty(),
        "state {still}"
    );
}

#[test]
fn only_allowlisted_images_are_accepted() {
    let s = settings();
    assert_eq!(
        ManagedManager::resolve_image(&s, None).unwrap(),
        "orb-node-base"
    );
    assert_eq!(
        ManagedManager::resolve_image(&s, Some(" ")).unwrap(),
        "orb-node-base"
    );
    assert_eq!(
        ManagedManager::resolve_image(&s, Some("orb-node-base")).unwrap(),
        "orb-node-base"
    );
    assert_eq!(
        ManagedManager::resolve_image(&s, Some("someone-elses-snapshot"))
            .unwrap_err()
            .error,
        "image_unknown"
    );
}

#[tokio::test]
async fn spawn_rejects_unlisted_image() {
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    let e = m
        .spawn(SpawnRequest {
            image: Some("research-xlarge-16gb".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(e.error, "image_unknown");
    assert_eq!(fake.created.load(Ordering::SeqCst), 0);
}

#[test]
fn managed_nodes_are_excluded_from_static_lookup() {
    let machine = ManagedMachine {
        id: "mmtrust01".into(),
        provider: "fake".into(),
        provider_id: None,
        node_id: "managed-mmtrust01".into(),
        image: "orb-node-base".into(),
        size: "small".into(),
        cpu: 2,
        ram_gb: 4,
        disk_gb: 12,
        usd_per_hour: 0.018,
        state: MachineState::Online,
        created_at: Utc::now(),
        expires_at: Utc::now(),
        online_at: None,
        destroyed_at: None,
        destroy_reason: None,
        cost_usd: 0.0,
        cost_is_metered: false,
        owner_mission_id: None,
        owner_user_id: None,
        reason: None,
        error: None,
        ledger_closed: false,
        last_busy_at: None,
    };
    register_node(&machine, 3999, "tok");
    let settings = crate::remote_node::RemoteNodeSettings {
        enabled: true,
        nodes: vec![],
    };
    // Job placement may resolve it by explicit id ...
    assert!(settings.node("managed-mmtrust01").is_some());
    // ... but credential-bearing paths use static_node and never see it.
    assert!(settings.static_node("managed-mmtrust01").is_none());
    assert!(is_managed_node("managed-mmtrust01"));
    // Token lives in memory, never in the process environment.
    assert!(std::env::var(token_env_for("mmtrust01")).is_err());
    unregister_node(&machine);
    assert!(settings.node("managed-mmtrust01").is_none());
}

fn probe_from(map: std::collections::HashMap<String, OwnerState>) -> OwnerProbe {
    let map = Arc::new(map);
    // Models the routes.rs probe: only tenant "t1" has a loaded store; any
    // other tenant is unknown (None) and must never cause a destroy.
    Arc::new(move |tenant: String, id: String| {
        let map = Arc::clone(&map);
        Box::pin(async move {
            if tenant != "t1" {
                return None;
            }
            Some(map.get(&id).copied().unwrap_or(OwnerState::Missing))
        })
    })
}

async fn online_machine(m: &Arc<ManagedManager>, owner: &str) -> ManagedMachine {
    let machine = m
        .spawn(SpawnRequest {
            wait: Some(false),
            ttl_minutes: Some(60),
            owner_mission_id: Some(owner.to_string()),
            owner_user_id: Some("t1".to_string()),
            ..Default::default()
        })
        .await
        .unwrap();
    // Let the background provisioner record the provider id, then mark online.
    for _ in 0..100 {
        if m.get(&machine.id).await.unwrap().provider_id.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    m.update(&machine.id, |x| {
        x.state = MachineState::Online;
        x.last_busy_at = Some(Utc::now());
    })
    .await
    .unwrap()
}

#[test]
fn owner_status_mapping() {
    for s in ["completed", "failed", "not_feasible", "acknowledged"] {
        assert_eq!(owner_state_for_status(s), OwnerState::Terminal, "{s}");
    }
    // Deploy restarts interrupt missions that are then resumed; keep their VMs.
    for s in [
        "active",
        "pending",
        "awaiting_user",
        "interrupted",
        "blocked",
        "paused",
        "waiting_background",
    ] {
        assert_eq!(owner_state_for_status(s), OwnerState::Live, "{s}");
    }
}

#[tokio::test]
async fn machine_is_destroyed_when_owner_ends_and_kept_while_owner_lives() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let live = online_machine(&m, "owner-live").await;
    let done = online_machine(&m, "owner-done").await;
    let gone_m = {
        // Raise the cap: three machines.
        m.update(&done.id, |_| {}).await;
        done.clone()
    };
    let mut map = std::collections::HashMap::new();
    map.insert("owner-live".to_string(), OwnerState::Live);
    map.insert("owner-done".to_string(), OwnerState::Terminal);
    m.set_owner_probe(probe_from(map));
    m.reap_once().await;
    assert_eq!(m.get(&live.id).await.unwrap().state, MachineState::Online);
    let after = m.get(&gone_m.id).await.unwrap();
    assert_eq!(after.state, MachineState::Destroyed);
    assert_eq!(after.destroy_reason.as_deref(), Some("owner_ended"));
    assert!(after.ledger_closed);
}

#[tokio::test]
async fn deleted_owner_destroys_and_adoption_keeps_machine() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let a = online_machine(&m, "deleted-parent").await;
    let b = online_machine(&m, "finished-parent").await;
    // A live child took b over (e.g. via extend_managed_machine).
    m.adopt(&b.id, "live-child").await.unwrap();
    let mut map = std::collections::HashMap::new();
    map.insert("finished-parent".to_string(), OwnerState::Terminal);
    map.insert("live-child".to_string(), OwnerState::Live);
    m.set_owner_probe(probe_from(map)); // deleted-parent -> Missing
    m.reap_once().await;
    assert_eq!(m.get(&a.id).await.unwrap().state, MachineState::Destroyed);
    let kept = m.get(&b.id).await.unwrap();
    assert_eq!(kept.state, MachineState::Online);
    assert_eq!(kept.owner_mission_id.as_deref(), Some("live-child"));
}

#[tokio::test]
async fn unknown_owner_status_keeps_machine() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let a = online_machine(&m, "unknowable").await;
    m.set_owner_probe(Arc::new(|_t: String, _id: String| Box::pin(async { None })));
    m.reap_once().await;
    assert_eq!(m.get(&a.id).await.unwrap().state, MachineState::Online);
}

#[tokio::test]
async fn store_miss_in_unknown_tenant_never_destroys() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.max_concurrent = 4;
    let (m, _) = manager(dir.path(), s);
    // Owner mission lives in another tenant whose store is not loaded.
    let foreign = online_machine(&m, "foreign-mission").await;
    m.update(&foreign.id, |x| x.owner_user_id = Some("t2".into()))
        .await;
    // Legacy row without a recorded tenant.
    let legacy = online_machine(&m, "legacy-mission").await;
    m.update(&legacy.id, |x| x.owner_user_id = None).await;
    // Terminal owner in the known tenant.
    let ended = online_machine(&m, "ended-mission").await;
    let mut map = std::collections::HashMap::new();
    map.insert("ended-mission".to_string(), OwnerState::Terminal);
    m.set_owner_probe(probe_from(map)); // foreign/legacy would be "Missing" in t1
    m.reap_once().await;
    assert_eq!(
        m.get(&foreign.id).await.unwrap().state,
        MachineState::Online
    );
    assert_eq!(m.get(&legacy.id).await.unwrap().state, MachineState::Online);
    assert_eq!(
        m.get(&ended.id).await.unwrap().state,
        MachineState::Destroyed
    );
}

#[test]
fn managed_jobs_may_use_most_of_the_vm_memory() {
    // xlarge (32 GB) must fit a 20 GB job; small keeps headroom for the OS.
    assert!(managed_job_memory_bytes(32) > 20 * 1024 * 1024 * 1024);
    assert_eq!(managed_job_memory_bytes(4), 4 * 1024 * 1024 * 1024 * 9 / 10);
}
