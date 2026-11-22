"""Offline replay of the native member's file protocol, permissions and limits."""
import importlib.util
import multiprocessing
import os
from pathlib import Path
import tempfile
from native_job_relay.remote import definition, respond

source = Path(__file__).resolve().parents[1] / "lean/OrbBin/OrbBin/native_job_file.py"
spec = importlib.util.spec_from_file_location("bound_job_file", source)
fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fs)


def main():
    with tempfile.TemporaryDirectory() as scratch:
        base = Path(scratch)
        checkout = base / "checkout"
        checkout.mkdir()
        (checkout / "src").mkdir()
        outside = base / "outside"
        outside.write_text("preserve")
        (checkout / "alias").symlink_to(outside)
        (checkout / "dir-link").symlink_to(base)
        os.link(outside, checkout / "hard-link")
        calls = []

        def exchange(request):
            calls.append(request["action"])
            # Production grants the filesystem policy to a one-shot subprocess.
            tx, rx = multiprocessing.Pipe()
            def child():
                try:
                    tx.send(fs.job_file(str(checkout), request, lambda name: name.lower() in (".git", ".env")))
                except (OSError, ValueError):
                    tx.send(None)
            worker = multiprocessing.get_context("fork").Process(target=child)
            worker.start()
            result = rx.recv()
            worker.join(5)
            assert worker.exitcode == 0
            return result

        def tool(name, path, content=None, readonly=False):
            params = {"name": name, "arguments": {"path": path}}
            if content is not None:
                params["arguments"]["content"] = content
            names = ["read_file"] if readonly else ["read_file", "write_file"]
            return respond({"jsonrpc": "2.0", "method": "tools/call", "params": params, "id": 4},
                           {n: definition(n) for n in names}, exchange)

        assert not tool("write_file", "src/proof", "hello")["result"]["isError"]
        assert tool("read_file", "src/proof", readonly=True)["result"]["content"][0]["text"] == "hello"
        assert (checkout / "src/proof").read_text() == "hello"
        before = calls[:]
        assert tool("write_file", "src/proof", "blocked", readonly=True)["error"]["code"] == -32602
        assert tool("exec", "src/proof")["error"]["code"] == -32602
        assert calls == before
        for path in ("../outside", "dir-link/outside", "alias", "hard-link", "/absolute", ".env", ".git/config"):
            assert tool("read_file", path)["result"]["isError"]
            assert tool("write_file", path, "bad")["result"]["isError"]
        assert tool("write_file", "src/proof", "x" * (fs.MAX_BYTES + 1))["result"]["isError"]
        assert (checkout / "src/proof").read_text() == "hello"
        assert outside.read_text() == "preserve"
        print("Native writer, reader, ownership boundaries, path filters, hard links and size guards passed.")


if __name__ == "__main__":
    main()
