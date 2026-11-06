//! Host observer adapter for `orb_pr_gate_step` (`lean/Orb/Kernel.lean`).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CheckRun {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub conclusion: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WorkflowRun {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub conclusion: Option<String>,
    #[serde(default)]
    pub head_sha: String,
    #[serde(default)]
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PrGates {
    #[serde(default)]
    pub owner_repo: String,
    #[serde(default)]
    pub number: u64,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub draft: bool,
    #[serde(default)]
    pub merged: bool,
    #[serde(default)]
    pub mergeable: Option<bool>,
    #[serde(default, alias = "mergeStateStatus")]
    pub merge_state_status: Option<String>,
    #[serde(default)]
    pub conflicting: bool,
    #[serde(default)]
    pub checks: Vec<CheckRun>,
    /// GitHub's complete check rollup for the current PR head is represented by
    /// `checks`. Workflow runs are kept separately because a run can conclude
    /// `action_required` before creating any job, in which case it is absent
    /// from `statusCheckRollup` entirely.
    #[serde(default)]
    pub workflow_runs: Vec<WorkflowRun>,
    /// Head that GitHub currently associates with the PR.
    #[serde(default, alias = "headRefOid")]
    pub current_head: Option<String>,
    /// Head on which the worker's local validation/review was performed.
    #[serde(default)]
    pub worker_head: Option<String>,
    #[serde(default)]
    pub bugbot_accessible: bool,
    #[serde(default)]
    pub recommendation: Option<String>,
}

pub fn apply_pr_gate_recommendation(gates: &mut PrGates) {
    let merge_state_status = gates
        .merge_state_status
        .as_deref()
        .map(str::to_ascii_lowercase);
    let blocked = merge_state_status.as_deref() == Some("blocked");
    let behind = merge_state_status.as_deref() == Some("behind");
    gates.conflicting = gates.conflicting
        || merge_state_status.as_deref() == Some("dirty")
        || (gates.mergeable == Some(false) && !blocked && !behind);
    let accepted_check_conclusion = |conclusion: &str| {
        matches!(
            conclusion.to_ascii_lowercase().as_str(),
            "success" | "skipped" | "neutral"
        )
    };
    let checks_green = !gates.checks.is_empty()
        && gates.checks.iter().all(|c| {
            c.status.eq_ignore_ascii_case("completed")
                && c.conclusion
                    .as_deref()
                    .map(accepted_check_conclusion)
                    .unwrap_or(false)
        });
    let action_required = gates.workflow_runs.iter().any(|run| {
        run.status.eq_ignore_ascii_case("completed")
            && run
                .conclusion
                .as_deref()
                .map(|value| value.eq_ignore_ascii_case("action_required"))
                .unwrap_or(false)
    });
    let workflow_runs_green = gates.workflow_runs.is_empty()
        || gates.workflow_runs.iter().all(|run| {
            run.status.eq_ignore_ascii_case("completed")
                && run
                    .conclusion
                    .as_deref()
                    .map(accepted_check_conclusion)
                    .unwrap_or(false)
        });
    let exact_head = match (&gates.worker_head, &gates.current_head) {
        (Some(worker), Some(current)) => worker.eq_ignore_ascii_case(current),
        _ => true,
    };
    let closed = gates.state.eq_ignore_ascii_case("closed");
    let code = crate::orb_spec::pr_gate_step(
        gates.merged,
        gates.draft,
        closed,
        exact_head,
        action_required,
        blocked,
        behind,
        gates.conflicting,
        checks_green,
        workflow_runs_green,
    );
    gates.recommendation = Some(crate::orb_spec::pr_gate_recommendation(code).to_string());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pr_103_green_but_conflicting_recommends_conflict_resolution() {
        let mut gates: PrGates = serde_json::from_str(
            r#"{
              "state":"open",
              "draft":false,
              "merged":false,
              "mergeable":false,
              "merge_state_status":"dirty",
              "checks":[{"name":"ci","status":"completed","conclusion":"success"}]
            }"#,
        )
        .unwrap();
        apply_pr_gate_recommendation(&mut gates);
        assert_eq!(
            gates.recommendation.as_deref(),
            Some("needs_conflict_resolution")
        );
    }

    #[test]
    fn head_drift_or_action_required_blocks_merge_recommendation() {
        let mut gates: PrGates = serde_json::from_str(
            r#"{
              "state":"open",
              "draft":false,
              "merged":false,
              "mergeable":true,
              "current_head":"aaaa1111",
              "worker_head":"bbbb2222",
              "checks":[{"name":"ci","status":"completed","conclusion":"success"}]
            }"#,
        )
        .unwrap();
        apply_pr_gate_recommendation(&mut gates);
        assert_eq!(
            gates.recommendation.as_deref(),
            Some("head_changed_since_worker")
        );
    }
}
