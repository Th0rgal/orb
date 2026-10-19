#!/bin/bash

# Xcode Cloud pre-xcodebuild: give every archive a unique, increasing build
# number. App Store Connect rejects an upload whose (version, build) pair was
# already used, so archives built without a hand-bumped build number never
# reached TestFlight even though the Xcode Cloud build itself succeeded.
#
# The version is single-sourced in project.yml (MARKETING_VERSION and
# CURRENT_PROJECT_VERSION); both Info.plists read $(CURRENT_PROJECT_VERSION).
# The committed CURRENT_PROJECT_VERSION stays the base (bump it by hand as
# before); Xcode Cloud appends its own run counter: 2026101601 -> 2026101601.<run>.
# ci_post_clone.sh has already generated and verified the project, so the
# generated project.pbxproj is rewritten here, just before xcodebuild reads it.
set -euo pipefail

if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
  exit 0
fi

ROOT="${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud repository path is required}/ios_dashboard"
PBXPROJ="${ROOT}/SandboxedDashboard.xcodeproj/project.pbxproj"

BASE="$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([0-9.]+)"?.*/\1/p' "${ROOT}/project.yml" | head -n 1)"
BASE="${BASE%%.*}"
if [[ -z "${BASE}" ]]; then
  echo "error: CURRENT_PROJECT_VERSION not found in project.yml" >&2
  exit 1
fi
BUILD="${BASE}.${CI_BUILD_NUMBER:?Xcode Cloud build number is required}"

# Every target configuration inherits the project-level value; rewrite all of
# them so the app and the Live Activity extension always match.
COUNT="$(grep -cE 'CURRENT_PROJECT_VERSION = [^;]+;' "${PBXPROJ}" || true)"
if [[ "${COUNT}" -eq 0 ]]; then
  echo "error: no CURRENT_PROJECT_VERSION in ${PBXPROJ}" >&2
  exit 1
fi
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = ${BUILD};/g" "${PBXPROJ}"

# Both Info.plists must resolve the build setting, never a literal.
for plist in "${ROOT}/SandboxedDashboard/Info.plist" "${ROOT}/OrbLiveActivity/Info.plist"; do
  value="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${plist}")"
  if [[ "${value}" != '$(CURRENT_PROJECT_VERSION)' ]]; then
    echo "error: ${plist} CFBundleVersion is ${value}, expected \$(CURRENT_PROJECT_VERSION)" >&2
    exit 1
  fi
done
echo "=== CURRENT_PROJECT_VERSION ${BUILD} (${COUNT} configurations) ==="
