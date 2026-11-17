import runpy
import unittest
from pathlib import Path

NS = runpy.run_path(str(Path(__file__).parent / "ops/orb-roadmap-reconcile"), run_name="test")
parse, plan, tagged = NS["parse_roadmap"], NS["plan"], NS["tagged_prs"]

ROADMAP = """
## 4. The DAG
| Id | Node | Needs | State | Done when |
| --- | --- | --- | --- | --- |
| A1 | First | — | done | — |
| A2 | Second | A1 | ready | x |
| A3 | Third | A2 | blocked | x |
| A4 | Human | — | blocked (Thomas, 5.2) | x |
| A5 | Dated | A2 (+ 7 days) | blocked | x |
| A6 | Other | — | ready | x |
## 7. Queue
`A2`, `A3`, `A4`, `A5`, `A6`
"""
NOW = 1_000_000


def pr(title, state="open", merged=False, updated=NOW - 7200, number=1):
    return {"title": title, "state": state, "merged_at": "x" if merged else None,
            "updated_ts": updated, "number": number, "html_url": "u"}


def mission(rid, status, updated=NOW - 3600, created="2026-11-17T10:00:00Z", mid=None, created_ts=None):
    return {"id": mid or f"m-{rid}-{created}", "status": status, "track": f"roadmap-{rid}",
            "created_at": created, "created_ts": created_ts if created_ts is not None else updated - 3600,
            "updated_ts": updated}


class ReconcileTest(unittest.TestCase):
    def setUp(self):
        self.rows, self.queue = parse(ROADMAP)

    def run_plan(self, prs=(), missions=(), green=True, ledger=None):
        acts = plan(self.rows, self.queue, tagged(list(prs)), list(missions), green, ledger or {}, NOW)
        self.models = [a[3] for a in acts if a[0] == "start"]
        return [a[:3] for a in acts]

    def test_parse_reads_rows_needs_and_queue(self):
        self.assertEqual(self.queue, ["A2", "A3", "A4", "A5", "A6"])
        self.assertEqual(self.rows["A2"]["needs"], ["A1"])
        self.assertIsNone(self.rows["A5"]["needs"])

    def test_starts_ready_rows_and_skips_unmet_human_and_dated_needs(self):
        self.assertEqual(self.run_plan(), [("start", "A2", 1), ("start", "A6", 1)])

    def test_a_merged_tagged_pr_marks_a_row_done_and_unblocks_its_dependents(self):
        acts = self.run_plan(prs=[pr("feat: second (A2)", "closed", merged=True)])
        self.assertEqual(acts, [("start", "A3", 1), ("start", "A6", 1)])

    def test_a_live_worker_is_left_alone(self):
        self.assertEqual(self.run_plan(missions=[mission("A2", "active")]), [("start", "A6", 1)])

    def test_a_recently_touched_foreign_pr_is_not_adopted_but_a_stale_one_is(self):
        self.assertEqual(self.run_plan(prs=[pr("x (A2)", updated=NOW - 60)]), [("start", "A6", 1)])
        self.assertEqual(self.run_plan(prs=[pr("x (A2)")]), [("start", "A2", 1), ("start", "A6", 1)])

    def test_idle_worker_is_nudged_then_replaced_then_escalated(self):
        first = mission("A2", "completed", mid="m1")
        self.assertIn(("nudge", "A2", "m1"), self.run_plan(missions=[first]))
        nudged = {"nudged": {"m1": NOW - 1800}}
        self.assertIn(("start", "A2", 2), self.run_plan(missions=[first], ledger=nudged))
        second = mission("A2", "failed", created="2026-11-17T11:00:00Z", mid="m2")
        second["track"] = "roadmap-A2-2"
        both = {"nudged": {"m1": 1, "m2": 1}}
        self.assertIn(("escalate", "A2", "m2"), self.run_plan(missions=[first, second], ledger=both))
        both["reported"] = {"A2": "m2"}
        self.assertNotIn("A2", [a[1] for a in self.run_plan(missions=[first, second], ledger=both)])

    def test_a_worker_that_died_at_start_is_replaced_not_nudged(self):
        dead = mission("A2", "cancelled", mid="m1", created_ts=NOW - 3605)
        self.assertIn(("start", "A2", 2), self.run_plan(missions=[dead]))

    def test_recent_quick_deaths_pause_dispatch_and_cost_no_attempt(self):
        dead = [mission(f"Z{i}", "cancelled", updated=NOW - 60, created_ts=NOW - 65) for i in range(2)]
        self.assertEqual(self.run_plan(missions=dead), [])
        many = [mission("A2", "cancelled", mid=f"q{i}", created=f"2026-11-17T1{i}:00:00Z",
                        updated=NOW - 7000 + i, created_ts=NOW - 7005 + i) for i in range(3)]
        acts = self.run_plan(missions=many)
        self.assertIn(("start", "A2", 4), acts)
        self.assertNotIn("escalate", [a[0] for a in acts])

    def test_old_master_fix_attempts_and_foreign_tracks_are_ignored(self):
        old = mission("MASTER", "cancelled", created_ts=NOW - 2 * 86400)
        pivot = mission("pivot", "active")
        self.assertEqual(self.run_plan(green=False, missions=[old, pivot]), [("start", "MASTER", 1)])

    def test_workers_start_on_the_first_free_model_and_wait_when_none_is(self):
        astra, sol = NS["MODELS"][:2]
        fable = sol  # the second model is the one used when the first cools
        a = mission("Z0", "cancelled", updated=NOW - 60, created_ts=NOW - 65)
        a.update(returns_ts=NOW + 600, model=astra)
        self.assertEqual(self.run_plan(missions=[a]), [("start", "A2", 1), ("start", "A6", 1)])
        self.assertEqual(self.models, [fable, fable])
        f = mission("Z1", "cancelled", updated=NOW - 60, created_ts=NOW - 65)
        f.update(returns_ts=NOW + 3600, model=fable)
        d = mission("Z2", "cancelled", updated=NOW - 60, created_ts=NOW - 65)
        d.update(returns_ts=NOW + 3600, model=NS["MODELS"][2])
        e = mission("Z3", "cancelled", updated=NOW - 60, created_ts=NOW - 65)
        e.update(returns_ts=NOW + 3600, model=NS["MODELS"][3])
        self.assertEqual(self.run_plan(missions=[a, f, d, e]), [])
        a["returns_ts"] = NOW - 1
        self.assertEqual(self.run_plan(missions=[a, f, d, e]), [("start", "A2", 1), ("start", "A6", 1)])
        self.assertEqual(self.models, [astra, astra])

    def test_each_attempt_uses_the_next_model(self):
        self.assertEqual(NS["MODELS"], ["openai/gpt-6-astra", "openai/gpt-6.1-sol",
                                        "anthropic/claude-fable-5-2", "ethereumfoundation/deepseek-v4.1-flash"])

    def test_a_recently_idle_worker_is_not_nudged_yet(self):
        self.assertNotIn("A2", [a[1] for a in self.run_plan(missions=[mission("A2", "awaiting_user", updated=NOW - 60)])])

    def test_red_master_runs_only_the_fix_row(self):
        self.assertEqual(self.run_plan(green=False), [("start", "MASTER", 1)])
        self.assertEqual(self.run_plan(green=False, missions=[mission("MASTER", "active")]), [])

    def test_worker_limit_is_respected(self):
        live = [mission(f"Z{i}", "active") for i in range(NS["MAX_WORKERS"])]
        self.assertEqual(self.run_plan(missions=live), [])

    def test_unknown_queue_entry_is_reported(self):
        self.queue.append("Q9")
        self.assertIn(("report", "Q9", "queue names Q9, which is not a row of the DAG"), self.run_plan())

    def test_brief_names_the_row_tag_and_open_prs(self):
        text = NS["brief"](self.rows["A2"], 2, [pr("x (A2)", number=42)])
        self.assertIn('end with "(A2)"', text)
        self.assertIn("#42", text)
        self.assertIn("attempt 2", text)


if __name__ == "__main__":
    unittest.main()
