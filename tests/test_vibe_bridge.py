"""ACP boundary tests for durable native identity and prompt admission."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

BRIDGE = Path(__file__).resolve().parents[1] / "shared/vibe_bridge.py"
FAKE = '''#!/usr/bin/env python3
import json, os, sys
session_created=False
for line in sys.stdin:
 m=json.loads(line); method=m["method"]; p=m["params"]
 if os.environ.get("REQUEST_LOG"):
  with open(os.environ["REQUEST_LOG"],"a") as log: log.write(json.dumps(m)+"\\n")
 def notify(text):
  print(json.dumps(dict(jsonrpc="2.0",method="session/update",params=dict(sessionId="native-1",update=dict(sessionUpdate="agent_message_chunk",content=dict(type="text",text=text))))),flush=True)
 result={}
 if method=="initialize": result={"agentCapabilities":{"loadSession":True}}
 if method=="session/new" and os.environ.get("NEW_FAIL"):
  if os.environ["NEW_FAIL"]=="eof": sys.exit(1)
  print(json.dumps(dict(jsonrpc="2.0",id=m["id"],error=dict(code=-32603,message="rejected"))),flush=True)
  continue
 if method=="session/load":
  assert p["sessionId"]=="native-1"
  notify("OLD HISTORY")
 if method in ("session/new","session/load"):
  session_created=True
  result={"sessionId":"native-1","modes":{"availableModes":[{"id":"auto-approve"},{"id":"plan"}]}}
  if os.environ.get("MODERN_MODEL_CONFIG"):
   result["configOptions"]=[{"id":"model","category":"model","type":"select","currentValue":"other","options":[{"value":"sandboxed-selected","name":"selected"}]}]
 if method=="session/set_model" and os.environ.get("MODERN_MODEL_CONFIG"):
  print(json.dumps(dict(jsonrpc="2.0",id=m["id"],error=dict(code=-32601,message="unsupported"))),flush=True)
  continue
 if method=="session/set_config_option":
  assert p==dict(sessionId="native-1",configId="model",value="sandboxed-selected")
 if method=="_trust/status" and os.environ.get("TRUST_REQUIRED"):
  result={"details":{"availableDecisions":["trust_cwd"]}}
 if method=="_trust/decision":
  assert session_created and p["sessionId"]=="native-1" and p["cwd"]==os.getcwd()
  assert p["decision"]=="trust_cwd"
  if os.environ.get("TRUST_FAIL"):
   print(json.dumps(dict(jsonrpc="2.0",id=m["id"],error=dict(code=-32600,message="trust rejected"))),flush=True)
   continue
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
        for key in ("SANDBOXED_MCP_WRAPPER", "SANDBOXED_SH_MISSION_ID", "SANDBOXED_VIBE_TRANSFER_ID"):
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

    def test_transfer_return_uses_new_journal_but_recovers_within_transfer(self):
        log = self.root / "requests"
        self.env["REQUEST_LOG"] = str(log)
        for scope, expected in [(None, "session/new"), ("transfer-one", "session/new"),
                                ("transfer-one", "session/load"), ("transfer-two", "session/new")]:
            if scope:
                self.env["SANDBOXED_VIBE_TRANSFER_ID"] = scope
            log.write_text("")
            child = self.start()
            output, errors = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 0, errors + output)
            methods = [json.loads(line)["method"] for line in log.read_text().splitlines()]
            self.assertIn(expected, methods)
            self.assertNotIn("session/load" if expected == "session/new" else "session/new", methods)

    def test_large_stdin_prompt_preserves_text_and_acknowledgement(self):
        prompt = "a multiline prompt\n" * 16000
        child = subprocess.Popen(["python3", str(BRIDGE), "--cli", str(self.cli),
                                  "--mission", "one", "--prompt-stdin", "--ack"],
                                 cwd=self.root, env=self.env, text=True,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        output, errors = child.communicate(json.dumps({"prompt": prompt}) + '\n{"continue":true}\n', timeout=10)
        self.assertEqual(child.returncode, 0, errors + output)
        self.assertEqual((self.root / "prompts").read_text(), prompt + "\n")

    def test_session_scoped_trust_follows_durable_identity_and_parent_ack(self):
        log = self.root / "requests.jsonl"
        self.env.update(TRUST_REQUIRED="1", REQUEST_LOG=str(log))
        for resume in (False, True):
            with self.subTest(resume=resume):
                log.write_text("")
                child = self.start("--ack", *(["--resume", "native-1"] if resume else []))
                self.assertEqual(json.loads(child.stdout.readline())["session_id"], "native-1")
                journals = list((self.root / ".local/state/sandboxed-vibe").glob("*.json"))
                self.assertEqual(json.loads(journals[0].read_text())["session"], "native-1")
                requests = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual([r["method"] for r in requests],
                                 ["initialize", "session/load" if resume else "session/new"])
                output, errors = child.communicate('{"continue":true}\n', timeout=10)
                self.assertEqual(child.returncode, 0, errors + output)
                requests = [json.loads(line) for line in log.read_text().splitlines()]
                methods = [r["method"] for r in requests]
                self.assertLess(methods.index("_trust/decision"), methods.index("session/prompt"))
                for request in requests:
                    if request["method"].startswith("_trust/"):
                        self.assertEqual(request["params"]["sessionId"], "native-1")
                        self.assertEqual(request["params"]["cwd"], str(self.root.resolve()))

    def test_rejected_trust_retains_native_identity_and_never_prompts(self):
        log = self.root / "requests.jsonl"
        self.env.update(TRUST_REQUIRED="1", TRUST_FAIL="1", REQUEST_LOG=str(log))
        child = self.start()
        output, _ = child.communicate(timeout=10)
        self.assertNotEqual(child.returncode, 0)
        self.assertIn("rejected _trust/decision", output)
        self.assertFalse((self.root / "prompts").exists())
        journals = list((self.root / ".local/state/sandboxed-vibe").glob("*.json"))
        self.assertEqual(json.loads(journals[0].read_text())["session"], "native-1")

        self.env.pop("TRUST_FAIL")
        log.write_text("")
        child = self.start()
        output, errors = child.communicate(timeout=10)
        self.assertEqual(child.returncode, 0, errors + output)
        methods = [json.loads(line)["method"] for line in log.read_text().splitlines()]
        self.assertIn("session/load", methods)
        self.assertNotIn("session/new", methods)
        self.assertEqual((self.root / "prompts").read_text(), "hello\n")

    def test_advertised_model_config_uses_standard_config_option(self):
        log = self.root / "requests.jsonl"
        self.env.update(MODERN_MODEL_CONFIG="1", REQUEST_LOG=str(log))
        child = self.start("--model", "mistral/selected-model")
        output, errors = child.communicate(timeout=10)
        self.assertEqual(child.returncode, 0, errors + output)
        requests = [json.loads(line) for line in log.read_text().splitlines()]
        methods = [request["method"] for request in requests]
        self.assertNotIn("session/set_model", methods)
        self.assertLess(methods.index("session/set_config_option"), methods.index("session/prompt"))

    def test_prompt_file_and_concurrent_session_lock(self):
        child = self.start("--ack")
        self.assertEqual(json.loads(child.stdout.readline())["type"], "session")
        concurrent = self.start()
        output, _ = concurrent.communicate(timeout=10)
        self.assertNotEqual(concurrent.returncode, 0)
        self.assertFalse((self.root / "prompts").exists())
        child.communicate('{"continue":true}\n', timeout=10)
        prompt = self.root / "prompt.txt"
        prompt.write_text("from file")
        resumed = subprocess.Popen(["python3", str(BRIDGE), "--cli", str(self.cli),
                                   "--mission", "one", "--prompt-file", str(prompt)],
                                  cwd=self.root, env=self.env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        output, errors = resumed.communicate(timeout=10)
        self.assertEqual(resumed.returncode, 0, errors + output)
        self.assertEqual((self.root / "prompts").read_text(), "hello\nfrom file\n")

    def test_windows_lock_uses_one_byte_exclusive_lock(self):
        spec = importlib.util.spec_from_file_location("vibe_bridge_test", BRIDGE)
        bridge = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bridge)
        calls = []
        windows = SimpleNamespace(LK_NBLCK=2, locking=lambda fd, mode, size: calls.append((fd, mode, size)))
        with (self.root / "windows.lock").open("w") as lock:
            with patch.object(bridge.os, "name", "nt"), patch.dict("sys.modules", {"msvcrt": windows}):
                bridge.lock_file(lock)
            self.assertEqual(calls, [(lock.fileno(), 2, 1)])
            self.assertEqual(lock.tell(), 0)

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

    def test_rejected_session_creation_can_retry_but_lost_response_cannot(self):
        for outcome in ("rejected", "eof"):
            with self.subTest(outcome=outcome):
                self.env["NEW_FAIL"] = outcome
                child = self.start()
                output, _ = child.communicate(timeout=10)
                self.assertNotEqual(child.returncode, 0, output)
                self.assertFalse((self.root / "prompts").exists())
                self.env.pop("NEW_FAIL")
                child = self.start()
                output, _ = child.communicate(timeout=10)
                if outcome == "rejected":
                    self.assertEqual(child.returncode, 0, output)
                    (self.root / "prompts").unlink()
                    for journal in (self.root / ".local/state/sandboxed-vibe").glob("*.json"):
                        journal.unlink()
                else:
                    self.assertNotEqual(child.returncode, 0)
                    self.assertIn("unresolved launch", output)
                    self.assertFalse((self.root / "prompts").exists())


if __name__ == "__main__":
    unittest.main()
