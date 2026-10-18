#!/bin/bash

# Xcode Cloud pre-xcodebuild: give every archive a unique, increasing build
# number. App Store Connect rejects an upload whose (version, build) pair was
# already used, so archives built without a hand-bumped CFBundleVersion never
# reached TestFlight even though the Xcode Cloud build itself succeeded.
#
# The committed CFBundleVersion stays the base (bump it by hand as before);
# Xcode Cloud appends its own run counter: 2026101203 -> 2026101203.<run>.
set -euo pipefail

if [[ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]]; then
  exit 0
fi

PLIST="${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud repository path is required}/ios_dashboard/SandboxedDashboard/Info.plist"
BASE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${PLIST}")"
BASE="${BASE%%.*}"
BUILD="${BASE}.${CI_BUILD_NUMBER:?Xcode Cloud build number is required}"

# The Live Activity extension must carry the same version as the app.
for plist in "${PLIST}" "${PLIST%/SandboxedDashboard/Info.plist}/OrbLiveActivity/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "${plist}"
done
echo "=== CFBundleVersion ${BUILD} ==="
