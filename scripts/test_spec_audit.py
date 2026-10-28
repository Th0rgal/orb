"""Regression cases for the advisory-success and stale-audit failure modes."""
import unittest
from scripts.check_spec_audit import validate


class SpecAuditTests(unittest.TestCase):
    def report(self):
        return dict(ok=True, cache_hit=False, vacuous_specs=0, trivial_specs=0,
                    horizontal_packing_warnings=[], total_specs_audited=118, tight_specs=118)

    def test_accepts_fresh_complete_report(self):
        validate(self.report())

    def test_rejects_advisory_success_and_incomplete_reports(self):
        for key, value in (("horizontal_packing_warnings", ["line 3"]),
                           ("vacuous_specs", 1), ("trivial_specs", 1),
                           ("cache_hit", True), ("ok", False),
                           ("total_specs_audited", 0), ("tight_specs", 117),
                           ("vacuous_specs", False)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                validate(self.report() | {key: value})
        for key in self.report():
            report = self.report()
            del report[key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                validate(report)


if __name__ == "__main__":
    unittest.main()
