use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

fn settings() -> ManagedSettings {
    ManagedSettings {
        enabled: true,
        provider: "boat".into(),
        daily_cap_usd: Some(1.0),
        max_concurrent: Some(2),
        default_ttl_minutes: 120,
        max_ttl_minutes: 720,
        default_size: "small".into(),
        max_size: "xlarge".into(),
        image: "orb-node-base".into(),
        allowed_images: vec!["orb-node-base".into()],
        raw_allowed_images: vec!["clean".into()],
        core_url: Some("https://core.example".into()),
        idle_minutes: 30,
        working_idle_minutes: 0,
        post_job_idle_minutes: 5,
        owner_grace_minutes: 0,
        waiting_grace_minutes: 60,
        orphan_grace_minutes: 0,
        reconcile_secs: 300,
        auto_extend_minutes: 30,
        stopped_retention_hours: 24,
        snapshot_keep: 2,
        snapshot_unused_days: 14,
    }
}

fn live_reaper(m: &ManagedManager) {
    m.set_runtime_settings(RuntimeSettings {
        antigravity_on_managed: true,
        reaper_dry_run: false,
        ..Default::default()
    });
}

#[derive(Default)]
struct FakeProvider {
    created: AtomicUsize,
    destroyed: std::sync::Mutex<Vec<String>>,
    listed: std::sync::Mutex<Vec<ProviderMachine>>,
    execs: std::sync::Mutex<Vec<String>>,
    writes: AtomicUsize,
    forks: std::sync::Mutex<Vec<String>>,
    stopped: std::sync::Mutex<Vec<String>>,
    saved: std::sync::Mutex<Vec<(String, String)>>,
    deleted_snapshots: std::sync::Mutex<Vec<String>>,
    fail_wipe: std::sync::atomic::AtomicBool,
}

#[async_trait]
impl ManagedProvider for FakeProvider {
    fn name(&self) -> &'static str {
        "fake"
    }
    fn supports_free_stop(&self) -> bool {
        true
    }
    fn supports_snapshots(&self) -> bool {
        true
    }
    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        let n = self.created.fetch_add(1, Ordering::SeqCst);
        Ok(ProviderMachine {
            provider_id: format!("bx_fake{n}"),
            state: "ready".into(),
            name: spec.name.clone(),
            deletable_at: None,
        })
    }
    async fn get(&self, provider_id: &str) -> Result<ProviderMachine, String> {
        Ok(ProviderMachine {
            provider_id: provider_id.into(),
            state: "ready".into(),
            name: String::new(),
            deletable_at: None,
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
        self.writes.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
    async fn exec(&self, _: &str, command: &str, _: u64) -> Result<Value, String> {
        self.execs.lock().unwrap().push(command.to_string());
        if command.contains(".paloma-secrets") && self.fail_wipe.load(Ordering::SeqCst) {
            return Ok(serde_json::json!({"exitCode": 1}));
        }
        Ok(Value::Null)
    }
    async fn raw_exec(
        &self,
        provider_id: &str,
        command: &str,
        timeout_secs: u64,
    ) -> Result<Value, String> {
        self.exec(provider_id, command, timeout_secs).await
    }
    async fn raw_write_file(
        &self,
        provider_id: &str,
        path: &str,
        content: &str,
    ) -> Result<(), String> {
        self.write_file(provider_id, path, content).await
    }
    async fn stop(&self, provider_id: &str) -> Result<(), String> {
        self.stopped.lock().unwrap().push(provider_id.into());
        Ok(())
    }
    async fn fork(&self, provider_id: &str, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        self.forks.lock().unwrap().push(provider_id.into());
        self.spawn(spec).await
    }
    async fn save_snapshot(&self, provider_id: &str, name: &str) -> Result<(), String> {
        self.saved
            .lock()
            .unwrap()
            .push((provider_id.into(), name.into()));
        Ok(())
    }
    async fn snapshot(&self, name: &str) -> Result<ProviderSnapshot, String> {
        Ok(ProviderSnapshot {
            name: name.into(),
            status: "ready".into(),
            size_bytes: Some(1),
        })
    }
    async fn delete_snapshot(&self, name: &str) -> Result<(), String> {
        self.deleted_snapshots.lock().unwrap().push(name.into());
        Ok(())
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
    live_reaper(&m);
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
            deletable_at: None,
        },
        ProviderMachine {
            provider_id: "bx_research".into(),
            state: "ready".into(),
            name: "autoresearch run".into(),
            deletable_at: None,
        },
        ProviderMachine {
            provider_id: "bx_old".into(),
            state: "archived".into(),
            name: "orb-managed-mmold".into(),
            deletable_at: None,
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
        machine_id: tag.clone(),
        size: "small".into(),
        cpu: 2,
        ram_gb: 4,
        gpu: None,
        arch: None,
        max_hourly_usd: None,
        preferred_offer_id: None,
        exclude_offer_ids: Vec::new(),
        ttl_seconds: 900,
        image: None,
        name: tag.clone(),
        idempotency_key: tag.clone(),
        bootstrap_script: None,
        allow_24h_commitment: false,
        provisioning_mode: ProvisioningMode::Worker,
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
        provisioning_mode: ProvisioningMode::Worker,
        name: "small-z".into(),
        antigravity_projected: false,
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
        owner_kind: None,
        requested_by_mission_id: None,
        reap_at: None,
        reap_reason: None,
        reason: None,
        error: None,
        ledger_closed: false,
        last_busy_at: None,
        budget_pool_id: None,
        cap_pool_id: None,
        auto_extensions: 0,
        prior_pool_charges: Vec::new(),
        pool_spent_offset: 0.0,
        stopped_at: None,
        stopped_by_reaper: false,
        source_snapshot: None,
        forked_from: None,
        fork_source_provider_id: None,
        resumes: 0,
        run_started_at: None,
        cost_before_resume: 0.0,
        secrets_wiped: false,
        project: None,
        root_mission_id: None,
        active_mission_ids: Vec::new(),
        deletable_at: None,
        has_executed_job: false,
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
    online_machine_sized(m, owner, None).await
}

async fn online_machine_sized(
    m: &Arc<ManagedManager>,
    owner: &str,
    size: Option<&str>,
) -> ManagedMachine {
    let machine = m
        .spawn(SpawnRequest {
            size: size.map(str::to_string),
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
    map.insert("owner-live".to_string(), OwnerState::Working);
    map.insert(
        "owner-done".to_string(),
        OwnerState::Terminal {
            status: "completed",
        },
    );
    m.set_owner_probe(probe_from(map));
    m.reap_once().await;
    assert_eq!(m.get(&live.id).await.unwrap().state, MachineState::Online);
    let after = m.get(&gone_m.id).await.unwrap();
    assert_eq!(after.state, MachineState::Destroyed);
    assert_eq!(after.destroy_reason.as_deref(), Some("owner_completed"));
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
    map.insert(
        "finished-parent".to_string(),
        OwnerState::Terminal {
            status: "completed",
        },
    );
    map.insert("live-child".to_string(), OwnerState::Working);
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
    s.max_concurrent = Some(4);
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
    map.insert(
        "ended-mission".to_string(),
        OwnerState::Terminal {
            status: "completed",
        },
    );
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

#[test]
fn names_reuse_the_lowest_free_letter_and_roll_over_after_z() {
    assert_eq!(allocate_name("small", &[]), "small-a");
    let live = vec!["small-a".to_string(), "small-b".to_string()];
    assert_eq!(allocate_name("small", &live), "small-c");
    // small-a destroyed -> reused.
    assert_eq!(allocate_name("small", &["small-b".to_string()]), "small-a");
    // Sizes are independent.
    assert_eq!(allocate_name("large", &live), "large-a");
    assert_eq!(allocate_name("default", &[]), "medium-a");
    let mut all: Vec<String> = (b'a'..=b'z')
        .map(|c| format!("small-{}", c as char))
        .collect();
    assert_eq!(allocate_name("small", &all), "small-a1");
    all.push("small-a1".into());
    assert_eq!(allocate_name("small", &all), "small-b1");
}

#[tokio::test]
async fn machines_get_unique_names_targetable_until_destroyed() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.max_concurrent = Some(4);
    s.daily_cap_usd = Some(100.0);
    let (m, _) = manager(dir.path(), s);
    let a = online_machine_sized(&m, "o1", Some("large")).await;
    let b = online_machine_sized(&m, "o1", Some("large")).await;
    assert_eq!((a.name.as_str(), b.name.as_str()), ("large-a", "large-b"));
    // Targetable by name; the name resolves to the immutable node id.
    assert_eq!(m.get("large-b").await.unwrap().id, b.id);
    assert_eq!(resolve_node_alias("large-a"), a.node_id);
    assert_eq!(resolve_node_alias("ashur"), "ashur");
    assert_eq!(display_name(&a.node_id).as_deref(), Some("large-a"));
    m.destroy(&a.id, "test").await.unwrap();
    // Destroyed name no longer resolves; next machine reuses it.
    assert_eq!(resolve_node_alias("large-a"), "large-a");
    let c = online_machine_sized(&m, "o1", Some("large")).await;
    assert_eq!(c.name, "large-a");
    assert_ne!(c.node_id, a.node_id, "node ids are never reused");
    assert_eq!(m.get("large-a").await.unwrap().id, c.id);
}

#[test]
fn antigravity_projection_requires_a_recorded_allowed_owner() {
    assert!(!antigravity_owner_allowed(None, None));
    assert!(!antigravity_owner_allowed(Some(""), None));
    assert!(antigravity_owner_allowed(Some("prod"), None));
    assert!(antigravity_owner_allowed(
        Some("prod"),
        Some("prod, thomas")
    ));
    assert!(!antigravity_owner_allowed(
        Some("guest"),
        Some("prod,thomas")
    ));
}

#[tokio::test]
async fn antigravity_setting_owner_and_wipe_on_destroy() {
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    let mine = online_machine(&m, "o1").await; // owner_user_id t1
    let anon = online_machine(&m, "o2").await;
    m.update(&anon.id, |x| x.owner_user_id = None).await;
    assert!(m.antigravity_allowed(&mine.node_id).await);
    assert!(
        !m.antigravity_allowed(&anon.node_id).await,
        "no recorded owner"
    );
    assert!(!m.antigravity_allowed("ashur").await);
    m.set_runtime_settings(RuntimeSettings {
        antigravity_on_managed: false,
        reaper_dry_run: false,
        ..Default::default()
    });
    assert!(!m.antigravity_allowed(&mine.node_id).await, "setting off");
    // Persisted across restarts.
    let reloaded = ManagedManager::new(settings(), None, dir.path(), 3999);
    reloaded.load().await;
    assert!(!reloaded.runtime_settings().antigravity_on_managed);
    m.set_runtime_settings(RuntimeSettings {
        antigravity_on_managed: true,
        reaper_dry_run: false,
        ..Default::default()
    });
    m.mark_antigravity_projected(&mine.node_id).await;
    m.destroy(&mine.id, "test").await.unwrap();
    let execs = fake.execs.lock().unwrap().clone();
    assert!(
        execs
            .iter()
            .any(|c| c.contains("rm -rf /var/lib/orb-node/work/managed-auth")),
        "{execs:?}"
    );
    // A machine without a projection is not wiped needlessly.
    let n = execs.len();
    m.destroy(&anon.id, "test").await.unwrap();
    assert_eq!(
        fake.execs
            .lock()
            .unwrap()
            .iter()
            .filter(|c| c.contains("managed-auth") && c.ends_with("&& sync"))
            .count(),
        1
    );
    let _ = n;
}

#[test]
fn caps_keep_safe_defaults_unless_explicitly_unlimited() {
    // Unset / empty / zero / negative / typo keep the safe default.
    for raw in [
        None,
        Some(""),
        Some("  "),
        Some("0"),
        Some("-3"),
        Some("abc"),
        Some("nonee"),
    ] {
        assert_eq!(optional_limit::<f64>(raw, 20.0), Some(20.0), "{raw:?}");
        assert_eq!(optional_limit::<usize>(raw, 6), Some(6), "{raw:?}");
    }
    // Only an explicit operator choice lifts the limit.
    for raw in ["none", "Unlimited", "OFF", " none "] {
        assert_eq!(optional_limit::<f64>(Some(raw), 20.0), None, "{raw:?}");
        assert_eq!(optional_limit::<usize>(Some(raw), 6), None, "{raw:?}");
    }
    assert_eq!(optional_limit::<f64>(Some("50"), 20.0), Some(50.0));
    assert_eq!(optional_limit::<usize>(Some(" 10 "), 6), Some(10));
}

#[tokio::test]
async fn unlimited_caps_never_refuse_and_report_null() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.daily_cap_usd = None;
    s.max_concurrent = None;
    let (m, _) = manager(dir.path(), s);
    // Well past the old defaults: 8 machines, and an xlarge for 12 h ($2.40).
    for _ in 0..7 {
        m.spawn(SpawnRequest {
            wait: Some(false),
            ttl_minutes: Some(30),
            ..Default::default()
        })
        .await
        .unwrap();
    }
    m.spawn(SpawnRequest {
        size: Some("xlarge".into()),
        ttl_minutes: Some(720),
        wait: Some(false),
        ..Default::default()
    })
    .await
    .unwrap();
    let view = m.list(24).await;
    assert_eq!(view.budget.active, 8);
    let json = serde_json::to_value(&view.budget).unwrap();
    assert!(json["daily_cap_usd"].is_null());
    assert!(json["max_concurrent"].is_null());
}

fn spend_machine(
    id: &str,
    size: &str,
    mission: Option<&str>,
    created: &str,
    destroyed: Option<&str>,
    cost: f64,
) -> ManagedMachine {
    let at = |s: &str| s.parse::<DateTime<Utc>>().unwrap();
    ManagedMachine {
        provisioning_mode: ProvisioningMode::Worker,
        name: String::new(),
        antigravity_projected: false,
        id: id.into(),
        provider: "fake".into(),
        provider_id: None,
        node_id: format!("managed-{id}"),
        image: "orb-node-base".into(),
        size: size.into(),
        cpu: 2,
        ram_gb: 4,
        disk_gb: 12,
        usd_per_hour: 1.0,
        state: if destroyed.is_some() {
            MachineState::Destroyed
        } else {
            MachineState::Online
        },
        created_at: at(created),
        expires_at: at("2030-01-01T00:00:00Z"),
        online_at: None,
        destroyed_at: destroyed.map(at),
        destroy_reason: None,
        cost_usd: cost,
        cost_is_metered: true,
        owner_mission_id: mission.map(Into::into),
        owner_user_id: None,
        owner_kind: None,
        requested_by_mission_id: None,
        reap_at: None,
        reap_reason: None,
        reason: None,
        error: None,
        ledger_closed: destroyed.is_some(),
        last_busy_at: None,
        budget_pool_id: None,
        cap_pool_id: None,
        auto_extensions: 0,
        prior_pool_charges: Vec::new(),
        pool_spent_offset: 0.0,
        stopped_at: None,
        stopped_by_reaper: false,
        source_snapshot: None,
        forked_from: None,
        fork_source_provider_id: None,
        resumes: 0,
        run_started_at: None,
        cost_before_resume: 0.0,
        secrets_wiped: false,
        project: None,
        root_mission_id: None,
        active_mission_ids: Vec::new(),
        deletable_at: None,
        has_executed_job: false,
    }
}

#[test]
fn daily_spend_buckets_by_day_mission_and_size() {
    let now: DateTime<Utc> = "2026-10-23T12:00:00Z".parse().unwrap();
    let machines = vec![
        // Out of range: before the 7-day window.
        spend_machine(
            "old",
            "small",
            Some("m1"),
            "2026-10-01T10:00:00Z",
            Some("2026-10-01T11:00:00Z"),
            5.0,
        ),
        // Single day.
        spend_machine(
            "a",
            "small",
            Some("m1"),
            "2026-10-20T10:00:00Z",
            Some("2026-10-20T11:00:00Z"),
            0.03,
        ),
        spend_machine(
            "b",
            "large",
            Some("m2"),
            "2026-10-20T12:00:00Z",
            Some("2026-10-20T13:00:00Z"),
            0.5,
        ),
        // Spans midnight evenly: half on 21st, half on 22nd.
        spend_machine(
            "c",
            "small",
            None,
            "2026-10-21T23:00:00Z",
            Some("2026-10-22T01:00:00Z"),
            0.2,
        ),
        // Running now, unmetered: accrued estimate (2h at $1/h) counts today.
        {
            let mut m = spend_machine("d", "small", Some("m3"), "2026-10-23T10:00:00Z", None, 0.0);
            m.cost_is_metered = false;
            m
        },
        // Zero-cost machine is ignored.
        spend_machine(
            "z",
            "small",
            Some("m9"),
            "2026-10-19T10:00:00Z",
            Some("2026-10-19T10:00:00Z"),
            0.0,
        ),
    ];
    let days = daily_spend(&machines, 7, now);
    assert_eq!(days.len(), 7);
    assert_eq!(days[0].day, "2026-10-17");
    assert_eq!(days[6].day, "2026-10-23");
    assert!(days[..3]
        .iter()
        .all(|d| d.usd == 0.0 && d.missions.is_empty()));
    let d20 = &days[3];
    assert_eq!(d20.usd, 0.53);
    assert_eq!(
        d20.missions[0],
        SpendPart {
            mission_id: Some("m2".into()),
            usd: 0.5
        }
    );
    assert_eq!(d20.missions[1].mission_id.as_deref(), Some("m1"));
    assert_eq!(d20.sizes[0].size, "large");
    assert_eq!(days[4].usd, 0.1);
    assert_eq!(days[4].missions[0].mission_id, None);
    assert_eq!(days[5].usd, 0.1);
    assert_eq!(days[6].usd, 2.0);
    assert_eq!(days[6].missions[0].mission_id.as_deref(), Some("m3"));
}

#[test]
fn daily_spend_empty_registry_is_all_zero_days() {
    let now: DateTime<Utc> = "2026-10-23T12:00:00Z".parse().unwrap();
    let days = daily_spend(&[], 3, now);
    assert_eq!(
        days.iter().map(|d| d.day.as_str()).collect::<Vec<_>>(),
        ["2026-10-21", "2026-10-22", "2026-10-23"]
    );
    assert!(days.iter().all(|d| d.usd == 0.0));
}

// ------------------------------------------------- lifecycle (spec tests)

#[tokio::test]
async fn dry_run_records_but_never_destroys_except_ttl() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.max_concurrent = Some(4);
    let (m, fake) = manager(dir.path(), s);
    m.set_runtime_settings(RuntimeSettings {
        antigravity_on_managed: true,
        reaper_dry_run: true,
        ..Default::default()
    });
    let done = online_machine(&m, "owner-done").await;
    let expired = online_machine(&m, "owner-live").await;
    m.update(&expired.id, |x| {
        x.expires_at = Utc::now() - chrono::Duration::seconds(1)
    })
    .await;
    let mut map = std::collections::HashMap::new();
    map.insert(
        "owner-done".to_string(),
        OwnerState::Terminal { status: "failed" },
    );
    map.insert("owner-live".to_string(), OwnerState::Working);
    m.set_owner_probe(probe_from(map));
    let plan = m.reap_plan().await;
    let row = plan.iter().find(|p| p.machine_id == done.id).unwrap();
    assert_eq!(row.decision.reason(), Some("owner_failed"));
    m.reap_once().await;
    let kept = m.get(&done.id).await.unwrap();
    assert_eq!(kept.state, MachineState::Online);
    assert_eq!(kept.reap_reason.as_deref(), Some("owner_failed"));
    assert!(kept.reap_at.is_some());
    let ledger =
        std::fs::read_to_string(dir.path().join(".sandboxed-sh/managed_ledger.jsonl")).unwrap();
    assert_eq!(ledger.matches("would_reap").count(), 1);
    m.reap_once().await; // logged once only
    let ledger =
        std::fs::read_to_string(dir.path().join(".sandboxed-sh/managed_ledger.jsonl")).unwrap();
    assert_eq!(ledger.matches("would_reap").count(), 1);
    // TTL is the backstop even in dry-run.
    let gone = m.get(&expired.id).await.unwrap();
    assert_eq!(gone.destroy_reason.as_deref(), Some("ttl_expired"));
    assert_eq!(fake.destroyed.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn owner_grace_schedules_then_destroys() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.owner_grace_minutes = 5;
    let (m, _) = manager(dir.path(), s);
    let a = online_machine(&m, "owner-done").await;
    let mut map = std::collections::HashMap::new();
    map.insert(
        "owner-done".to_string(),
        OwnerState::Terminal {
            status: "completed",
        },
    );
    m.set_owner_probe(probe_from(map));
    m.reap_once().await;
    let row = m.get(&a.id).await.unwrap();
    assert_eq!(row.state, MachineState::Online);
    assert_eq!(row.reap_reason.as_deref(), Some("owner_completed"));
    // Grace elapsed (as recorded on the row).
    m.update(&a.id, |x| {
        x.reap_at = Some(Utc::now() - chrono::Duration::seconds(1))
    })
    .await;
    m.reap_once().await;
    let row = m.get(&a.id).await.unwrap();
    assert_eq!(row.state, MachineState::Destroyed);
    assert_eq!(row.destroy_reason.as_deref(), Some("owner_completed"));
}

#[tokio::test]
async fn ownerless_idle_machine_is_reaped_with_precise_reason() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let a = m
        .spawn(SpawnRequest {
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(a.owner_kind.as_deref(), Some("user"));
    // Legacy row: no owner kind either.
    m.update(&a.id, |x| {
        x.state = MachineState::Online;
        x.owner_kind = None;
        x.last_busy_at = Some(Utc::now() - chrono::Duration::minutes(31));
    })
    .await;
    m.reap_once().await;
    let row = m.get(&a.id).await.unwrap();
    assert_eq!(row.destroy_reason.as_deref(), Some("idle_no_owner"));
}

#[tokio::test]
async fn claim_moves_ownership_to_the_served_mission_only() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.max_concurrent = Some(4);
    let (m, _) = manager(dir.path(), s);
    // start_mission from a mission: rented by the caller, claimed by the child.
    let a = online_machine(&m, "caller").await;
    let claimed = m
        .claim_for_mission(&a.id, "child", Some("caller"), Some("t1"))
        .await
        .unwrap();
    assert_eq!(claimed.owner_mission_id.as_deref(), Some("child"));
    assert_eq!(claimed.requested_by_mission_id.as_deref(), Some("caller"));
    assert_eq!(claimed.owner_kind.as_deref(), Some("mission"));
    // Another tree cannot take it.
    let err = m
        .claim_for_mission(&a.id, "intruder", Some("someone"), Some("t1"))
        .await
        .unwrap_err();
    assert_eq!(err.error, "owned");
    // An ownerless (Hermes-rented / legacy) machine is claimable.
    let b = m
        .spawn(SpawnRequest {
            wait: Some(false),
            owner_user_id: Some("t1".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    let b = m
        .claim_for_mission(&b.id, "child2", Some("caller"), Some("t1"))
        .await
        .unwrap();
    assert_eq!(b.owner_mission_id.as_deref(), Some("child2"));
    assert_eq!(b.requested_by_mission_id.as_deref(), Some("caller"));
    // The served child's end reaps it; the requester's liveness does not keep it.
    let mut map = std::collections::HashMap::new();
    map.insert(
        "child".to_string(),
        OwnerState::Terminal {
            status: "completed",
        },
    );
    map.insert("caller".to_string(), OwnerState::Working);
    m.set_owner_probe(probe_from(map));
    m.reap_once().await;
    assert_eq!(
        m.get(&a.id).await.unwrap().destroy_reason.as_deref(),
        Some("owner_completed")
    );
}

#[tokio::test]
async fn reconcile_orphan_grace_and_vanished_rows() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.orphan_grace_minutes = 10;
    let (m, fake) = manager(dir.path(), s);
    let live = online_machine(&m, "owner").await;
    let live_pid = live.provider_id.clone().unwrap();
    let other = ProviderMachine {
        provider_id: "bx_unrelated".into(),
        state: "ready".into(),
        name: "not ours".into(),
        deletable_at: None,
    };
    *fake.listed.lock().unwrap() = vec![
        ProviderMachine {
            provider_id: "bx_orphan".into(),
            state: "ready".into(),
            name: "orb-managed-mmzz".into(),
            deletable_at: None,
        },
        other.clone(),
    ];
    // Orphan within grace: reported, not stopped. Live row missing once: kept.
    let r = m.reconcile_once().await.unwrap();
    assert_eq!(r["orphans_stopped"], serde_json::json!([]));
    assert_eq!(r["orphans_pending"].as_array().unwrap().len(), 1);
    assert_eq!(m.get(&live.id).await.unwrap().state, MachineState::Online);
    // Grace passed (age the first sighting).
    m.reconcile_state.lock().await.orphans_seen.insert(
        "fake:bx_orphan".into(),
        Utc::now() - chrono::Duration::minutes(11),
    );
    let r = m.reconcile_once().await.unwrap();
    assert_eq!(r["orphans_stopped"], serde_json::json!(["bx_orphan"]));
    // Second pass without the live VM: the row is closed as vanished.
    assert_eq!(r["vanished_rows"], serde_json::json!([live.id.clone()]));
    let row = m.get(&live.id).await.unwrap();
    assert_eq!(row.state, MachineState::Destroyed);
    assert_eq!(row.destroy_reason.as_deref(), Some("provider_vanished"));
    assert!(row.ledger_closed);
    assert!(!fake.destroyed.lock().unwrap().contains(&live_pid));
}

#[tokio::test]
async fn empty_provider_list_never_closes_rows() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let live = online_machine(&m, "owner").await;
    for _ in 0..3 {
        m.reconcile_once().await.unwrap();
    }
    assert_eq!(m.get(&live.id).await.unwrap().state, MachineState::Online);
}

#[tokio::test]
async fn reconcile_dry_run_keeps_orphans() {
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    m.set_runtime_settings(RuntimeSettings {
        antigravity_on_managed: true,
        reaper_dry_run: true,
        ..Default::default()
    });
    *fake.listed.lock().unwrap() = vec![ProviderMachine {
        provider_id: "bx_orphan".into(),
        state: "ready".into(),
        name: "orb-managed-mmzz".into(),
        deletable_at: None,
    }];
    let r = m.reconcile_once().await.unwrap();
    assert_eq!(r["dry_run"], serde_json::json!(true));
    assert!(fake.destroyed.lock().unwrap().is_empty());
}

#[tokio::test]
async fn claim_rejects_cross_user_and_forged_requester() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let a = online_machine(&m, "caller").await; // tenant t1
    let err = m
        .claim_for_mission(&a.id, "x", Some("caller"), Some("t2"))
        .await
        .unwrap_err();
    assert_eq!((err.error, err.status), ("forbidden", 403));
    let err = m
        .claim_for_mission(&a.id, "x", Some("caller"), None)
        .await
        .unwrap_err();
    assert_eq!(err.status, 403);
    // Same tenant but a requester that is not the current owner: refused.
    let err = m
        .claim_for_mission(&a.id, "x", Some("forged"), Some("t1"))
        .await
        .unwrap_err();
    assert_eq!(err.error, "owned");
    // No requester (REST backfill path) cannot take an owned machine.
    assert!(m
        .claim_for_mission(&a.id, "x", None, Some("t1"))
        .await
        .is_err());
    assert_eq!(
        m.get(&a.id).await.unwrap().owner_mission_id.as_deref(),
        Some("caller")
    );
}

// ---------------------------------------------------------------- budgets

fn pool(id: &str, usd: f64, parent: Option<&str>) -> budget::BudgetPool {
    budget::BudgetPool {
        mission_id: id.into(),
        budget_usd: Some(usd),
        parent_pool_id: parent.map(Into::into),
        vm_limits: None,
        parent_cap_pool_id: None,
        owner_user_id: Some("t1".into()),
        updated_at: Utc::now(),
    }
}

fn pooled_machine(id: &str, pool: &str, rate: f64, ttl_min: i64, spent: f64) -> ManagedMachine {
    let mut m = spend_machine(id, "small", Some(id), "2026-10-24T00:00:00Z", None, spent);
    let now = Utc::now();
    m.created_at = now;
    m.expires_at = now + chrono::Duration::minutes(ttl_min);
    m.usd_per_hour = rate;
    m.budget_pool_id = Some(pool.into());
    m
}

#[test]
fn pool_usage_reserves_at_most_an_hour_and_carves_open_children() {
    let mut pools = HashMap::new();
    pools.insert("root".to_string(), pool("root", 1.0, None));
    pools.insert("child".to_string(), pool("child", 0.3, Some("root")));
    // 3 h TTL at $0.20/h reserves only 60 min = $0.20; spent $0.05.
    let machines = vec![
        pooled_machine("a", "root", 0.20, 180, 0.05),
        pooled_machine("b", "child", 0.10, 30, 0.01),
    ];
    let now = Utc::now();
    let u = budget::pool_usage("root", &pools, &machines, now, &|_| true).unwrap();
    assert!((u.reserved_usd - 0.20).abs() < 0.002, "{u:?}");
    assert!((u.spent_usd - 0.05).abs() < 1e-9);
    // Open child holds its whole sub-budget.
    assert!((u.carved_usd - 0.3).abs() < 1e-9, "{u:?}");
    assert!((u.available_usd - (1.0 - 0.05 - 0.20 - 0.3)).abs() < 0.002);
    // Ended child returns what it did not use (spent + its 30 min reserve).
    let closed = budget::pool_usage("root", &pools, &machines, now, &|_| false).unwrap();
    assert!(closed.carved_usd < 0.07, "{closed:?}");
    let c = budget::pool_usage("child", &pools, &machines, now, &|_| true).unwrap();
    assert!((c.reserved_usd - 0.05).abs() < 0.002, "{c:?}");
    assert_eq!(c.live_machines, 1);
}

#[test]
fn nearest_pool_walks_the_lineage_and_amounts_are_validated() {
    let mut pools = HashMap::new();
    pools.insert("gp".to_string(), pool("gp", 1.0, None));
    assert_eq!(
        budget::nearest_pool(["kid", "parent", "gp"], &pools, "t1").as_deref(),
        Some("gp")
    );
    assert_eq!(budget::nearest_pool(["x", "y"], &pools, "t1"), None);
    assert!(budget::validate_amount(-1.0).is_err());
    assert!(budget::validate_amount(f64::NAN).is_err());
    assert_eq!(budget::validate_amount(2.5).unwrap(), 2.5);
    assert!((budget::reservation_for(180, 0.2) - 0.2).abs() < 1e-9);
    assert!((budget::reservation_for(30, 0.2) - 0.1).abs() < 1e-9);
}

#[tokio::test]
async fn spawn_and_extend_respect_the_pool_and_sub_budgets() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.daily_cap_usd = None;
    s.max_concurrent = None;
    let (m, _) = manager(dir.path(), s);
    m.set_mission_budget("root", Some(0.10), None, Some("t1".into()))
        .await
        .unwrap();
    // xlarge reserves 60 min * $0.20 = $0.20 > $0.10.
    let e = m
        .spawn(SpawnRequest {
            size: Some("xlarge".into()),
            wait: Some(false),
            budget_pool_id: Some("root".into()),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!((e.error, e.status), ("budget_exceeded", 402));
    assert!(e.message.contains("remaining $0.1000"), "{}", e.message);
    // small (60 min * $0.018) fits.
    let ok = m
        .spawn(SpawnRequest {
            wait: Some(false),
            budget_pool_id: Some("root".into()),
            owner_mission_id: Some("root".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(ok.budget_pool_id.as_deref(), Some("root"));
    // A sub-budget larger than the pool's remaining is refused...
    let e = m
        .set_mission_budget("kid", Some(0.5), Some("root".into()), Some("t1".into()))
        .await
        .unwrap_err();
    assert_eq!(e.error, "sub_budget_exceeds_pool");
    // ...and a machine for a child whose sub-budget cannot cover it too.
    let e = m
        .spawn(SpawnRequest {
            size: Some("large".into()),
            wait: Some(false),
            budget_pool_id: Some("root".into()),
            sub_budget_usd: Some(0.01),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(e.error, "budget_exceeded");
    m.set_mission_budget("kid", Some(0.05), Some("root".into()), Some("t1".into()))
        .await
        .unwrap();
    let u = m.pool_usage("root").await.unwrap();
    assert!((u.carved_usd - 0.05).abs() < 1e-9);
    // Extending past the remaining pool is refused with the remaining amount.
    m.set_mission_budget("root", Some(0.07), None, Some("t1".into()))
        .await
        .unwrap();
    let e = m.extend(&ok.id, 60).await.unwrap_err();
    assert_eq!(e.error, "budget_exceeded");
    // Removing the budget lifts the pool limit (daily cap still applies).
    m.set_mission_budget("root", None, None, Some("t1".into()))
        .await
        .unwrap();
    assert!(m.pool_usage("root").await.is_none());
    assert!(m.extend(&ok.id, 60).await.is_ok());
    // Persisted across a restart.
    m.set_mission_budget("root", Some(3.0), None, Some("t1".into()))
        .await
        .unwrap();
    let (m2, _) = manager(dir.path(), settings());
    m2.load().await;
    assert_eq!(m2.budget_pools().await["root"].budget_usd, Some(3.0));
}

#[tokio::test]
async fn mission_budget_view_reports_pooled_and_sub_budget_children() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    m.set_mission_budget("root", Some(1.0), None, Some("t1".into()))
        .await
        .unwrap();
    m.set_mission_budget("kid2", Some(0.2), Some("root".into()), Some("t1".into()))
        .await
        .unwrap();
    let v = m
        .mission_budget(
            "root",
            &["root".to_string()],
            &["kid1".to_string(), "kid2".to_string()],
            "t1",
        )
        .await;
    assert_eq!(v.mode, "own");
    assert_eq!(v.children[0].mode, "pooled");
    assert_eq!(v.children[1].mode, "sub_budget");
    assert_eq!(v.max_grant_usd, None);
    let kid = m
        .mission_budget("kid1", &["kid1".to_string(), "root".to_string()], &[], "t1")
        .await;
    assert_eq!((kid.mode, kid.pool_id.as_deref()), ("pooled", Some("root")));
    assert!((kid.max_grant_usd.unwrap() - 0.8).abs() < 1e-9);
    let none = m
        .mission_budget("solo", &["solo".to_string()], &[], "t1")
        .await;
    assert_eq!(none.mode, "none");
}

#[tokio::test]
async fn idle_machine_of_an_ended_sibling_is_reused_once() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let vm = online_machine(&m, "sib-done").await;
    let got = m
        .take_idle_sibling(
            &SiblingReuse {
                size: "small",
                image: "orb-node-base",
                requested_by: "parent",
                tenant: Some("t1"),
                budget_pool_id: None,
                sub_budget_usd: None,
            },
            &|o| o == "sib-done",
        )
        .await
        .unwrap();
    assert_eq!(got.id, vm.id);
    assert_eq!(got.owner_mission_id, None);
    assert_eq!(got.requested_by_mission_id.as_deref(), Some("parent"));
    // Wrong size, other tenant, or already taken: nothing.
    assert!(m
        .take_idle_sibling(
            &SiblingReuse {
                size: "small",
                image: "orb-node-base",
                requested_by: "parent",
                tenant: Some("t1"),
                budget_pool_id: None,
                sub_budget_usd: None
            },
            &|o| o == "sib-done"
        )
        .await
        .is_none());
    let other = online_machine(&m, "sib2").await;
    assert!(m
        .take_idle_sibling(
            &SiblingReuse {
                size: "large",
                image: "orb-node-base",
                requested_by: "parent",
                tenant: Some("t1"),
                budget_pool_id: None,
                sub_budget_usd: None
            },
            &|_| true
        )
        .await
        .is_none());
    assert!(m
        .take_idle_sibling(
            &SiblingReuse {
                size: "small",
                image: "orb-node-base",
                requested_by: "parent",
                tenant: Some("t2"),
                budget_pool_id: None,
                sub_budget_usd: None
            },
            &|_| true
        )
        .await
        .is_none());
    let _ = other;
}

#[test]
fn defaults_shorten_idle_tails() {
    let s = ManagedSettings::from_env(true);
    assert_eq!(s.max_concurrent, Some(100));
    assert_eq!(default_provider_max_concurrent("boat"), Some(100));
    assert_eq!(default_provider_max_concurrent("hetzner"), None);
    assert_eq!(s.waiting_grace_minutes, 15);
    assert_eq!(s.default_ttl_minutes, 60);
    assert_eq!(s.auto_extend_minutes, 30);
    assert_eq!(LifecyclePolicy::default().waiting_grace_minutes, 15);
}

#[test]
fn boat_stop_failed_is_retryable_and_exit_codes_are_read() {
    assert!(boat::stop_failed_retryable(
        "boat POST /sandboxes/bx_1/stop -> HTTP 400 stop_failed"
    ));
    assert!(!boat::stop_failed_retryable("HTTP 500 internal"));
    assert_eq!(exec_exit_code(&serde_json::json!({"exitCode": 2})), Some(2));
    assert_eq!(exec_exit_code(&Value::Null), None);
}

#[test]
fn provision_script_is_embedded_and_scoped() {
    assert!(PROVISION_SCRIPT.contains("/tmp/opencode"));
    assert!(PROVISION_SCRIPT.contains("credential.https://github.com.helper"));
    assert!(PROVISION_SCRIPT.contains("RUSTUP_HOME"));
    // The helper answers github.com only and never echoes the token to logs.
    assert!(PROVISION_SCRIPT.contains("[ \"$host\" = github.com ] || exit 0"));
    assert!(!PROVISION_SCRIPT.contains("set -x"));
}

#[tokio::test]
async fn provision_runs_the_script_before_starting_the_node() {
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
    for _ in 0..200 {
        if fake.execs.lock().unwrap().len() >= 3 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let execs = fake.execs.lock().unwrap().clone();
    assert!(execs[0].contains("provision.sh"), "{execs:?}");
    assert!(
        execs[1].contains("rm -rf /var/lib/orb-node/node.cred")
            && !execs[1].contains("systemctl restart"),
        "{execs:?}"
    );
    assert!(
        execs[2].contains("systemctl restart orb-node") && !execs[2].contains("node.cred"),
        "{execs:?}"
    );
    let _ = m.destroy(&machine.id, "test").await;
}

#[tokio::test]
async fn reusing_an_idle_sibling_vm_respects_the_target_budget() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.daily_cap_usd = None;
    s.max_concurrent = None;
    let (m, _) = manager(dir.path(), s);
    let vm = online_machine_sized(&m, "sib-done", Some("xlarge")).await;
    // Pool too small for the VM's reservation ($0.20): no handover.
    m.set_mission_budget("parent", Some(0.05), None, Some("t1".into()))
        .await
        .unwrap();
    assert!(m
        .take_idle_sibling(
            &SiblingReuse {
                size: "xlarge",
                image: "orb-node-base",
                requested_by: "parent",
                tenant: Some("t1"),
                budget_pool_id: Some("parent"),
                sub_budget_usd: None
            },
            &|_| true
        )
        .await
        .is_none());
    // Sub-budget too small: no handover either.
    m.set_mission_budget("parent", Some(5.0), None, Some("t1".into()))
        .await
        .unwrap();
    assert!(m
        .take_idle_sibling(
            &SiblingReuse {
                size: "xlarge",
                image: "orb-node-base",
                requested_by: "parent",
                tenant: Some("t1"),
                budget_pool_id: Some("parent"),
                sub_budget_usd: Some(0.01)
            },
            &|_| true
        )
        .await
        .is_none());
    // The VM was left untouched by the refusals.
    assert_eq!(
        m.get(&vm.id).await.unwrap().owner_mission_id.as_deref(),
        Some("sib-done")
    );
    // Within budget: handed over and charged to the new pool.
    let got = m
        .take_idle_sibling(
            &SiblingReuse {
                size: "xlarge",
                image: "orb-node-base",
                requested_by: "parent",
                tenant: Some("t1"),
                budget_pool_id: Some("parent"),
                sub_budget_usd: Some(1.0),
            },
            &|_| true,
        )
        .await
        .unwrap();
    assert_eq!(got.budget_pool_id.as_deref(), Some("parent"));
}

#[test]
fn a_vm_changing_pool_keeps_its_past_cost_on_the_old_pool() {
    let mut pools = HashMap::new();
    pools.insert("old".to_string(), pool("old", 1.0, None));
    pools.insert("new".to_string(), pool("new", 1.0, None));
    let now = Utc::now();
    let mut vm = pooled_machine("a", "old", 0.20, 30, 0.40);
    vm.change_pool(Some("new".into()), now);
    let machines = vec![vm.clone()];
    let old = budget::pool_usage("old", &pools, &machines, now, &|_| true).unwrap();
    let new = budget::pool_usage("new", &pools, &machines, now, &|_| true).unwrap();
    assert!((old.spent_usd - 0.40).abs() < 1e-9, "{old:?}");
    assert_eq!(old.reserved_usd, 0.0);
    assert_eq!(new.spent_usd, 0.0, "{new:?}");
    assert!(new.reserved_usd > 0.0);
    // Later spend lands on the new pool only.
    let mut later = vm;
    later.cost_usd = 0.55;
    let machines = vec![later];
    let new = budget::pool_usage("new", &pools, &machines, now, &|_| true).unwrap();
    let old = budget::pool_usage("old", &pools, &machines, now, &|_| true).unwrap();
    assert!((new.spent_usd - 0.15).abs() < 1e-9, "{new:?}");
    assert!((old.spent_usd - 0.40).abs() < 1e-9);
}

#[test]
fn foreign_pools_are_never_selected() {
    let mut pools = HashMap::new();
    let mut theirs = pool("gp", 1.0, None);
    theirs.owner_user_id = Some("t2".into());
    pools.insert("gp".to_string(), theirs);
    assert_eq!(budget::nearest_pool(["kid", "gp"], &pools, "t1"), None);
    assert_eq!(
        budget::nearest_pool(["kid", "gp"], &pools, "t2").as_deref(),
        Some("gp")
    );
}

#[tokio::test]
async fn removing_a_sub_budget_moves_its_spend_to_the_parent_pool() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.daily_cap_usd = None;
    s.max_concurrent = None;
    let (m, _) = manager(dir.path(), s);
    m.set_mission_budget("root", Some(5.0), None, Some("t1".into()))
        .await
        .unwrap();
    m.set_mission_budget("kid", Some(1.0), Some("root".into()), Some("t1".into()))
        .await
        .unwrap();
    // A VM that spent $0.30 in the kid pool, then moved to another pool.
    let vm = online_machine(&m, "kid").await;
    m.update(&vm.id, |x| {
        x.budget_pool_id = Some("kid".into());
        x.cost_usd = 0.30;
        x.cost_is_metered = true;
    })
    .await;
    m.set_machine_pool(&vm.id, Some("other".into())).await;
    let vm2 = online_machine(&m, "kid").await;
    m.update(&vm2.id, |x| {
        x.budget_pool_id = Some("kid".into());
        x.cost_usd = 0.20;
        x.cost_is_metered = true;
    })
    .await;
    m.set_mission_budget("kid", None, Some("root".into()), Some("t1".into()))
        .await
        .unwrap();
    let root = m.pool_usage("root").await.unwrap();
    // Both the departed VM's $0.30 and the live VM's $0.20 now count here.
    assert!((root.spent_usd - 0.50).abs() < 1e-6, "{root:?}");
    assert_eq!(root.carved_usd, 0.0);
}

// ------------------------------------------------- snapshots, fork, stop

use super::snapshots as snaps;

fn snap(name: &str, project: &str, days_old: i64, status: &str) -> snaps::ManagedSnapshot {
    snaps::ManagedSnapshot {
        provisioning_mode: ProvisioningMode::Worker,
        name: name.into(),
        label: name.into(),
        project: Some(project.into()),
        owner_mission_id: None,
        owner_user_id: Some("t1".into()),
        source_machine_id: "mm1".into(),
        source_size: "small".into(),
        created_at: Utc::now() - chrono::Duration::days(days_old),
        last_used_at: None,
        status: status.into(),
        size_bytes: None,
        error: None,
        monthly_usd: 0.0,
    }
}

#[test]
fn snapshot_names_pricing_and_cleanup_plan() {
    assert_eq!(
        snaps::snapshot_name(Some("Lean Native!"), "warm tree", "ab12"),
        "orb-snap-lean-native-warm-tree-ab12"
    );
    assert_eq!(snaps::snapshot_name(None, "", "x"), "orb-snap-none-warm-x");
    assert!(snaps::stops_instead_of_destroy("owner_interrupted_idle"));
    assert!(!snaps::stops_instead_of_destroy("owner_completed"));
    assert!(!snaps::stops_instead_of_destroy("idle_user_owned"));
    let list = vec![
        snap("a-new", "a", 0, "ready"),
        snap("a-mid", "a", 1, "ready"),
        snap("a-old", "a", 2, "ready"),
        snap("a-older", "a", 3, "ready"),
        snap("b-stale", "b", 20, "ready"),
        snap("b-failed", "b", 0, "failed"),
        snap("b-saving", "b", 0, "saving"),
    ];
    // Keep 2 newest per project; a-older is being provisioned from.
    let plan = snaps::cleanup_plan(&list, 2, 14, &["a-older".into()], Utc::now());
    assert_eq!(plan, vec!["a-old", "b-failed", "b-stale"]);
    let mut many: Vec<_> = (0..12)
        .map(|i| snap(&format!("s{i}"), "a", 12 - i, "ready"))
        .collect();
    snaps::price_snapshots(&mut many);
    assert_eq!(many.iter().filter(|s| s.monthly_usd > 0.0).count(), 2);
    assert_eq!(many[11].monthly_usd, snaps::SNAPSHOT_USD_PER_MONTH);
}

async fn wait_provider_id(m: &Arc<ManagedManager>, id: &str) -> ManagedMachine {
    for _ in 0..200 {
        let x = m.get(id).await.unwrap();
        if x.provider_id.is_some() {
            return x;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("no provider id");
}

#[tokio::test]
async fn snapshot_then_spawn_from_it_is_tenant_and_status_checked() {
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    let src = online_machine(&m, "owner").await;
    let s = m
        .snapshot_machine(
            &src.id,
            "lean warm",
            Some("lean"),
            Some("owner"),
            Some("t1"),
        )
        .await
        .unwrap();
    assert_eq!(s.status, "saving");
    assert!(s.name.starts_with("orb-snap-lean-lean-warm-"));
    assert_eq!(fake.saved.lock().unwrap()[0].1, s.name);
    // Delivered secrets are wiped before saving.
    assert!(fake
        .execs
        .lock()
        .unwrap()
        .iter()
        .any(|c| c.contains(".paloma-secrets")));
    let spawn = |tenant: &str| SpawnRequest {
        from_snapshot: Some("lean-warm".into()),
        snapshot_project: Some("lean".into()),
        owner_user_id: Some(tenant.into()),
        wait: Some(false),
        ttl_minutes: Some(30),
        ..Default::default()
    };
    assert_eq!(
        m.spawn(spawn("t1")).await.unwrap_err().error,
        "snapshot_not_ready"
    );
    m.snapshots.lock().await[0].status = "ready".into();
    assert_eq!(
        m.spawn(spawn("t2")).await.unwrap_err().error,
        "snapshot_not_found"
    );
    let vm = m.spawn(spawn("t1")).await.unwrap();
    assert_eq!(vm.image, s.name);
    assert_eq!(vm.source_snapshot.as_deref(), Some(s.name.as_str()));
    assert!(m.snapshots.lock().await[0].last_used_at.is_some());
    // Visible only to the same tenant and project.
    assert_eq!(m.list_snapshots(Some("t1"), Some("lean")).await.len(), 1);
    assert!(m.list_snapshots(Some("t1"), Some("other")).await.is_empty());
    assert!(m.list_snapshots(Some("t2"), Some("lean")).await.is_empty());
    // A machine being created from it blocks deletion.
    m.update(&vm.id, |x| x.state = MachineState::Provisioning)
        .await;
    assert_eq!(
        m.delete_snapshot(&s.name, Some("t1"), Some("lean"))
            .await
            .unwrap_err()
            .error,
        "snapshot_in_use"
    );
    m.update(&vm.id, |x| x.state = MachineState::Online).await;
    m.delete_snapshot("lean-warm", Some("t1"), Some("lean"))
        .await
        .unwrap();
    assert_eq!(fake.deleted_snapshots.lock().unwrap().as_slice(), [s.name]);
}

#[tokio::test]
async fn fork_copies_an_online_machine_but_never_a_projected_sign_in() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.max_concurrent = None;
    let (m, fake) = manager(dir.path(), s);
    let src = online_machine(&m, "parent").await;
    let child = m
        .spawn(SpawnRequest {
            fork_of: Some(src.name.clone()),
            owner_mission_id: Some("parent".into()),
            owner_user_id: Some("t1".into()),
            wait: Some(false),
            ttl_minutes: Some(30),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(child.forked_from.as_deref(), Some(src.id.as_str()));
    let child = wait_provider_id(&m, &child.id).await;
    assert_eq!(
        fake.forks.lock().unwrap().as_slice(),
        [src.provider_id.clone().unwrap()]
    );
    assert_ne!(child.node_id, src.node_id);
    m.update(&src.id, |x| x.antigravity_projected = true).await;
    let e = m
        .spawn(SpawnRequest {
            fork_of: Some(src.id.clone()),
            owner_user_id: Some("t1".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(e.error, "not_forkable");
    // Another tenant cannot fork it either.
    m.update(&src.id, |x| x.antigravity_projected = false).await;
    let e = m
        .spawn(SpawnRequest {
            fork_of: Some(src.id.clone()),
            owner_user_id: Some("t2".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(e.error, "forbidden");
}

#[tokio::test]
async fn stop_and_resume_keep_the_node_identity() {
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    let vm = online_machine(&m, "owner").await;
    let old_pid = vm.provider_id.clone().unwrap();
    let stopped = m.stop_inner(&vm.id, "requested", false).await.unwrap();
    assert_eq!(stopped.state, MachineState::Stopped);
    assert_eq!(fake.stopped.lock().unwrap().as_slice(), [old_pid.clone()]);
    assert_eq!(m.budget().await.active, 0);
    assert!(node_config(&vm.node_id).is_none());
    let resumed = m.resume(&vm.id, Some(30)).await.unwrap();
    assert_eq!(
        (resumed.id.as_str(), resumed.node_id.as_str()),
        (vm.id.as_str(), vm.node_id.as_str())
    );
    assert_eq!(resumed.resumes, 1);
    let after = wait_provider_id(&m, &vm.id).await;
    assert_ne!(after.provider_id, Some(old_pid.clone()));
    assert_eq!(fake.forks.lock().unwrap().as_slice(), [old_pid]);
    // Resuming something that is not stopped is refused.
    assert_eq!(
        m.resume(&vm.id, None).await.unwrap_err().error,
        "not_stopped"
    );
}

#[tokio::test]
async fn reaper_stops_for_waiting_owners_and_closes_after_retention() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.waiting_grace_minutes = 15;
    let (m, fake) = manager(dir.path(), s);
    let vm = online_machine(&m, "waiting").await;
    m.update(&vm.id, |x| {
        x.last_busy_at = Some(Utc::now() - chrono::Duration::hours(2))
    })
    .await;
    let mut map = std::collections::HashMap::new();
    map.insert(
        "waiting".to_string(),
        OwnerState::Waiting {
            status: "interrupted",
            since: Utc::now() - chrono::Duration::hours(1),
        },
    );
    m.set_owner_probe(probe_from(map));
    m.reap_once().await;
    let row = m.get(&vm.id).await.unwrap();
    assert_eq!(row.state, MachineState::Stopped);
    assert!(row.stopped_by_reaper);
    assert_eq!(fake.stopped.lock().unwrap().len(), 1);
    assert!(fake.destroyed.lock().unwrap().is_empty());
    // Still waiting: kept stopped. Past the retention: closed.
    m.reap_once().await;
    assert_eq!(m.get(&vm.id).await.unwrap().state, MachineState::Stopped);
    m.update(&vm.id, |x| {
        x.stopped_at = Some(Utc::now() - chrono::Duration::hours(25))
    })
    .await;
    m.reap_once().await;
    let row = m.get(&vm.id).await.unwrap();
    assert_eq!(row.state, MachineState::Destroyed);
    assert_eq!(row.destroy_reason.as_deref(), Some("stopped_retention"));
}

#[tokio::test]
async fn a_stopped_machine_closes_when_its_owner_ends() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let vm = online_machine(&m, "done").await;
    m.stop_inner(&vm.id, "requested", false).await.unwrap();
    let mut map = std::collections::HashMap::new();
    map.insert(
        "done".to_string(),
        OwnerState::Terminal {
            status: "completed",
        },
    );
    m.set_owner_probe(probe_from(map));
    m.reap_once().await;
    let row = m.get(&vm.id).await.unwrap();
    assert_eq!(row.state, MachineState::Destroyed);
    assert_eq!(row.destroy_reason.as_deref(), Some("owner_completed"));
}

#[tokio::test]
async fn reaper_resumes_a_machine_it_stopped_when_the_owner_works() {
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    let vm = online_machine(&m, "back").await;
    m.stop_inner(&vm.id, "owner_interrupted_idle", true)
        .await
        .unwrap();
    let mut map = std::collections::HashMap::new();
    map.insert("back".to_string(), OwnerState::Working);
    m.set_owner_probe(probe_from(map));
    m.reap_once().await;
    let row = m.get(&vm.id).await.unwrap();
    assert_eq!(row.resumes, 1);
    assert_ne!(row.state, MachineState::Stopped);
    // Provisioning (the fork) runs in the background.
    wait_provider_id(&m, &vm.id).await;
    assert_eq!(fake.forks.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn snapshot_names_are_project_scoped() {
    let dir = tempfile::tempdir().unwrap();
    let mut st = settings();
    st.max_concurrent = None;
    let (m, _) = manager(dir.path(), st);
    let a = online_machine(&m, "owner-a").await;
    let b = online_machine(&m, "owner-b").await;
    let sa = m
        .snapshot_machine(&a.id, "warm", Some("alpha"), None, Some("t1"))
        .await
        .unwrap();
    let sb = m
        .snapshot_machine(&b.id, "warm", Some("beta"), None, Some("t1"))
        .await
        .unwrap();
    for s in m.snapshots.lock().await.iter_mut() {
        s.status = "ready".into();
    }
    let vm = m
        .spawn(SpawnRequest {
            from_snapshot: Some("warm".into()),
            snapshot_project: Some("beta".into()),
            owner_user_id: Some("t1".into()),
            wait: Some(false),
            ttl_minutes: Some(30),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(vm.image, sb.name);
    assert_ne!(vm.image, sa.name);
    let e = m
        .spawn(SpawnRequest {
            from_snapshot: Some("warm".into()),
            snapshot_project: Some("gamma".into()),
            owner_user_id: Some("t1".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(e.error, "snapshot_not_found");
}

#[tokio::test]
async fn secrets_must_be_wiped_before_any_disk_copy() {
    let dir = tempfile::tempdir().unwrap();
    let mut st = settings();
    st.max_concurrent = None;
    let (m, fake) = manager(dir.path(), st);
    let vm = online_machine(&m, "owner").await;
    // Snapshot of a running VM: a failed wipe aborts before saving.
    fake.fail_wipe.store(true, Ordering::SeqCst);
    let e = m
        .snapshot_machine(&vm.id, "warm", Some("p"), None, Some("t1"))
        .await
        .unwrap_err();
    assert_eq!(e.error, "secret_wipe_failed");
    assert!(fake.saved.lock().unwrap().is_empty());
    // Stopped after a failed wipe: no snapshot of that disk.
    let stopped = m.stop_inner(&vm.id, "requested", false).await.unwrap();
    assert!(!stopped.secrets_wiped);
    let e = m
        .snapshot_machine(&vm.id, "warm", Some("p"), None, Some("t1"))
        .await
        .unwrap_err();
    assert_eq!(e.error, "not_snapshottable");
    // A fork whose secret cleanup fails never enrolls: provisioning fails.
    let src = online_machine(&m, "owner2").await;
    let fork = m
        .spawn(SpawnRequest {
            fork_of: Some(src.id.clone()),
            owner_user_id: Some("t1".into()),
            wait: Some(true),
            ttl_minutes: Some(30),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(fork.error, "provision_failed");
    // Wipe works: stop records it and the stopped disk may be saved.
    fake.fail_wipe.store(false, Ordering::SeqCst);
    let ok = online_machine(&m, "owner3").await;
    assert!(
        m.stop_inner(&ok.id, "requested", false)
            .await
            .unwrap()
            .secrets_wiped
    );
    assert!(m
        .snapshot_machine(&ok.id, "warm", Some("p"), None, Some("t1"))
        .await
        .is_ok());
}

#[tokio::test]
async fn raw_lifecycle_never_touches_guest_and_preserves_mode() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.core_url = None;
    let (m, fake) = manager(dir.path(), s.clone());
    let raw = m
        .spawn(SpawnRequest {
            provisioning_mode: Some(ProvisioningMode::Raw),
            image: Some("clean".into()),
            owner_user_id: Some("t1".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(raw.state, MachineState::Online);
    assert!(node_config(&raw.node_id).is_none());
    assert!(!m.antigravity_allowed(&raw.node_id).await);
    assert_eq!(
        m.enroll(&raw.id, "anything").await.unwrap_err().error,
        "enrollment_denied"
    );
    let snapshot = m
        .snapshot_machine(&raw.id, "raw-save", Some("p"), None, Some("t1"))
        .await
        .unwrap();
    assert_eq!(snapshot.provisioning_mode, ProvisioningMode::Raw);
    m.stop_inner(&raw.id, "test", false).await.unwrap();
    let resumed = m.resume(&raw.id, Some(30)).await.unwrap();
    assert_eq!(resumed.provisioning_mode, ProvisioningMode::Raw);
    for _ in 0..100 {
        if m.get(&raw.id).await.unwrap().state == MachineState::Online {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    m.destroy(&raw.id, "test").await.unwrap();
    assert!(fake.execs.lock().unwrap().is_empty());
    assert_eq!(fake.writes.load(Ordering::SeqCst), 0);
    let reload = ManagedManager::new(s, None, dir.path(), 3999);
    reload.load().await;
    assert_eq!(
        reload.get(&raw.id).await.unwrap().provisioning_mode,
        ProvisioningMode::Raw
    );
}

#[tokio::test]
async fn raw_requires_explicit_clean_image_and_cannot_convert_sources() {
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    for (image, error) in [
        (None, "image_required"),
        (Some("orb-node-base"), "image_not_allowed"),
    ] {
        let e = m
            .spawn(SpawnRequest {
                provisioning_mode: Some(ProvisioningMode::Raw),
                image: image.map(str::to_owned),
                ..Default::default()
            })
            .await
            .unwrap_err();
        assert_eq!(e.error, error);
    }
    assert_eq!(fake.created.load(Ordering::SeqCst), 0);
    let raw = m
        .spawn(SpawnRequest {
            provisioning_mode: Some(ProvisioningMode::Raw),
            image: Some("clean".into()),
            owner_user_id: Some("t1".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    let req = SpawnRequest {
        fork_of: Some(raw.id.clone()),
        owner_user_id: Some("t1".into()),
        ..Default::default()
    };
    assert_eq!(
        m.resolve_source(&req).await.unwrap().3,
        ProvisioningMode::Raw
    );
    let e = m
        .resolve_source(&SpawnRequest {
            provisioning_mode: Some(ProvisioningMode::Worker),
            ..req
        })
        .await
        .unwrap_err();
    assert_eq!(e.error, "mode_mismatch");
    m.destroy(&raw.id, "test").await.unwrap();
}

#[test]
fn legacy_mode_defaults_to_worker_and_invalid_mode_is_rejected() {
    let request: SpawnRequest = serde_json::from_value(serde_json::json!({})).unwrap();
    assert_eq!(
        request.provisioning_mode.unwrap_or_default(),
        ProvisioningMode::Worker
    );
    assert!(serde_json::from_value::<SpawnRequest>(
        serde_json::json!({"provisioning_mode":"unsafe"})
    )
    .is_err());
    let mut snapshot = serde_json::to_value(snap("legacy", "p", 0, "ready")).unwrap();
    snapshot
        .as_object_mut()
        .unwrap()
        .remove("provisioning_mode");
    assert_eq!(
        serde_json::from_value::<snaps::ManagedSnapshot>(snapshot)
            .unwrap()
            .provisioning_mode,
        ProvisioningMode::Worker
    );
}

#[tokio::test]
async fn raw_operations_enforce_owner_replay_and_do_not_leak_payloads_to_audit() {
    use super::raw_operations::{Operation, OperationRequest};
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    let raw = m
        .spawn(SpawnRequest {
            provisioning_mode: Some(ProvisioningMode::Raw),
            image: Some("clean".into()),
            owner_user_id: Some("t1".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    let request = OperationRequest {
        idempotency_key: "exec-1".into(),
        operation: Operation::Exec {
            command: "printf unique-sensitive-content".into(),
            timeout_secs: 10,
        },
    };
    assert_eq!(
        m.raw_operation(&raw.id, "t2", request.clone())
            .await
            .unwrap_err()
            .error,
        "not_found"
    );
    assert!(fake.execs.lock().unwrap().is_empty());
    assert_eq!(
        m.raw_operation(&raw.id, "t1", request.clone())
            .await
            .unwrap()
            .status,
        "completed"
    );
    let loaded = ManagedManager::new(settings(), Some(fake.clone()), dir.path(), 3999);
    loaded.load().await;
    assert_eq!(
        loaded
            .raw_operation(&raw.id, "t1", request.clone())
            .await
            .unwrap()
            .status,
        "completed"
    );
    assert_eq!(fake.execs.lock().unwrap().len(), 1);
    let changed = OperationRequest {
        operation: Operation::ReadFile {
            path: "/tmp/a".into(),
        },
        ..request.clone()
    };
    assert_eq!(
        m.raw_operation(&raw.id, "t1", changed)
            .await
            .unwrap_err()
            .error,
        "idempotency_conflict"
    );
    m.stop_inner(&raw.id, "test", false).await.unwrap();
    assert_eq!(
        m.raw_operation(&raw.id, "t1", request)
            .await
            .unwrap()
            .status,
        "completed"
    );
    let ledger = std::fs::read_to_string(m.ledger_path()).unwrap();
    assert!(!ledger.contains("unique-sensitive-content"));
    assert!(ledger.contains("raw_operation_finished"));
    m.destroy(&raw.id, "test").await.unwrap();
}

#[tokio::test]
async fn raw_snapshot_modes_and_budget_visibility_are_owner_scoped() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let raw = m
        .spawn(SpawnRequest {
            provisioning_mode: Some(ProvisioningMode::Raw),
            image: Some("clean".into()),
            owner_user_id: Some("t1".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(m.budget().await.active, 1);
    assert_eq!(m.visible_budget("t1").await.active, 1);
    assert_eq!(m.visible_budget("t2").await.active, 0);
    let mut snapshot = snap("raw-source", "p", 0, "ready");
    snapshot.provisioning_mode = ProvisioningMode::Raw;
    m.snapshots.lock().await.push(snapshot);
    let request = SpawnRequest {
        from_snapshot: Some("raw-source".into()),
        snapshot_project: Some("p".into()),
        owner_user_id: Some("t1".into()),
        ..Default::default()
    };
    assert_eq!(
        m.resolve_source(&request).await.unwrap().3,
        ProvisioningMode::Raw
    );
    assert_eq!(
        m.resolve_source(&SpawnRequest {
            provisioning_mode: Some(ProvisioningMode::Worker),
            ..request.clone()
        })
        .await
        .unwrap_err()
        .error,
        "mode_mismatch"
    );
    assert_eq!(
        m.resolve_source(&SpawnRequest {
            owner_user_id: Some("t2".into()),
            ..request
        })
        .await
        .unwrap_err()
        .error,
        "snapshot_not_found"
    );
    m.destroy(&raw.id, "test").await.unwrap();
}

#[tokio::test]
async fn worker_only_spawn_rejects_raw_snapshot_before_renting() {
    let dir = tempfile::tempdir().unwrap();
    let (manager, provider) = manager(dir.path(), settings());
    let mut snapshot = snap("raw-source", "project", 0, "ready");
    snapshot.provisioning_mode = ProvisioningMode::Raw;
    manager.snapshots.lock().await.push(snapshot);
    let error = manager
        .spawn(SpawnRequest {
            provisioning_mode: Some(ProvisioningMode::Worker),
            from_snapshot: Some("raw-source".into()),
            snapshot_project: Some("project".into()),
            owner_user_id: Some("t1".into()),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(error.error, "mode_mismatch");
    assert_eq!(provider.created.load(Ordering::SeqCst), 0);
    assert!(provider.forks.lock().unwrap().is_empty());
    assert!(manager.machines_snapshot().await.is_empty());
}

#[tokio::test]
async fn working_owner_idle_reaps_unused_and_post_job_machines() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.working_idle_minutes = 15;
    s.post_job_idle_minutes = 5;
    s.max_concurrent = Some(4);
    let (m, _) = manager(dir.path(), s);
    let unused = online_machine(&m, "parent-working").await;
    let post_job = online_machine(&m, "parent-working").await;
    let mut map = std::collections::HashMap::new();
    map.insert("parent-working".to_string(), OwnerState::Working);
    m.set_owner_probe(probe_from(map));

    // Unused worker at 6 minutes: kept (< 15m working_idle_minutes).
    // Post-job worker at 6 minutes: reaped (>= 5m post_job_idle_minutes).
    let six_min_ago = Utc::now() - chrono::Duration::minutes(6);
    m.update(&unused.id, |x| {
        x.last_busy_at = Some(six_min_ago);
        x.has_executed_job = false;
    })
    .await;
    m.update(&post_job.id, |x| {
        x.last_busy_at = Some(six_min_ago);
        x.has_executed_job = true;
    })
    .await;
    m.reap_once().await;
    assert_eq!(m.get(&unused.id).await.unwrap().state, MachineState::Online);
    let reaped_post = m.get(&post_job.id).await.unwrap();
    assert_eq!(reaped_post.state, MachineState::Destroyed);
    assert_eq!(
        reaped_post.destroy_reason.as_deref(),
        Some("working_owner_idle")
    );

    // Unused worker at 16 minutes: now reaped too.
    m.update(&unused.id, |x| {
        x.last_busy_at = Some(Utc::now() - chrono::Duration::minutes(16));
    })
    .await;
    m.reap_once().await;
    let reaped_unused = m.get(&unused.id).await.unwrap();
    assert_eq!(reaped_unused.state, MachineState::Destroyed);
    assert_eq!(
        reaped_unused.destroy_reason.as_deref(),
        Some("working_owner_idle")
    );
}

#[tokio::test]
async fn crash_recovery_closes_half_provisioned_rows_on_load() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.max_concurrent = Some(4);
    let (m, _) = manager(dir.path(), s.clone());
    let mut no_pid = online_machine(&m, "owner").await;
    no_pid.id = "mm_nopid".into();
    no_pid.state = MachineState::Provisioning;
    no_pid.provider_id = None;
    no_pid.ledger_closed = false;

    let mut with_pid = online_machine(&m, "owner").await;
    with_pid.id = "mm_withpid".into();
    with_pid.state = MachineState::Enrolling;
    with_pid.provider_id = Some("bx_half".into());
    with_pid.ledger_closed = false;

    *m.machines.lock().await = vec![no_pid, with_pid];
    m.persist().await;

    let reloaded_fake = Arc::new(FakeProvider::default());
    let reloaded = Arc::new(ManagedManager::new(
        s,
        Some(reloaded_fake.clone()),
        dir.path(),
        3999,
    ));
    reloaded.load().await;

    let r1 = reloaded.get("mm_nopid").await.unwrap();
    assert_eq!(r1.state, MachineState::Failed);
    assert!(r1.ledger_closed);
    assert_eq!(
        r1.destroy_reason.as_deref(),
        Some("core_restarted_during_provision")
    );

    let r2 = reloaded.get("mm_withpid").await.unwrap();
    assert_eq!(r2.state, MachineState::Destroying);
    reloaded.reap_once().await;
    assert_eq!(
        reloaded.get("mm_withpid").await.unwrap().state,
        MachineState::Destroyed
    );
    assert!(reloaded_fake
        .destroyed
        .lock()
        .unwrap()
        .contains(&"bx_half".to_string()));
}

#[tokio::test]
async fn stopped_machine_reserves_its_name_against_duplicate_allocation() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = settings();
    s.max_concurrent = Some(4);
    s.daily_cap_usd = Some(50.0);
    let (m, _) = manager(dir.path(), s);
    let first = online_machine_sized(&m, "o1", Some("xlarge")).await;
    assert_eq!(first.name, "xlarge-a");
    m.stop_inner(&first.id, "user_stopped", false)
        .await
        .unwrap();
    assert_eq!(m.get(&first.id).await.unwrap().state, MachineState::Stopped);

    // Spawning another xlarge while `xlarge-a` is Stopped must allocate `xlarge-b`, never `xlarge-a`.
    let second = online_machine_sized(&m, "o2", Some("xlarge")).await;
    assert_eq!(second.name, "xlarge-b");
}

#[tokio::test]
async fn deletable_at_defers_provider_destroy_until_minimum_lease_expires() {
    let dir = tempfile::tempdir().unwrap();
    let (m, fake) = manager(dir.path(), settings());
    let vm = online_machine(&m, "mac-owner").await;
    let lease_end = Utc::now() + chrono::Duration::hours(23);
    m.update(&vm.id, |x| x.deletable_at = Some(lease_end)).await;

    // Attempting to destroy before `deletable_at` unregisters the node and schedules
    // `awaiting_deletable_at`, without calling provider.destroy prematurely.
    let deferred = m.destroy(&vm.id, "user_destroyed").await.unwrap();
    assert_eq!(deferred.state, MachineState::Online);
    assert_eq!(deferred.reap_at, Some(lease_end));
    assert_eq!(
        deferred.reap_reason.as_deref(),
        Some("awaiting_deletable_at:user_destroyed")
    );
    assert!(fake.destroyed.lock().unwrap().is_empty());

    // Once `deletable_at` passes, `reap_once` destroys the VM cleanly.
    m.update(&vm.id, |x| {
        let past = Utc::now() - chrono::Duration::seconds(5);
        x.deletable_at = Some(past);
        x.reap_at = Some(past);
    })
    .await;
    m.reap_once().await;
    assert_eq!(m.get(&vm.id).await.unwrap().state, MachineState::Destroyed);
    assert_eq!(fake.destroyed.lock().unwrap().len(), 1);
}

#[test]
fn multi_provider_planning_and_scaleway_commitment_gate() {
    let s = settings();
    let (hz, _) = ManagedManager::plan_for_provider(
        &s,
        "hetzner",
        &SpawnRequest {
            size: Some("large".into()),
            arch: Some("arm64".into()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(hz.size, "cax31");
    assert_eq!(hz.arch, "arm64");

    // CPU/RAM selection with arch="arm64" must pick cax31 instead of x86_64 cpx41.
    let (hz_cpu_ram, _) = ManagedManager::plan_for_provider(
        &s,
        "hetzner",
        &SpawnRequest {
            cpu: Some(8),
            ram_gb: Some(16),
            arch: Some("arm64".into()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(hz_cpu_ram.size, "cax31");

    // Requesting 16 vCPU arm64 on Hetzner has no matching size and must fail cleanly.
    let err_hz_arch = ManagedManager::plan_for_provider(
        &s,
        "hetzner",
        &SpawnRequest {
            cpu: Some(16),
            arch: Some("arm64".into()),
            ..Default::default()
        },
    )
    .unwrap_err();
    assert_eq!(err_hz_arch.error, "invalid_size");

    // Boat only offers x86_64 sizes.
    let err_boat_arch = ManagedManager::plan_for_provider(
        &s,
        "boat",
        &SpawnRequest {
            arch: Some("arm64".into()),
            ..Default::default()
        },
    )
    .unwrap_err();
    assert_eq!(err_boat_arch.error, "invalid_size");

    let err_bad_arch = ManagedManager::plan_for_provider(
        &s,
        "hetzner",
        &SpawnRequest {
            arch: Some("riscv64".into()),
            ..Default::default()
        },
    )
    .unwrap_err();
    assert_eq!(err_bad_arch.error, "invalid_arch");

    let (vast, _) = ManagedManager::plan_for_provider(
        &s,
        "vastai",
        &SpawnRequest {
            size: Some("a100".into()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(vast.size, "a100");
    assert_eq!(vast.gpu, Some("A100 SXM4"));

    // Scaleway Apple Silicon cannot bootstrap Linux orb-node workers: reject worker mode upfront.
    let worker_err = ManagedManager::plan_for_provider(
        &s,
        "scaleway",
        &SpawnRequest {
            size: Some("M2-M".into()),
            allow_24h_commitment: Some(true),
            ..Default::default()
        },
    )
    .unwrap_err();
    assert_eq!(worker_err.error, "unsupported_provisioning_mode");

    // Raw mode still requires explicit 24h commitment confirmation.
    let err = ManagedManager::plan_for_provider(
        &s,
        "scaleway",
        &SpawnRequest {
            size: Some("M2-M".into()),
            provisioning_mode: Some(ProvisioningMode::Raw),
            ..Default::default()
        },
    )
    .unwrap_err();
    assert_eq!(err.error, "commitment_confirmation_required");

    let (mac, _) = ManagedManager::plan_for_provider(
        &s,
        "scaleway",
        &SpawnRequest {
            size: Some("M2-M".into()),
            provisioning_mode: Some(ProvisioningMode::Raw),
            allow_24h_commitment: Some(true),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(mac.size, "M2-M");
    assert_eq!(mac.min_billing_hours, Some(24));
    assert!(!RuntimeSettings::default().reaper_dry_run);
}

#[tokio::test]
async fn scaleway_provider_spawn_rejects_apple_silicon_worker_before_network() {
    let scw =
        scaleway::ScalewayProvider::new("http://127.0.0.1:9", "dummy-key", Some("proj-1".into()));
    let spec = SpawnSpec {
        machine_id: "mmmac001".into(),
        size: "M2-M".into(),
        cpu: 8,
        ram_gb: 16,
        ttl_seconds: 3600,
        image: Some("macos-15".into()),
        name: "orb-managed-mmmac001".into(),
        idempotency_key: "orb-managed-mmmac001".into(),
        bootstrap_script: None,
        gpu: None,
        arch: Some("arm64".into()),
        max_hourly_usd: None,
        preferred_offer_id: None,
        exclude_offer_ids: Vec::new(),
        allow_24h_commitment: true,
        provisioning_mode: ProvisioningMode::Worker,
    };
    let err = scw.spawn(&spec).await.unwrap_err();
    assert!(err.contains("provisioning_mode: \"raw\""), "{err}");
}

#[test]
fn provider_for_never_aliases_boat_to_non_test_cloud_providers() {
    let dir = tempfile::tempdir().unwrap();
    let hz: Arc<dyn ManagedProvider> = Arc::new(hetzner::HetznerProvider::new(
        "http://127.0.0.1:9",
        "hz-key",
    ));
    let m = Arc::new(ManagedManager::new(settings(), Some(hz), dir.path(), 3000));
    assert!(
        m.provider_for("boat").is_none(),
        "boat must remain unconfigured so Bitwarden discovery can still register BoatProvider"
    );
    assert_eq!(m.provider_for("hetzner").unwrap().name(), "hetzner");

    // FakeProvider in unit tests still backs default "boat" rows.
    let (m_fake, _) = manager(dir.path(), settings());
    assert_eq!(m_fake.provider_for("boat").unwrap().name(), "fake");
}

#[tokio::test]
async fn vastai_quote_admits_real_offer_rate_and_enforces_cpu_ram_floors() {
    use axum::{
        routing::{post, put},
        Json, Router,
    };
    use std::sync::atomic::{AtomicUsize, Ordering};

    let asks_called = Arc::new(AtomicUsize::new(0));
    let asks_called_route = Arc::clone(&asks_called);

    let app = Router::new()
        .route(
            "/bundles/",
            post(|| async {
                Json(serde_json::json!({
                    "offers": [
                        // Cheaper offer, but undersized RAM (16 GB < 64 GB floor) -> must be skipped!
                        {"id": 101, "dph_total": 0.35, "cpu_cores_effective": 16.0, "cpu_ram": 16384.0},
                        // Undersized CPU (8 < 16 floor) -> must be skipped!
                        {"id": 102, "dph_total": 0.40, "cpu_cores_effective": 8.0, "cpu_ram": 65536.0},
                        // Valid 20 vCPU / 64 GB RTX 4090 offer at $0.68/h (above $0.45 catalog rate, within 1.6x ceiling)
                        {"id": 103, "dph_total": 0.68, "cpu_cores_effective": 20.0, "cpu_ram": 64512.0}
                    ]
                }))
            }),
        )
        .route(
            "/asks/:offer_id/",
            put(move |axum::extract::Path(offer_id): axum::extract::Path<String>| {
                let asks_called_route = Arc::clone(&asks_called_route);
                async move {
                    asks_called_route.fetch_add(1, Ordering::SeqCst);
                    assert_eq!(offer_id, "103", "must rent verified offer 103, never undersized 101/102");
                    Json(serde_json::json!({"success": true, "new_contract": 999001}))
                }
            }),
        );

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let srv = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });

    let dir = tempfile::tempdir().unwrap();
    let mut tight = settings();
    // 60 min at catalog $0.45/h would fit under $0.55 cap, but actual offer is $0.68/h!
    tight.daily_cap_usd = Some(0.55);
    let vast: Arc<dyn ManagedProvider> = Arc::new(vastai::VastAiProvider::new(
        format!("http://{addr}"),
        "vast-test-key",
    ));
    let m_tight = Arc::new(ManagedManager::new(
        tight,
        Some(Arc::clone(&vast)),
        dir.path(),
        3000,
    ));
    let rejected = m_tight
        .spawn(SpawnRequest {
            provider: Some("vastai".into()),
            size: Some("rtx4090".into()),
            ttl_minutes: Some(60),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(rejected.error, "budget_exceeded");
    assert_eq!(
        asks_called.load(Ordering::SeqCst),
        0,
        "budget admission must reject actual offer rate BEFORE renting any GPU"
    );

    // With $1.00 daily cap, spawn admits and records the quoted $0.68/h rate + 20 vCPU / 63 GB RAM.
    let dir2 = tempfile::tempdir().unwrap();
    let mut ample = settings();
    ample.daily_cap_usd = Some(1.00);
    let m_ample = Arc::new(ManagedManager::new(ample, Some(vast), dir2.path(), 3000));
    let spawned = m_ample
        .spawn(SpawnRequest {
            provider: Some("vastai".into()),
            size: Some("rtx4090".into()),
            ttl_minutes: Some(60),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();
    assert!((spawned.usd_per_hour - 0.68).abs() < 1e-6);
    assert_eq!(spawned.cpu, 20);
    assert_eq!(spawned.ram_gb, 63);
    srv.abort();
}

#[tokio::test]
async fn vastai_fallback_reconciles_machine_resources_and_regenerates_bootstrap() {
    use axum::{
        extract::Path,
        http::StatusCode,
        routing::{post, put},
        Json, Router,
    };

    let captured_9003_onstart: Arc<tokio::sync::Mutex<Option<String>>> =
        Arc::new(tokio::sync::Mutex::new(None));
    let captured_route = Arc::clone(&captured_9003_onstart);

    let app = Router::new()
        .route(
            "/bundles/",
            post(|| async {
                Json(serde_json::json!({
                    "offers": [
                        // Preferred offer 9002: 64 vCPU / 256 GB RAM @ $0.68/h (sniped on PUT)
                        {"id": 9002, "dph_total": 0.68, "cpu_cores_effective": 64.0, "cpu_ram": 262144.0},
                        // Replacement offer 9003: 20 vCPU / 64 GB RAM @ $0.55/h
                        {"id": 9003, "dph_total": 0.55, "cpu_cores_effective": 20.0, "cpu_ram": 65536.0}
                    ]
                }))
            }),
        )
        .route(
            "/asks/:offer_id/",
            put(move |Path(offer_id): Path<String>, Json(body): Json<Value>| {
                let captured_route = Arc::clone(&captured_route);
                async move {
                    if offer_id == "9002" {
                        return (
                            StatusCode::CONFLICT,
                            Json(serde_json::json!({"error": "offer 9002 already rented"})),
                        );
                    }
                    assert_eq!(offer_id, "9003");
                    let onstart = body
                        .get("onstart")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    *captured_route.lock().await = Some(onstart);
                    (
                        StatusCode::OK,
                        Json(serde_json::json!({"success": true, "new_contract": 999002})),
                    )
                }
            }),
        );

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let srv = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });

    let dir = tempfile::tempdir().unwrap();
    let mut cfg = settings();
    cfg.daily_cap_usd = Some(5.0);
    let vast: Arc<dyn ManagedProvider> = Arc::new(vastai::VastAiProvider::new(
        format!("http://{addr}"),
        "vast-test-key",
    ));
    let mgr = Arc::new(ManagedManager::new(cfg, Some(vast), dir.path(), 3000));
    let spawned = mgr
        .spawn(SpawnRequest {
            provider: Some("vastai".into()),
            size: Some("rtx4090".into()),
            ttl_minutes: Some(60),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();

    // Wait briefly for the spawned background provision task to hit PUT /asks/9002/ -> fallback PUT /asks/9003/.
    for _ in 0..50 {
        if mgr
            .get(&spawned.id)
            .await
            .and_then(|m| m.provider_id)
            .is_some()
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let reconciled = mgr.get(&spawned.id).await.unwrap();
    assert_eq!(reconciled.provider_id.as_deref(), Some("999002"));
    assert_eq!(reconciled.cpu, 20, "must reconcile CPU down from 64 to 20");
    assert_eq!(
        reconciled.ram_gb, 64,
        "must reconcile RAM down from 256 to 64"
    );
    assert!((reconciled.usd_per_hour - 0.55).abs() < 1e-6);

    let onstart = captured_9003_onstart
        .lock()
        .await
        .clone()
        .expect("onstart sent to 9003");
    assert!(
        onstart.contains("SANDBOXED_NODE_CAPACITY=10\n"),
        "regenerated bootstrap must advertise 10 slots (not 32): {onstart}"
    );
    assert!(
        onstart.contains(&format!(
            "SANDBOXED_NODE_JOB_MEMORY_BYTES={}\n",
            managed_job_memory_bytes(64)
        )),
        "regenerated bootstrap must cap job memory to 64 GB RAM (not 256 GB): {onstart}"
    );
    srv.abort();
}

#[test]
fn cloud_bootstrap_script_configures_user_bus_and_harnesses_within_onstart_budget() {
    let script = cloud_bootstrap_script(
        "https://agent-core.sandboxed.example.com",
        "0123456789abcdef0123456789abcdef",
        "managed-0123456789abcdef0123456789abcdef",
        &"a".repeat(64),
        16,
        managed_job_memory_bytes(64),
        "vastai",
        "gpu-rtx4090",
        "nvidia/cuda:12.4.1-devel-ubuntu22.04",
    );
    assert!(
        script.len() < 4096,
        "bootstrap script ({} bytes) must fit Vast.ai 4 KiB onstart limit",
        script.len()
    );
    assert!(script.contains("dbus-user-session"));
    assert!(script.contains("loginctl enable-linger orbnode"));
    assert!(script.contains(
        "for g in sudo adm admin wheel docker lxd; do q gpasswd -d orbnode \"$g\" || :; done"
    ));
    assert!(
        script.contains("for g in kvm video render; do q usermod -aG \"$g\" orbnode || :; done")
    );
    assert!(script.contains("XDG_RUNTIME_DIR=/run/user/${UID_N}"));
    assert!(script.contains("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${UID_N}/bus"));
    assert!(script.contains("orb_fetch sandboxed-node \"$B/sandboxed-node\" 0755"));
    assert!(script.contains("orb_fetch sandboxed-mcp \"$B/sandboxed-mcp\" 0755"));
    assert!(script.contains("orb_fetch update-node-codex \"$S/update-node-codex\" 0755"));
    assert!(script.contains("orb_fetch update-node-harnesses \"$S/update-node-harnesses\" 0755"));
    assert!(script.contains("update-node-harnesses\" --only \"$h\" --probe-user orbnode"));
    assert!(!script.contains("$H/enroll.env"));

    let syntax = std::process::Command::new("bash")
        .arg("-n")
        .arg("-c")
        .arg(&script)
        .output()
        .expect("bash -n");
    assert!(
        syntax.status.success(),
        "cloud_bootstrap_script failed bash -n: {}",
        String::from_utf8_lossy(&syntax.stderr)
    );
    let sh_syntax = std::process::Command::new("sh")
        .arg("-n")
        .arg("-c")
        .arg(&script)
        .output()
        .expect("sh -n");
    assert!(
        sh_syntax.status.success(),
        "cloud_bootstrap_script failed POSIX sh -n: {}",
        String::from_utf8_lossy(&sh_syntax.stderr)
    );
    assert!(
        !script.contains("pipefail"),
        "onstart runs under /bin/sh (dash on Ubuntu), which rejects set -o pipefail"
    );
}

#[tokio::test]
async fn provider_catalog_and_list_view_match_shared_cross_client_fixture() {
    let dir = tempfile::tempdir().unwrap();
    let m = Arc::new(ManagedManager::new(settings(), None, dir.path(), 3000));
    m.register_base_credential("boat", "bitwarden", "boat-secret-1234", None, None);
    m.update_provider_config(
        "hetzner",
        ProviderUpdateRequest {
            enabled: Some(true),
            api_key: Some("hz-secret-5678".into()),
            region: Some("fsn1".into()),
            project_id: None,
            ..Default::default()
        },
    )
    .unwrap();
    m.update_provider_config(
        "scaleway",
        ProviderUpdateRequest {
            enabled: Some(false),
            ..Default::default()
        },
    )
    .unwrap();

    let catalog = m.provider_catalog();
    assert_eq!(catalog.len(), 4);
    assert_eq!(catalog[0].provider, "boat");
    assert_eq!(catalog[0].display_name, "boat.dev");
    assert!(catalog[0].configured);
    assert!(catalog[0].enabled);
    assert_eq!(catalog[0].credential_source.as_deref(), Some("bitwarden"));
    assert_eq!(catalog[0].key_hint.as_deref(), Some("••••1234"));
    assert!(catalog[0].supports_free_stop);
    assert!(catalog[0].supports_snapshots);

    assert_eq!(catalog[1].provider, "hetzner");
    assert_eq!(catalog[1].display_name, "Hetzner Cloud");
    assert!(catalog[1].configured);
    assert!(catalog[1].enabled);
    assert_eq!(catalog[1].credential_source.as_deref(), Some("settings"));
    assert_eq!(catalog[1].key_hint.as_deref(), Some("••••5678"));
    assert_eq!(catalog[1].region.as_deref(), Some("fsn1"));
    assert!(!catalog[1].supports_free_stop);
    assert!(!catalog[1].supports_snapshots);

    assert_eq!(catalog[2].provider, "vastai");
    assert!(!catalog[2].configured);
    assert!(catalog[2].enabled);
    assert_eq!(catalog[3].provider, "scaleway");
    assert!(!catalog[3].configured);
    assert!(!catalog[3].enabled);
    assert!(
        catalog[3]
            .sizes
            .iter()
            .all(|s| !scaleway::is_apple_silicon_type(s.size)),
        "worker catalog must not advertise macOS-only Apple Silicon sizes"
    );

    let t0 = chrono::DateTime::parse_from_rfc3339("2026-10-29T10:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let t1 = chrono::DateTime::parse_from_rfc3339("2026-10-29T12:00:00Z")
        .unwrap()
        .with_timezone(&Utc);
    let sample_machine = ManagedMachine {
        id: "mm1001".into(),
        name: "cpx42-a".into(),
        provider: "hetzner".into(),
        provider_id: Some("42001".into()),
        node_id: "managed-mm1001".into(),
        provisioning_mode: ProvisioningMode::Worker,
        antigravity_projected: false,
        image: "ubuntu-24.04".into(),
        size: "cpx42".into(),
        cpu: 8,
        ram_gb: 16,
        disk_gb: 320,
        usd_per_hour: 0.12,
        state: MachineState::Online,
        created_at: t0,
        expires_at: t1,
        online_at: Some(t0),
        destroyed_at: None,
        destroy_reason: None,
        cost_usd: 0.06,
        cost_is_metered: false,
        owner_kind: Some("mission".into()),
        requested_by_mission_id: None,
        owner_mission_id: Some("550e8400-e29b-41d4-a716-446655440000".into()),
        owner_user_id: Some("user-1".into()),
        reason: Some("Lean proof shard".into()),
        reap_at: None,
        reap_reason: None,
        error: None,
        ledger_closed: false,
        last_busy_at: Some(t0),
        budget_pool_id: None,
        cap_pool_id: None,
        auto_extensions: 0,
        stopped_at: None,
        stopped_by_reaper: false,
        source_snapshot: None,
        forked_from: None,
        fork_source_provider_id: None,
        resumes: 0,
        secrets_wiped: false,
        run_started_at: None,
        cost_before_resume: 0.0,
        prior_pool_charges: Vec::new(),
        pool_spent_offset: 0.0,
        project: Some("verity".into()),
        root_mission_id: Some("550e8400-e29b-41d4-a716-446655440000".into()),
        active_mission_ids: vec!["550e8400-e29b-41d4-a716-446655440000".into()],
        deletable_at: None,
        has_executed_job: true,
    };
    let view = ListView {
        enabled: true,
        provider: "boat".into(),
        providers: catalog,
        machines: vec![sample_machine.clone()],
        budget: BudgetView {
            spent_today_usd: 0.06,
            committed_usd: 0.18,
            daily_cap_usd: Some(50.0),
            active: 1,
            shared_active: 1,
            max_concurrent: Some(16),
            default_ttl_minutes: 60,
            max_ttl_minutes: 720,
            default_size: "small".into(),
            max_size: "xlarge".into(),
            image: "orb-node-base".into(),
        },
        sizes: SIZES.to_vec(),
        daily_spend: daily_spend(&[sample_machine], 7, t0 + chrono::Duration::minutes(30)),
    };
    let actual = serde_json::to_value(&view).unwrap();
    let fixture_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("shared/orb-spec/fixtures/managed-machines-response.json");
    let expected: Value =
        serde_json::from_str(&std::fs::read_to_string(&fixture_path).expect("read fixture"))
            .expect("parse fixture");
    assert_eq!(actual, expected);
}

#[tokio::test]
async fn provider_enable_disable_and_encrypted_config_lifecycle() {
    let dir = tempfile::tempdir().unwrap();
    let fake_p: Arc<dyn ManagedProvider> = Arc::new(FakeProvider::default());
    let m = Arc::new(ManagedManager::new(
        settings(),
        Some(Arc::clone(&fake_p)),
        dir.path(),
        3000,
    ));
    m.register_base_credential("hetzner", "bitwarden", "bw-hetzner-key-9999", None, None);

    // Settings override encrypts secret on disk, never writes raw plaintext, and wins over bitwarden.
    let updated = m
        .update_provider_config(
            "hetzner",
            ProviderUpdateRequest {
                enabled: Some(true),
                api_key: Some("ui-hetzner-secret-abcd".into()),
                region: Some("hel1".into()),
                project_id: None,
                ..Default::default()
            },
        )
        .unwrap();
    assert!(updated.configured);
    assert!(updated.enabled);
    assert_eq!(updated.credential_source.as_deref(), Some("settings"));
    assert_eq!(updated.key_hint.as_deref(), Some("••••abcd"));
    assert_eq!(updated.region.as_deref(), Some("hel1"));

    let on_disk =
        std::fs::read_to_string(dir.path().join(".sandboxed-sh/managed_providers.json")).unwrap();
    assert!(!on_disk.contains("ui-hetzner-secret-abcd"));
    let parsed: serde_json::Value = serde_json::from_str(&on_disk).unwrap();
    let stored = parsed["hetzner"]["encrypted_api_key"].as_str().unwrap();
    assert!(crate::library::env_crypto::is_encrypted(stored));

    // Clearing the settings override falls back to the Bitwarden credential while keeping region override.
    let cleared = m
        .update_provider_config(
            "hetzner",
            ProviderUpdateRequest {
                api_key: Some(String::new()),
                ..Default::default()
            },
        )
        .unwrap();
    assert!(cleared.configured);
    assert_eq!(cleared.credential_source.as_deref(), Some("bitwarden"));
    assert_eq!(cleared.key_hint.as_deref(), Some("••••9999"));
    assert_eq!(cleared.region.as_deref(), Some("hel1"));

    // Disabling Hetzner blocks new spawns with 409 provider_disabled, while provider_for remains live for reaping.
    let disabled = m
        .update_provider_config(
            "hetzner",
            ProviderUpdateRequest {
                enabled: Some(false),
                ..Default::default()
            },
        )
        .unwrap();
    assert!(!disabled.enabled);
    assert!(m.provider_for("hetzner").is_some());

    let err = m
        .spawn(SpawnRequest {
            provider: Some("hetzner".into()),
            size: Some("cpx32".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(err.error, "provider_disabled");
    assert_eq!(err.status, 409);

    // Reloading from disk preserves both disabled_providers and encrypted provider overrides.
    let m2 = Arc::new(ManagedManager::new(settings(), None, dir.path(), 3000));
    m2.load().await;
    m2.update_provider_config(
        "scaleway",
        ProviderUpdateRequest {
            enabled: Some(true),
            api_key: Some("scw-secret-xyz1234".into()),
            region: Some("nl-ams-1".into()),
            project_id: Some("proj-uuid-1".into()),
            ..Default::default()
        },
    )
    .unwrap();
    let m3 = Arc::new(ManagedManager::new(settings(), None, dir.path(), 3000));
    m3.load().await;
    assert!(!m3.is_provider_enabled("hetzner"));
    let scw = m3
        .provider_catalog()
        .into_iter()
        .find(|p| p.provider == "scaleway")
        .unwrap();
    assert!(scw.configured);
    assert_eq!(scw.credential_source.as_deref(), Some("settings"));
    assert_eq!(scw.key_hint.as_deref(), Some("••••1234"));
    assert_eq!(scw.region.as_deref(), Some("nl-ams-1"));
    assert_eq!(scw.project_id.as_deref(), Some("proj-uuid-1"));
}

#[tokio::test]
async fn reconcile_closes_vanished_destroying_rows_even_when_list_is_empty() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let online = online_machine(&m, "owner-online").await;
    let stuck = online_machine(&m, "owner-destroying").await;
    m.update(&stuck.id, |row| {
        row.state = MachineState::Destroying;
        row.destroy_reason = Some("stopped: owner_interrupted_idle".into());
        row.error = Some("destroy failed: HTTP 403 api_key_action_forbidden".into());
    })
    .await;

    // First pass: neither closed yet.
    let r1 = m.reconcile_once().await.unwrap();
    assert_eq!(r1["vanished_rows"], serde_json::json!([]));
    assert_eq!(
        m.get(&stuck.id).await.unwrap().state,
        MachineState::Destroying
    );
    assert_eq!(m.get(&online.id).await.unwrap().state, MachineState::Online);

    // Second pass with empty list: Destroying closes as vanished, Online stays protected.
    let r2 = m.reconcile_once().await.unwrap();
    assert_eq!(r2["vanished_rows"], serde_json::json!([stuck.id.clone()]));
    let closed = m.get(&stuck.id).await.unwrap();
    assert_eq!(closed.state, MachineState::Destroyed);
    assert!(closed.ledger_closed);
    assert_eq!(m.get(&online.id).await.unwrap().state, MachineState::Online);
}

#[test]
fn retryable_exec_error_matches_transient_sandbox_proxy_faults() {
    assert!(super::is_retryable_exec_error(
        "boat POST /sandboxes/bx_123/commands -> HTTP 502 sandbox_direct_failed: Failed to execute command in sandbox"
    ));
    assert!(super::is_retryable_exec_error(
        "HTTP 503 Service Unavailable"
    ));
    assert!(!super::is_retryable_exec_error("exit code 1"));
    assert!(!super::is_retryable_exec_error("HTTP 403 forbidden"));
}

#[test]
fn resource_ledger_gate_conserves_slots_budget_ttl_and_zero_divergences() {
    use crate::orb_spec::ResourceLedgerOp;

    let r0 = super::evaluate_resource_ledger_gate(
        ResourceLedgerOp::Reserve,
        0,
        1,
        2,
        400,
        300,
        1_000,
        10,
        100,
    );
    assert!(r0.admitted);
    assert_eq!(r0.next_reserved_slots, 1);
    assert_eq!(r0.next_active_slots, 1);

    let over_cap = super::evaluate_resource_ledger_gate(
        ResourceLedgerOp::Reserve,
        1,
        1,
        2,
        400,
        100,
        1_000,
        10,
        100,
    );
    assert!(!over_cap.admitted);
    assert_eq!(over_cap.next_reserved_slots, 1);

    let act = super::evaluate_resource_ledger_gate(
        ResourceLedgerOp::ActivateReserved,
        1,
        1,
        2,
        700,
        0,
        1_000,
        20,
        100,
    );
    assert!(act.admitted);
    assert_eq!(act.next_reserved_slots, 0);
    assert_eq!(act.next_active_slots, 2);

    let reap = super::evaluate_resource_ledger_gate(
        ResourceLedgerOp::ReapExpired,
        1,
        0,
        2,
        700,
        0,
        1_000,
        100,
        100,
    );
    assert!(reap.admitted);
    assert_eq!(reap.next_reserved_slots, 0);

    let snap = super::resource_ledger_shadow_counter().snapshot("orb_resource_ledger_step");
    assert!(snap.total_events >= 4);
    assert_eq!(snap.total_divergences, 0);
}

struct NamedFakeProvider {
    id: &'static str,
    inner: FakeProvider,
}

impl NamedFakeProvider {
    fn new(id: &'static str) -> Arc<dyn ManagedProvider> {
        Arc::new(Self {
            id,
            inner: FakeProvider::default(),
        })
    }
}

#[async_trait]
impl ManagedProvider for NamedFakeProvider {
    fn name(&self) -> &'static str {
        self.id
    }
    fn supports_free_stop(&self) -> bool {
        true
    }
    fn supports_snapshots(&self) -> bool {
        true
    }
    async fn spawn(&self, spec: &SpawnSpec) -> Result<ProviderMachine, String> {
        self.inner.spawn(spec).await
    }
    async fn get(&self, provider_id: &str) -> Result<ProviderMachine, String> {
        self.inner.get(provider_id).await
    }
    async fn list(&self) -> Result<Vec<ProviderMachine>, String> {
        self.inner.list().await
    }
    async fn destroy(&self, provider_id: &str) -> Result<(), String> {
        self.inner.destroy(provider_id).await
    }
    async fn extend(&self, provider_id: &str, ttl_seconds: u64) -> Result<(), String> {
        self.inner.extend(provider_id, ttl_seconds).await
    }
    async fn write_file(&self, provider_id: &str, path: &str, content: &str) -> Result<(), String> {
        self.inner.write_file(provider_id, path, content).await
    }
    async fn exec(
        &self,
        provider_id: &str,
        command: &str,
        timeout_secs: u64,
    ) -> Result<Value, String> {
        self.inner.exec(provider_id, command, timeout_secs).await
    }
    async fn usage(&self, provider_id: &str) -> Result<ProviderUsage, String> {
        self.inner.usage(provider_id).await
    }
}

#[tokio::test]
async fn mission_vm_limits_bypass_saturated_global_pool_and_enforce_per_provider_caps() {
    let dir = tempfile::tempdir().unwrap();
    let mut st = settings();
    st.max_concurrent = Some(2);
    st.daily_cap_usd = Some(100.0);
    let boat = NamedFakeProvider::new("boat");
    let vastai = NamedFakeProvider::new("vastai");
    let m = Arc::new(ManagedManager::new(st, Some(boat), dir.path(), 3000));
    m.providers.write().unwrap().insert("vastai".into(), vastai);

    // Fill the global concurrency cap (2/2) with un-overridden boat VMs.
    let g1 = m
        .spawn(SpawnRequest {
            provider: Some("boat".into()),
            size: Some("small".into()),
            owner_mission_id: Some("evm-1".into()),
            owner_user_id: Some("t1".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();
    let _g2 = m
        .spawn(SpawnRequest {
            provider: Some("boat".into()),
            size: Some("small".into()),
            owner_mission_id: Some("evm-2".into()),
            owner_user_id: Some("t1".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(g1.cap_pool_id, None);

    // Un-overridden Vast.ai spawn is blocked by global 2/2.
    let blocked = m
        .spawn(SpawnRequest {
            provider: Some("vastai".into()),
            size: Some("rtx4090".into()),
            owner_mission_id: Some("ecdsa".into()),
            owner_user_id: Some("t1".into()),
            cap_lineage: vec!["ecdsa".into()],
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(blocked.error, "quota_exceeded");
    assert_eq!(blocked.status, 429);

    // Configure per-provider override `vastai: 2` on `ecdsa` (leaving `boat` on global).
    m.set_mission_vm_limits(
        "ecdsa",
        Some(budget::VmConcurrencyLimits {
            max_concurrent: None,
            provider_max_concurrent: std::collections::BTreeMap::from([("vastai".into(), 2)]),
        }),
        &["ecdsa".into()],
        None,
        Some("t1".into()),
    )
    .await
    .unwrap();

    // `ecdsa` and its subagent `ecdsa-sub` can now spawn 2 Vast.ai GPUs despite global 2/2.
    let v1 = m
        .spawn(SpawnRequest {
            provider: Some("vastai".into()),
            size: Some("rtx4090".into()),
            owner_mission_id: Some("ecdsa".into()),
            owner_user_id: Some("t1".into()),
            cap_lineage: vec!["ecdsa".into()],
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(v1.cap_pool_id.as_deref(), Some("ecdsa"));

    let v2 = m
        .spawn(SpawnRequest {
            provider: Some("vastai".into()),
            size: Some("rtx4090".into()),
            owner_mission_id: Some("ecdsa-sub".into()),
            owner_user_id: Some("t1".into()),
            cap_lineage: vec!["ecdsa-sub".into(), "ecdsa".into()],
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(v2.cap_pool_id.as_deref(), Some("ecdsa"));

    // 3rd Vast.ai GPU in `ecdsa`'s tree is rejected by the mission's `vastai: 2` cap.
    let v3_err = m
        .spawn(SpawnRequest {
            provider: Some("vastai".into()),
            size: Some("rtx4090".into()),
            owner_mission_id: Some("ecdsa-sub".into()),
            owner_user_id: Some("t1".into()),
            cap_lineage: vec!["ecdsa-sub".into(), "ecdsa".into()],
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(v3_err.error, "quota_exceeded");
    assert!(v3_err.message.contains("provider max 2"));

    // Uncovered provider (`boat`) on `ecdsa` still respects the saturated global 2/2 pool.
    let boat_err = m
        .spawn(SpawnRequest {
            provider: Some("boat".into()),
            size: Some("small".into()),
            owner_mission_id: Some("ecdsa".into()),
            owner_user_id: Some("t1".into()),
            cap_lineage: vec!["ecdsa".into()],
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(boat_err.error, "quota_exceeded");

    // Dedicated VMs do NOT consume global slots: destroying `g1` frees 1 global slot even with 3 live VMs total.
    m.destroy(&g1.id, "done").await.unwrap();
    let g3 = m
        .spawn(SpawnRequest {
            provider: Some("boat".into()),
            size: Some("small".into()),
            owner_mission_id: Some("other".into()),
            owner_user_id: Some("t1".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(g3.cap_pool_id, None);
    assert_eq!(m.budget().await.active, 4);
    assert_eq!(m.budget().await.shared_active, 2);

    // View surfaces both mission override and global counts accurately.
    let view = m
        .mission_budget("ecdsa", &["ecdsa".into()], &["ecdsa-sub".into()], "t1")
        .await;
    assert_eq!(view.vm_limits_mode, "own");
    assert_eq!(view.effective_vm_limits.source, "mission");
    assert_eq!(view.effective_vm_limits.active, 2);
    assert_eq!(view.effective_vm_limits.max_concurrent, None);
    assert_eq!(view.effective_vm_limits.global_active, 2);
    assert_eq!(view.effective_vm_limits.global_max_concurrent, Some(2));
    assert_eq!(
        view.effective_vm_limits.provider_limits,
        vec![ProviderCapUsageView {
            provider: "vastai".into(),
            active: 2,
            max_concurrent: 2,
        }]
    );
}

#[tokio::test]
async fn mission_vm_limits_ancestor_ceiling_zero_provider_block_and_independent_usd_budget() {
    let dir = tempfile::tempdir().unwrap();
    let mut st = settings();
    st.max_concurrent = Some(1);
    st.daily_cap_usd = Some(100.0);
    let boat = NamedFakeProvider::new("boat");
    let hetzner = NamedFakeProvider::new("hetzner");
    let m = Arc::new(ManagedManager::new(st, Some(boat), dir.path(), 3000));
    m.providers
        .write()
        .unwrap()
        .insert("hetzner".into(), hetzner);

    m.set_mission_budget("root", Some(25.0), None, Some("t1".into()))
        .await
        .unwrap();
    m.set_mission_vm_limits(
        "root",
        Some(budget::VmConcurrencyLimits {
            max_concurrent: Some(3),
            provider_max_concurrent: std::collections::BTreeMap::from([("hetzner".into(), 0)]),
        }),
        &["root".into()],
        None,
        Some("t1".into()),
    )
    .await
    .unwrap();

    // Clearing USD budget preserves `vm_limits`, and re-setting USD budget preserves `vm_limits`.
    m.set_mission_budget("root", None, None, Some("t1".into()))
        .await
        .unwrap();
    let v_after_clear = m.mission_budget("root", &["root".into()], &[], "t1").await;
    assert_eq!(v_after_clear.mode, "none");
    assert_eq!(v_after_clear.vm_limits_mode, "own");
    assert_eq!(v_after_clear.effective_vm_limits.max_concurrent, Some(3));

    m.set_mission_budget("root", Some(20.0), None, Some("t1".into()))
        .await
        .unwrap();

    // Child cannot configure a sub-limit larger than ancestor's `max_concurrent` (3).
    let over = m
        .set_mission_vm_limits(
            "child",
            Some(budget::VmConcurrencyLimits {
                max_concurrent: Some(5),
                provider_max_concurrent: Default::default(),
            }),
            &["child".into(), "root".into()],
            Some("root".into()),
            Some("t1".into()),
        )
        .await
        .unwrap_err();
    assert_eq!(over.error, "sub_limit_exceeds_pool");

    // Child sets tighter `max_concurrent: 2` under `root`.
    m.set_mission_vm_limits(
        "child",
        Some(budget::VmConcurrencyLimits {
            max_concurrent: Some(2),
            provider_max_concurrent: Default::default(),
        }),
        &["child".into(), "root".into()],
        Some("root".into()),
        Some("t1".into()),
    )
    .await
    .unwrap();

    // Ancestor `hetzner: 0` blocks Hetzner even under child's `max_concurrent: 2`.
    let hz_err = m
        .spawn(SpawnRequest {
            provider: Some("hetzner".into()),
            size: Some("cpx22".into()),
            owner_mission_id: Some("child".into()),
            owner_user_id: Some("t1".into()),
            cap_lineage: vec!["child".into(), "root".into()],
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(hz_err.error, "quota_exceeded");
    assert!(hz_err.message.contains("disabled"));

    // Lowering `root` to `max_concurrent: 1` immediately caps `child` at 1 at runtime.
    m.set_mission_vm_limits(
        "root",
        Some(budget::VmConcurrencyLimits {
            max_concurrent: Some(1),
            provider_max_concurrent: std::collections::BTreeMap::from([("hetzner".into(), 0)]),
        }),
        &["root".into()],
        None,
        Some("t1".into()),
    )
    .await
    .unwrap();

    let _c1 = m
        .spawn(SpawnRequest {
            provider: Some("boat".into()),
            size: Some("small".into()),
            owner_mission_id: Some("child".into()),
            owner_user_id: Some("t1".into()),
            cap_lineage: vec!["child".into(), "root".into()],
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();
    let c2_err = m
        .spawn(SpawnRequest {
            provider: Some("boat".into()),
            size: Some("small".into()),
            owner_mission_id: Some("child".into()),
            owner_user_id: Some("t1".into()),
            cap_lineage: vec!["child".into(), "root".into()],
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(c2_err.error, "quota_exceeded");
    assert!(c2_err.message.contains("ancestor pool root"));
}

#[tokio::test]
async fn boat_global_limit_defaults_to_100_and_enforces_provider_cap() {
    let dir = tempfile::tempdir().unwrap();
    let mut st = settings();
    st.daily_cap_usd = None;
    st.max_concurrent = None; // Even with global pool unlimited, boat.dev defaults to 100.
    let m = Arc::new(ManagedManager::new(
        st,
        Some(NamedFakeProvider::new("boat")),
        dir.path(),
        3000,
    ));
    assert_eq!(m.provider_max_concurrent("boat"), Some(100));

    // Lower boat.dev's global provider cap via update_provider_config and verify enforcement + persistence.
    let entry = m
        .update_provider_config(
            "boat",
            ProviderUpdateRequest {
                max_concurrent: Some(Some(2)),
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!(entry.max_concurrent, Some(2));

    for _ in 0..2 {
        m.spawn(SpawnRequest {
            provider: Some("boat".into()),
            size: Some("small".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();
    }
    let third = m
        .spawn(SpawnRequest {
            provider: Some("boat".into()),
            size: Some("small".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert_eq!(third.error, "quota_exceeded");
    assert_eq!(third.status, 429);
    assert!(third.message.contains("provider max 2"));

    // Explicit `null` (`Some(None)`) lifts the provider cap and persists across reload.
    let lifted: ProviderUpdateRequest =
        serde_json::from_value(serde_json::json!({"max_concurrent": null})).unwrap();
    let unlim = m.update_provider_config("boat", lifted).unwrap();
    assert_eq!(unlim.max_concurrent, None);

    let st2 = settings();
    let m2 = Arc::new(ManagedManager::new(
        st2,
        Some(NamedFakeProvider::new("boat")),
        dir.path(),
        3000,
    ));
    m2.load().await;
    assert_eq!(m2.provider_max_concurrent("boat"), None);
}

#[tokio::test]
async fn vastai_splits_v0_and_v1_routes_and_guards_destroy_and_null_usage() {
    use axum::{
        extract::{Path, Query},
        http::StatusCode,
        routing::{get, post, put},
        Json, Router,
    };
    use std::sync::atomic::{AtomicBool, Ordering};

    let deleted = Arc::new(AtomicBool::new(false));
    let deleted_get = Arc::clone(&deleted);
    let deleted_del = Arc::clone(&deleted);

    let route_404 = || async {
        (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"success": false, "msg": "Not found"})),
        )
    };

    let app = Router::new()
        // v1 only serves `GET /api/v1/instances/`; every other route on v1 is 404.
        .route("/api/v1/bundles/", post(route_404))
        .route("/api/v1/asks/:offer_id/", put(route_404))
        .route(
            "/api/v1/instances/:id/",
            get(route_404).delete(route_404),
        )
        .route(
            "/api/v1/instances/",
            get(
                |Query(q): Query<std::collections::HashMap<String, String>>| async move {
                    if q.get("next_token").map(String::as_str) == Some("page2") {
                        Json(serde_json::json!({
                            "success": true,
                            "instances": [
                                {"id": 7002, "actual_status": "running", "cur_state": "running", "label": "orb-managed-mm2"}
                            ],
                            "next_token": null
                        }))
                    } else {
                        Json(serde_json::json!({
                            "success": true,
                            "instances": [
                                // Immediately after creation: actual_status is null while cur_state is "running".
                                {"id": 7001, "actual_status": null, "cur_state": "running", "label": "orb-managed-mm1"}
                            ],
                            "next_token": "page2"
                        }))
                    }
                },
            ),
        )
        // v0 deprecates `GET /api/v0/instances/` with 410, but serves bundles/asks/instance-by-id.
        .route(
            "/api/v0/instances/",
            get(|| async {
                (
                    StatusCode::GONE,
                    Json(serde_json::json!({"error": "deprecated_endpoint"})),
                )
            }),
        )
        .route(
            "/api/v0/bundles/",
            post(|| async {
                Json(serde_json::json!({
                    "offers": [
                        {"id": 501, "dph_total": 0.42, "cpu_cores_effective": 32.0, "cpu_ram": 128000.0}
                    ]
                }))
            }),
        )
        .route(
            "/api/v0/asks/:offer_id/",
            put(|Path(offer_id): Path<String>| async move {
                assert_eq!(offer_id, "501");
                Json(serde_json::json!({"success": true, "new_contract": 7001}))
            }),
        )
        .route(
            "/api/v0/instances/:id/",
            get(move |Path(id): Path<String>| {
                let deleted_get = Arc::clone(&deleted_get);
                async move {
                    if id == "route404" {
                        return (
                            StatusCode::NOT_FOUND,
                            Json(serde_json::json!({"success": false, "msg": "Not found"})),
                        );
                    }
                    if deleted_get.load(Ordering::SeqCst) {
                        (StatusCode::OK, Json(serde_json::json!({"instances": null})))
                    } else {
                        (
                            StatusCode::OK,
                            Json(serde_json::json!({
                                "instances": {
                                    "id": 7001,
                                    "cur_state": "running",
                                    "label": "orb-managed-mm1"
                                }
                            })),
                        )
                    }
                }
            })
            .delete(move |Path(id): Path<String>| {
                let deleted_del = Arc::clone(&deleted_del);
                async move {
                    if id == "route404" {
                        return (
                            StatusCode::NOT_FOUND,
                            Json(serde_json::json!({"success": false, "msg": "Not found"})),
                        );
                    }
                    if deleted_del.swap(true, Ordering::SeqCst) {
                        return (
                            StatusCode::NOT_FOUND,
                            Json(serde_json::json!({"success": false, "error": "no_such_instance"})),
                        );
                    }
                    (StatusCode::OK, Json(serde_json::json!({"success": true})))
                }
            }),
        );

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let srv = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });

    // Even when initialized with `/api/v1` (legacy env override), VastAiProvider routes v0/v1 properly.
    let p = vastai::VastAiProvider::new(format!("http://{addr}/api/v1"), "vast-key");
    let spec = SpawnSpec {
        machine_id: "mm1".into(),
        size: "rtx4090".into(),
        cpu: 16,
        ram_gb: 64,
        ttl_seconds: 1800,
        image: None,
        name: "orb-managed-mm1".into(),
        idempotency_key: "orb-managed-mm1".into(),
        bootstrap_script: Some("#!/usr/bin/env bash\n".into()),
        gpu: None,
        arch: None,
        max_hourly_usd: None,
        preferred_offer_id: None,
        exclude_offer_ids: Vec::new(),
        allow_24h_commitment: false,
        provisioning_mode: ProvisioningMode::Worker,
    };

    let quote = p.quote_spawn(&spec).await.unwrap().unwrap();
    assert_eq!(quote.offer_id.as_deref(), Some("501"));

    let created = p.spawn(&spec).await.unwrap();
    assert_eq!(created.provider_id, "7001");

    // Missing/null `actual_status` with `cur_state: "running"` stays `"loading"` (not ready).
    let got = p.get("7001").await.unwrap();
    assert_eq!(got.state, "loading");
    assert!(!p.is_ready_state(&got.state));

    // `list()` uses `/api/v1/instances/` and follows `next_token` pagination.
    let listed = p.list().await.unwrap();
    assert_eq!(listed.len(), 2);
    assert_eq!(listed[0].provider_id, "7001");
    assert_eq!(listed[0].state, "loading");
    assert_eq!(listed[1].provider_id, "7002");
    assert_eq!(listed[1].state, "running");

    // Generic route 404 (`"msg":"Not found"`) MUST fail rather than silently pretending to destroy.
    let route_err = p.destroy("route404").await.unwrap_err();
    assert!(route_err.contains("HTTP 404"));

    // First delete succeeds; second delete (`404 no_such_instance`) is idempotent; post-delete usage errors cleanly.
    p.destroy("7001").await.unwrap();
    p.destroy("7001").await.unwrap();
    assert!(p.usage("7001").await.is_err());

    let gpu_script = cloud_bootstrap_script(
        "https://agent-core.sandboxed.example.com",
        "0123456789abcdef0123456789abcdef",
        "managed-0123456789abcdef0123456789abcdef",
        &"b".repeat(64),
        16,
        managed_job_memory_bytes(64),
        "vastai",
        "rtx4090",
        "pytorch/pytorch:2.4.1-cuda12.4-cudnn9-devel",
    );
    assert!(gpu_script.contains(",lean,gpu\n"));
    assert!(gpu_script.contains("/usr/local/cuda/bin"));
    assert!(gpu_script.len() < 4096);

    srv.abort();
}

#[tokio::test]
async fn dispatch_reservation_reuses_unclaimed_vm_and_clears_on_claim() {
    let dir = tempfile::tempdir().unwrap();
    let (m, _) = manager(dir.path(), settings());
    let vm = m
        .spawn(SpawnRequest {
            wait: Some(false),
            ttl_minutes: Some(60),
            owner_mission_id: None,
            owner_user_id: Some("t1".into()),
            requested_by_mission_id: Some("parent-1".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    for _ in 0..100 {
        if m.get(&vm.id).await.unwrap().provider_id.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let vm = m
        .update(&vm.id, |x| {
            x.state = MachineState::Online;
            x.last_busy_at = Some(Utc::now());
        })
        .await
        .unwrap();
    m.record_dispatch_reservation("t1", "dispatch:parent-1:key-1", &vm.id)
        .await;

    // Retrying with the same `(tenant, parent, idempotency_key)` before claim
    // reuses the exact pre-spawned VM requested by `parent-1`.
    let reused = m
        .take_unclaimed_for_dispatch("t1", Some("parent-1"), "dispatch:parent-1:key-1")
        .await
        .expect("should reuse unclaimed reservation");
    assert_eq!(reused.id, vm.id);

    // Re-record to test tenant/parent isolation: another tenant or wrong parent
    // cannot hijack the reservation (and invalid lookups drop stale keys).
    assert!(m
        .take_unclaimed_for_dispatch("t2", Some("parent-1"), "dispatch:parent-1:key-1")
        .await
        .is_none());
    assert!(m
        .take_unclaimed_for_dispatch("t1", Some("other-parent"), "dispatch:parent-1:key-1")
        .await
        .is_none());
    m.record_dispatch_reservation("t1", "dispatch:parent-1:key-1", &vm.id)
        .await;

    // Once claimed for the child mission, the reservation is cleared and the VM
    // cannot be multiplexed onto a second concurrent child.
    let claimed = m
        .claim_for_mission(&vm.id, "child-1", Some("parent-1"), Some("t1"))
        .await
        .unwrap();
    assert_eq!(claimed.owner_mission_id.as_deref(), Some("child-1"));
    assert_eq!(claimed.requested_by_mission_id.as_deref(), Some("parent-1"));
    assert!(m
        .take_unclaimed_for_dispatch("t1", Some("parent-1"), "dispatch:parent-1:key-1")
        .await
        .is_none());
}

#[tokio::test]
async fn newest_ready_worker_snapshot_is_project_and_tenant_scoped_and_light_is_default() {
    let dir = tempfile::tempdir().unwrap();
    let mut st = settings();
    st.max_concurrent = None;
    let (m, _) = manager(dir.path(), st);
    let vm = online_machine(&m, "owner").await;
    let s1 = m
        .snapshot_machine(&vm.id, "older", Some("orb"), None, Some("t1"))
        .await
        .unwrap();
    let s2 = m
        .snapshot_machine(&vm.id, "newer", Some("orb"), None, Some("t1"))
        .await
        .unwrap();
    let _s3 = m
        .snapshot_machine(&vm.id, "saving-snap", Some("orb"), None, Some("t1"))
        .await
        .unwrap();
    {
        let mut snaps = m.snapshots.lock().await;
        snaps[0].status = "ready".into();
        snaps[0].created_at = Utc::now() - chrono::Duration::minutes(10);
        snaps[1].status = "ready".into();
        snaps[1].created_at = Utc::now() - chrono::Duration::minutes(1);
        // snaps[2] stays "saving" and must be ignored.
    }
    assert_ne!(s1.name, s2.name);
    assert_eq!(
        m.newest_ready_worker_snapshot(Some("t1"), Some("orb"))
            .await,
        Some(s2.name.clone())
    );
    assert_eq!(
        m.newest_ready_worker_snapshot(Some("t1"), Some("other"))
            .await,
        None
    );
    assert_eq!(
        m.newest_ready_worker_snapshot(Some("t2"), Some("orb"))
            .await,
        None
    );

    // Omitted `from_snapshot` or `"light"` / `"none"` / `"base"` boots clean base image with zero snapshot transfer.
    for opt in [
        None,
        Some("light".into()),
        Some("none".into()),
        Some("base".into()),
    ] {
        let clean = m
            .spawn(SpawnRequest {
                from_snapshot: opt,
                snapshot_project: Some("orb".into()),
                owner_user_id: Some("t1".into()),
                wait: Some(false),
                ..Default::default()
            })
            .await
            .unwrap();
        assert_eq!(clean.image, "orb-node-base");
        assert_eq!(clean.source_snapshot, None);
    }

    // Explicit `"latest"` selects the newest ready project snapshot.
    let warm = m
        .spawn(SpawnRequest {
            from_snapshot: Some("latest".into()),
            snapshot_project: Some("orb".into()),
            owner_user_id: Some("t1".into()),
            wait: Some(false),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(warm.image, s2.name);
    assert_eq!(warm.source_snapshot.as_deref(), Some(s2.name.as_str()));
}
