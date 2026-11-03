#!/bin/bash

# Xcode Cloud post-clone: use the same generator as GitHub iOS CI, regardless
# of which XcodeGen version happens to be installed on the build image.
set -euo pipefail

XCODEGEN_VERSION=2.46.0
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
XCODEGEN_TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${XCODEGEN_TMP_DIR}"
}
trap cleanup EXIT

echo "=== Installing XcodeGen ${XCODEGEN_VERSION} ==="
curl -fsSL --retry 3 --retry-delay 2 \
  -o "${XCODEGEN_TMP_DIR}/xcodegen.zip" "${XCODEGEN_URL}"
unzip -q "${XCODEGEN_TMP_DIR}/xcodegen.zip" -d "${XCODEGEN_TMP_DIR}"
XCODEGEN_BIN="${XCODEGEN_TMP_DIR}/xcodegen/bin/xcodegen"
chmod +x "${XCODEGEN_BIN}"
"${XCODEGEN_BIN}" --version

echo "=== Generating Xcode Project ==="
cd "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud repository path is required}/ios_dashboard"
"${XCODEGEN_BIN}" generate

# A release must use the project reviewed in GitHub, not silently accept drift.
git diff --exit-code SandboxedDashboard.xcodeproj/project.pbxproj

# Enforce PBXGroup tree & file-reference invariants (catches multi-parent group
# membership that Xcode Cloud's strict project loader rejects as unreadable even
# when older xcodebuild versions only emit a stderr warning).
python3 -I - SandboxedDashboard.xcodeproj/project.pbxproj <<'PY'
import collections, json, os, subprocess, sys

pbx_path = os.path.abspath(sys.argv[1])
root_dir = os.path.dirname(os.path.dirname(pbx_path))
pbx = json.loads(
    subprocess.check_output(["plutil", "-convert", "json", "-o", "-", pbx_path])
)
objs = pbx["objects"]
proj = objs[pbx["rootObject"]]
main_gid = proj["mainGroup"]
prod_gid = proj.get("productRefGroup")
group_isas = {"PBXGroup", "PBXVariantGroup", "XCVersionGroup"}

parents = collections.defaultdict(list)
errors = []

for oid, obj in objs.items():
    isa = obj.get("isa")
    if isa == "PBXBuildFile" and "fileRef" in obj and obj["fileRef"] not in objs:
        errors.append(f"dangling PBXBuildFile.fileRef {obj['fileRef']} in {oid}")
    if isa not in group_isas:
        continue
    glabel = obj.get("name") or obj.get("path") or ("<mainGroup>" if oid == main_gid else oid)
    seen = set()
    for cid in obj.get("children", []):
        if cid not in objs:
            errors.append(f"dangling child {cid} in group {oid} ({glabel})")
            continue
        if cid in seen:
            errors.append(f"duplicate child {cid} inside group {oid} ({glabel})")
        seen.add(cid)
        parents[cid].append((oid, glabel))

for cid, plist in parents.items():
    if len(plist) > 1:
        cobj = objs[cid]
        clabel = cobj.get("name") or cobj.get("path") or cid
        pdesc = ", ".join(f"{pid} ({plabel})" for pid, plabel in plist)
        errors.append(f"multi-parent reference {cid} ({clabel}) in groups: {pdesc}")

visited = set()
def walk(oid, rel_dir, stack):
    if oid in stack:
        errors.append(f"group cycle involving {oid}")
        return
    visited.add(oid)
    obj = objs[oid]
    st = obj.get("sourceTree", "<group>")
    p = obj.get("path", "")
    if st == "<group>":
        cur_dir = os.path.normpath(os.path.join(rel_dir, p)) if p else rel_dir
    elif st == "SOURCE_ROOT":
        cur_dir = os.path.normpath(os.path.join(root_dir, p)) if p else root_dir
    else:
        return
    if oid == prod_gid:
        return
    if obj.get("isa") in group_isas:
        for cid in obj.get("children", []):
            if cid in objs:
                walk(cid, cur_dir, stack | {oid})
    elif obj.get("isa") == "PBXFileReference":
        if not os.path.exists(cur_dir):
            errors.append(f"missing path on disk for {oid}: {cur_dir}")

walk(main_gid, root_dir, set())
for oid, obj in objs.items():
    if obj.get("isa") in group_isas and oid not in visited:
        glabel = obj.get("name") or obj.get("path") or oid
        errors.append(f"orphan group {oid} ({glabel}) not reachable from mainGroup")

if errors:
    for err in errors:
        print(f"pbxproj error: {err}", file=sys.stderr)
    sys.exit(1)
PY

echo "=== Project generated successfully ==="
