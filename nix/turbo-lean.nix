{
  lib,
  stdenv,
  rustPlatform,
  fetchurl,
  fetchFromGitHub,
  autoPatchelfHook,
  binutils,
  bubblewrap,
  clang,
  coreutils,
  git,
  gnutar,
  lld,
  makeWrapper,
  procps,
  zstd,
  turboLeanSrc ? fetchFromGitHub {
    owner = "Th0rgal";
    repo = "turbo-lean";
    rev = "f240450af444a302a0e02d5a5f8af00351089386";
    hash = "sha256-Ovtl0aJsBASBuEk2eZjEF/uVfsDgOW+B3p7XI6DPWs0=";
  },
  leanToolchain ? null,
}:
let
  version = "0.1.0-${builtins.substring 0 7 (turboLeanSrc.rev or "82a9406")}";
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
    }.${stdenv.hostPlatform.system}
      or (throw "Unsupported system for Lean ${leanVersion}: ${stdenv.hostPlatform.system}");

  resolvedLeanToolchain =
    if leanToolchain != null then
      leanToolchain
    else
      stdenv.mkDerivation {
        pname = "lean4-bin";
        version = leanVersion;
        src = fetchurl {
          url = "https://github.com/leanprover/lean4/releases/download/v${leanVersion}/${leanArchiveSpec.artifact}";
          inherit (leanArchiveSpec) sha256;
        };
        nativeBuildInputs =
          [
            gnutar
            zstd
          ]
          ++ lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
        buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];
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

  leanManifest = lib.importJSON "${turboLeanSrc}/lean/lake-manifest.json";
  leanSysPkg = lib.findFirst (
    p: p.name == "«lean-sys»" || p.name == "lean-sys"
  ) (throw "lean-sys entry missing from turbo-lean lean/lake-manifest.json") leanManifest.packages;

  pinnedLeanSys = fetchFromGitHub {
    owner = "Th0rgal";
    repo = "lean-sys";
    inherit (leanSysPkg) rev;
    hash = "sha256-ZR9yVxTaImW0z7NzlRPrNLlNiOZF77u6q76A7CBka70=";
  };

  nixSysBins =
    [
      coreutils
      binutils
      clang
      lld
      procps
      zstd
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ bubblewrap ];

  runtimeToolPath = lib.makeBinPath (
    [
      resolvedLeanToolchain
      git
    ]
    ++ nixSysBins
  );

  turboLeanRust = rustPlatform.buildRustPackage {
    pname = "turbo-lean-unwrapped";
    inherit version;
    src = turboLeanSrc;

    cargoLock = {
      lockFile = "${turboLeanSrc}/Cargo.lock";
    };

    cargoBuildFlags = [
      "-p"
      "turbo-lean"
    ];

    nativeBuildInputs = [
      resolvedLeanToolchain
      clang
      lld
      binutils
      git
      zstd
    ];

    env = {
      CC = "${clang}/bin/clang";
      HOST_CC = "${clang}/bin/clang";
      CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "2";
      TURBO_LEAN_NIX_SYS_PATH = lib.makeBinPath nixSysBins;
      TURBO_LEAN_NIX_DEFAULT_LEAN = "${resolvedLeanToolchain}/bin/lean";
      TURBO_LEAN_NIX_DEFAULT_CC = "${clang}/bin/clang";
      TURBO_LEAN_NIX_DEFAULT_GIT = "${git}/bin/git";
      TURBO_LEAN_NIX_BWRAP = lib.optionalString stdenv.hostPlatform.isLinux "${bubblewrap}/bin/bwrap";
    };

    doCheck = false;

    postPatch = ''
      chmod -R u+w crates lean

      awk '
        /^require «lean-sys» from git/ {
          print "require «lean-sys» from \".lake/packages/lean-sys\""
          getline
          next
        }
        { print }
      ' lean/lakefile.lean > lean/lakefile.lean.offline
      mv lean/lakefile.lean.offline lean/lakefile.lean

      cat > lean/lake-manifest.json <<'EOF'
      {"version": "1.3.0",
       "packagesDir": ".lake/packages",
       "packages":
       [{"type": "path",
         "scope": "",
         "name": "«lean-sys»",
         "manifestFile": "lake-manifest.json",
         "inherited": false,
         "dir": ".lake/packages/lean-sys",
         "configFile": "lakefile.lean"}],
       "name": "«turbo-lean-proofs»",
       "lakeDir": ".lake",
       "fixedToolchain": false}
      EOF

      mkdir -p lean/.lake/packages/lean-sys
      cp -R "${pinnedLeanSys}/." lean/.lake/packages/lean-sys/
      chmod -R u+w lean/.lake/packages/lean-sys
    '';

    preBuild = ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      export PATH="${clang}/bin:${lld}/bin:${binutils}/bin:${resolvedLeanToolchain}/bin:$PATH"
      export CC="${clang}/bin/clang"
      export LEAN_CC="${clang}/bin/clang"
      export LEAN_SYSROOT="${resolvedLeanToolchain}"
      export TURBO_LEAN_BIN="${resolvedLeanToolchain}/bin/lean"

      (
        cd lean
        lake build LeanSys LeanNative.Spec
      )
    '';

    postInstall = ''
      mkdir -p "$out/share"
      cp -R lean "$out/share/lean-src"
    '';
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "turbo-lean";
  inherit version;
  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = [
    resolvedLeanToolchain
    clang
    lld
    binutils
    git
    makeWrapper
    zstd
  ];

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    export PATH="${clang}/bin:${lld}/bin:${binutils}/bin:${resolvedLeanToolchain}/bin:$PATH"
    export CC="${clang}/bin/clang"
    export LEAN_CC="${clang}/bin/clang"
    export LEAN_SYSROOT="${resolvedLeanToolchain}"
    export TURBO_LEAN_BIN="${resolvedLeanToolchain}/bin/lean"
    export TURBO_LEAN_HOME="$TMPDIR/turbo-lean-state"
    export TURBO_LEAN_EMIT_C=1
    export TURBO_LEAN_NO_DAEMON=1
    export TURBO_LEAN_TELEMETRY=off
    export RAYON_NUM_THREADS=2

    cp -R "${turboLeanRust}/share/lean-src" ./lean
    chmod -R u+w ./lean

    "${turboLeanRust}/bin/turbo-lean" \
      --cache-dir "$TMPDIR/turbo-lean-state" \
      --no-daemon \
      --no-telemetry \
      --max-memory-mb 6144 \
      build \
      --project-dir lean \
      lean-native \
      lean-native-core \
      turbo-lean-native \
      turbo-zygote

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/share/turbo-lean" "$out/libexec/turbo-lean"
    install -Dm755 "${turboLeanRust}/bin/turbo-lean" "$out/bin/turbo-lean"
    cp -r lean/.lake/build/lib/lean "$out/share/turbo-lean/lib-lean"
    cp -r lean/.lake/packages/lean-sys/.lake/build/lib/lean "$out/share/turbo-lean/lean-sys-lib-lean"

    for exe in lean-native lean-native-core turbo-lean-native turbo-zygote; do
      install -Dm755 "lean/.lake/build/bin/$exe" "$out/libexec/turbo-lean/$exe-unwrapped"
      makeWrapper "$out/libexec/turbo-lean/$exe-unwrapped" "$out/bin/$exe" \
        --set-default LEAN_SYSROOT "${resolvedLeanToolchain}" \
        --set-default LEAN_NATIVE_CLANG_RAW "${clang.cc}/bin/clang" \
        --suffix PATH : "${runtimeToolPath}" \
        --suffix LEAN_PATH : "$out/share/turbo-lean/lib-lean:$out/share/turbo-lean/lean-sys-lib-lean:${resolvedLeanToolchain}/lib/lean" \
        --suffix LD_LIBRARY_PATH : "${resolvedLeanToolchain}/lib/lean:${resolvedLeanToolchain}/lib"
    done

    wrapProgram "$out/bin/turbo-lean" \
      --set-default LEAN_SYSROOT "${resolvedLeanToolchain}" \
      --set-default TURBO_LEAN_BIN "${resolvedLeanToolchain}/bin/lean" \
      --set-default LEAN_CC "${clang}/bin/clang" \
      --set-default TURBO_LEAN_GIT "${git}/bin/git" \
      --suffix PATH : "${runtimeToolPath}"

    export HOME="$TMPDIR/home"
    export TURBO_LEAN_HOME="$TMPDIR/turbo-lean-state"
    "$out/bin/turbo-lean" --version >/dev/null
    "$out/bin/lean-native" --help >/dev/null
    (cd lean && "$out/bin/lean-native" audit-axioms >/dev/null)
    (cd lean && "$out/bin/lean-native" self-test >/dev/null)

    runHook postInstall
  '';

  passthru = {
    unwrapped = turboLeanRust;
    leanToolchain = resolvedLeanToolchain;
    leanLibDir = "${finalAttrs.finalPackage}/share/turbo-lean/lib-lean";
    leanSysLibDir = "${finalAttrs.finalPackage}/share/turbo-lean/lean-sys-lib-lean";
  };

  meta = {
    description = "Incremental Lean 4 module DAG builder, proof cache, and LeanNative LLVM compiler";
    homepage = "https://github.com/Th0rgal/turbo-lean";
    mainProgram = "turbo-lean";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
