#!/usr/bin/env python3
"""Isolated command-level tests: no Lean downloads or compilations."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("build_orb_bins.sh")


class BuildOrbBinsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts/build_orb_bins.sh")
        shutil.copy2(SCRIPT.with_name("turbo_lean.sh"), self.root / "scripts/turbo_lean.sh")
        for pkg in ("OrbBin", "OrbNode", "OrbCore", "OrbLocald", "OrbClient", "OrbNetLeaf", "OrbDesktop"):
            (self.root / "lean" / pkg).mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.root / "home"),
                    "FIXTURE_ROOT": str(self.root), "MOCK_ARCH": "x86_64",
                    "MOCK_ELF_ARCH": "62", "ORB_SKIP_TURBO_LEAN": "1"}
        self.write("uname", '#!/bin/sh\ncase "$1" in -m) echo "$MOCK_ARCH";; *) echo Linux;; esac\n')
        self.write("nm", "#!/bin/sh\nexit 0\n")
        self.write("lake", '''#!/usr/bin/python3
import os, pathlib, shutil, struct, sys
root = pathlib.Path(os.environ['FIXTURE_ROOT'])
with (root / 'build.log').open('a') as log:
    log.write(str(pathlib.Path.cwd().name) + ' ' + ' '.join(sys.argv[1:]) + '\\n')
for target in sys.argv[2:]:
    if target == '--': break
    name = {'lean-mesh-cli': 'lean-mesh', 'orb-node': 'sandboxed-node'}.get(target, target)
    out = pathlib.Path('.lake/build/bin') / name
    out.parent.mkdir(parents=True, exist_ok=True)
    if os.environ.get('MOCK_REAL_EXE'):
        shutil.copy2('/bin/true', out)
    else:
        data = bytearray(64)
        data[:6] = b'\\x7fELF\\x02\\x01'
        struct.pack_into('<H', data, 18, int(os.environ['MOCK_ELF_ARCH']))
        out.write_bytes(data)
    out.chmod(0o755)
''')

    def write(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def run_build(self, *args, success=True):
        result = subprocess.run(["bash", str(self.root / "scripts/build_orb_bins.sh"), *args],
                                env=self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stderr)
        return result

    def log(self):
        return (self.root / "build.log").read_text()

    def test_default_native_and_only_and_repeated_outputs(self):
        self.run_build('--only', 'sandboxed-mcp', '--only', 'orb-privd',
                       '--out-dir', str(self.root / 'one'), '--out-dir', str(self.root / 'two'))
        for directory in ('one', 'two'):
            self.assertEqual(sorted(p.name for p in (self.root / directory).iterdir()),
                             ['orb-privd', 'sandboxed-mcp'])
        self.assertIn('OrbBin build sandboxed-mcp orb-privd', self.log())

    def test_native_aarch64(self):
        self.env.update(MOCK_ARCH='aarch64', MOCK_ELF_ARCH='183')
        self.run_build('--target-arch', 'aarch64', '--only', 'orb-privd')
        self.assertTrue((self.root / 'target/release/orb-privd').exists())

    def test_environment_and_alias(self):
        self.env.update(MOCK_ARCH='arm64', MOCK_ELF_ARCH='183', ORB_TARGET_ARCH='aarch64')
        self.run_build('--only', 'sandboxed-mcp')

    def test_cli_overrides_environment(self):
        self.env['ORB_TARGET_ARCH'] = 'aarch64'
        self.run_build('--target-arch', 'amd64', '--only', 'orb-privd')

    def test_cross_requests_fail_before_build_or_output(self):
        for host, target in [('x86_64', 'aarch64'), ('aarch64', 'x86_64')]:
            with self.subTest(host=host):
                self.env['MOCK_ARCH'] = host
                result = self.run_build('--target-arch', target, success=False)
                self.assertIn('cross compilation is unsupported', result.stderr)
                self.assertFalse((self.root / 'build.log').exists())
                self.assertFalse((self.root / 'target').exists())

    def test_invalid_and_missing_arch(self):
        for args in [('--target-arch',), ('--target-arch', '--only'),
                     ('--target-arch', 'riscv64'), ('--target-arch', '')]:
            with self.subTest(args=args):
                self.run_build(*args, success=False)
        self.env['ORB_TARGET_ARCH'] = 'bogus'
        self.run_build(success=False)
        self.assertFalse((self.root / 'build.log').exists())

    def test_foreign_cached_artifact_rejected(self):
        self.env['MOCK_ELF_ARCH'] = '183'
        result = self.run_build('--only', 'sandboxed-mcp', success=False)
        self.assertIn('refusing to stage', result.stderr)
        self.assertFalse((self.root / 'target/debug/sandboxed-mcp').exists())

    def test_non_elf_rejected(self):
        self.write('lake', '''#!/bin/sh
mkdir -p .lake/build/bin
printf '#!/bin/sh\\n' > .lake/build/bin/orb-privd
chmod +x .lake/build/bin/orb-privd
''')
        self.assertIn('refusing to stage', self.run_build('--only', 'orb-privd', success=False).stderr)

    def test_package_routing_and_alias(self):
        self.run_build('--only', 'sandboxed-sh', '--only', 'sandboxed-node',
                       '--only', 'orb-locald', '--only', 'lean-mesh')
        self.assertIn('OrbCore build orb-core', self.log())
        self.assertIn('OrbNode build orb-node', self.log())
        self.assertIn('OrbLocald build orb-locald', self.log())
        self.assertIn('OrbBin build lean-mesh-cli', self.log())
        self.assertEqual(os.readlink(self.root / 'target/debug/sandboxed-sh'), 'orb-core')

    def test_no_telemetry_and_turbo(self):
        self.env['ORB_SKIP_TURBO_LEAN'] = '0'
        self.write('turbo-lean', '''#!/bin/sh
if [ "$1" = --help ]; then
  printf '%s\\n' '--no-telemetry' '--no-daemon' '--no-auto-worktree-link'
  exit 0
fi
printf '%s\\n' "$*" >> "$FIXTURE_ROOT/turbo.log"
while [ "$1" != build ]; do shift; done
exec lake "$@"
''')
        self.run_build('--no-telemetry', '--only', 'orb-privd')
        self.assertIn('--no-telemetry', (self.root / 'turbo.log').read_text())

    @unittest.skipUnless(os.uname().machine == 'x86_64', 'fixture executes x86_64 /bin/true')
    def test_with_tests(self):
        self.env['MOCK_REAL_EXE'] = '1'
        self.run_build('--with-tests', '--only', 'orb-privd')
        for pkg in ('OrbNetLeaf', 'OrbBin', 'OrbNode', 'OrbClient', 'OrbCore', 'OrbLocald'):
            self.assertIn(pkg + ' build', self.log())

    def test_ensure_lean_aarch64_bootstrap(self):
        shutil.copy2(self.bin / 'lake', self.bin / 'lake.seed')
        (self.bin / 'lake').unlink()
        self.env.update(MOCK_ARCH='aarch64', MOCK_ELF_ARCH='183')
        self.write('curl', '''#!/bin/sh
printf '%s\\n' "$*" >> "$FIXTURE_ROOT/download.log"
while [ "$1" != -o ]; do shift; done
touch "$2"
''')
        self.write('sha256sum', '#!/bin/sh\ncat > "$FIXTURE_ROOT/checksum.log"\n')
        self.write('tar', '''#!/bin/sh
while [ "$1" != -C ]; do shift; done
mkdir -p "$2/bin"
cp "$FIXTURE_ROOT/bin/lake.seed" "$2/bin/lake"
''')
        self.run_build('--ensure-lean', '--target-arch', 'aarch64', '--only', 'orb-privd')
        self.assertIn('lean-4.35.0-linux_aarch64.tar.zst', (self.root / 'download.log').read_text())
        self.assertIn('c8f0f8a3920e839718b1343e6781fd80a3e9b1024fbcd7078eb30f54e806b028',
                      (self.root / 'checksum.log').read_text())

    def test_missing_lean_without_bootstrap(self):
        (self.bin / 'lake').unlink()
        self.assertIn('lake\' not found', self.run_build('--only', 'orb-privd', success=False).stderr)


ROOT = Path(__file__).resolve().parent.parent
OPTIONAL = ['--no-telemetry', '--no-daemon', '--no-auto-worktree-link']
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, struct, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
optional = ['--no-telemetry', '--no-daemon', '--no-auto-worktree-link']
supported = json.loads(os.environ['FAKE_SUPPORTED'])
with open(os.environ['FAKE_LOG'], 'a') as f:
    f.write(json.dumps(dict(tool=name, args=args, package=pathlib.Path.cwd().name,
        telemetry=os.environ.get('TURBO_LEAN_TELEMETRY'), native=os.environ.get('LEAN_NATIVE_TELEMETRY'))) + '\n')
if args == ['--help']:
    print('Usage: turbo-lean [OPTIONS] <COMMAND>\n' + '\n'.join(supported))
    sys.exit(0)
if name == 'turbo-lean':
    for arg in args:
        if arg in optional and arg not in supported:
            print("error: unexpected argument '" + arg + "' found", file=sys.stderr)
            sys.exit(2)
    if os.environ.get('FAKE_FAIL') == pathlib.Path.cwd().name:
        sys.exit(42)
if 'build' not in args:
    sys.exit(0)
args = args[args.index('build') + 1:]
if '--' in args:
    args = args[:args.index('--')]
if not args:
    args = ['orb-client-test']
for target in args:
    target = {'lean-mesh-cli': 'lean-mesh', 'orb-node': 'sandboxed-node'}.get(target, target)
    binary = pathlib.Path('.lake/build/bin') / target
    binary.parent.mkdir(parents=True, exist_ok=True)
    if target.endswith('-test') or target == 'orb-spec-runner':
        binary.write_text('#!/bin/sh\nexit 0\n')
    else:
        data = bytearray(64)
        data[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', data, 18, 62 if os.uname().machine in ('x86_64', 'amd64') else 183)
        binary.write_bytes(data)
    binary.chmod(0o755)
'''


class TurboLeanCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        for name in ('build_orb_bins.sh', 'turbo_lean.sh'):
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        for name in ('OrbNetLeaf', 'OrbBin', 'OrbNode', 'OrbClient', 'OrbCore', 'OrbLocald', 'OrbDesktop'):
            (self.root / 'lean' / name).mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        for name in ('turbo-lean', 'lake'):
            path = self.bin / name
            path.write_text(FAKE)
            path.chmod(0o755)
        nm_path = self.bin / 'nm'
        nm_path.write_text('#!/bin/sh\nexit 0\n')
        nm_path.chmod(0o755)
        self.log = self.root / 'calls.jsonl'
        self.env = dict(os.environ, HOME=str(self.root), LEAN_BIN_DIR=str(self.bin),
                        PATH=f'{self.bin}:/usr/bin:/bin', FAKE_LOG=str(self.log),
                        FAKE_SUPPORTED=json.dumps(OPTIONAL), TURBO_LEAN_NO_DAEMON='1',
                        TURBO_LEAN_NO_AUTO_WORKTREE_LINK='1')
        for name in ('ORB_SKIP_TURBO_LEAN', 'ORB_ALLOW_RAW_LAKE_FALLBACK', 'TURBO_LEAN_CLI', 'LEAN_CC', 'NIX_CC'):
            self.env.pop(name, None)

    def build(self, *args, **env):
        return subprocess.run(['bash', str(self.root / 'scripts/build_orb_bins.sh'),
                               '--out-dir', str(self.root / 'out'), *args],
                              env={**self.env, **env}, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_old_new_and_partial_cli_build_all_packages_without_raw_lake(self):
        for supported in ([], OPTIONAL, ['--no-telemetry']):
            with self.subTest(supported=supported):
                self.log.unlink(missing_ok=True)
                result = self.build('--with-tests', '--only', 'orb-desktop-native',
                                    FAKE_SUPPORTED=json.dumps(supported))
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.calls()
                self.assertFalse(any(c['tool'] == 'lake' for c in calls), calls)
                builds = [c for c in calls if 'build' in c['args']]
                self.assertEqual({c['package'] for c in builds},
                                 {'OrbNetLeaf', 'OrbBin', 'OrbNode', 'OrbClient', 'OrbCore', 'OrbLocald', 'OrbDesktop'})
                self.assertTrue((self.root / 'out/orb-desktop-native').is_file())
                for call in calls:
                    self.assertEqual(call['telemetry'], 'off')
                    self.assertEqual(call['native'], 'off')
                for call in builds:
                    self.assertEqual([f for f in OPTIONAL if f in call['args']], supported)

    def test_turbo_failure_is_fatal_without_raw_fallback(self):
        result = self.build('--only', 'sandboxed-mcp', FAKE_FAIL='OrbBin')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn('ORB_ALLOW_RAW_LAKE_FALLBACK=1', result.stderr)
        self.assertFalse(any(c['tool'] == 'lake' for c in self.calls()))

    def test_explicit_raw_fallback_preserves_warning_as_error_and_telemetry(self):
        result = self.build('--only', 'sandboxed-mcp', FAKE_FAIL='OrbBin', ORB_ALLOW_RAW_LAKE_FALLBACK='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = [c for c in self.calls() if c['tool'] == 'lake']
        self.assertEqual(len(raw), 1)
        self.assertIn('-DwarningAsError=true', raw[0]['args'])
        self.assertEqual((raw[0]['telemetry'], raw[0]['native']), ('off', 'off'))

    def test_skip_does_not_silently_bypass_installed_turbo(self):
        result = self.build('--only', 'sandboxed-mcp', ORB_SKIP_TURBO_LEAN='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ORB_ALLOW_RAW_LAKE_FALLBACK=1', result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == '__main__':
    unittest.main()
