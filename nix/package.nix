# Core: the sandboxed-sh API server and the companion binaries it launches
# beside itself (sandboxed-mcp, workspace-mcp, desktop-mcp, sandboxed-node,
# palomactl, ...). Core finds companions next to its own executable, so they
# must stay in one bin/ directory.
#
# Nothing here needs Lean: the kernel ships as the generated C translation
# unit shared/orb-spec/cabi/orb_kernel_unboxed.c, which crates/orb-spec/build.rs
# compiles with the stdenv C compiler. SQLite is bundled and TLS is rustls, so
# there are no native library inputs either.
#
# Programs Core spawns at runtime (git, python3, bash, the harness CLIs) are
# looked up on PATH; the service that runs Core provides them.
{
  lib,
  rustPlatform,
  stdenv,
  cctools,
}: let
  cargo = lib.importTOML ../Cargo.toml;
in
  rustPlatform.buildRustPackage {
    pname = "sandboxed-sh";
    inherit (cargo.package) version;

    # crates/orb-spec/build.rs and crates/lean-mesh/build.rs invoke bare `nm`
    # and `ar` to verify the C-ABI symbol tables.
    nativeBuildInputs = lib.optionals stdenv.hostPlatform.isDarwin [cctools];

    # The same tree the Dockerfile's Rust stage copies: build.rs reads
    # catalog/, and the sources include shared/*.rs and some scripts/ via
    # #[path] and include_str!.
    src = lib.fileset.toSource {
      root = ../.;
      fileset = lib.fileset.unions [
        ../Cargo.toml
        ../Cargo.lock
        ../build.rs
        ../crates
        ../lean
        ../src
        ../shared
        ../catalog
        ../scripts
      ];
    };

    cargoLock.lockFile = ../Cargo.lock;

    # buildRustPackage builds in release mode, as the Dockerfile does. The
    # upstream deploy scripts use debug builds only to keep their rebuild loop
    # short.

    # The test suite runs in CI (`cargo test --locked --workspace`); several
    # tests expect git, a writable HOME and other things the build sandbox
    # does not have.
    doCheck = false;

    meta = {
      description = cargo.package.description;
      homepage = "https://orb.thomas.md";
      mainProgram = "sandboxed-sh";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  }
