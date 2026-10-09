"""ACP boundary tests for durable native identity and prompt admission."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BRIDGE = Path(__file__).resolve().parents[1] / "shared/vibe_bridge.py"
FAKE = '''#!/usr/bin/env python3
import json, os, sys
for line in sys.stdin:
 m=json.loads(line); method=m["method"]; p=m["params"]
 def notify(text):
  print(json.dumps(dict(jsonrpc="2.0",method="session/update",params=dict(sessionId="native-1",update=dict(sessionUpdate="agent_message_chunk",content=dict(type="text",text=text))))),flush=True)
 result={}
 if method=="initialize": result={"agentCapabilities":{"loadSession":True}}
 if method=="session/load":
  assert p["sessionId"]=="native-1"
  notify("OLD HISTORY")
 if method in ("session/new","session/load"):
  result={"sessionId":"native-1","modes":{"availableModes":[{"id":"auto-approve"},{"id":"plan"}]}}
 if method=="session/prompt":
  open(os.environ["PROMPT_MARKER"],"a").write(p["prompt"][0]["text"]+"\\n")
  notify("NEW ANSWER")
  if os.environ.get("EXIT_EARLY"): sys.exit(0)
  result={"stopReason":"end_turn"}
 print(json.dumps(dict(jsonrpc="2.0",id=m["id"],result=result)),flush=True)
'''


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.cli = self.root / "fake-acp"
        self.cli.write_text(FAKE)
        self.cli.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.root), PROMPT_MARKER=str(self.root / "prompts"))
        for key in ("SANDBOXED_MCP_WRAPPER", "SANDBOXED_SH_MISSION_ID"):
            self.env.pop(key, None)

    def tearDown(self):
        self.tmp.cleanup()

    def start(self, *extra):
        return subprocess.Popen(["python3", str(BRIDGE), "--cli", str(self.cli), "--mission", "one", "--prompt", "hello", *extra],
                                cwd=self.root, env=self.env, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_acknowledgement_and_resume_do_not_replay_history(self):
        child = self.start("--ack")
        identity = json.loads(child.stdout.readline())
        self.assertEqual(identity, {"type": "session", "session_id": "native-1"})
        self.assertFalse((self.root / "prompts").exists())
        output, errors = child.communicate('{"continue":true}\n', timeout=10)
        self.assertEqual(child.returncode, 0, errors + output)
        self.assertIn("NEW ANSWER", output)
        child = self.start("--resume", "native-1")
        output, errors = child.communicate(timeout=10)
        self.assertEqual(child.returncode, 0, errors + output)
        self.assertNotIn("OLD HISTORY", output)
        self.assertIn("NEW ANSWER", output)
        self.assertEqual((self.root / "prompts").read_text(), "hello\nhello\n")

    def test_lost_parent_never_starts_prompt(self):
        child = self.start("--ack")
        output, _ = child.communicate('', timeout=10)
        self.assertNotEqual(child.returncode, 0)
        self.assertFalse((self.root / "prompts").exists())
        self.assertIn('"type": "session"', output)

    def test_text_without_terminal_result_is_failure(self):
        self.env["EXIT_EARLY"] = "1"
        child = self.start()
        output, _ = child.communicate(timeout=10)
        self.assertNotEqual(child.returncode, 0)
        self.assertIn('"type": "error"', output)

    def test_different_native_identity_is_rejected_before_prompt(self):
        child = self.start()
        child.communicate(timeout=10)
        child = self.start("--resume", "different")
        output, _ = child.communicate(timeout=10)
        self.assertNotEqual(child.returncode, 0)
        self.assertIn("differs", output)
        self.assertEqual((self.root / "prompts").read_text(), "hello\n")


if __name__ == "__main__":
    unittest.main()
