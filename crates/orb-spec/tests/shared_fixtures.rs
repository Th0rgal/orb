//! Replays every `shared/orb-spec/fixtures` case that has a matching Lean
//! kernel function through `orb_spec::*` (the Lean-compiled C-ABI). The
//! desktop, iOS and Android suites compare their ports against the same
//! fixtures, so this test makes the verified kernel, not the fixture author,
//! the ground truth: a fixture that disagrees with the kernel fails here even
//! if every client was changed to match it.

use orb_spec::*;
use serde_json::Value;
use std::path::PathBuf;

fn fixture(name: &str) -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../shared/orb-spec/fixtures")
        .join(name);
    let text =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

fn cases<'a>(doc: &'a Value, key: &str) -> &'a [Value] {
    let list = doc[key]
        .as_array()
        .unwrap_or_else(|| panic!("fixture key {key} missing"));
    assert!(!list.is_empty(), "fixture key {key} has no cases");
    list
}

fn b(v: &Value, key: &str) -> bool {
    v[key]
        .as_bool()
        .unwrap_or_else(|| panic!("{key} is not a bool in {v}"))
}

fn u(v: &Value, key: &str) -> u64 {
    v[key]
        .as_u64()
        .unwrap_or_else(|| panic!("{key} is not an unsigned int in {v}"))
}

fn name(c: &Value) -> &str {
    c["name"].as_str().unwrap_or("<unnamed>")
}

/// Every top-level case list of a fixture must be covered by this test, so a
/// new list cannot silently skip kernel verification.
fn assert_covered(doc: &Value, covered: &[&str]) {
    for (key, value) in doc.as_object().unwrap() {
        if value.is_array() {
            assert!(
                covered.contains(&key.as_str()),
                "uncovered fixture list {key}"
            );
        }
    }
}

#[test]
fn projection_invariants() {
    let doc = fixture("projection-invariants.json");
    assert_covered(
        &doc,
        &[
            "workfold_cases",
            "taskcard_cases",
            "sidebar_visibility_cases",
            "pr_gate_cases",
            "turn_summary_cases",
            "transcript_patch_cases",
        ],
    );

    for c in cases(&doc, "workfold_cases") {
        let i = &c["input"];
        let kind = if b(i, "is_text") { 2 } else { 5 };
        let v = workfold_step(
            kind,
            b(i, "cumulative"),
            b(i, "non_empty"),
            b(i, "tool_ahead"),
            b(i, "next_is_tool"),
            b(i, "fold_has_tool"),
        );
        let e = &c["expected"];
        assert_eq!(v.fold_item, b(e, "fold"), "workfold: {}", name(c));
        assert_eq!(
            v.fold_has_tool_next,
            b(e, "next_fold_has_tool"),
            "workfold: {}",
            name(c)
        );
    }

    for c in cases(&doc, "taskcard_cases") {
        let i = &c["input"];
        let (ended, all_closed, finished) = (
            b(i, "ended"),
            b(i, "all_done_or_cancelled"),
            b(i, "outcome_finished"),
        );
        let state = taskcard_step(ended, all_closed, finished);
        let e = &c["expected"];
        assert_eq!(state, e["state"].as_str().unwrap(), "taskcard: {}", name(c));
        assert_eq!(
            state == "stale",
            b(e, "mark_open_stale"),
            "taskcard: {}",
            name(c)
        );
        // An open in_progress task (raw status 1) stays in progress only while live.
        let in_progress_kept = turn_summary_step(1, ended, all_closed, finished).is_active;
        assert_eq!(
            b(i, "has_open_tasks") && !in_progress_kept,
            b(e, "clear_in_progress"),
            "taskcard: {}",
            name(c)
        );
    }

    for c in cases(&doc, "sidebar_visibility_cases") {
        let i = &c["input"];
        // Superseded missions match the sidebar filter only while working or selected;
        // archived (acknowledged) missions are kept only through a visible descendant.
        let matches_filter = !b(i, "is_archived")
            && (!b(i, "is_superseded") || b(i, "is_working") || b(i, "is_selected"));
        let v = sidebar_visibility(
            matches_filter,
            b(i, "has_visible_descendant"),
            b(i, "is_archived"),
            false,
            false,
            false,
        );
        let e = &c["expected"];
        assert_eq!(
            v.retain_in_main_tree,
            b(e, "show_in_main_tree"),
            "sidebar: {}",
            name(c)
        );
        assert_eq!(
            v.show_in_archive_only,
            b(e, "show_in_archive_only"),
            "sidebar: {}",
            name(c)
        );
    }

    for c in cases(&doc, "pr_gate_cases") {
        let i = &c["input"];
        let code = pr_gate_step(
            b(i, "merged"),
            b(i, "draft"),
            b(i, "closed"),
            b(i, "exact_head"),
            b(i, "action_required"),
            b(i, "blocked"),
            b(i, "behind"),
            b(i, "conflicting"),
            b(i, "checks_green"),
            b(i, "workflows_green"),
        );
        let e = &c["expected"];
        assert_eq!(u64::from(code), u(e, "code"), "pr_gate: {}", name(c));
        assert_eq!(
            pr_gate_recommendation(code),
            e["recommendation"].as_str().unwrap(),
            "pr_gate: {}",
            name(c)
        );
    }

    for c in cases(&doc, "turn_summary_cases") {
        let i = &c["input"];
        let v = turn_summary_step(
            u(i, "raw_status") as u8,
            b(i, "turn_ended"),
            b(i, "all_closed"),
            b(i, "turn_outcome_finished"),
        );
        let e = &c["expected"];
        assert_eq!(
            v,
            TurnSummaryVerdict {
                normalized_status: u(e, "normalized_status") as u8,
                is_done: b(e, "is_done"),
                is_active: b(e, "is_active"),
                card_state: u(e, "card_state") as u8,
            },
            "turn_summary: {}",
            name(c)
        );
    }

    for c in cases(&doc, "transcript_patch_cases") {
        let fold = |s: TranscriptPatchState, chunk: &Value| {
            chunk.as_array().unwrap().iter().fold(s, |s, ev| {
                transcript_patch_step(s, u(ev, "event_kind") as u8, u(ev, "delta_len") as u32)
            })
        };
        let init = TranscriptPatchState { len: 0, seq: 0 };
        let incremental = fold(fold(init, &c["chunk1"]), &c["chunk2"]);
        let e = &c["expected"];
        assert_eq!(
            incremental,
            TranscriptPatchState {
                len: u(e, "final_len") as u32,
                seq: u(e, "final_seq") as u32,
            },
            "transcript_patch: {}",
            name(c)
        );
    }
}

#[test]
fn relative_time() {
    let doc = fixture("relative-time.json");
    assert_covered(&doc, &["cases"]);
    for c in cases(&doc, "cases") {
        let secs = c["secondsAgo"].as_i64().unwrap();
        assert_eq!(
            format_relative_time_secs(secs),
            c["expected"].as_str().unwrap(),
            "relative time {secs}s"
        );
    }
}

/// Renders the kernel verdict the way every client does (see the fixture's description).
fn usage_limit_label(usage: &Value, now: u64) -> Option<(&'static str, String)> {
    let status = usage["unified_status"]
        .as_str()
        .unwrap_or("")
        .to_ascii_lowercase();
    let status_kind = match status.as_str() {
        "" | "allowed" | "ok" => 0,
        "allowed_warning" => 1,
        "rejected" => 2,
        _ => 3,
    };
    let claim = usage["unified_representative_claim"].as_str().unwrap_or("");
    let (claim_kind, util_key) = match claim {
        "five_hour" => (1, Some("unified_5h_utilization")),
        "seven_day" => (2, Some("unified_7d_utilization")),
        "seven_day_opus" => (3, None),
        "seven_day_sonnet" => (4, None),
        _ => (0, None),
    };
    let util = util_key.and_then(|k| usage[k].as_f64());
    let pct = util.map(|u| (u * 100.0).round().clamp(0.0, 255.0) as u8);
    let reset = usage["unified_reset"].as_u64();
    let v = usage_limit_status_step(
        status_kind,
        claim_kind,
        pct.is_some(),
        pct.unwrap_or(0),
        reset.is_some(),
        reset.map_or(0, |r| r.saturating_sub(now)),
    );
    let (tone, mut label) = match v.tone {
        0 => return None,
        1 => ("warning", "Approaching limit".to_string()),
        2 => ("error", "Limit reached".to_string()),
        _ => return Some(("warning", "Limit status unknown".to_string())),
    };
    let window = match v.window_kind {
        1 => "5h",
        2 => "weekly",
        3 => "weekly Opus",
        4 => "weekly Sonnet",
        _ => "",
    };
    if !window.is_empty() {
        label.push_str(&format!(" · {window}"));
        if v.show_pct {
            label.push_str(&format!(" {}%", v.pct));
        }
    }
    let unit = match v.reset_unit {
        1 => "m",
        2 => "h",
        3 => "d",
        _ => "",
    };
    if !unit.is_empty() {
        label.push_str(&format!(" · resets in {}{unit}", v.reset_value));
    }
    Some((tone, label))
}

#[test]
fn usage_limit_status() {
    let doc = fixture("usage-limit-status.json");
    assert_covered(&doc, &["cases"]);
    for c in cases(&doc, "cases") {
        let got = usage_limit_label(&c["usage"], u(c, "nowSec"));
        let e = &c["expected"];
        let want = (!e.is_null()).then(|| {
            (
                e["tone"].as_str().unwrap(),
                e["label"].as_str().unwrap().to_string(),
            )
        });
        assert_eq!(
            got.as_ref().map(|(t, l)| (*t, l.clone())),
            want,
            "usage limit: {}",
            name(c)
        );
    }
}
