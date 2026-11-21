"""Exercise native capture with a synthetic PCM source and Orb's fake worker."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

PKG = Path(__file__).resolve().parents[1]
ADAPTER = PKG / "OrbDesktop/voice_capture.py"
WORKER = PKG.parents[1] / "orb/voice/worker.py"


class VoiceCaptureTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.marker = self.root / "captured"
        recorder = self.root / "parec"
        recorder.write_text(f"""#!{sys.executable}
import os, time
from pathlib import Path
# More than a pipe buffer, so the controller has read audio before the marker.
for _ in range(32):
    os.write(1, b'\\x01\\x10' * 4096)
Path({str(self.marker)!r}).touch()
time.sleep(10)
""")
        recorder.chmod(0o755)
        self.env = dict(PATH=str(self.root), HOME=str(self.root), ORB_VOICE_FAKE="1",
                        ORB_VOICE_WORKER=str(WORKER), ORB_VOICE_PYTHON=sys.executable)

    def test_probe_does_not_capture(self):
        cmd = [sys.executable, str(ADAPTER), "probe"]
        self.assertEqual(subprocess.run(cmd, env=self.env).returncode, 0)
        self.assertFalse(self.marker.exists())
        del self.env["ORB_VOICE_WORKER"]
        self.assertNotEqual(subprocess.run(cmd, env=self.env).returncode, 0)
        self.assertFalse(self.marker.exists())

    def record(self, command):
        with subprocess.Popen([sys.executable, str(ADAPTER), "record"], env=self.env,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE) as proc:
            try:
                deadline = time.monotonic() + 5
                while not self.marker.exists() and time.monotonic() < deadline and proc.poll() is None:
                    time.sleep(.01)
                self.assertTrue(self.marker.exists())
                out, _ = proc.communicate(command, timeout=5)
                self.assertEqual(proc.returncode, 0)
                return out
            finally:
                proc.kill()

    def test_finish_transcribes_local_pcm(self):
        self.assertIn(b"[fake en]", self.record(b"F"))

    def run_adapter(self, mode, *args):
        return subprocess.run([sys.executable, str(ADAPTER), mode, *args], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def test_french_desktop_locale(self):
        self.env.update(LANGUAGE="sv_SE:fr_CA.UTF-8", LANG="en_US.UTF-8")
        self.assertIn(b"[fake fr]", self.record(b"F"))

    def test_saved_language_overrides_locale(self):
        prefs = self.root / ".orb/ui-prefs.json"
        prefs.parent.mkdir()
        prefs.write_text(json.dumps({"orb.voiceLang": "en", "orb-theme": "dark"}))
        self.env["LANG"] = "fr_FR.UTF-8"
        self.assertIn(b"[fake en]", self.record(b"F"))
        self.assertEqual(json.loads(prefs.read_text())["orb.voiceLang"], "en")

    def test_picker_saves_language_and_cancel_preserves_it(self):
        prefs = self.root / ".orb/ui-prefs.json"
        prefs.parent.mkdir()
        prefs.write_text('{"orb-theme":"light"}')
        picker = self.root / "zenity"
        picker.write_text(f"#!{sys.executable}\nimport sys\nassert 'Français' in sys.argv\nprint('fr')\n")
        picker.chmod(0o755)
        self.assertEqual(self.run_adapter("choose").stdout.strip(), "fr")
        picker.write_text(f"#!{sys.executable}\nraise SystemExit(1)\n")
        self.assertEqual(self.run_adapter("choose").stdout.strip(), "fr")
        self.assertEqual(json.loads(prefs.read_text()), {"orb-theme": "light", "orb.voiceLang": "fr"})
        self.assertFalse(self.marker.exists())
        self.assertIn(b"[fake fr]", self.record(b"F"))

    def test_model_languages_and_readiness_gate_capture(self):
        worker = self.root / "worker.py"
        self.env["ORB_VOICE_WORKER"] = str(worker)
        catalog = (PKG.parents[1] / "orb/src/voiceLanguages.json").read_text()
        prefs = self.root / ".orb/ui-prefs.json"
        prefs.parent.mkdir()
        prefs.write_text('{"orb.voiceLang":"fr"}')
        for languages, present, expected in [(["en"], True, "en"), (["fr"], True, "fr"),
                                             (["xx"], True, ""), (["fr"], False, "")]:
            capability = dict(protocol=1, backend="fixture", languages=languages, model_present=present)
            response = json.dumps(dict(id=1, ok=True, result=capability))
            worker.write_text(f"import json, sys\nassert json.loads(sys.stdin.readline())['op'] == 'hello'\nprint({response!r})")
            result = self.run_adapter("probe")
            self.assertEqual(result.returncode == 0, bool(expected))
            if expected:
                self.assertEqual(result.stdout.split()[0], expected)
            self.assertNotEqual(self.run_adapter("record", catalog, "de").returncode, 0)
            self.assertFalse(self.marker.exists())
            self.assertEqual(json.loads(prefs.read_text())["orb.voiceLang"], "fr")

    def test_cancel_discards_audio(self):
        self.assertEqual(self.record(b""), b"")


if __name__ == "__main__":
    unittest.main()
