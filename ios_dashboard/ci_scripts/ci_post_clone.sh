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

echo "=== Project generated successfully ==="
