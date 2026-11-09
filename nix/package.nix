# Core: the sandboxed-sh API server and the companion binaries it launches
# beside itself (sandboxed-mcp, workspace-mcp, desktop-mcp, sandboxed-node,
# palomactl, orb-locald, ...). Core finds companions next to its own executable,
# so they must stay in one bin/ directory.
#
# Core and all companion binaries are compiled directly from the repository's
# Pure Lean 4 packages (`lean/OrbBin`, `lean/OrbNode`, `lean/OrbCore`,
# `lean/OrbLocald`) with the pinned Lean 4 v4.35.0 toolchain (`lean/lean-toolchain`)
# and linked against OpenSSL (`libssl`, `libcrypto`) and SQLite (`libsqlite3`).
#
# Programs Core spawns at runtime (git, python3, bash, the harness CLIs) are
# looked up on PATH; the service that runs Core provides them.
{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  autoPatchelfHook,
  cctools,
  git,
  gnutar,
  openssl,
  python3,
  sqlite,
  zstd,
}: let
  orbPackageJson = lib.importJSON ../orb/package.json;
  coreLakeManifest = lib.importJSON ../lean/OrbCore/lake-manifest.json;
  leanSysPkg =
    lib.findFirst
    (p: p.name == "«lean-sys»" || p.name == "lean-sys")
    (throw "lean-sys entry missing from lean/OrbCore/lake-manifest.json")
    coreLakeManifest.packages;

  leanVersion = "4.35.0";
  leanArchiveSpec =
    {
      x86_64-linux = {
        artifact = "lean-${leanVersion}-linux.tar.zst";
        sha256 = "7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d";
      };
      aarch64-linux = {
        artifact = "lean-${leanVersion}-linux_aarch64.tar.zst";
        sha256 = "c8f0f8a3920e839718b1343e6781fd80a3e9b1024fbcd7078eb30f54e806b028";
      };
      aarch64-darwin = {
        artifact = "lean-${leanVersion}-darwin_aarch64.tar.zst";
        sha256 = "c0c6f34f35ba1dcc5c4a5fd106fefab9eb5e8469712624dd2c868d51b63177c2";
      };
      x86_64-darwin = {
        artifact = "lean-${leanVersion}-darwin.tar.zst";
        sha256 = "0b43be5c7ecfb36016566a41005ab62bdb04743e6bfd5837e45f796ef4750b4e";
      };
    }.${
      stdenv.hostPlatform.system
    } or (throw "Unsupported system for Lean ${leanVersion}: ${stdenv.hostPlatform.system}");

  leanToolchain = stdenv.mkDerivation {
    pname = "lean4-bin";
    version = leanVersion;
    src = fetchurl {
      url = "https://github.com/leanprover/lean4/releases/download/v${leanVersion}/${leanArchiveSpec.artifact}";
      inherit (leanArchiveSpec) sha256;
    };
    nativeBuildInputs =
      [gnutar zstd]
      ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [stdenv.cc.cc.lib];
    dontConfigure = true;
    dontBuild = true;
    unpackPhase = ''
      runHook preUnpack
      mkdir -p "$out"
      tar --zstd -xf "$src" --strip-components=1 -C "$out"
      runHook postUnpack
    '';
    installPhase = ''
      runHook preInstall
      test -x "$out/bin/lean"
      test -x "$out/bin/lake"
      runHook postInstall
    '';
  };

  pinnedLeanSys = fetchFromGitHub {
    owner = "Th0rgal";
    repo = "lean-sys";
    inherit (leanSysPkg) rev;
    hash = "sha256-TKE6Zhx4mWHFkJJbZEOQLwPQomAAYU5L3fYAiDMGwi8=";
  };
in
  stdenv.mkDerivation {
    pname = "sandboxed-sh";
    inherit (orbPackageJson) version;

    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../lean
        ../shared
        ../catalog
        ../scripts
      ];
    };

    nativeBuildInputs =
      [
        leanToolchain
        git
        python3
        zstd
      ]
      ++ lib.optionals stdenv.hostPlatform.isDarwin [cctools];

    buildInputs = [
      openssl
      sqlite
    ];

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild

      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      export LEAN_BIN_DIR="${leanToolchain}/bin"
      export ORB_SKIP_TURBO_LEAN=1
      export SANDBOXED_ALLOW_RAW_LAKE=1
      export CPATH="${lib.makeSearchPathOutput "dev" "include" [openssl sqlite]}''${CPATH:+:$CPATH}"
      export LIBRARY_PATH="${lib.makeLibraryPath [openssl sqlite]}''${LIBRARY_PATH:+:$LIBRARY_PATH}"

      # Pre-populate the pinned `lean-sys` package in every Lake workspace so
      # `scripts/build_orb_bins.sh` builds strictly offline inside the Nix sandbox.
      for pkg in OrbNetLeaf OrbBin OrbNode OrbCore OrbLocald; do
        if [ -d "lean/$pkg" ]; then
          mkdir -p "lean/$pkg/.lake/packages/lean-sys"
          cp -R "${pinnedLeanSys}/." "lean/$pkg/.lake/packages/lean-sys/"
          chmod -R u+w "lean/$pkg/.lake/packages/lean-sys"
        fi
      done

      patchShebangs scripts/build_orb_bins.sh
      mkdir -p "$TMPDIR/orb-bins"
      ./scripts/build_orb_bins.sh --out-dir "$TMPDIR/orb-bins"

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/bin"
      install -m 0755 "$TMPDIR/orb-bins"/* "$out/bin/"

      runHook postInstall
    '';

    # The test suite runs in CI (`scripts/build_orb_bins.sh --with-tests`);
    # several integration tests expect loopback sockets, git, and runtime tools
    # outside the pure build sandbox.
    doCheck = false;

    meta = {
      description = "Self-hosted orchestrator for AI coding agents";
      homepage = "https://orb.thomas.md";
      mainProgram = "sandboxed-sh";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
