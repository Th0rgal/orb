"""Local PCM capture and Orb worker stdio adapter. Only 'record' opens audio."""
import io
import json
import os
import selectors
import shutil
import subprocess
import sys
import time
import wave
from contextlib import contextmanager

RATE = 16000
LIMIT = RATE * 2 * 120


def bridge():
    python = os.getenv("ORB_VOICE_PYTHON", "")
    worker = os.getenv("ORB_VOICE_WORKER", "")
    if (os.path.isfile(python) and os.access(python, os.X_OK)
            and os.path.isfile(worker) and os.access(worker, os.R_OK)):
        return [python, worker]


@contextmanager
def process(argv, **pipes):
    child = subprocess.Popen(argv, stderr=subprocess.DEVNULL, **pipes)
    try:
        yield child
    finally:
        child.kill()
        child.wait()


def capture(recorder, commands):
    pcm = bytearray()
    deadline = time.monotonic() + 120
    with process(recorder, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE) as child, selectors.DefaultSelector() as sel:
        sel.register(commands, selectors.EVENT_READ)
        sel.register(child.stdout, selectors.EVENT_READ)
        while len(pcm) < LIMIT:
            events = sel.select(max(0, deadline - time.monotonic()))
            if not events:
                break
            for key, _ in events:
                if key.fileobj is commands:
                    return pcm if commands.read(1) == b"F" else None
                chunk = os.read(child.stdout.fileno(), min(65536, LIMIT - len(pcm)))
                if not chunk:
                    raise ValueError("capture ended")
                pcm.extend(chunk)
    return pcm


def transcribe(worker, pcm):
    wav = io.BytesIO()
    with wave.open(wav, "wb") as audio:
        audio.setparams((1, 2, RATE, 0, "NONE", ""))
        audio.writeframes(pcm[:len(pcm) // 2 * 2])
    payload = wav.getvalue()
    header = dict(id=1, op="transcribe", language="en", punctuation=True, audio_bytes=len(payload))
    with process(worker, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
        data, _ = child.communicate(json.dumps(header).encode() + b"\n" + payload, timeout=120)
    result = json.loads(data)
    if result.get("id") != 1 or result.get("ok") is not True:
        raise ValueError("transcription failed")
    return result["result"]["text"]


def main(mode):
    worker = bridge()
    parec = shutil.which("parec")
    if not worker or not parec:
        return 1
    if mode == "probe":
        return 0
    if mode != "record":
        return 1
    pcm = capture([parec, "--raw", "--rate=16000", "--channels=1", "--format=s16le"], sys.stdin.buffer)
    if pcm:
        sys.stdout.write(transcribe(worker, pcm))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
