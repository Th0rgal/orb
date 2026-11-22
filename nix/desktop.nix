{lib, stdenv, callPackage, clang, pkg-config, nodejs, pnpm, fetchPnpmDeps, pnpmConfigHook, gtk3, webkitgtk_4_1, makeBinaryWrapper, python3, pulseaudio, wl-clipboard, zenity, revision ? "local checkout", turbo-lean ? null}:

let
  core = callPackage ./package.nix {inherit turbo-lean; buildDesktop = true;};
  webUi = stdenv.mkDerivation {
    pname = "orb-ui";
    inherit (core) version;
    src = ../orb;
    pnpmDeps = fetchPnpmDeps {
      pname = "orb-desktop";
      inherit (core) version;
      src = ../orb;
      fetcherVersion = 5;
      hash = "sha256-Dd/+Hxbe0bef8hp/37aIfpVgqYuf0XXPspotz8rW5fw=";
    };
    nativeBuildInputs = [nodejs pnpm pnpmConfigHook];
    ORB_BUILD_ID = revision;
    buildPhase = "pnpm build";
    installPhase = "cp -r dist $out";
  };
in
stdenv.mkDerivation {
  pname = "orb-desktop";
  version = core.version;
  src = ../.;
  passthru = {inherit core webUi;};
  dontConfigure = true;
  nativeBuildInputs = [clang pkg-config makeBinaryWrapper];
  buildInputs = [gtk3 webkitgtk_4_1];
  buildPhase = ''
    runHook preBuild
    ${clang}/bin/clang -std=gnu11 -O2 -Wall -Wextra -Werror -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE \
      -DORB_HAS_WEBKITGTK $(pkg-config --cflags gtk+-3.0 webkit2gtk-4.1) \
      -o orb-webkit linux_shell/main.c linux_shell/gtk_chrome.c linux_shell/gtk_icons.c linux_shell/gtk_menu.c \
      $(pkg-config --libs gtk+-3.0 webkit2gtk-4.1) -pie -Wl,-z,relro,-z,now
    make -C linux_shell CC=${clang}/bin/clang orb-sidebar-host.so
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p "$out/bin" "$out/share/applications" "$out/share/orb-desktop"
    makeBinaryWrapper "${core}/bin/orb-desktop-native" "$out/bin/orb-desktop-native" \
      --set ORB_ACCOUNT_LAUNCHER "$out/bin/orb-desktop" \
      --prefix PATH : "${lib.makeBinPath [python3 pulseaudio wl-clipboard zenity]}"
    install -Dm0755 linux_shell/orb-sidebar-host.so "$out/lib/orb-sidebar-host.so"
    makeBinaryWrapper "${core}/bin/orb-desktop-native" "$out/bin/orb-desktop-hybrid" \
      --add-flags "--gtk-sidebar-host" --add-flags "$out/lib/orb-sidebar-host.so" \
      --set ORB_LOCALD_BIN "${core}/bin/orb-locald" --set ORB_UI_ROOT "${webUi}"
    install -m 0755 orb-webkit "$out/bin/.orb-webkit"
    makeBinaryWrapper "$out/bin/.orb-webkit" "$out/bin/orb-webkit" \
      --set ORB_LOCALD_BIN "${core}/bin/orb-locald" --set ORB_UI_ROOT "${webUi}"
    install -m 0644 "$src/nix/orb-desktop.hyprland.conf" "$out/share/orb-desktop/hyprland.conf"
    cat > "$out/bin/orb-desktop" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# GTK/WebKit is the default; LeanUI is available as a separate trial launcher.
case "''${1:-}" in
  --leanui) shift; exec "$(dirname "$0")/orb-desktop-native" "$@" ;;
  --leanui-hybrid) shift; exec "$(dirname "$0")/orb-desktop-hybrid" "$@" ;;
  --webkit) shift ;;
esac
exec "$(dirname "$0")/orb-webkit" "$@"
SH
    chmod 0755 "$out/bin/orb-desktop"
    cat > "$out/share/applications/orb-desktop.desktop" <<EOF
[Desktop Entry]
Name=Orb
Comment=Orb desktop client
Exec=$out/bin/orb-desktop
Terminal=false
Type=Application
Categories=Development;Utility;
StartupWMClass=orb-desktop
EOF
    cat > "$out/share/applications/orb-leanui.desktop" <<EOF
[Desktop Entry]
Name=Orb LeanUI
Comment=Native Orb desktop trial
Exec=$out/bin/orb-desktop --leanui
Terminal=false
Type=Application
Categories=Development;Utility;
StartupWMClass=orb-desktop
Actions=About;

[Desktop Action About]
Name=About Orb LeanUI
Exec=${zenity}/bin/zenity --info --title="About Orb LeanUI" --text="Orb LeanUI · ${revision}"
EOF
  '';
  meta = {
    description = "Orb Linux desktop: GTK/WebKit client (experimental LeanUI: --leanui)";
    mainProgram = "orb-desktop";
    platforms = lib.platforms.linux;
  };
}
