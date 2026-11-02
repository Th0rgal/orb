# Orb Core (the sandboxed-sh backend and its companion binaries) for Nix.
#
#   nix build .#sandboxed-sh        # or just `nix build`
#   nix develop                     # cargo, clippy and rustfmt for the backend
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
        packages = [pkgs.clippy pkgs.rustfmt];
      };
    });
  };
}
