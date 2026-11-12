# Orb Core (the sandboxed-sh backend and its companion binaries) for Nix.
#
#   nix build .#sandboxed-sh        # or just `nix build`
#   nix develop                     # Lean 4, turbo-lean, OpenSSL, SQLite and native build inputs
#
# A NixOS or home-manager configuration takes the package from
# `packages.<system>.default` or through `overlays.default` (pkgs.sandboxed-sh)
# and runs bin/sandboxed-sh as a service; see nix/package.nix for what that
# service must put on PATH.
{
  description = "Orb Core: self-hosted orchestrator for AI coding agents";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    # nixpkgs 26.11 dropped x86_64-darwin.
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    overlays.default = final: prev: rec {
      turbo-lean = prev.turbo-lean or (final.callPackage ./nix/turbo-lean.nix {});
      orb-core = final.callPackage ./nix/package.nix {inherit turbo-lean;};
      sandboxed-sh = orb-core;
    };

    packages = forAllSystems (pkgs: rec {
      turbo-lean = pkgs.callPackage ./nix/turbo-lean.nix {};
      orb-core = pkgs.callPackage ./nix/package.nix {inherit turbo-lean;};
      sandboxed-sh = orb-core;
      default = orb-core;
    });

    devShells = forAllSystems (pkgs: let
      useTurboLeanShims = pkgs.runCommand "orb-use-turbo-lean-shims" {} ''
        mkdir -p "$out/bin"
        for cmd in lake leanc; do
          {
            echo "#!${pkgs.runtimeShell}"
            cat <<'SHIM'
set -u
cmd="$(basename "$0")"
self_real="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

find_next_bin() {
  for cand in "''${LEAN_BIN_DIR:-}/$cmd" "''${ELAN_HOME:-}/bin/$cmd" "''${HOME:-}/.elan/bin/$cmd"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    cand_real="$(readlink -f "$cand" 2>/dev/null || printf '%s' "$cand")"
    [ "$cand_real" = "$self_real" ] && continue
    printf '%s\n' "$cand"
    return 0
  done
  old_ifs=$IFS; IFS=:
  for dir in ''${PATH:-}; do
    [ -n "$dir" ] || continue
    cand="$dir/$cmd"
    [ -x "$cand" ] || continue
    cand_real="$(readlink -f "$cand" 2>/dev/null || printf '%s' "$cand")"
    [ "$cand_real" = "$self_real" ] && continue
    IFS=$old_ifs
    printf '%s\n' "$cand"
    return 0
  done
  IFS=$old_ifs
  return 1
}

if [ "''${SANDBOXED_ALLOW_RAW_LAKE:-0}" = "1" ] || [ "''${SANDBOXED_REMOTE_EXECUTION:-0}" = "1" ]; then
  if real_bin="$(find_next_bin)"; then
    exec "$real_bin" "$@"
  fi
  echo "error: SANDBOXED_ALLOW_RAW_LAKE=1 was set, but no underlying '$cmd' binary was found on PATH." >&2
  exit 127
fi

cat >&2 <<EOF
warning: '$cmd''${1:+ $1}' is disabled by default in this devShell — use 'turbo-lean' instead (shared CAS + native clang codegen without multi-GiB .lake duplication):
  - Orb binaries:      ./scripts/build_orb_bins.sh --only <bin>
  - build targets:     turbo-lean build --project-dir <dir> [targets...]
  - check single file: turbo-lean check <path/to/File.lean> [--decl <Full.DeclName>]
  - audit formal spec: turbo-lean audit-spec <path/to/Spec.lean>
(Set SANDBOXED_ALLOW_RAW_LAKE=1 only if raw Lake is strictly required, e.g. 'lake update'.)
EOF
exit 1
SHIM
          } > "$out/bin/$cmd"
          chmod 0755 "$out/bin/$cmd"
        done

        {
          echo "#!${pkgs.runtimeShell}"
          cat <<'SHIM'
set -u
self_real="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

if [ "''${SANDBOXED_ALLOW_RAW_ELAN:-0}" = "1" ]; then
  old_ifs=$IFS; IFS=:
  for dir in ''${PATH:-}; do
    [ -n "$dir" ] && [ -x "$dir/elan" ] || continue
    cand_real="$(readlink -f "$dir/elan" 2>/dev/null || printf '%s' "$dir/elan")"
    [ "$cand_real" = "$self_real" ] && continue
    IFS=$old_ifs
    exec "$dir/elan" "$@"
  done
  IFS=$old_ifs
  echo "error: SANDBOXED_ALLOW_RAW_ELAN=1 was set, but no underlying 'elan' binary was found on PATH." >&2
  exit 127
fi

cat >&2 <<EOF
warning: 'elan''${1:+ $1}' is disabled in this devShell — Lean toolchains are managed declaratively via Nix and 'turbo-lean':
  - Orb binaries:      ./scripts/build_orb_bins.sh --only <bin>
  - build targets:     turbo-lean build --project-dir <dir> [targets...]
  - check single file: turbo-lean check <path/to/File.lean> [--decl <Full.DeclName>]
  - audit formal spec: turbo-lean audit-spec <path/to/Spec.lean>
(Set SANDBOXED_ALLOW_RAW_ELAN=1 only if raw elan is strictly required.)
EOF
exit 1
SHIM
        } > "$out/bin/elan"
        chmod 0755 "$out/bin/elan"
      '';
    in {
      default = pkgs.mkShell {
        inputsFrom = [self.packages.${pkgs.stdenv.hostPlatform.system}.orb-core];
        CC = "${pkgs.clang}/bin/clang";
        LEAN_CC = "${pkgs.clang}/bin/clang";
        TURBO_LEAN_EMIT_C = "1";
        npm_config_manage_package_manager_versions = "false";
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
          pkgs.openssl
          pkgs.sqlite
        ];
        packages =
          [
            self.packages.${pkgs.stdenv.hostPlatform.system}.turbo-lean
            pkgs.clang
            pkgs.lld
            pkgs.curl
            pkgs.nodejs
            pkgs.openssl
            pkgs.pkg-config
            pkgs.pnpm_10
            pkgs.python3
          ]
          ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.dconf
            pkgs.glib-networking
            pkgs.gsettings-desktop-schemas
            pkgs.gtk3
            pkgs.webkitgtk_4_1
          ];
        shellHook =
          ''
            export PATH="${useTurboLeanShims}/bin:${pkgs.clang}/bin:${pkgs.lld}/bin:$PATH"
            export CC="${pkgs.clang}/bin/clang"
            export LEAN_CC="${pkgs.clang}/bin/clang"
          ''
          + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            export XDG_DATA_DIRS="${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
            if [ -d /run/opengl-driver/share ]; then
              export XDG_DATA_DIRS="/run/opengl-driver/share:$XDG_DATA_DIRS"
            fi
            if [ -d /run/opengl-driver/lib ]; then
              export LD_LIBRARY_PATH="/run/opengl-driver/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            fi
            if [ -d /run/opengl-driver/lib/dri ]; then
              export LIBGL_DRIVERS_PATH="/run/opengl-driver/lib/dri"
            fi
            if [ -d /run/opengl-driver/lib/gbm ]; then
              export GBM_BACKENDS_PATH="/run/opengl-driver/lib/gbm"
            fi
            if [ -d /run/opengl-driver/share/glvnd/egl_vendor.d ]; then
              export __EGL_VENDOR_LIBRARY_DIRS="/run/opengl-driver/share/glvnd/egl_vendor.d"
            fi
            export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules:${pkgs.dconf.lib}/lib/gio/modules''${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"
          '';
      };
    });
  };
}
