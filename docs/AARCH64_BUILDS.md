# aarch64 Linux Orb binaries (dgx-spark)

`scripts/build_orb_bins.sh --target-arch aarch64` builds **natively on an
aarch64 host**. `ORB_TARGET_ARCH=aarch64` is equivalent; a CLI flag takes
precedence. The default is `native`. Accepted aliases are `arm64` for
`aarch64` and `amd64` for `x86_64`. Invalid values and cross-architecture
requests fail before downloads, compilation or staging. This is an architecture
selector, not an OS selector: run on Linux for Linux output.

The supported toolchain is native Lean 4.35.0 plus native C tools and OpenSSL
headers/libraries. A cross C compiler alone cannot cross-build Lean's runtime,
package shims and cached objects. No cross mode is implemented. Do not override
`LEAN_CC` with a foreign compiler or copy `.lake` caches from another architecture.
On Linux the script also checks ELF64 little-endian machine type before staging
each binary, rejecting foreign or non-ELF artifacts, including stale cache output.
This check does not certify runtime library compatibility; build on the deployment
OS or a compatible older distribution. Ubuntu binaries need Nix packaging for NixOS.

## Build on dgx-spark

Use your existing operator access (`ssh spark`); this worker needs no credentials
or access to that host. On spark, in a dedicated checkout containing this change:

```bash
uname -s -m                         # Linux aarch64
free -g
pgrep -lx 'lean|lake|turbo-lean'     # wait if another heavy build is active
cd ~/work/orb
sudo apt-get update
sudo apt-get install -y build-essential clang libssl-dev libsqlite3-0 \
  python3 curl git zstd binutils file
export LEAN_CC=/usr/bin/clang
export ORB_TURBO_LEAN_JOBS=2 ORB_TURBO_LEAN_MAX_MB=6144
scripts/build_orb_bins.sh --target-arch aarch64 --ensure-lean --no-telemetry \
  --only sandboxed-mcp --only orb-privd --only orb-sudo \
  --out-dir "$PWD/target/aarch64-linux"
file target/aarch64-linux/{sandboxed-mcp,orb-privd,orb-sudo}
ldd target/aarch64-linux/orb-privd
```

Expect `ELF 64-bit LSB ... ARM aarch64` for all three and no `not found` in
`ldd`. Keep that output as deployment evidence. `--ensure-lean` downloads the
SHA-256-checked Linux aarch64 v4.35.0 release if `lake` is absent. If `lake`
is already on PATH (including elan shims), ensure its pinned v4.35.0 toolchain
is installed and usable first. It does not replace an existing `lake`.

If installed, turbo-lean is preferred with telemetry disabled and the above
memory/job bounds. Otherwise the script uses raw Lake; budget memory accordingly
and keep one heavy build at a time. For a systemd-managed user session, a hard
cap can be applied by prefixing the build command with
`systemd-run --user --scope -p MemoryMax=8G --`.

Omit all `--only` options to build the default Orb set, including `sandboxed-node`,
`orb-core`, `orb-locald` and the MCP tools. Repeat `--only` to select binaries;
repeat `--out-dir` to stage to multiple locations. Without `--out-dir`, existing
`target/debug` and `target/release` defaults (or `CARGO_TARGET_DIR`) remain.
`--with-tests` builds and **runs** the existing native test suites on spark.
`--no-telemetry` is accepted explicitly; turbo-lean telemetry is always disabled.
The optional `orb-desktop-native` target additionally needs its GTK/WebKit
system development libraries and turbo-lean, as before.

## First-time Lean orb-privd installation on spark

These are operator commands, after verifying the output above. First-time
installation needs an existing root shell or ordinary sudo; a broker that is
not installed yet cannot authorize its own installation. Do not install the
Python confinement model as the daemon. The checked-in service still names a
Python interpreter, so install a systemd override for the native executable:

```bash
cd ~/work/orb
getent group sandboxed-node || sudo groupadd --system sandboxed-node
sudo install -o root -g root -m 0755 target/aarch64-linux/orb-privd /usr/local/sbin/orb-privd
sudo install -o root -g root -m 0755 target/aarch64-linux/orb-sudo /usr/local/bin/orb-sudo
sudo install -o root -g root -m 0755 target/aarch64-linux/sandboxed-mcp /usr/local/bin/sandboxed-mcp
sudo install -d -o root -g root -m 0755 /etc/systemd/system/orb-privd.service.d
sudo install -o root -g root -m 0644 deploy/systemd/orb-privd.service /etc/systemd/system/orb-privd.service
sudo tee /etc/systemd/system/orb-privd.service.d/native.conf >/dev/null <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/local/sbin/orb-privd
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now orb-privd.service
sudo systemctl status --no-pager orb-privd.service
sudo journalctl -u orb-privd.service -n 30 --no-pager
sudo stat -c '%a %U:%G %n' /run/orb-privd.sock
```

Expect `active (running)`, `orb-privd listening on /run/orb-privd.sock` and
`660 root:sandboxed-node`. The unit reads the existing root-managed node
environment files; provision normal node enrollment/configuration through the
operator process before expecting approved remote actions to succeed. Never
copy an administrator credential to a worker. This build procedure neither
reads nor provisions tokens. Only the authorized node service identity should
belong to the socket group; do not grant it to arbitrary users. Existing
installations should back up their unit/binary, retain their environment, and
use `systemctl restart orb-privd` after installing the native override and binary.

## Credential-free worker evidence (2026-11-14)

The inspected VM is Linux x86_64. `/usr/bin/clang` is Ubuntu clang 18.1.3;
`/usr/bin/gcc` and LLD 18 are present. `aarch64-linux-gnu-gcc`, Zig,
`qemu-aarch64` and `qemu-aarch64-static` are absent from PATH; no
`/usr/aarch64-linux-gnu` sysroot was present. The link probe:

```bash
printf 'int main(void){return 0;}\n' | \
  clang --target=aarch64-linux-gnu -fuse-ld=lld -x c - -o /tmp/orb-aarch64-probe
```

failed with missing `Scrt1.o`, `crti.o`, `crtbeginS.o`, `-lgcc`, `-lgcc_s`,
`-lc`, `crtendS.o`, `crtn.o`. Thus there is no usable aarch64 cross toolchain
on this image. No aarch64 Orb binary was produced and there is no real aarch64
`file` output to report. Native spark execution remains an operator validation.

```bash
scripts/build_orb_bins.sh --target-arch aarch64 --only sandboxed-mcp --only orb-privd
# exit 2: error: cannot build aarch64 on x86_64: cross compilation is unsupported; ...
python3 -m unittest -v scripts/test_build_orb_bins.py
# Ran 13 tests ... OK (isolated fixtures, not a real Lean compilation)
bash -n scripts/build_orb_bins.sh
```
