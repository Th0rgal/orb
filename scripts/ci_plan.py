#!/usr/bin/env python3
"""Select the CI jobs a change needs, from ci/domains.toml (stdlib only).

Conservative by construction: a path no domain claims, a change to CI itself,
an unverified push to master, the nightly schedule, a manual dispatch, or a diff that
cannot be computed all select every job.

    scripts/ci_plan.py --base <sha> [--head HEAD] [--event pull_request] [--ref <ref>]
    scripts/ci_plan.py --paths-file changed.txt
    scripts/ci_plan.py ... --github-output "$GITHUB_OUTPUT" --summary "$GITHUB_STEP_SUMMARY"
"""
import argparse
import fnmatch
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import time
import tomllib
import urllib.request
import zipfile
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


# Receipts are scoped to one workflow: CI OK does not certify Kernel ABI.
WORKFLOWS = {"ci": "ci.yml", "kernel-abi": "kernel-abi.yml"}
RECEIPT_VERSION = 1


def tree_inputs(head="HEAD", domains=None, root=ROOT):
    """Hash tracked Git objects, including names, modes, deletions and gitlinks.

    These are input hashes, not hashes of a dirty working directory. The build
    hash includes CI configuration as well as all Orb sources and dependencies.
    """
    domains = load_domains() if domains is None else domains
    tree = subprocess.check_output(
        ["git", "rev-parse", f"{head}^{{tree}}"], cwd=root, text=True).strip()
    entries = subprocess.check_output(["git", "ls-tree", "-rz", tree], cwd=root)
    grouped = {d["name"]: [] for d in domains}
    build = []
    desktop_build = []
    for entry in entries.split(b"\0"):
        if not entry:
            continue
        path = entry.split(b"\t", 1)[1].decode("utf-8", "surrogateescape")
        domain = claim(path, domains)
        if domain:
            grouped[domain["name"]].append(entry)
        if path.startswith("orb/") or (domain and domain.get("full")):
            build.append(entry)
        if ((path.startswith("lean/") and not path.startswith("lean/OrbDesktop/"))
                or path.startswith("shared/") or (domain and domain.get("full"))
                or path in {"scripts/build_orb_bins.sh", "scripts/ci_harden_ubuntu_apt.sh"}):
            desktop_build.append(entry)
    def digest(items):
        return hashlib.sha256(b"\0".join(items)).hexdigest()
    return {"tree_hash": tree,
            "domain_hashes": {k: digest(v) for k, v in grouped.items()},
            "orb_build_hash": digest(build), "desktop_build_hash": digest(desktop_build)}


def workflow_jobs(domains, workflow):
    if workflow == "kernel-abi":
        return {"wf:kernel-abi"}
    return {j for j in all_jobs(domains) if not j.startswith("wf:")}


def valid_receipt(receipt, workflow, repository):
    def hash_value(value, lengths):
        return isinstance(value, str) and len(value) in lengths and bool(re.fullmatch("[0-9a-f]+", value))

    return (isinstance(receipt, dict)
            and receipt.get("version") == RECEIPT_VERSION
            and receipt.get("workflow") == workflow
            and receipt.get("repository") == repository
            and isinstance(receipt.get("jobs"), list)
            and all(isinstance(j, str) for j in receipt["jobs"])
            and isinstance(receipt.get("unaffected", []), list)
            and all(isinstance(j, str) for j in receipt.get("unaffected", []))
            and hash_value(receipt.get("tree_hash"), (40, 64))
            and hash_value(receipt.get("orb_build_hash"), (64,))
            and str(receipt.get("run_id", "")).isdigit()
            and isinstance(receipt.get("run_attempt"), int)
            and receipt["run_attempt"] > 0
            and (receipt.get("dist_run_id", "") == ""
                 or str(receipt["dist_run_id"]).isdigit())
            and (receipt.get("desktop_run_id", "") == ""
                 or str(receipt["desktop_run_id"]).isdigit()))


def github_get(repository, token, path, binary=False):
    """Read only from this repository's Actions API; never log credentials."""
    url = f"https://api.github.com/repos/{repository}/{path}"
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    # urllib strips Authorization on redirects only if explicitly requested.
    # Artifact downloads redirect to signed blob URLs: do not forward our token.
    class Redirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
            redirected.remove_header("Authorization")
            return redirected
    with urllib.request.build_opener(Redirect()).open(request, timeout=5) as response:
        data = response.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise ValueError("verification API response exceeds 1 MiB")
    return data if binary else json.loads(data)


def green_receipts(repository, token, workflow, get=None):
    """Find exact checkout-tree evidence, including PR synthetic merge trees.

    PR run.head_sha is usually the PR *head*, not the checkout's merge commit.
    An artifact produced by the green run records the actual tested tree. Cache
    entries on refs/pull/*/merge cannot be restored by master, so this read-only
    API path bridges the branch cache boundary. Missing/expired evidence is a miss.
    """
    get = get or (lambda path, binary=False: github_get(repository, token, path, binary))
    receipts = []
    deadline = time.monotonic() + 25
    # Bounded lookup: misses cost a normal run, never an unverified skip.
    runs = get(f"actions/workflows/{WORKFLOWS[workflow]}/runs?status=success&per_page=20")["workflow_runs"]
    for run in runs:
        if time.monotonic() >= deadline:
            break
        if (run.get("status") != "completed" or run.get("conclusion") != "success"
                or run.get("event") not in {"pull_request", "push"}
                or str(run["id"]) == os.environ.get("GITHUB_RUN_ID")):
            continue
        try:
            artifacts = get(f"actions/runs/{run['id']}/artifacts?per_page=100")["artifacts"]
            for artifact in artifacts:
                if artifact["name"] != f"{workflow}-verification" or artifact.get("expired"):
                    continue
                raw = get(f"actions/artifacts/{artifact['id']}/zip", binary=True)
                with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                    info = archive.getinfo("verified.json")
                    if info.file_size > 1024 * 1024:
                        continue
                    receipt = json.loads(archive.read(info))
                if (valid_receipt(receipt, workflow, repository)
                        and str(receipt.get("run_id")) == str(run["id"])
                        and receipt.get("run_attempt") == run.get("run_attempt")):
                    receipts.append(receipt)
        except (OSError, ValueError, KeyError, zipfile.BadZipFile):
            # An expired artifact or API error is not evidence.
            continue
    return receipts


def reuse_verified(result, inputs, receipts, workflow, repository):
    """Reuse only jobs actually certified on this exact tree, in this workflow."""
    reused = set()
    unaffected = set()
    allowed = workflow_jobs(load_domains(), workflow)
    dist_run_id = ""
    desktop_run_id = ""
    for receipt in receipts:
        if not valid_receipt(receipt, workflow, repository):
            continue
        if receipt["tree_hash"] == inputs["tree_hash"]:
            reused.update(set(receipt["jobs"]) & set(result["jobs"]) & allowed - set(ALWAYS))
            unaffected.update(set(receipt.get("unaffected", [])) & set(result["jobs"]) & allowed - set(ALWAYS))
        if (not dist_run_id and receipt.get("orb_build_hash") == inputs["orb_build_hash"]
                and receipt.get("dist_run_id")):
            dist_run_id = str(receipt["dist_run_id"])
        if (not desktop_run_id and receipt.get("desktop_build_hash") == inputs["desktop_build_hash"]
                and receipt.get("desktop_run_id")):
            desktop_run_id = str(receipt["desktop_run_id"])
    result = {**result, **inputs, "reused": sorted(reused),
              "unaffected": sorted(unaffected), "dist_run_id": dist_run_id,
              "desktop_run_id": desktop_run_id}
    result["jobs"] = sorted(set(result["jobs"]) - reused - unaffected)
    result["skipped"] = sorted(set(result["skipped"]) | reused | unaffected)
    return result


def verification_receipt(result, needs, workflow, repository, run_id, run_attempt,
                         performance_verified=False):
    """Only successful jobs count; report-only performance failures never do."""
    allowed = workflow_jobs(load_domains(), workflow)
    passed = {j for j, value in needs.items() if value.get("result") == "success"}
    if workflow == "kernel-abi" and "kernel-abi" in passed:
        passed.add("wf:kernel-abi")
    if workflow == "ci" and not performance_verified:
        passed.discard("orb-performance")
    # A successful impact-scoped PR also certifies that jobs outside its plan
    # were unrelated to that tree's change. Preserve that routing decision on
    # an identical master tree instead of reverting to the push/full fallback.
    selected = set(result["jobs"]) & allowed
    unexpected_skips = {j for j in selected if j not in passed}
    unexpected_skips.discard("orb-performance")  # report-only on PRs
    if needs.get("plan", {}).get("result") != "success" or unexpected_skips:
        raise ValueError("cannot certify a failed plan or skipped required job")
    unaffected = allowed - selected - set(result.get("reused", []))
    passed &= selected
    passed |= set(result.get("reused", []))
    receipt = {"version": RECEIPT_VERSION, "workflow": workflow,
               "repository": repository, "run_id": str(run_id), "run_attempt": int(run_attempt),
               "tree_hash": result["tree_hash"], "domain_hashes": result["domain_hashes"],
               "orb_build_hash": result["orb_build_hash"], "jobs": sorted(passed & allowed),
               "unaffected": sorted(unaffected), "dist_run_id": "",
               "desktop_build_hash": result["desktop_build_hash"], "desktop_run_id": ""}
    if workflow == "ci" and needs.get("orb-build", {}).get("result") == "success":
        receipt["dist_run_id"] = str(run_id)
    elif workflow == "ci":
        receipt["dist_run_id"] = result.get("dist_run_id", "")
    if workflow == "ci" and needs.get("orb-desktop-shell", {}).get("result") == "success":
        receipt["desktop_run_id"] = str(run_id)
    elif workflow == "ci":
        receipt["desktop_run_id"] = result.get("desktop_run_id", "")
    return receipt


def summary_markdown(result, report_only):
    mode = "report only: every job still runs" if report_only else "enforced"
    lines = [f"### CI plan ({mode})", ""]
    if result["full"]:
        lines.append("**Full fallback before verified-tree reuse:** " + "; ".join(result["reasons"]))
    else:
        lines.append(f"{result['changed']} changed path(s).")
    if result.get("tree_hash"):
        lines += ["", f"Tree: `{result['tree_hash']}`"]
    if result.get("reused"):
        lines += ["", "Previously passed on this exact tree: " + ", ".join(result["reused"])]
    if result.get("unaffected"):
        lines += ["", "Previously certified unrelated on this exact tree: " + ", ".join(result["unaffected"])]
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
    ap.add_argument("--workflow", choices=WORKFLOWS, default="ci")
    ap.add_argument("--receipt", help="exact-tree receipt restored by actions/cache")
    ap.add_argument("--hashes-only", action="store_true")
    ap.add_argument("--write-receipt", help="write evidence from CI_PLAN and CI_NEEDS")
    args = ap.parse_args(argv)

    domains = load_domains()
    if args.write_receipt:
        receipt = verification_receipt(
            json.loads(os.environ["CI_PLAN"]), json.loads(os.environ["CI_NEEDS"]),
            args.workflow, os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_RUN_ID"],
            os.environ["GITHUB_RUN_ATTEMPT"], os.environ.get("PERFORMANCE_VERIFIED") == "true")
        destination = Path(args.write_receipt)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(receipt, indent=2) + "\n")
        return
    inputs = tree_inputs(args.head, domains)
    if args.hashes_only:
        if args.github_output:
            with open(args.github_output, "a") as f:
                for key in ("tree_hash", "orb_build_hash", "desktop_build_hash"):
                    f.write(f"{key}={inputs[key]}\n")
        json.dump(inputs, sys.stdout, indent=2)
        return
    force = None
    if args.paths_file:
        paths = [l.strip() for l in Path(args.paths_file).read_text().splitlines() if l.strip()]
    else:
        paths = changed_paths(args.base, args.head)
        if paths is None:
            force, paths = "diff against base unavailable", []
    result = plan(paths, domains, args.event, args.ref, force)
    receipts = []
    repository, token = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", "")
    if args.event == "push" and args.ref in FULL_REFS and not args.report_only:
        if args.receipt:
            try:
                receipts.append(json.loads(Path(args.receipt).read_text()))
            except (OSError, ValueError):
                pass
        if repository and token:
            try:
                receipts.extend(green_receipts(repository, token, args.workflow))
            except (OSError, ValueError, KeyError):
                print("Verification lookup unavailable; running checks without API reuse.", file=sys.stderr)
    result = reuse_verified(result, inputs, receipts, args.workflow, repository)

    if args.github_output:
        with open(args.github_output, "a") as f:
            f.write(f"full={'true' if result['full'] else 'false'}\n")
            f.write(f"jobs={json.dumps(result['jobs'])}\n")
            for key in ("tree_hash", "orb_build_hash", "desktop_build_hash", "dist_run_id", "desktop_run_id"):
                f.write(f"{key}={result[key]}\n")
            f.write(f"verification={json.dumps(result, separators=(',', ':'))}\n")
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
