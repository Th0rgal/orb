#!/bin/bash

# Archive, sign and upload Orb to TestFlight from this Mac, without waiting for
# Xcode Cloud. Signing is automatic through an App Store Connect API key read
# from Bitwarden Secrets Manager:
#   APPSTORE_CONNECT_API_PRIVATE_KEY        the .p8 private key (PEM)
#   APPSTORE_CONNECT_KEY_ID     e.g. CSV5HVF963
#   APPSTORE_CONNECT_ISSUER_ID  issuer UUID from App Store Connect
# Env overrides: ASC_TEAM_ID (default BQ6Z84B8L5), BWS (bws binary path).
#
# Build numbers are <base CFBundleVersion>.<UTC day-of-year HHMM> (Apple caps
# CFBundleVersion at 18 characters), which can never
# collide with Xcode Cloud's <base>.<run number> (run numbers stay small).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS="${ROOT}/ios_dashboard"
TEAM_ID="${ASC_TEAM_ID:-BQ6Z84B8L5}"
BWS="${BWS:-$(command -v bws || echo "${HOME}/.hermes/bin/bws")}"

if [[ -z "${BWS_ACCESS_TOKEN:-}" && -f "${HOME}/.hermes/.env" ]]; then
  BWS_ACCESS_TOKEN="$(grep -m1 '^BWS_ACCESS_TOKEN=' "${HOME}/.hermes/.env" | cut -d= -f2- | tr -d '"')"
  export BWS_ACCESS_TOKEN
fi

WORK="$(mktemp -d)"
chmod 700 "${WORK}"
PLIST="${IOS}/SandboxedDashboard/Info.plist"
EXT_PLIST="${IOS}/OrbLiveActivity/Info.plist"
cp "${PLIST}" "${WORK}/Info.plist.orig"
cp "${EXT_PLIST}" "${WORK}/ExtInfo.plist.orig"
cleanup() {
  cp "${WORK}/Info.plist.orig" "${PLIST}"
  cp "${WORK}/ExtInfo.plist.orig" "${EXT_PLIST}"
  rm -rf "${WORK}"
}
trap cleanup EXIT

"${BWS}" secret list -o json > "${WORK}/secrets.json"
secret() {
  python3 -I -c 'import json,sys
v=[s["value"] for s in json.load(open(sys.argv[1])) if s["key"]==sys.argv[2]]
sys.exit("missing Bitwarden secret "+sys.argv[2]) if not v else print(v[0].strip())' "${WORK}/secrets.json" "$1"
}
KEY_ID="${ASC_KEY_ID:-$(secret APPSTORE_CONNECT_KEY_ID 2>/dev/null || echo CSV5HVF963)}"
ISSUER_ID="${ASC_ISSUER_ID:-$(secret APPSTORE_CONNECT_ISSUER_ID)}"
KEY_PATH="${WORK}/AuthKey_${KEY_ID}.p8"
secret APPSTORE_CONNECT_API_PRIVATE_KEY > "${KEY_PATH}"
rm -f "${WORK}/secrets.json"
AUTH=(-allowProvisioningUpdates
  -authenticationKeyPath "${KEY_PATH}"
  -authenticationKeyID "${KEY_ID}"
  -authenticationKeyIssuerID "${ISSUER_ID}")

# Same project generation as Xcode Cloud (pinned XcodeGen, no drift allowed).
CI_PRIMARY_REPOSITORY_PATH="${ROOT}" bash "${IOS}/ci_scripts/ci_post_clone.sh"

BASE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${PLIST}")"
BUILD="${BASE%%.*}.$(date -u +%j%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "${EXT_PLIST}"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${PLIST}")"
echo "=== Orb ${VERSION} (${BUILD}) ==="

xcodebuild archive \
  -project "${IOS}/SandboxedDashboard.xcodeproj" \
  -scheme SandboxedDashboard \
  -configuration Release \
  -destination generic/platform=iOS \
  -archivePath "${WORK}/Orb.xcarchive" \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="${TEAM_ID}" \
  "${AUTH[@]}"

cat > "${WORK}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "${WORK}/Orb.xcarchive" \
  -exportOptionsPlist "${WORK}/ExportOptions.plist" \
  -exportPath "${WORK}/export" \
  "${AUTH[@]}"

echo "=== Uploaded Orb ${VERSION} (${BUILD}); TestFlight shows it after Apple finishes processing ==="
