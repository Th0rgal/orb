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


def mission(rid, status, updated=NOW - 3600, created="2026-11-17T10:00:00Z", mid=None):
    return {"id": mid or f"m-{rid}-{created}", "status": status, "track": f"roadmap-{rid}",
            "created_at": created, "updated_ts": updated}


class ReconcileTest(unittest.TestCase):
    def setUp(self):
        self.rows, self.queue = parse(ROADMAP)

    def run_plan(self, prs=(), missions=(), green=True, ledger=None):
        return plan(self.rows, self.queue, tagged(list(prs)), list(missions), green, ledger or {}, NOW)

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
        both = {"nudged": {"m1": 1, "m2": 1}}
        self.assertIn(("escalate", "A2", "m2"), self.run_plan(missions=[first, second], ledger=both))
        both["reported"] = {"A2": "m2"}
        self.assertNotIn("A2", [a[1] for a in self.run_plan(missions=[first, second], ledger=both)])

    def test_a_recently_idle_worker_is_not_nudged_yet(self):
        self.assertNotIn("A2", [a[1] for a in self.run_plan(missions=[mission("A2", "awaiting_user", updated=NOW - 60)])])

    def test_red_master_runs_only_the_fix_row(self):
        self.assertEqual(self.run_plan(green=False), [("start", "MASTER", 1)])
        self.assertEqual(self.run_plan(green=False, missions=[mission("MASTER", "active")]), [])

    def test_worker_limit_is_respected(self):
        live = [mission(f"Z{i}", "active") for i in range(3)]
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
