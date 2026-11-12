#!/usr/bin/env python3
"""Select the CI jobs a change needs, from ci/domains.toml (stdlib only).

Conservative by construction: a path no domain claims, a change to CI itself,
a push to master, the nightly schedule, a manual dispatch, or a diff that
cannot be computed all select every job.

    scripts/ci_plan.py --base <sha> [--head HEAD] [--event pull_request] [--ref <ref>]
    scripts/ci_plan.py --paths-file changed.txt
    scripts/ci_plan.py ... --github-output "$GITHUB_OUTPUT" --summary "$GITHUB_STEP_SUMMARY"
"""
import argparse
import fnmatch
import json
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOMAINS = ROOT / "ci" / "domains.toml"
# Jobs that run whatever changed (cheap and always informative).
ALWAYS = ("fmt",)
FULL_REFS = {"master", "main", "refs/heads/master", "refs/heads/main"}
NULL_SHA = "0" * 40


def load_domains(path=DOMAINS):
    with open(path, "rb") as f:
        domains = tomllib.load(f)["domain"]
    for d in domains:
        if not d.get("full") and "jobs" not in d:
            raise ValueError(f"domain {d['name']!r} needs `jobs` or `full = true`")
    return domains


def all_jobs(domains):
    jobs = set(ALWAYS)
    for d in domains:
        jobs.update(d.get("jobs", ()))
    return sorted(jobs)


def claim(path, domains):
    for d in domains:
        if any(fnmatch.fnmatchcase(path, pat) for pat in d["paths"]):
            return d
    return None


def plan(paths, domains, event="pull_request", ref="", force_reason=None):
    """Return the plan dict for the changed `paths`."""
    reasons = []
    if force_reason:
        reasons.append(force_reason)
    if event in {"schedule", "workflow_dispatch"}:
        reasons.append(f"event {event} runs everything")
    if event == "push" and ref in FULL_REFS:
        reasons.append(f"push to {ref} runs everything")

    claimed, unclaimed, jobs = {}, [], set(ALWAYS)
    for p in paths:
        d = claim(p, domains)
        if d is None:
            unclaimed.append(p)
            continue
        claimed.setdefault(d["name"], []).append(p)
        if d.get("full"):
            reasons.append(f"{p} is CI input ({d['name']})")
        jobs.update(d.get("jobs", ()))
    if unclaimed:
        reasons.append(f"{len(unclaimed)} path(s) not in any domain")

    full = bool(reasons)
    selected = all_jobs(domains) if full else sorted(jobs)
    return {
        "full": full,
        "reasons": reasons,
        "jobs": selected,
        "skipped": sorted(set(all_jobs(domains)) - set(selected)),
        "domains": {k: sorted(v) for k, v in sorted(claimed.items())},
        "unclaimed": sorted(unclaimed),
        "changed": len(paths),
    }


def changed_paths(base, head):
    """Paths changed on `head` since its merge-base with `base`, or None."""
    if not base or base == NULL_SHA:
        return None
    try:
        mb = subprocess.check_output(
            ["git", "merge-base", base, head], cwd=ROOT, text=True,
            stderr=subprocess.DEVNULL).strip()
        out = subprocess.check_output(
            ["git", "diff", "--name-only", "--no-renames", "-z", mb, head],
            cwd=ROOT, text=True)
    except subprocess.CalledProcessError:
        return None
    return [p for p in out.split("\0") if p]


def summary_markdown(result, report_only):
    mode = "report only: every job still runs" if report_only else "enforced"
    lines = [f"### CI plan ({mode})", ""]
    if result["full"]:
        lines.append("**Full run:** " + "; ".join(result["reasons"]))
    else:
        lines.append(f"{result['changed']} changed path(s).")
    lines += ["", "| Job | Planned |", "| --- | --- |"]
    for j in result["jobs"]:
        lines.append(f"| `{j}` | run |")
    for j in result["skipped"]:
        lines.append(f"| `{j}` | skip |")
    if result["domains"]:
        lines += ["", "Domains: " + ", ".join(
            f"`{k}` ({len(v)})" for k, v in result["domains"].items())]
    if result["unclaimed"]:
        lines += ["", "Unclaimed (add them to `ci/domains.toml`):", ""]
        lines += [f"- `{p}`" for p in result["unclaimed"][:50]]
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--base")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--event", default="pull_request")
    ap.add_argument("--ref", default="")
    ap.add_argument("--paths-file", help="newline-separated changed paths")
    ap.add_argument("--github-output")
    ap.add_argument("--summary")
    ap.add_argument("--report-only", action="store_true")
    args = ap.parse_args(argv)

    domains = load_domains()
    force = None
    if args.paths_file:
        paths = [l.strip() for l in Path(args.paths_file).read_text().splitlines() if l.strip()]
    else:
        paths = changed_paths(args.base, args.head)
        if paths is None:
            force, paths = "diff against base unavailable", []
    result = plan(paths, domains, args.event, args.ref, force)

    if args.github_output:
        with open(args.github_output, "a") as f:
            f.write(f"full={'true' if result['full'] else 'false'}\n")
            f.write(f"jobs={json.dumps(result['jobs'])}\n")
            for j in all_jobs(domains):
                key = "run_" + j.replace(":", "_").replace("-", "_")
                f.write(f"{key}={'true' if j in result['jobs'] else 'false'}\n")
    if args.summary:
        with open(args.summary, "a") as f:
            f.write(summary_markdown(result, args.report_only))
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
