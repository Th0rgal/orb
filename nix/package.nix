# Core: the sandboxed-sh API server and the companion binaries it launches
# beside itself (sandboxed-mcp, workspace-mcp, desktop-mcp, sandboxed-node,
# palomactl, orb-locald, ...). Core finds companions next to its own executable,
# so they must stay in one bin/ directory.
#
# Core and all companion binaries are compiled directly from the repository's
# Pure Lean 4 packages (`lean/OrbBin`, `lean/OrbNode`, `lean/OrbCore`,
# `lean/OrbLocald`) with the pinned Lean 4 v4.35.0 toolchain (`lean/lean-toolchain`)
# via `turbo-lean` + `clang`/`lld` and linked against OpenSSL (`libssl`, `libcrypto`)
# and SQLite (`libsqlite3`).
#
# Programs Core spawns at runtime (git, python3, bash, the harness CLIs) are
# looked up on PATH; the service that runs Core provides them.
{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  autoPatchelfHook,
  binutils,
  callPackage,
  cctools,
  clang,
  git,
  gnutar,
  lld,
  openssl,
  patchelf,
  python3,
  sqlite,
  zstd,
  turbo-lean ? null,
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

  resolvedTurboLean =
    if turbo-lean != null
    then turbo-lean
    else callPackage ./turbo-lean.nix {inherit leanToolchain;};

  # The Lean build is split into one derivation per Lake package layer, so Nix
  # caches each layer and a change rebuilds only the packages that depend on it:
  #
  #   orb-lean-base   lean-sys, orb-spec (lean/Orb), LeanMesh, OrbNetLeaf, OrbBin
  #   orb-lean-node   OrbNode   (sandboxed-node)
  #   orb-lean-core   OrbCore   (orb-core)
  #   orb-lean-locald OrbLocald (orb-locald)
  #   orb-core        assembles every layer's binaries (no compilation)
  #
  # Each later layer copies the earlier layer's `.lake` build trees into place, so
  # Lake reuses them instead of rebuilding. Every source set below holds only the
  # files that layer compiles, so editing one package leaves the others cached.
  baseLeanFiles = with lib.fileset; [
    ../lean/lakefile.lean
    ../lean/lean-toolchain
    ../lean/turbo-lean.toml
    ../lean/Orb
    ../lean/LeanMesh
    ../lean/OrbNetLeaf
    ../lean/OrbBin
    ../scripts/build_orb_bins.sh
  ];

  leanSource = extra:
    lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions (baseLeanFiles ++ extra);
    };

  buildEnv = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export PATH="${clang}/bin:${lld}/bin:${binutils}/bin:${leanToolchain}/bin:$PATH"
    export LEAN_BIN_DIR="${leanToolchain}/bin"
    export CC="${clang}/bin/clang"
    export LEAN_CC="${clang}/bin/clang"
    export TURBO_LEAN_BIN="${leanToolchain}/bin/lean"
    export TURBO_LEAN_HOME="$TMPDIR/turbo-lean-state"
    export TURBO_LEAN_STATE_DIR="$TMPDIR/turbo-lean-state"
    export TURBO_LEAN_EMIT_C=1
    export TURBO_LEAN_NO_DAEMON=1
    export TURBO_LEAN_TELEMETRY=off
    export CPATH="${lib.makeSearchPathOutput "dev" "include" [openssl sqlite]}''${CPATH:+:$CPATH}"
    export LIBRARY_PATH="${leanToolchain}/lib:${lib.makeLibraryPath [openssl sqlite]}''${LIBRARY_PATH:+:$LIBRARY_PATH}"

    # Stage pinned `lean-sys` as a sibling path package so `turbo-lean` and Lake 4.35
    # build strictly offline inside the Nix sandbox without `.git` network fetches.
    cp -R "${pinnedLeanSys}" lean/lean-sys
    chmod -R u+w lean/lean-sys
    python3 - <<'PY'
    import glob, json, pathlib, re

    lf = pathlib.Path("lean/OrbNetLeaf/lakefile.lean")
    lf.write_text(
        re.sub(
            r'require\s+«lean-sys»\s+from\s+git\s+"[^"]+"\s*@\s*"[^"]+"',
            'require «lean-sys» from "../lean-sys"',
            lf.read_text(),
        )
    )

    for path in glob.glob("lean/*/lake-manifest.json"):
        p = pathlib.Path(path)
        data = json.loads(p.read_text())
        new_pkgs = []
        for entry in data.get("packages", []):
            if entry.get("name") in ("«lean-sys»", "lean-sys"):
                new_pkgs.append({
                    "type": "path",
                    "scope": entry.get("scope", ""),
                    "name": entry["name"],
                    "manifestFile": entry.get("manifestFile", "lake-manifest.json"),
                    "inherited": entry.get("inherited", False),
                    "dir": "../lean-sys",
                    "copy": False,
                    "configFile": entry.get("configFile", "lakefile.lean"),
                })
            else:
                new_pkgs.append(entry)
        data["packages"] = new_pkgs
        p.write_text(json.dumps(data, indent=1) + "\n")
    PY
    patchShebangs scripts/build_orb_bins.sh
  '';

  commonAttrs = {
    inherit (orbPackageJson) version;

    nativeBuildInputs =
      [
        leanToolchain
        resolvedTurboLean
        clang
        lld
        binutils
        git
        python3
        zstd
      ]
      ++ lib.optionals stdenv.hostPlatform.isLinux [patchelf]
      ++ lib.optionals stdenv.hostPlatform.isDarwin [cctools];

    buildInputs = [
      openssl
      sqlite
    ];

    # OrbCore loads libsqlite3 and libcrypto via dlopen() (`orb_core_sqlite.c`),
    # so expose their runtime library paths to `nix develop` (`inputsFrom`) and
    # bake them into DT_RUNPATH during `installPhase` on Linux.
    LD_LIBRARY_PATH = lib.makeLibraryPath [openssl sqlite];

    # Each layer builds in a fresh sandbox, so turbo-lean's module cache always
    # starts empty there and its extra kernel audits only add time (OrbCore:
    # 7m22s with turbo-lean vs 4m45s with Lake on DGX Spark). Nix caches the
    # layers instead; turbo-lean stays the default for warm local and CI builds.
    ORB_SKIP_TURBO_LEAN = "1";

    dontConfigure = true;

    # The test suite runs in CI (`scripts/build_orb_bins.sh --with-tests`);
    # several integration tests expect loopback sockets, git, and runtime tools
    # outside the pure build sandbox.
    doCheck = false;
  };

  # Builds `bins` (names understood by `build_orb_bins.sh --only`) on top of
  # `deps`, and outputs the binaries plus this layer's `.lake` build trees.
  mkLeanLayer = {
    pname,
    src,
    bins,
    deps ? [],
    keepLake ? false,
  }:
    stdenv.mkDerivation (commonAttrs
      // {
        inherit pname src;
        buildPhase = ''
          runHook preBuild
          ${buildEnv}
          ${restoreLake deps}
          mkdir -p "$TMPDIR/orb-bins"
          ./scripts/build_orb_bins.sh --out-dir "$TMPDIR/orb-bins" ${lib.concatMapStringsSep " " (b: "--only ${b}") bins}
          ${lib.optionalString keepLake ''
            # Later layers import shared modules (e.g. Orb.Spec) that this
            # layer's own binaries do not, so build the whole shared libraries
            # here; otherwise Node, Core and Locald each recompile them.
            (cd lean && SANDBOXED_ALLOW_RAW_LAKE=1 lake build Orb -- -DwarningAsError=true)
            (cd lean/OrbBin && SANDBOXED_ALLOW_RAW_LAKE=1 lake build OrbBin -- -DwarningAsError=true)
          ''}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p "$out/bin"
          cp -P "$TMPDIR/orb-bins"/* "$out/bin/"
          ${lib.optionalString keepLake ''
            mkdir -p "$out/lake"
            (cd lean && find . -name .lake -type d -prune -exec cp -a --parents {} "$out/lake/" \;)
          ''}
          runHook postInstall
        '';
        dontFixup = true;
      });

  restoreLake = deps:
    lib.concatMapStrings (dep: ''
      cp -a --no-preserve=ownership "${dep}/lake/." lean/
      chmod -R u+w lean
    '')
    deps;

  orbBinBins = [
    "fido-agent-proxy"
    "orb-privd"
    "orb-sudo"
    "lean-mesh"
    "palomactl"
    "sandboxed-mcp"
    "workspace-mcp"
    "desktop-mcp"
    "automation-manager-mcp"
  ];

  leanBase = mkLeanLayer {
    pname = "orb-lean-base";
    src = leanSource [];
    bins = orbBinBins;
    keepLake = true;
  };

  leanNode = mkLeanLayer {
    pname = "orb-lean-node";
    src = leanSource [../lean/OrbNode];
    bins = ["sandboxed-node"];
    deps = [leanBase];
  };

  leanCore = mkLeanLayer {
    pname = "orb-lean-core";
    src = leanSource [../lean/OrbCore];
    bins = ["orb-core"];
    deps = [leanBase];
  };

  leanLocald = mkLeanLayer {
    pname = "orb-lean-locald";
    src = leanSource [../lean/OrbLocald];
    bins = ["orb-locald"];
    deps = [leanBase];
  };

  layers = [leanBase leanNode leanCore leanLocald];
in
  # Node, Core and Locald build in parallel on top of the base layer; this
  # derivation only gathers their binaries and fixes their runtime paths.
  stdenv.mkDerivation {
      pname = "orb-core";
      inherit (orbPackageJson) version;
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;
      nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [patchelf];
      inherit (commonAttrs) buildInputs LD_LIBRARY_PATH;

      installPhase = ''
        runHook preInstall

        mkdir -p "$out/bin"
        for f in ${lib.concatMapStringsSep " " (l: "${l}/bin/*") layers}; do
          if [ -L "$f" ]; then
            cp -P "$f" "$out/bin/$(basename "$f")"
          else
            install -m 0755 "$f" "$out/bin/"
          fi
        done

        runHook postInstall
      '';

      # `libsqlite3` and `libcrypto` are loaded with dlopen(), not DT_NEEDED, so the
      # fixup phase's `patchelf --shrink-rpath` removes them from DT_RUNPATH when they
      # are added during install: `orb-locald` then fails every `sqlite3_open`
      # ("sqlite_open_failed", drafts and UI cache unavailable). Add them after fixup.
      postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
        for f in "$out/bin"/*; do
          if [ ! -L "$f" ] && [ -f "$f" ]; then
            patchelf --add-rpath "${lib.makeLibraryPath [openssl sqlite]}" "$f"
          fi
        done
      '';

      # Fail the build if a binary cannot resolve the libraries it dlopen()s.
      doInstallCheck = stdenv.hostPlatform.isLinux;
      installCheckPhase = ''
        for b in orb-locald orb-core; do
          if [ -f "$out/bin/$b" ]; then
            patchelf --print-rpath "$out/bin/$b" | grep -q "${lib.getLib sqlite}/lib" \
              || { echo "$b: sqlite missing from DT_RUNPATH" >&2; exit 1; }
          fi
        done
      '';

      passthru = {inherit leanBase leanNode leanCore leanLocald;};

      meta = {
        description = "Self-hosted orchestrator for AI coding agents";
        homepage = "https://orb.thomas.md";
        mainProgram = "orb-core";
        platforms = lib.platforms.linux ++ lib.platforms.darwin;
      };
    }
