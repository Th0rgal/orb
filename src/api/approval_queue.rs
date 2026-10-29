//! One approval model for every request a mission can raise: secret access
//! (`secret_broker`), privileged access (`privilege_broker`) and mission
//! access (`mission_access`). Each store keeps its own records; this module
//! defines the common shape clients show ([`ApprovalItem`]), the digest that
//! pins what the approver saw, and the single admission rule every approval
//! goes through ([`admit`], the Lean `orb_verify_approval` gate).
//!
//! `GET /api/approvals/queue` lists pending items of every kind.
//! `POST /api/approvals/approve-all` approves a list of them with one device
//! signature: the body names each item by kind, id and digest, Core
//! re-derives every digest from its own state and admits the batch only if
//! every item passes the gate. Critical items (root, secret delete or move)
//! need `confirm_critical`. Per-kind approve/deny endpoints keep working.

use std::collections::HashSet;
use std::sync::Arc;

use axum::{extract::State, http::StatusCode, Extension, Json};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

use super::approval_flow::RequesterSubject;
use super::auth::AuthUser;
use super::mission_access::AccessRequest;
use super::privilege_broker::{PrivilegeRequest, PrivilegeScope};
use super::routes::AppState;
use super::secret_broker::{RequestKind, SecretRequest};
use crate::orb_spec::{approval_admitted, ApprovalAdmission, ApprovalRisk};

/// Most items one signature may approve: the device prompt must still say what it grants.
pub const MAX_BATCH: usize = 20;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalKind {
    Secret,
    Privilege,
    MissionAccess,
}

/// A pending request of any kind, as clients list it and as Core checks it.
#[derive(Debug, Clone, Serialize)]
pub struct ApprovalItem {
    pub kind: ApprovalKind,
    pub id: Uuid,
    pub requester_mission_id: Option<Uuid>,
    pub requester_title: Option<String>,
    pub requester_subject: RequesterSubject,
    pub requester_label: Option<String>,
    /// Kind-specific action: `ops_read` / `service_deploy` / `root_exec`,
    /// `read` / `write` / `delete` / `move`, or `read_mission`.
    pub tier: String,
    /// What it applies to: a host, a secret or project, or a mission id.
    pub target: String,
    pub risk: &'static str,
    pub reason: String,
    pub created_at: DateTime<Utc>,
    /// SHA-256 over every field that changes what approving grants.
    pub digest: String,
    /// The kind's own request as its list endpoint shows it, for labels.
    pub request: Value,
    #[serde(skip)]
    pub risk_tier: ApprovalRisk,
}

fn risk_label(r: ApprovalRisk) -> &'static str {
    match r {
        ApprovalRisk::Routine => "routine",
        ApprovalRisk::Elevated => "elevated",
        ApprovalRisk::Critical => "critical",
    }
}

/// Domain-separated approval digest:
/// - `RequesterSubject::Mission { mission_id }` preserves `"orb-approval-v1\n{kind}\n{id}\n{mission_id}..."`
///   byte-for-byte so existing mission approvals and `LegacyPrivilegeBatch` never regress.
/// - `RequesterSubject::ExternalSession { .. }` uses `"orb-approval-v2\n{kind}\n{id}\n{canonical_subject}..."`.
pub fn subject_digest(
    kind: ApprovalKind,
    id: Uuid,
    subject: &RequesterSubject,
    fields: &[&str],
) -> String {
    let kind = serde_json::to_value(kind).unwrap_or_default();
    let kind_str = kind.as_str().unwrap_or("");
    let mut text = match subject {
        RequesterSubject::Mission { mission_id } => {
            format!("orb-approval-v1\n{kind_str}\n{id}\n{mission_id}")
        }
        RequesterSubject::ExternalSession { .. } => {
            format!(
                "orb-approval-v2\n{kind_str}\n{id}\n{}",
                subject.canonical_id()
            )
        }
    };
    for f in fields {
        text.push('\n');
        text.push_str(f);
    }
    super::approvals::sha256_hex(text.as_bytes())
}

impl ApprovalItem {
    #[allow(clippy::too_many_arguments)]
    fn new(
        kind: ApprovalKind,
        id: Uuid,
        subject: RequesterSubject,
        title: Option<String>,
        requester_label: Option<String>,
        tier: &str,
        target: String,
        risk: ApprovalRisk,
        reason: &str,
        created_at: DateTime<Utc>,
        extra: &[&str],
        request: Value,
    ) -> Self {
        let mut fields = vec![tier, target.as_str()];
        fields.extend_from_slice(extra);
        let requester_mission_id = subject.mission_id();
        let resolved_label = requester_label.or_else(|| subject.external_display_label());
        let digest = subject_digest(kind, id, &subject, &fields);
        Self {
            kind,
            id,
            requester_mission_id,
            requester_title: title,
            requester_subject: subject,
            requester_label: resolved_label,
            tier: tier.into(),
            digest,
            target,
            risk: risk_label(risk),
            risk_tier: risk,
            reason: reason.into(),
            created_at,
            request,
        }
    }

    pub fn privilege(r: &PrivilegeRequest) -> Self {
        let risk = match r.scope {
            PrivilegeScope::OpsRead => ApprovalRisk::Routine,
            PrivilegeScope::ServiceDeploy => ApprovalRisk::Elevated,
            PrivilegeScope::RootExec => ApprovalRisk::Critical,
        };
        Self::new(
            ApprovalKind::Privilege,
            r.id,
            r.subject(),
            r.requester_title.clone(),
            r.requester_label.clone(),
            r.scope.as_str(),
            r.target_host.clone(),
            risk,
            &r.reason,
            r.created_at,
            &[
                r.allowed_unit.as_deref().unwrap_or(""),
                &r.ttl_minutes.to_string(),
                if r.session_scoped { "session" } else { "fixed" },
            ],
            json!(r),
        )
    }

    pub fn secret(r: &SecretRequest) -> Self {
        let (tier, risk) = match r.kind {
            RequestKind::Read if r.all_projects => ("read", ApprovalRisk::Elevated),
            RequestKind::Read => ("read", ApprovalRisk::Routine),
            RequestKind::Write => ("write", ApprovalRisk::Elevated),
            RequestKind::Delete => ("delete", ApprovalRisk::Critical),
            RequestKind::Move => ("move", ApprovalRisk::Critical),
        };
        let target = match (&r.key, &r.project_id) {
            (Some(k), _) => k.clone(),
            (None, Some(p)) => p.clone(),
            (None, None) => "*".into(),
        };
        Self::new(
            ApprovalKind::Secret,
            r.id,
            r.subject(),
            r.mission_title.clone(),
            r.requester_label.clone(),
            tier,
            target,
            risk,
            &r.reason,
            r.created_at,
            &[
                r.project_id.as_deref().unwrap_or(""),
                if r.all_projects { "all" } else { "" },
                r.target_project_id.as_deref().unwrap_or(""),
                // A write is pinned to the value it would store.
                r.value_sha256.as_deref().unwrap_or(""),
            ],
            r.public(),
        )
    }

    pub fn mission_access(r: &AccessRequest) -> Self {
        Self::new(
            ApprovalKind::MissionAccess,
            r.id,
            r.subject(),
            r.requester_title.clone(),
            r.requester_label.clone(),
            "read_mission",
            r.target_mission_id.to_string(),
            ApprovalRisk::Elevated,
            &r.reason,
            r.created_at,
            &[&r.ttl_hours.to_string()],
            json!(r),
        )
    }
}

/// A request as a per-kind list shows it, plus its approval `digest` while
/// pending, so any screen can sign an "Approve all" without a second fetch.
pub fn listed(mut v: Value, pending: bool, item: impl FnOnce() -> ApprovalItem) -> Value {
    if pending {
        if let Some(o) = v.as_object_mut() {
            o.insert("digest".into(), Value::String(item().digest));
        }
    }
    v
}

/// One item of a signed batch: what the approver saw, by digest.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BatchRef {
    pub kind: ApprovalKind,
    pub id: Uuid,
    pub digest: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BatchBody {
    pub items: Vec<BatchRef>,
    /// Critical items are only approved when the approver ticked them.
    #[serde(default)]
    pub confirm_critical: bool,
}

impl BatchBody {
    pub fn check_shape(&self) -> Result<(), String> {
        if self.items.is_empty() {
            return Err("Nothing to approve".into());
        }
        if self.items.len() > MAX_BATCH {
            return Err(format!("At most {MAX_BATCH} requests per approval"));
        }
        let mut seen = HashSet::new();
        if !self.items.iter().all(|i| seen.insert((i.kind, i.id))) {
            return Err("A request is listed twice".into());
        }
        Ok(())
    }

    pub fn of(&self, kind: ApprovalKind) -> Vec<BatchRef> {
        self.items
            .iter()
            .filter(|i| i.kind == kind)
            .cloned()
            .collect()
    }
}

/// The one admission rule (`orb_verify_approval`). `current` is the request as
/// the store holds it now, `None` when it is unknown to (or not owned by) the
/// approver; the store only returns pending, unexpired requests. Callers run
/// behind the device-signature middleware, so the batch is signed.
pub fn admit(current: Option<&ApprovalItem>, want: &BatchRef, confirm: bool) -> Result<(), String> {
    let found = current.filter(|c| c.kind == want.kind && c.id == want.id);
    let admitted = approval_admitted(ApprovalAdmission {
        signed: true,
        owned: found.is_some(),
        pending: found.is_some(),
        unexpired: found.is_some(),
        unchanged: found.is_some_and(|c| c.digest == want.digest),
        risk: found.map_or(ApprovalRisk::Critical, |c| c.risk_tier),
        confirmed: confirm,
    });
    if admitted {
        return Ok(());
    }
    Err(match found {
        None => format!(
            "Request {} is no longer pending; nothing was approved",
            want.id
        ),
        Some(c) if c.digest != want.digest => {
            format!(
                "Request {} changed since it was shown; nothing was approved",
                want.id
            )
        }
        Some(_) => "Critical requests must be confirmed explicitly; nothing was approved".into(),
    })
}

/// Pending items of every kind for `owner`, newest first.
pub async fn pending(state: &Arc<AppState>, owner: &str) -> Vec<ApprovalItem> {
    let mut items = super::privilege_broker::store(state)
        .pending_items(owner)
        .await;
    items.extend(
        super::mission_access::store(state)
            .pending_items(owner)
            .await,
    );
    items.extend(super::secret_broker::broker(state).pending_items().await);
    items.sort_by_key(|i| std::cmp::Reverse(i.created_at));
    items
}

/// Core's text for the device prompt: counts by risk first so the length cap
/// never hides a critical item, then what each item grants.
pub fn summary(items: &[ApprovalItem]) -> String {
    use super::approvals::quoted;
    let count = |r: ApprovalRisk| items.iter().filter(|i| i.risk_tier == r).count();
    let tiers: Vec<String> = [
        ApprovalRisk::Critical,
        ApprovalRisk::Elevated,
        ApprovalRisk::Routine,
    ]
    .into_iter()
    .filter(|r| count(*r) > 0)
    .map(|r| format!("{} {}", count(r), risk_label(r).to_uppercase()))
    .collect();
    let mut sorted: Vec<&ApprovalItem> = items.iter().collect();
    sorted.sort_by_key(|i| std::cmp::Reverse(i.risk_tier));
    let what: Vec<String> = sorted
        .iter()
        .map(|i| match i.requester_label.as_deref() {
            Some(label) if i.requester_subject.is_external() => {
                format!(
                    "{} {} for {}",
                    i.tier.to_uppercase(),
                    quoted(&i.target),
                    quoted(label)
                )
            }
            _ => format!("{} {}", i.tier.to_uppercase(), quoted(&i.target)),
        })
        .collect();
    format!(
        "Approve {} requests ({}): {}",
        items.len(),
        tiers.join(", "),
        what.join("; ")
    )
}

/// The items a batch names, checked against current state (for the prompt).
pub async fn describe(
    state: &Arc<AppState>,
    owner: &str,
    body: &BatchBody,
) -> Result<String, String> {
    body.check_shape()?;
    let current = pending(state, owner).await;
    let mut chosen = Vec::with_capacity(body.items.len());
    for want in &body.items {
        let c = current
            .iter()
            .find(|c| c.kind == want.kind && c.id == want.id);
        admit(c, want, body.confirm_critical)?;
        chosen.extend(c.cloned());
    }
    Ok(summary(&chosen))
}

/// Body of `POST /api/privilege-access/approve-all` as 1.14 clients send it:
/// each request's fields instead of a digest. Kept so those builds keep
/// working; it is translated into a [`BatchBody`] and goes through the same
/// path. A field that no longer matches yields a digest that cannot match.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LegacyPrivilegeBatch {
    pub items: Vec<LegacyPrivilegeItem>,
    #[serde(default)]
    pub confirm_root: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LegacyPrivilegeItem {
    pub id: Uuid,
    pub requester_mission_id: Uuid,
    pub target_host: String,
    pub scope: PrivilegeScope,
    #[serde(default)]
    pub allowed_unit: Option<String>,
    pub ttl_minutes: i64,
    pub session_scoped: bool,
}

impl LegacyPrivilegeBatch {
    pub fn into_batch(self) -> BatchBody {
        BatchBody {
            items: self
                .items
                .into_iter()
                .map(|i| {
                    // The digest of the request exactly as the client described it.
                    let seen: PrivilegeRequest = serde_json::from_value(json!({
                        "id": i.id, "owner": "", "requester_mission_id": i.requester_mission_id,
                        "target_host": i.target_host, "scope": i.scope, "allowed_unit": i.allowed_unit,
                        "reason": "", "session_scoped": i.session_scoped, "ttl_minutes": i.ttl_minutes,
                        "state": "pending", "created_at": Utc::now(),
                    }))
                    .expect("privilege request from typed fields");
                    BatchRef {
                        kind: ApprovalKind::Privilege,
                        id: i.id,
                        digest: ApprovalItem::privilege(&seen).digest,
                    }
                })
                .collect(),
            confirm_critical: self.confirm_root,
        }
    }
}

pub async fn approve_all_legacy_privilege(
    state: State<Arc<AppState>>,
    user: Extension<AuthUser>,
    Json(body): Json<LegacyPrivilegeBatch>,
) -> Result<Json<Value>, (StatusCode, String)> {
    let batch = body.into_batch();
    if batch
        .items
        .iter()
        .any(|i| i.kind != ApprovalKind::Privilege)
    {
        return Err((StatusCode::BAD_REQUEST, "Privilege requests only".into()));
    }
    let out = approve_all(state, user, Json(batch)).await?;
    Ok(Json(out.0["privilege"].clone()))
}

pub async fn queue(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
) -> Json<Value> {
    Json(json!({ "items": pending(&state, &user.id).await }))
}

/// Approve every listed item or none. Stores are checked (and, for the two
/// in-memory stores, approved) under their own lock in a fixed order:
/// privilege, mission access, then secrets, whose writes call Bitwarden and
/// report a failure per item.
pub async fn approve_all(
    State(state): State<Arc<AppState>>,
    Extension(user): Extension<AuthUser>,
    Json(body): Json<BatchBody>,
) -> Result<Json<Value>, (StatusCode, String)> {
    let conflict = |e: String| (StatusCode::CONFLICT, e);
    body.check_shape().map_err(conflict)?;
    // Check everything before changing anything.
    let current = pending(&state, &user.id).await;
    for want in &body.items {
        let c = current
            .iter()
            .find(|c| c.kind == want.kind && c.id == want.id);
        admit(c, want, body.confirm_critical).map_err(conflict)?;
    }
    let mission_refs = body.of(ApprovalKind::MissionAccess);
    if !mission_refs.is_empty() {
        let access = super::mission_access::store(&state);
        let missions = state.control.get_or_spawn(&user).await.mission_store;
        for want in &mission_refs {
            let target = access
                .get(&user.id, want.id)
                .await
                .map(|r| r.target_mission_id);
            let owned = match target {
                Some(t) => matches!(missions.get_mission(t).await, Ok(Some(_))),
                None => false,
            };
            if !owned {
                return Err((
                    StatusCode::FORBIDDEN,
                    "You do not own the target mission".into(),
                ));
            }
        }
    }
    let privileges = super::privilege_broker::store(&state)
        .approve_batch(
            &user.id,
            &body.of(ApprovalKind::Privilege),
            body.confirm_critical,
        )
        .await
        .map_err(conflict)?;
    for r in &privileges {
        super::privilege_broker::notify_requester(&state, r).await;
    }
    let accesses = super::mission_access::store(&state)
        .approve_batch(&user.id, &mission_refs, body.confirm_critical)
        .await
        .map_err(conflict)?;
    for r in &accesses {
        super::mission_access::notify_requester(&state, r).await;
    }
    let secrets = super::secret_broker::broker(&state)
        .approve_batch(
            &state,
            &body.of(ApprovalKind::Secret),
            body.confirm_critical,
        )
        .await
        .map_err(conflict)?;
    Ok(Json(json!({
        "privilege": privileges,
        "mission_access": accesses,
        "secret": secrets.iter().map(SecretRequest::public).collect::<Vec<_>>(),
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn priv_req(scope: PrivilegeScope) -> PrivilegeRequest {
        serde_json::from_value(json!({
            "id": Uuid::new_v4(), "owner": "thomas", "requester_mission_id": Uuid::new_v4(),
            "requester_title": "Ship", "target_host": "agent-core", "scope": scope,
            "reason": "deploy", "ttl_minutes": 60, "state": "pending", "created_at": Utc::now(),
        }))
        .unwrap()
    }

    fn reference(i: &ApprovalItem) -> BatchRef {
        BatchRef {
            kind: i.kind,
            id: i.id,
            digest: i.digest.clone(),
        }
    }

    const FIXTURE: &str = include_str!("../../shared/orb-spec/fixtures/approvals.json");

    #[test]
    fn gate_and_risk_match_shared_fixture() {
        let f: Value = serde_json::from_str(FIXTURE).unwrap();
        for c in f["gate"].as_array().unwrap() {
            let i = &c["input"];
            let b = |k: &str| i[k].as_u64() == Some(1);
            let risk = match i["risk"].as_u64() {
                Some(0) => ApprovalRisk::Routine,
                Some(1) => ApprovalRisk::Elevated,
                _ => ApprovalRisk::Critical,
            };
            let got = approval_admitted(ApprovalAdmission {
                signed: b("signed"),
                owned: b("owned"),
                pending: b("pending"),
                unexpired: b("unexpired"),
                unchanged: b("unchanged"),
                risk,
                confirmed: b("confirmed"),
            });
            assert_eq!(got, c["admitted"] == 1, "{}", c["name"]);
        }
        for c in f["risk"].as_array().unwrap() {
            let tier = c["tier"].as_str().unwrap();
            let item = match c["kind"].as_str().unwrap() {
                "privilege" => {
                    ApprovalItem::privilege(&priv_req(PrivilegeScope::from_str_opt(tier).unwrap()))
                }
                "secret" => ApprovalItem::secret(
                    &serde_json::from_value(json!({
                        "id": Uuid::new_v4(), "kind": tier, "status": "pending",
                        "mission_id": Uuid::new_v4(), "key": "K", "all_projects": c["all_projects"] == true,
                        "reason": "r", "created_at": Utc::now(),
                    }))
                    .unwrap(),
                ),
                _ => ApprovalItem::mission_access(
                    &serde_json::from_value(json!({
                        "id": Uuid::new_v4(), "owner": "thomas", "requester_mission_id": Uuid::new_v4(),
                        "target_mission_id": Uuid::new_v4(), "scope": "read", "reason": "r",
                        "ttl_hours": 4, "state": "pending", "created_at": Utc::now(),
                    }))
                    .unwrap(),
                ),
            };
            assert_eq!(
                (item.tier.as_str(), item.risk),
                (tier, c["risk"].as_str().unwrap()),
                "{c}"
            );
        }
        for d in f["digests"].as_array().unwrap() {
            let kind: ApprovalKind = serde_json::from_value(d["kind"].clone()).unwrap();
            let id = Uuid::parse_str(d["id"].as_str().unwrap()).unwrap();
            let subject: RequesterSubject = serde_json::from_value(d["subject"].clone()).unwrap();
            assert_eq!(
                subject.canonical_id(),
                d["canonical_subject"].as_str().unwrap(),
                "{}",
                d["name"]
            );
            let fields: Vec<&str> = d["fields"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap())
                .collect();
            let got = subject_digest(kind, id, &subject, &fields);
            assert_eq!(got, d["digest"].as_str().unwrap(), "{}", d["name"]);
        }
    }

    #[test]
    fn digest_pins_everything_approving_grants() {
        let r = priv_req(PrivilegeScope::ServiceDeploy);
        let base = ApprovalItem::privilege(&r).digest;
        for change in [
            |r: &mut PrivilegeRequest| r.scope = PrivilegeScope::RootExec,
            |r: &mut PrivilegeRequest| r.target_host = "ashur".into(),
            |r: &mut PrivilegeRequest| {
                let next = Uuid::new_v4();
                r.requester_mission_id = Some(next);
                r.requester = Some(RequesterSubject::mission(next));
            },
            |r: &mut PrivilegeRequest| r.ttl_minutes = 240,
            |r: &mut PrivilegeRequest| r.session_scoped = false,
            |r: &mut PrivilegeRequest| r.allowed_unit = Some("orb-core.service".into()),
        ] as [fn(&mut PrivilegeRequest); 6]
        {
            let mut c = r.clone();
            change(&mut c);
            assert_ne!(ApprovalItem::privilege(&c).digest, base);
        }
        // The reason is shown but does not change what is granted.
        let mut c = r.clone();
        c.reason = "other words".into();
        assert_eq!(ApprovalItem::privilege(&c).digest, base);
    }

    #[test]
    fn admit_is_the_shared_gate() {
        let item = ApprovalItem::privilege(&priv_req(PrivilegeScope::OpsRead));
        let want = reference(&item);
        assert!(admit(Some(&item), &want, false).is_ok());
        assert!(
            admit(None, &want, true).is_err(),
            "unknown, foreign or expired"
        );
        let tampered = BatchRef {
            digest: "0".repeat(64),
            ..want.clone()
        };
        assert!(admit(Some(&item), &tampered, true).is_err());
        let wrong_kind = BatchRef {
            kind: ApprovalKind::Secret,
            ..want
        };
        assert!(admit(Some(&item), &wrong_kind, true).is_err());
        let root = ApprovalItem::privilege(&priv_req(PrivilegeScope::RootExec));
        assert!(admit(Some(&root), &reference(&root), false).is_err());
        assert!(admit(Some(&root), &reference(&root), true).is_ok());
    }

    #[test]
    fn summary_leads_with_risk_counts_and_critical_items() {
        let items = [
            ApprovalItem::privilege(&priv_req(PrivilegeScope::OpsRead)),
            ApprovalItem::privilege(&priv_req(PrivilegeScope::RootExec)),
        ];
        let s = summary(&items);
        assert!(
            s.starts_with("Approve 2 requests (1 CRITICAL, 1 ROUTINE): ROOT_EXEC \"agent-core\"; "),
            "{s}"
        );
    }

    #[test]
    fn legacy_privilege_body_maps_onto_the_same_digest() {
        let r = priv_req(PrivilegeScope::ServiceDeploy);
        let legacy = |host: &str| LegacyPrivilegeBatch {
            items: vec![LegacyPrivilegeItem {
                id: r.id,
                requester_mission_id: r.requester_mission_id.unwrap(),
                target_host: host.into(),
                scope: r.scope,
                allowed_unit: r.allowed_unit.clone(),
                ttl_minutes: r.ttl_minutes,
                session_scoped: r.session_scoped,
            }],
            confirm_root: false,
        };
        let item = ApprovalItem::privilege(&r);
        let same = legacy(&r.target_host).into_batch();
        assert_eq!(same.items[0].digest, item.digest);
        assert!(admit(Some(&item), &same.items[0], false).is_ok());
        let moved = legacy("ashur").into_batch();
        assert!(admit(Some(&item), &moved.items[0], false).is_err());
    }

    #[test]
    fn external_session_digest_uses_v2_domain_and_pins_label() {
        let req_id = Uuid::new_v4();
        let sess_id = Uuid::new_v4();
        let ext = RequesterSubject::external_session(
            sess_id,
            super::super::approval_flow::ExternalClientKind::LocalMcp,
            "claude-code",
            Some("macbook-air".into()),
        );
        let mission = RequesterSubject::mission(sess_id);
        let r_ext: PrivilegeRequest = serde_json::from_value(json!({
            "id": req_id, "owner": "thomas", "requester": ext,
            "target_host": "dgx-spark", "scope": PrivilegeScope::OpsRead,
            "reason": "logs", "ttl_minutes": 60, "state": "pending", "created_at": Utc::now(),
        }))
        .unwrap();
        let r_msn: PrivilegeRequest = serde_json::from_value(json!({
            "id": req_id, "owner": "thomas", "requester_mission_id": sess_id,
            "target_host": "dgx-spark", "scope": PrivilegeScope::OpsRead,
            "reason": "logs", "ttl_minutes": 60, "state": "pending", "created_at": Utc::now(),
        }))
        .unwrap();
        let item_ext = ApprovalItem::privilege(&r_ext);
        let item_msn = ApprovalItem::privilege(&r_msn);
        assert_eq!(item_ext.requester_mission_id, None);
        assert_eq!(
            item_ext.requester_label.as_deref(),
            Some("External · macbook-air (claude-code)")
        );
        assert_eq!(item_msn.requester_subject, mission);
        assert_ne!(item_ext.digest, item_msn.digest);

        let ext_spoof = RequesterSubject::external_session(
            sess_id,
            super::super::approval_flow::ExternalClientKind::LocalMcp,
            "other-client",
            Some("macbook-air".into()),
        );
        let r_spoof: PrivilegeRequest = serde_json::from_value(json!({
            "id": req_id, "owner": "thomas", "requester": ext_spoof,
            "target_host": "dgx-spark", "scope": PrivilegeScope::OpsRead,
            "reason": "logs", "ttl_minutes": 60, "state": "pending", "created_at": Utc::now(),
        }))
        .unwrap();
        assert_ne!(ApprovalItem::privilege(&r_spoof).digest, item_ext.digest);

        let batch_summary = summary(&[item_ext, item_msn]);
        assert!(
            batch_summary.contains("for \"External · macbook-air (claude-code)\""),
            "{batch_summary}"
        );
    }
}
