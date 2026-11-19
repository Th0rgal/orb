"""Replay the credential owner's renewal code against an in-process mock transport."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
revision = '0341bcc440583738d7d0e673abefc63bbe99e131'
if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip() != revision:
    sys.exit(f'Expected kaitranntt/CLIProxyAPIPlus at {revision}')
test = Path(__file__).resolve().parent / 'testdata/r21a_kimi_refresh_test.go'
with tempfile.TemporaryDirectory() as directory:
    overlay = Path(directory) / 'overlay.json'
    overlay.write_text(json.dumps({'Replace': {str(source / 'internal/runtime/executor' / test.name): str(test)}}))
    subprocess.run(['go', 'test', '-overlay', str(overlay), './internal/runtime/executor',
                    '-run', '^TestR21aExpiredKimiRenewal$', '-count=1', '-v'], cwd=source, check=True)
