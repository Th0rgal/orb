#!/usr/bin/env bash
# Fast Orb Desktop developer loop & macOS/Linux bundle staging.
#
# Usage:
#   ./scripts/orb_desktop_dev.sh                     # UI HMR dev loop: Vite on 127.0.0.1:1430 + native shell + orb-locald (shares ~/.orb prod connection)
#   ./scripts/orb_desktop_dev.sh --local-server      # Isolated full-stack loop: also starts local orb-server in .orb-dev/
#   ./scripts/orb_desktop_dev.sh --rebuild           # Force rebuild of Lean/native binaries even if sources are unchanged
#   ./scripts/orb_desktop_dev.sh --install-desktop   # Install 'Orb Dev' XDG desktop launcher entry (~/.local/share/applications/orb-dev.desktop)
#   ./scripts/orb_desktop_dev.sh --bundle            # Stage standalone macos_shell/build/Orb.app (or linux_shell/build)
#   ./scripts/orb_desktop_dev.sh --bundle --install  # Also sync staged Orb.app into /Applications/Orb.app
#   ./scripts/orb_desktop_dev.sh --ui-only --install # ~10s UI-only update: rebuild orb/dist + sync into Orb.app (skips Lean/Swift)
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ORIG_ARGS=("$@")
MODE="dev"
INSTALL_APP=0
INSTALL_DESKTOP=0
FORCE_REBUILD=0
UI_ONLY=0
NO_SERVER="${ORB_NO_LOCAL_SERVER:-1}"
if [[ "${ORB_WITH_LOCAL_SERVER:-0}" == "1" ]]; then
  NO_SERVER=0
fi
VITE_PORT="${ORB_VITE_PORT:-1430}"
LOCALD_PORT="${ORB_LOCALD_PORT:-}"
SERVER_PORT="${ORB_SERVER_PORT:-3000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)
      MODE="bundle"
      shift
      ;;
    --static|--preview)
      MODE="static"
      shift
      ;;
    --ui-only)
      MODE="bundle"
      UI_ONLY=1
      shift
      ;;
    --install)
      INSTALL_APP=1
      shift
      ;;
    --install-desktop)
      INSTALL_DESKTOP=1
      shift
      ;;
    --rebuild)
      FORCE_REBUILD=1
      shift
      ;;
    --local-server)
      NO_SERVER=0
      shift
      ;;
    --no-server)
      NO_SERVER=1
      shift
      ;;
    *)
      echo "error: unknown option '$1' (expected --bundle, --ui-only, --install, --install-desktop, --rebuild, --local-server, or --no-server)" >&2
      exit 2
      ;;
  esac
done

OS_NAME="$(uname -s)"

if [[ "$INSTALL_DESKTOP" == "1" ]]; then
  if [[ "$OS_NAME" != "Linux" ]]; then
    echo "error: --install-desktop is only supported on Linux XDG desktops" >&2
    exit 1
  fi
  DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
  APPS_DIR="$DATA_HOME/applications"
  HICOLOR_DIR="$DATA_HOME/icons/hicolor"
  mkdir -p \
    "$APPS_DIR" \
    "$HICOLOR_DIR/32x32/apps" \
    "$HICOLOR_DIR/128x128/apps" \
    "$HICOLOR_DIR/128x128@2/apps" \
    "$HICOLOR_DIR/256x256/apps"
  for icon_name in orb orb-dev; do
    install -m 0644 "$ROOT_DIR/macos_shell/icons/32x32.png" "$HICOLOR_DIR/32x32/apps/${icon_name}.png"
    install -m 0644 "$ROOT_DIR/macos_shell/icons/128x128.png" "$HICOLOR_DIR/128x128/apps/${icon_name}.png"
    install -m 0644 "$ROOT_DIR/macos_shell/icons/128x128@2x.png" "$HICOLOR_DIR/128x128@2/apps/${icon_name}.png"
    install -m 0644 "$ROOT_DIR/macos_shell/icons/icon.png" "$HICOLOR_DIR/256x256/apps/${icon_name}.png"
  done
  DESKTOP_FILE="$APPS_DIR/orb-dev.desktop"
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Orb Dev
GenericName=Orb UI Dev Client
Comment=Orb UI from ${ROOT_DIR} (Vite HMR + orb-locald, shared ~/.orb connection)
Exec=${ROOT_DIR}/scripts/orb_desktop_dev.sh
Icon=orb-dev
Terminal=false
Type=Application
Categories=Development;Utility;
Keywords=orb;dev;hmr;ui;
StartupWMClass=orb-desktop
EOF
  chmod 0644 "$DESKTOP_FILE"
  echo "==> Installed XDG launcher entry ($DESKTOP_FILE) and hicolor icons ($HICOLOR_DIR)"
  exit 0
fi

# When launched from an app launcher (fuzzel/rofi/dmenu, non-TTY stdout), log to
# .orb-dev/orb-dev.log and surface build errors via desktop notifications.
LAUNCHED_FROM_GUI=0
if [[ ! -t 1 && -z "${ORB_DEV_LOGGED:-}" ]]; then
  LAUNCHED_FROM_GUI=1
  mkdir -p "$ROOT_DIR/.orb-dev"
  chmod 0700 "$ROOT_DIR/.orb-dev"
  LOG_FILE="$ROOT_DIR/.orb-dev/orb-dev.log"
  export ORB_DEV_LOGGED=1
  exec >"$LOG_FILE" 2>&1
fi
if [[ "${ORB_DEV_LOGGED:-}" == "1" ]]; then
  LAUNCHED_FROM_GUI=1
  LOG_FILE="$ROOT_DIR/.orb-dev/orb-dev.log"
  trap 'command -v notify-send >/dev/null 2>&1 && notify-send -u critical "Orb Dev failed to start" "Check ${LOG_FILE}" || true' ERR
fi

# Ensure NixOS user/system profile directories are on PATH (GUI launchers may have a minimal PATH),
# and transparently enter `nix develop` if pnpm, GTK/WebKitGTK dev headers, or GIO TLS modules are missing.
if [[ "$OS_NAME" == "Linux" && -e /etc/NIXOS ]]; then
  for p in \
    "$HOME/.nix-profile/bin" \
    "$HOME/.local/state/nix/profile/bin" \
    "/etc/profiles/per-user/${USER:-$(id -un)}/bin" \
    "/run/current-system/sw/bin" \
    "/nix/var/nix/profiles/default/bin"
  do
    if [[ -d "$p" && ":$PATH:" != *":$p:"* ]]; then
      export PATH="$p:$PATH"
    fi
  done
  export npm_config_manage_package_manager_versions="${npm_config_manage_package_manager_versions:-false}"
  has_gio_tls_module() {
    local IFS=':'
    for d in ${GIO_EXTRA_MODULES:-}; do
      [[ -n "$d" && -f "$d/libgiognutls.so" ]] && return 0
    done
    return 1
  }
  if [[ -z "${ORB_IN_NIX_SHELL:-}" ]] && { ! command -v pnpm >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1 || ! command -v pkg-config >/dev/null 2>&1; }; then
    echo "==> Entering nix develop environment for $ROOT_DIR..."
    exec nix develop "$ROOT_DIR" -c env ORB_IN_NIX_SHELL=1 "$ROOT_DIR/scripts/orb_desktop_dev.sh" "${ORIG_ARGS[@]}"
  fi
  if [[ -d /run/opengl-driver/share && ":${XDG_DATA_DIRS:-}:" != *":/run/opengl-driver/share:"* ]]; then
    export XDG_DATA_DIRS="/run/opengl-driver/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  elif [[ -d /run/opengl-driver/share ]]; then
    export XDG_DATA_DIRS="/run/opengl-driver/share:${XDG_DATA_DIRS//\/run\/opengl-driver\/share:/}"
  fi
  [[ -d /run/opengl-driver/lib ]] && export LD_LIBRARY_PATH="/run/opengl-driver/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  [[ -d /run/opengl-driver/lib/dri ]] && export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri"
  [[ -d /run/opengl-driver/lib/gbm ]] && export GBM_BACKENDS_PATH="/run/opengl-driver/lib/gbm"
  [[ -d /run/opengl-driver/share/glvnd/egl_vendor.d ]] && export __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d"
fi

if [[ "$OS_NAME" == "Linux" ]]; then
  STAGE_BIN_DIR="$ROOT_DIR/linux_shell/build"
else
  STAGE_BIN_DIR="$ROOT_DIR/macos_shell/build"
fi
mkdir -p "$STAGE_BIN_DIR"

if [[ "$UI_ONLY" == "1" ]]; then
  echo "==> Fast UI-only build (orb/dist)..."
  (cd "$ROOT_DIR/orb" && pnpm build)
  GIT_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)"
  if [[ "$OS_NAME" == "Darwin" ]]; then
    APP_BUNDLE="$STAGE_BIN_DIR/Orb.app"
    if [[ -d "$APP_BUNDLE/Contents/Resources" ]]; then
      rm -rf "$APP_BUNDLE/Contents/Resources/dist"
      cp -R "$ROOT_DIR/orb/dist" "$APP_BUNDLE/Contents/Resources/dist"
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_SHA" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
      codesign --force --deep --entitlements "$ROOT_DIR/macos_shell/Entitlements.plist" --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
      echo "==> Updated dist/ in $APP_BUNDLE (CFBundleVersion=$GIT_SHA)"
    fi
    if [[ "$INSTALL_APP" == "1" ]]; then
      if [[ ! -d "/Applications/Orb.app/Contents/MacOS" ]]; then
        echo "error: /Applications/Orb.app not found; run './scripts/orb_desktop_dev.sh --bundle --install' once first" >&2
        exit 1
      fi
      # Sync without --delete so an already-running Orb.app never hits 404 on lazy
      # JS/CSS chunks from its previous bundle while index.html points to the new build.
      rsync -a "$ROOT_DIR/orb/dist/" "/Applications/Orb.app/Contents/Resources/dist/"
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_SHA" "/Applications/Orb.app/Contents/Info.plist" 2>/dev/null || true
      codesign --force --deep --entitlements "$ROOT_DIR/macos_shell/Entitlements.plist" --sign - "/Applications/Orb.app" >/dev/null 2>&1 || true
      echo "==> Synced orb/dist into /Applications/Orb.app (CFBundleVersion=$GIT_SHA)"
    fi
  else
    rm -rf "$STAGE_BIN_DIR/dist"
    cp -R "$ROOT_DIR/orb/dist" "$STAGE_BIN_DIR/dist"
    echo "==> Synced orb/dist into $STAGE_BIN_DIR/dist"
    if [[ "$INSTALL_APP" == "1" ]]; then
      LINUX_APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/orb-app"
      if [[ ! -x "$LINUX_APP_DIR/bin/orb" ]]; then
        echo "error: $LINUX_APP_DIR not found; run './scripts/orb_desktop_dev.sh --bundle --install' once first" >&2
        exit 1
      fi
      rsync -a "$ROOT_DIR/orb/dist/" "$LINUX_APP_DIR/share/orb/"
      echo "==> Synced orb/dist into $LINUX_APP_DIR/share/orb"
    fi
  fi
  exit 0
fi

SERVER_BIN="orb-core"
if grep -q '"orb-server"' "$ROOT_DIR/scripts/build_orb_bins.sh" 2>/dev/null; then
  SERVER_BIN="orb-server"
fi

BINS_ARGS=(--only orb-locald --only sandboxed-mcp)
REQUIRED_LEAN_BINS=("$STAGE_BIN_DIR/orb-locald" "$STAGE_BIN_DIR/sandboxed-mcp")
if [[ "$MODE" == "dev" && "$NO_SERVER" == "0" ]]; then
  BINS_ARGS+=(--only "$SERVER_BIN" --only workspace-mcp)
  REQUIRED_LEAN_BINS+=("$STAGE_BIN_DIR/$SERVER_BIN" "$STAGE_BIN_DIR/workspace-mcp")
fi

NEED_LEAN_BUILD=0
LEAN_WATCH_DIRS=("$ROOT_DIR/lean/Orb" "$ROOT_DIR/lean/OrbBin" "$ROOT_DIR/lean/OrbNetLeaf" "$ROOT_DIR/lean/OrbLocald" "$ROOT_DIR/lean/LeanSys")
if [[ "$MODE" == "dev" && "$NO_SERVER" == "0" ]]; then
  LEAN_WATCH_DIRS=("$ROOT_DIR/lean")
fi
if [[ "$FORCE_REBUILD" == "1" || "$MODE" == "bundle" ]]; then
  NEED_LEAN_BUILD=1
else
  for bin_path in "${REQUIRED_LEAN_BINS[@]}"; do
    if [[ ! -x "$bin_path" ]]; then
      NEED_LEAN_BUILD=1
      break
    fi
    if [[ -n "$(find "${LEAN_WATCH_DIRS[@]}" \( -name .lake -prune \) -o \( -name '*.lean' -o -name '*.c' -o -name '*.h' -o -name 'lakefile.lean' \) -newer "$bin_path" -print -quit 2>/dev/null)" ]]; then
      NEED_LEAN_BUILD=1
      break
    fi
  done
fi

GUI_BUILD_NOTIFIED=0
notify_gui_build() {
  if [[ "$LAUNCHED_FROM_GUI" == "1" && "$GUI_BUILD_NOTIFIED" == "0" ]]; then
    GUI_BUILD_NOTIFIED=1
    command -v notify-send >/dev/null 2>&1 && notify-send "Orb Dev" "Building local Orb binaries..." || true
  fi
}

if [[ "$NEED_LEAN_BUILD" == "1" ]]; then
  notify_gui_build
  echo "==> Building ${BINS_ARGS[*]} via turbo-lean / lake..."
  "$ROOT_DIR/scripts/build_orb_bins.sh" \
    --out-dir "$STAGE_BIN_DIR" \
    "${BINS_ARGS[@]}"
else
  echo "==> Lean binaries in $STAGE_BIN_DIR are up to date (pass --rebuild to force)."
fi

if [[ "$OS_NAME" == "Darwin" ]]; then
  if [[ "$FORCE_REBUILD" == "1" || "$MODE" == "bundle" || ! -x "$STAGE_BIN_DIR/orb" || "$ROOT_DIR/macos_shell/main.swift" -nt "$STAGE_BIN_DIR/orb" || "$ROOT_DIR/macos_shell/Entitlements.plist" -nt "$STAGE_BIN_DIR/orb" ]]; then
    notify_gui_build
    echo "==> Compiling native macos_shell..."
    swiftc -O \
      -framework AppKit \
      -framework WebKit \
      -framework Security \
      "$ROOT_DIR/macos_shell/main.swift" \
      -o "$STAGE_BIN_DIR/orb"
    codesign --force --entitlements "$ROOT_DIR/macos_shell/Entitlements.plist" --sign - "$STAGE_BIN_DIR/orb" >/dev/null 2>&1 || true
  fi
  if [[ "$FORCE_REBUILD" == "1" || "$MODE" == "bundle" || ! -x "$STAGE_BIN_DIR/orb-signer" || "$ROOT_DIR/macos_shell/signer/main.swift" -nt "$STAGE_BIN_DIR/orb-signer" || "$ROOT_DIR/orb/scripts/build-signer.py" -nt "$STAGE_BIN_DIR/orb-signer" ]]; then
    notify_gui_build
    echo "==> Compiling native macOS orb-signer..."
    python3 "$ROOT_DIR/orb/scripts/build-signer.py"
  fi
elif [[ "$OS_NAME" == "Linux" ]]; then
  if [[ "$FORCE_REBUILD" == "1" || "$MODE" == "bundle" || ! -x "$STAGE_BIN_DIR/orb" || "$ROOT_DIR/c/lean_ui_wayland.c" -nt "$STAGE_BIN_DIR/orb" || "$ROOT_DIR/c/lean_ui_text.c" -nt "$STAGE_BIN_DIR/orb" || "$ROOT_DIR/c/lean_ui_vulkan.c" -nt "$STAGE_BIN_DIR/orb" || "$ROOT_DIR/c/lean_ui.h" -nt "$STAGE_BIN_DIR/orb" || "$ROOT_DIR/linux_shell/Makefile" -nt "$STAGE_BIN_DIR/orb" ]]; then
    notify_gui_build
    echo "==> Compiling native lean-ui orb-desktop..."
    make -C "$ROOT_DIR/linux_shell"
    install -m 0755 "$ROOT_DIR/linux_shell/orb-desktop" "$STAGE_BIN_DIR/orb"
  fi
  if [[ "$FORCE_REBUILD" == "1" || "$MODE" == "bundle" || ! -x "$STAGE_BIN_DIR/orb-signer" || "$ROOT_DIR/linux_shell/signer/orb-signer.py" -nt "$STAGE_BIN_DIR/orb-signer" || "$ROOT_DIR/orb/scripts/build-signer.py" -nt "$STAGE_BIN_DIR/orb-signer" ]]; then
    python3 "$ROOT_DIR/orb/scripts/build-signer.py"
  fi
else
  echo "error: unsupported OS '$OS_NAME'" >&2
  exit 1
fi

if [[ ! -d "$ROOT_DIR/orb/node_modules" ]]; then
  echo "==> Installing frontend dependencies (pnpm install --frozen-lockfile)..."
  (cd "$ROOT_DIR/orb" && CI=true pnpm install --frozen-lockfile)
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
    codesign --force --deep --entitlements "$ROOT_DIR/macos_shell/Entitlements.plist" --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
    echo "==> Staged standalone bundle at $APP_BUNDLE"

    if [[ "$INSTALL_APP" == "1" ]]; then
      rsync -a "$APP_BUNDLE/" "/Applications/Orb.app/"
      find "/Applications/Orb.app/Contents/Resources/dist/assets" -type f -mtime +7 -delete 2>/dev/null || true
      codesign --force --deep --entitlements "$ROOT_DIR/macos_shell/Entitlements.plist" --sign - "/Applications/Orb.app" >/dev/null 2>&1 || true
      echo "==> Synced /Applications/Orb.app"
    fi
  else
    rm -rf "$STAGE_BIN_DIR/dist"
    cp -R "$ROOT_DIR/orb/dist" "$STAGE_BIN_DIR/dist"
    echo "==> Staged Linux desktop build in $STAGE_BIN_DIR"
    if [[ "$INSTALL_APP" == "1" ]]; then
      XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
      LINUX_APP_DIR="$XDG_DATA/orb-app"
      PY_BIN="$(command -v python3)"
      mkdir -p "$LINUX_APP_DIR/bin" "$LINUX_APP_DIR/share/orb" "$XDG_DATA/applications" "$XDG_DATA/icons/hicolor/256x256/apps"
      install -m 0755 "$STAGE_BIN_DIR/orb" "$LINUX_APP_DIR/bin/.orb-desktop-unwrapped"
      install -m 0755 "$STAGE_BIN_DIR/orb-locald" "$LINUX_APP_DIR/bin/orb-locald"
      install -m 0755 "$STAGE_BIN_DIR/orb-signer" "$LINUX_APP_DIR/bin/orb-signer"
      install -m 0755 "$STAGE_BIN_DIR/sandboxed-mcp" "$LINUX_APP_DIR/bin/sandboxed-mcp"
      rsync -a "$ROOT_DIR/orb/dist/" "$LINUX_APP_DIR/share/orb/"
      find "$LINUX_APP_DIR/share/orb/assets" -type f -mtime +7 -delete 2>/dev/null || true
      if [[ -f "$ROOT_DIR/macos_shell/icons/icon.png" ]]; then
        install -m 0644 "$ROOT_DIR/macos_shell/icons/icon.png" "$XDG_DATA/icons/hicolor/256x256/apps/orb.png"
      fi
      rm -f "$LINUX_APP_DIR/bin/.orb-static-server"
      printf '#!%s\n' "${PY_BIN}" > "$LINUX_APP_DIR/bin/.orb-migrate-1431"
      cat >> "$LINUX_APP_DIR/bin/.orb-migrate-1431" <<'PY'
import hmac, json, os, secrets, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

MIG_DONE = sys.argv[1]
TARGET = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] in ("tauri://localhost", "orb://localhost") else "tauri://localhost"
NONCE = secrets.token_hex(32)
STAGED = {"body": None}

HTML = ("""<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:#141414}</style><script>
(async()=>{
  const NONCE=%s,TARGET=%s;
  const b64=(u8)=>{let s="";for(let i=0;i<u8.length;i+=0x8000)s+=String.fromCharCode.apply(null,u8.subarray(i,i+0x8000));return btoa(s);};
  const enc=async(v)=>{
    if(!v||typeof v!=="object")return v;
    if(v instanceof File)return{__orb_t:"File",name:v.name,type:v.type,lastModified:v.lastModified,b64:b64(new Uint8Array(await v.arrayBuffer()))};
    if(v instanceof Blob)return{__orb_t:"Blob",type:v.type,b64:b64(new Uint8Array(await v.arrayBuffer()))};
    if(v instanceof Uint8Array)return{__orb_t:"Uint8Array",b64:b64(v)};
    if(v instanceof ArrayBuffer)return{__orb_t:"ArrayBuffer",b64:b64(new Uint8Array(v))};
    if(v instanceof Date)return{__orb_t:"Date",iso:v.toISOString()};
    if(Array.isArray(v))return Promise.all(v.map(enc));
    const o={};for(const[k,x]of Object.entries(v))o[k]=await enc(x);return o;
  };
  try{
    const raw=await new Promise((res,rej)=>{
      let missing=false;const rq=indexedDB.open("orb-composer-drafts");
      rq.onupgradeneeded=(e)=>{if(e.oldVersion===0){missing=true;rq.transaction.abort();}};
      rq.onerror=()=>missing?res([]):rej(rq.error);
      rq.onsuccess=()=>{
        const db=rq.result;if(!db.objectStoreNames.contains("drafts")){db.close();res([]);return;}
        const out=[],tx=db.transaction("drafts","readonly"),cr=tx.objectStore("drafts").openCursor();
        cr.onsuccess=()=>{const c=cr.result;if(c){if(typeof c.key==="string")out.push([c.key,c.value]);c.continue();}};
        tx.oncomplete=()=>{db.close();res(out);};tx.onerror=()=>{db.close();rej(tx.error);};
      };
    });
    const entries=await Promise.all(raw.map(async([k,v])=>[k,await enc(v)]));
    const r=await fetch("/__orb_migrate_stage?nonce="+NONCE,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({entries})});
    if(!r.ok)throw new Error("stage");
    location.replace(TARGET+"/?migrate_1431="+NONCE);
  }catch{
    fetch("/__orb_migrate_abort?nonce="+NONCE,{method:"POST"}).catch(()=>{});
    location.replace(TARGET+"/");
  }
})();
</script>""" % (json.dumps(NONCE), json.dumps(TARGET))).encode("utf-8")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): return
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", TARGET)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Cache-Control", "no-store")
    def _valid(self):
        u = urlsplit(self.path)
        got = (parse_qs(u.query).get("nonce") or [""])[0]
        return u.path, hmac.compare_digest(got, NONCE)
    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()
    def do_GET(self):
        p, ok = self._valid()
        if not ok:
            self.send_response(403); self.end_headers(); return
        if p == "/__orb_migrate":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; connect-src 'self'; style-src 'unsafe-inline'")
            self.send_header("Content-Length", str(len(HTML)))
            self.end_headers(); self.wfile.write(HTML); return
        if p == "/__orb_migrate_pull" and STAGED["body"] is not None:
            b = STAGED["body"]
            self.send_response(200); self._cors()
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers(); self.wfile.write(b); return
        self.send_response(404); self._cors(); self.end_headers()
    def do_POST(self):
        p, ok = self._valid()
        if not ok:
            self.send_response(403); self.end_headers(); return
        n = int(self.headers.get("Content-Length") or "0")
        body = self.rfile.read(n) if n > 0 else b""
        if p == "/__orb_migrate_stage":
            STAGED["body"] = body
            self.send_response(204); self.send_header("Cache-Control", "no-store"); self.end_headers(); return
        if p == "/__orb_migrate_ack":
            d = os.path.dirname(MIG_DONE)
            if d: os.makedirs(d, exist_ok=True)
            tmp = MIG_DONE + ".tmp"
            with open(tmp, "wb") as f: f.write(b"1\n")
            os.replace(tmp, MIG_DONE)
            self.send_response(204); self._cors(); self.end_headers()
            threading.Thread(target=self.server.shutdown, daemon=True).start(); return
        if p == "/__orb_migrate_abort":
            self.send_response(204); self.end_headers()
            threading.Thread(target=self.server.shutdown, daemon=True).start(); return
        self.send_response(404); self.end_headers()

class ReusableServer(ThreadingHTTPServer):
    allow_reuse_address = True

try:
    srv = ReusableServer(("127.0.0.1", 1431), Handler)
except OSError:
    sys.stdout.write("skip\n"); sys.stdout.flush(); sys.exit(0)

sys.stdout.write(NONCE + "\n"); sys.stdout.flush()
t = threading.Timer(30.0, srv.shutdown); t.daemon = True; t.start()
srv.serve_forever()
PY
      chmod 0755 "$LINUX_APP_DIR/bin/.orb-migrate-1431"
      cat > "$LINUX_APP_DIR/bin/orb" <<EOF
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="\$APP_DIR/bin:/etc/profiles/per-user/\${USER:-\$(id -un)}/bin:/run/current-system/sw/bin:\$PATH"
export ORB_LOCALD_BIN="\$APP_DIR/bin/orb-locald"
export ORB_SIGNER_BIN="\$APP_DIR/bin/orb-signer"
if [[ -d /run/opengl-driver/share ]]; then
  export XDG_DATA_DIRS="/run/opengl-driver/share:\${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
fi
if [[ -d /run/opengl-driver/lib ]]; then
  export LD_LIBRARY_PATH="/run/opengl-driver/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
fi
if [[ -d /run/opengl-driver/lib/dri ]]; then
  export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri"
fi
if [[ -d /run/opengl-driver/lib/gbm ]]; then
  export GBM_BACKENDS_PATH="/run/opengl-driver/lib/gbm"
fi
if [[ -d /run/opengl-driver/share/glvnd/egl_vendor.d ]]; then
  export __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d"
fi
if [[ " \$* " == *" --self-test "* ]]; then
  exec "\$APP_DIR/bin/.orb-desktop-unwrapped" "\$@"
fi
if [[ -z "\${ORB_DEV_URL:-}" && -z "\${ORB_DIST_DIR:-}" ]]; then
  export ORB_DIST_DIR="\$APP_DIR/share/orb"
fi
mig_url=""
state_dir="\${ORB_STATE_DIR:-\$HOME/.orb}"
mig_done="\$state_dir/.linux-1431-drafts-migrated"
if [[ -z "\${ORB_DEV_URL:-}" && ! -f "\$mig_done" ]]; then
  if [[ ! -d "\${XDG_DATA_HOME:-\$HOME/.local/share}/orb-desktop" ]]; then
    mkdir -p "\$state_dir" && : > "\$mig_done"
  elif [[ -x "\$APP_DIR/bin/.orb-migrate-1431" ]]; then
    target_origin="tauri://localhost"
    [[ "\${ORB_URI_SCHEME:-}" == "orb" ]] && target_origin="orb://localhost"
    fifo="\$(mktemp -u)"
    mkfifo -m 0600 "\$fifo"
    "\$APP_DIR/bin/.orb-migrate-1431" "\$mig_done" "\$target_origin" >"\$fifo" 2>/dev/null &
    IFS= read -r mig_tok <"\$fifo" || true
    rm -f "\$fifo"
    if [[ "\${mig_tok:-}" =~ ^[0-9a-f]{64}\$ ]]; then
      mig_url="http://127.0.0.1:1431/__orb_migrate?nonce=\$mig_tok"
    fi
  fi
fi
if [[ -z "\${ORB_LOCALD_PORT:-}" ]]; then
  export ORB_LOCALD_PORT=\$("${PY_BIN}" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
fi
if [[ -n "\$mig_url" ]]; then
  ORB_DEV_URL="\$mig_url" exec "\$APP_DIR/bin/.orb-desktop-unwrapped" "\$@"
fi
exec "\$APP_DIR/bin/.orb-desktop-unwrapped" "\$@"
EOF
      chmod 0755 "$LINUX_APP_DIR/bin/orb"
      cat > "$XDG_DATA/applications/orb.desktop" <<EOF
[Desktop Entry]
Name=Orb
Comment=All your AI providers, machines, and agent harnesses in one place
Exec=$LINUX_APP_DIR/bin/orb
Icon=orb
Terminal=false
Type=Application
Categories=Development;Utility;
StartupWMClass=orb-desktop
EOF
      chmod 0644 "$XDG_DATA/applications/orb.desktop"
      echo "==> Installed standalone Orb app to $LINUX_APP_DIR ($XDG_DATA/applications/orb.desktop)"
    fi
  fi
  exit 0
fi

# Dev HMR mode: start local orb-server (unless --no-server), Vite on 127.0.0.1:$VITE_PORT, then launch native shell.
mkdir -p "$ROOT_DIR/.orb-dev"
chmod 0700 "$ROOT_DIR/.orb-dev"
VITE_PID_FILE="$ROOT_DIR/.orb-dev/vite-${VITE_PORT}.pid"
VITE_PID=""
SERVER_PID=""
has_other_dev_shell() {
  local needle="ORB_DEV_URL=http://127.0.0.1:${VITE_PORT}/"
  if [[ "$OS_NAME" == "Linux" ]]; then
    local envf pid cmd
    for envf in /proc/[0-9]*/environ; do
      pid="${envf#/proc/}"
      pid="${pid%/environ}"
      [[ "$pid" == "$$" ]] && continue
      cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
      [[ "$cmd" =~ (^|/)orb([[:space:]]|$) && "$cmd" != *"orb_desktop_dev.sh"* ]] || continue
      if tr '\0' '\n' <"$envf" 2>/dev/null | grep -Fqx "$needle"; then
        return 0
      fi
    done
    return 1
  fi
  local pid cmd candidate_pids=","
  while read -r pid cmd; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    if [[ "$cmd" =~ (^|/)orb([[:space:]]|$) && "$cmd" != *"orb_desktop_dev.sh"* ]]; then
      candidate_pids+="${pid},"
    fi
  done < <(ps axww -o pid=,command= 2>/dev/null || true)
  [[ "$candidate_pids" == "," ]] && return 1
  while read -r pid cmd; do
    if [[ "$candidate_pids" == *",${pid},"* && " $cmd " == *" $needle "* ]]; then
      return 0
    fi
  done < <(ps axeww -o pid=,command= 2>/dev/null || true)
  return 1
}
cleanup_dev() {
  if ! has_other_dev_shell; then
    local vpid="${VITE_PID:-}"
    if [[ -z "$vpid" && -f "$VITE_PID_FILE" ]]; then
      vpid="$(cat "$VITE_PID_FILE" 2>/dev/null || true)"
    fi
    if [[ -n "$vpid" && "$vpid" =~ ^[0-9]+$ ]]; then
      pkill -P "$vpid" >/dev/null 2>&1 || true
      kill "$vpid" >/dev/null 2>&1 || true
    fi
    rm -f "$VITE_PID_FILE"
  fi
  if [[ -n "$SERVER_PID" ]]; then
    pkill -P "$SERVER_PID" >/dev/null 2>&1 || true
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup_dev EXIT HUP INT TERM

if [[ -z "$LOCALD_PORT" ]]; then
  LOCALD_PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
try:
    s.bind(("127.0.0.1", 19477))
    print(19477)
except OSError:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
finally:
    s.close()
PY
)"
fi

DEV_STATE_DIR="${ORB_STATE_DIR:-}"
if [[ "$NO_SERVER" == "0" ]]; then
  DEV_STATE_DIR="${DEV_STATE_DIR:-$ROOT_DIR/.orb-dev}"
  mkdir -p "$DEV_STATE_DIR/server"
  chmod 0700 "$DEV_STATE_DIR"
  SERVER_URL="http://127.0.0.1:${SERVER_PORT}"
  if ! curl -fsS "${SERVER_URL}/api/health" >/dev/null 2>&1; then
    echo "==> Starting local orb-server on ${SERVER_URL} (state: ${DEV_STATE_DIR}/server)..."
    (
      export HOST="127.0.0.1"
      export PORT="$SERVER_PORT"
      export DEV_MODE="true"
      export WORKING_DIR="$DEV_STATE_DIR/server"
      export LIBRARY_PATH="$DEV_STATE_DIR/server/.sandboxed-sh/library"
      exec "$STAGE_BIN_DIR/$SERVER_BIN"
    ) &
    SERVER_PID="$!"
    for _ in {1..60}; do
      if curl -fsS "${SERVER_URL}/api/health" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
  fi
  CONN_FILE="$DEV_STATE_DIR/connection.json"
  python3 - "$SERVER_URL" "$CONN_FILE" <<'PY'
import json, os, sys, urllib.request
server_url, conn_file = sys.argv[1], sys.argv[2]
if os.path.exists(conn_file):
    try:
        existing = json.loads(open(conn_file).read())
        if isinstance(existing, dict) and existing.get("api_url", "").rstrip("/") not in ("", server_url.rstrip("/")):
            sys.exit(0)
    except Exception:
        pass
req = urllib.request.Request(
    f"{server_url}/api/auth/login",
    data=b'{"password":""}',
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=5) as resp:
    tok = json.loads(resp.read().decode()).get("token", "")
if tok:
    tmp = conn_file + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"api_url": server_url, "token": tok}, f)
        f.write("\n")
    os.replace(tmp, conn_file)
PY
  echo "==> Connected desktop state ($CONN_FILE) to local orb-server (${SERVER_URL})"
fi

if [[ "$MODE" == "static" ]]; then
  if [[ ! -f "$ROOT_DIR/orb/dist/index.html" || "$FORCE_REBUILD" == "1" ]]; then
    echo "==> Building frontend dist/ for static mode (zero vite/esbuild runtime overhead)..."
    (cd "$ROOT_DIR/orb" && pnpm build)
  fi
  echo "==> Starting lightweight static asset server on http://127.0.0.1:${VITE_PORT}/..."
  python3 - "$ROOT_DIR/orb/dist" "$VITE_PORT" <<'PY' &
import os, sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
ROOT, PORT = os.path.realpath(sys.argv[1]), int(sys.argv[2])
MIME = {".html":"text/html; charset=utf-8",".js":"text/javascript; charset=utf-8",".mjs":"text/javascript; charset=utf-8",".css":"text/css; charset=utf-8",".wasm":"application/wasm",".json":"application/json; charset=utf-8",".svg":"image/svg+xml",".png":"image/png",".webp":"image/webp",".ico":"image/x-icon",".woff2":"font/woff2"}
class H(SimpleHTTPRequestHandler):
    def log_message(self, *a): return
    def end_headers(self):
        p = getattr(self, "path", "").split("?", 1)[0]
        self.send_header("Cache-Control", "public, max-age=31536000, immutable" if p.startswith(("/assets/","/provider-icons/")) or p.endswith((".woff2",".wasm")) else "no-cache")
        super().end_headers()
    def guess_type(self, p): return MIME.get(os.path.splitext(p)[1].lower(), "application/octet-stream")
    def translate_path(self, p):
        rel = p.split("?",1)[0].split("#",1)[0].lstrip("/") or "index.html"
        c = os.path.normpath(os.path.join(ROOT, rel))
        if not (c == ROOT or c.startswith(ROOT + os.sep)): return os.path.join(ROOT, "__missing__")
        return c if os.path.isfile(c) else (os.path.join(ROOT, "index.html") if not os.path.splitext(rel)[1] else os.path.join(ROOT, "__missing__"))
class S(ThreadingHTTPServer): allow_reuse_address = True
S(("127.0.0.1", PORT), H).serve_forever()
PY
  VITE_PID="$!"
  for _ in {1..40}; do
    curl -fsS "http://127.0.0.1:${VITE_PORT}/" >/dev/null 2>&1 && break
    sleep 0.1
  done
elif ! curl -fsS "http://127.0.0.1:${VITE_PORT}/" >/dev/null 2>&1; then
  echo "==> Starting Vite dev server on http://127.0.0.1:${VITE_PORT}/..."
  if command -v setsid >/dev/null 2>&1; then
    (
      cd "$ROOT_DIR/orb"
      exec setsid pnpm dev --host 127.0.0.1 --port "$VITE_PORT" --strictPort </dev/null
    ) &
  else
    (
      cd "$ROOT_DIR/orb"
      exec pnpm dev --host 127.0.0.1 --port "$VITE_PORT" --strictPort </dev/null
    ) &
  fi
  VITE_PID="$!"
  printf '%s\n' "$VITE_PID" >"$VITE_PID_FILE"
  for _ in {1..60}; do
    if curl -fsS "http://127.0.0.1:${VITE_PORT}/" >/dev/null 2>&1; then
      break
    fi
    sleep 0.25
  done
fi

echo "==> Launching native Orb shell against http://127.0.0.1:${VITE_PORT}/ (orb-locald port ${LOCALD_PORT})..."
ORB_APP_ICON="$ROOT_DIR/macos_shell/icons/icon.icns" \
ORB_STATE_DIR="$DEV_STATE_DIR" \
ORB_LOCALD_PORT="$LOCALD_PORT" \
ORB_LOCALD_BIN="$STAGE_BIN_DIR/orb-locald" \
ORB_SIGNER_BIN="$STAGE_BIN_DIR/orb-signer" \
ORB_DEV_URL="http://127.0.0.1:${VITE_PORT}/" \
  "$STAGE_BIN_DIR/orb"
