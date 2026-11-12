#!/usr/bin/env python3
"""Fail closed on turbo-lean's JSON audit, including its advisory packing tier."""
import json
import sys


def validate(report):
    if not isinstance(report, dict):
        raise ValueError("expected an audit report object")
    if "file_reports" in report or "files" in report:
        reports, files = report.get("file_reports"), report.get("files")
        if (not isinstance(reports, list) or not reports or not isinstance(files, list)
                or len(files) != len(reports) or any(not isinstance(path, str) for path in files)):
            raise ValueError("expected matching nonempty files and file_reports")
        for path, child in zip(files, reports):
            if not isinstance(child, dict) or child.get("file") != path:
                raise ValueError(f"missing or mismatched file report: {path}")
            validate(child)
        for key in ("total_specs_audited", "tight_specs", "vacuous_specs", "trivial_specs"):
            if report.get(key) != sum(child[key] for child in reports):
                raise ValueError(f"batch {key} does not match file reports")
    errors = []
    for key, expected in (("ok", True), ("cache_hit", False),
                          ("vacuous_specs", 0), ("trivial_specs", 0),
                          ("horizontal_packing_warnings", [])):
        actual = report.get(key)
        if type(actual) is not type(expected) or actual != expected:
            errors.append(f"{key}: expected {expected!r}, got {actual!r}")
    total = report.get("total_specs_audited")
    tight = report.get("tight_specs")
    if type(total) is not int or total <= 0 or type(tight) is not int or tight != total:
        errors.append(f"expected nonempty all-tight inventory, got {tight!r}/{total!r}")
    if errors:
        raise ValueError("; ".join(errors))


if __name__ == "__main__":
    try:
        with open(sys.argv[1]) as source:
            report = json.load(source)
        validate(report)
    except (ValueError, OSError, IndexError, AttributeError) as error:
        sys.exit(f"Spec audit rejected: {error}")
    print(f"Spec audit: {report['tight_specs']}/{report['total_specs_audited']} tight; fresh, no packing warnings")
