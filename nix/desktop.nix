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
    mkdir -p "$out/bin"
    install -m 0755 "${core}/bin/orb-desktop-native" "$out/bin/orb-desktop-native"
    install -m 0755 orb-webkit "$out/bin/orb-webkit"
    cat > "$out/bin/orb-desktop" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "''${1:-}" == "--webkit" ]]; then
  shift
  exec "$(dirname "$0")/orb-webkit" "$@"
fi
exec "$(dirname "$0")/orb-desktop-native" "$@"
SH
    chmod 0755 "$out/bin/orb-desktop"
  '';
  meta = {
    description = "Orb LeanUI Linux desktop (WebKit fallback: --webkit)";
    mainProgram = "orb-desktop";
    platforms = lib.platforms.linux;
  };
}
