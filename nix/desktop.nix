{lib, stdenv, callPackage, clang, pkg-config, gtk3, webkitgtk_4_1, turbo-lean ? null}:

let
  core = callPackage ./package.nix {inherit turbo-lean; buildDesktop = true;};
in
stdenv.mkDerivation {
  pname = "orb-desktop";
  version = core.version;
  src = ../.;
  dontConfigure = true;
  nativeBuildInputs = [clang pkg-config];
  buildInputs = [gtk3 webkitgtk_4_1];
  buildPhase = ''
    runHook preBuild
    ${clang}/bin/clang -std=gnu11 -O2 -Wall -Wextra -Werror -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIE \
      -DORB_HAS_WEBKITGTK $(pkg-config --cflags gtk+-3.0 webkit2gtk-4.1) \
      -o orb-webkit linux_shell/main.c linux_shell/gtk_chrome.c linux_shell/gtk_icons.c linux_shell/gtk_menu.c \
      $(pkg-config --libs gtk+-3.0 webkit2gtk-4.1) -pie -Wl,-z,relro,-z,now
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p "$out/bin" "$out/share/applications" "$out/share/orb-desktop"
    install -m 0755 "${core}/bin/orb-desktop-native" "$out/bin/orb-desktop-native"
    install -m 0755 orb-webkit "$out/bin/orb-webkit"
    install -m 0644 "$src/nix/orb-desktop.hyprland.conf" "$out/share/orb-desktop/hyprland.conf"
    cat > "$out/bin/orb-desktop" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# GTK/WebKit is the default; LeanUI is experimental (renders the parity screens only).
if [[ "''${1:-}" == "--leanui" ]]; then
  shift
  exec "$(dirname "$0")/orb-desktop-native" "$@"
fi
[[ "''${1:-}" == "--webkit" ]] && shift
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
  '';
  meta = {
    description = "Orb Linux desktop: GTK/WebKit client (experimental LeanUI: --leanui)";
    mainProgram = "orb-desktop";
    platforms = lib.platforms.linux;
  };
}
