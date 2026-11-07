#!/usr/bin/env bash
# Fast Orb Desktop developer loop & macOS/Linux bundle staging.
#
# Usage:
#   ./scripts/orb_desktop_dev.sh                     # HMR dev loop: Vite on 127.0.0.1:1430 + native shell + orb-locald
#   ./scripts/orb_desktop_dev.sh --bundle            # Stage standalone macos_shell/build/Orb.app (or linux_shell/build)
#   ./scripts/orb_desktop_dev.sh --bundle --install  # Also sync staged Orb.app into /Applications/Orb.app
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="dev"
INSTALL_APP=0
VITE_PORT="${ORB_VITE_PORT:-1430}"
LOCALD_PORT="${ORB_LOCALD_PORT:-19477}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)
      MODE="bundle"
      shift
      ;;
    --install)
      INSTALL_APP=1
      shift
      ;;
    *)
      echo "error: unknown option '$1' (expected --bundle or --install)" >&2
      exit 2
      ;;
  esac
done

OS_NAME="$(uname -s)"
STAGE_BIN_DIR="$ROOT_DIR/macos_shell/build"
mkdir -p "$STAGE_BIN_DIR"

echo "==> Building orb-locald + sandboxed-mcp via turbo-lean / lake..."
"$ROOT_DIR/scripts/build_orb_bins.sh" \
  --out-dir "$STAGE_BIN_DIR" \
  --only orb-locald \
  --only sandboxed-mcp

if [[ "$OS_NAME" == "Darwin" ]]; then
  echo "==> Compiling native macos_shell + orb-signer..."
  swiftc -O \
    -framework AppKit \
    -framework WebKit \
    -framework Security \
    "$ROOT_DIR/macos_shell/main.swift" \
    -o "$STAGE_BIN_DIR/orb"
  python3 "$ROOT_DIR/orb/scripts/build-signer.py"
elif [[ "$OS_NAME" == "Linux" ]]; then
  echo "==> Compiling native linux_shell..."
  make -C "$ROOT_DIR/linux_shell"
  install -m 0755 "$ROOT_DIR/linux_shell/orb-linux-shell" "$STAGE_BIN_DIR/orb"
else
  echo "error: unsupported OS '$OS_NAME'" >&2
  exit 1
fi

if [[ "$MODE" == "bundle" ]]; then
  echo "==> Building frontend dist/..."
  (cd "$ROOT_DIR/orb" && pnpm build)

  if [[ "$OS_NAME" == "Darwin" ]]; then
    APP_BUNDLE="$STAGE_BIN_DIR/Orb.app"
    MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
    RES_DIR="$APP_BUNDLE/Contents/Resources"
    mkdir -p "$MACOS_DIR" "$RES_DIR"

    install -m 0755 "$STAGE_BIN_DIR/orb" "$MACOS_DIR/orb"
    install -m 0755 "$STAGE_BIN_DIR/orb-locald" "$MACOS_DIR/orb-locald"
    install -m 0755 "$STAGE_BIN_DIR/orb-signer" "$MACOS_DIR/orb-signer"
    install -m 0755 "$STAGE_BIN_DIR/sandboxed-mcp" "$MACOS_DIR/sandboxed-mcp"

    rm -rf "$RES_DIR/dist"
    cp -R "$ROOT_DIR/orb/dist" "$RES_DIR/dist"

    node "$ROOT_DIR/orb/scripts/build-macos-icon.mjs"
    if [[ -f "$ROOT_DIR/macos_shell/gen/app-icon/Assets.car" ]]; then
      cp -f "$ROOT_DIR/macos_shell/gen/app-icon/Assets.car" "$RES_DIR/Assets.car"
    fi
    if [[ -f "$ROOT_DIR/macos_shell/gen/app-icon/Orb.icns" ]]; then
      cp -f "$ROOT_DIR/macos_shell/gen/app-icon/Orb.icns" "$RES_DIR/Orb.icns"
      cp -f "$ROOT_DIR/macos_shell/gen/app-icon/Orb.icns" "$RES_DIR/icon.icns"
    elif [[ -f "$ROOT_DIR/macos_shell/icons/icon.icns" ]]; then
      cp -f "$ROOT_DIR/macos_shell/icons/icon.icns" "$RES_DIR/Orb.icns"
      cp -f "$ROOT_DIR/macos_shell/icons/icon.icns" "$RES_DIR/icon.icns"
    fi

    SHORT_VER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT_DIR/orb/package.json")"
    GIT_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)"
    cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>English</string>
  <key>CFBundleDisplayName</key>
  <string>Orb</string>
  <key>CFBundleExecutable</key>
  <string>orb</string>
  <key>CFBundleIconFile</key>
  <string>Orb.icns</string>
  <key>CFBundleIconName</key>
  <string>Orb</string>
  <key>CFBundleIdentifier</key>
  <string>md.thomas.orb</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Orb</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${SHORT_VER}</string>
  <key>CFBundleVersion</key>
  <string>${GIT_SHA}</string>
  <key>CSResourcesFileMapped</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
  <key>LSRequiresCarbon</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Orb uses the microphone to dictate prompts. Audio is transcribed on this Mac and never leaves it.</string>
</dict>
</plist>
EOF
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
    echo "==> Staged standalone bundle at $APP_BUNDLE"

    if [[ "$INSTALL_APP" == "1" ]]; then
      rsync -a --delete "$APP_BUNDLE/" "/Applications/Orb.app/"
      echo "==> Synced /Applications/Orb.app"
    fi
  else
    rm -rf "$STAGE_BIN_DIR/dist"
    cp -R "$ROOT_DIR/orb/dist" "$STAGE_BIN_DIR/dist"
    echo "==> Staged Linux desktop build in $STAGE_BIN_DIR"
  fi
  exit 0
fi

# Dev HMR mode: start Vite on 127.0.0.1:$VITE_PORT if not already listening, then launch native shell.
VITE_PID=""
cleanup_dev() {
  if [[ -n "$VITE_PID" ]]; then
    kill "$VITE_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup_dev EXIT INT TERM

if ! curl -fsS "http://127.0.0.1:${VITE_PORT}/" >/dev/null 2>&1; then
  echo "==> Starting Vite dev server on http://127.0.0.1:${VITE_PORT}/..."
  (
    cd "$ROOT_DIR/orb"
    exec pnpm dev --host 127.0.0.1 --port "$VITE_PORT" --strictPort
  ) &
  VITE_PID="$!"
  for _ in {1..60}; do
    if curl -fsS "http://127.0.0.1:${VITE_PORT}/" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
fi

echo "==> Launching native Orb shell against http://127.0.0.1:${VITE_PORT}/ (orb-locald port ${LOCALD_PORT})..."
ORB_LOCALD_PORT="$LOCALD_PORT" \
ORB_LOCALD_BIN="$STAGE_BIN_DIR/orb-locald" \
ORB_SIGNER_BIN="$STAGE_BIN_DIR/orb-signer" \
ORB_DEV_URL="http://127.0.0.1:${VITE_PORT}/" \
  "$STAGE_BIN_DIR/orb"
