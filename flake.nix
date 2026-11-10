# Orb Core (the sandboxed-sh backend and its companion binaries) for Nix.
#
#   nix build .#sandboxed-sh        # or just `nix build`
#   nix develop                     # Lean 4, OpenSSL, SQLite and native build inputs
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
    overlays.default = final: _prev: {
      sandboxed-sh = final.callPackage ./nix/package.nix {};
    };

    packages = forAllSystems (pkgs: rec {
      sandboxed-sh = pkgs.callPackage ./nix/package.nix {};
      default = sandboxed-sh;
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        inputsFrom = [self.packages.${pkgs.stdenv.hostPlatform.system}.sandboxed-sh];
        LEAN_CC = "cc";
        npm_config_manage_package_manager_versions = "false";
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
          pkgs.openssl
          pkgs.sqlite
        ];
        packages =
          [
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
        shellHook = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
          export XDG_DATA_DIRS="${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
          export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules:${pkgs.dconf.lib}/lib/gio/modules''${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"
        '';
      };
    });
  };
}
