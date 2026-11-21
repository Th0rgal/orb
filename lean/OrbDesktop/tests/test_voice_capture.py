"""Exercise native capture with a synthetic PCM source and Orb's fake worker."""
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

    def test_cancel_discards_audio(self):
        self.assertEqual(self.record(b""), b"")


if __name__ == "__main__":
    unittest.main()
