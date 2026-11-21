"""Local PCM capture and Orb worker stdio adapter. Only 'record' opens audio."""
import fcntl
import io
import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from contextlib import contextmanager
from pathlib import Path

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


def request(worker, header, payload=b"", timeout=5):
    with process(worker, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
        data, _ = child.communicate(json.dumps(dict(header, id=1)).encode() + b"\n" + payload, timeout=timeout)
    response = json.loads(data)
    if response.get("id") != 1 or response.get("ok") is not True:
        raise ValueError("voice worker request failed")
    return response["result"]


def prefs_path():
    root = os.getenv("ORB_STATE_DIR") or Path.home() / ".orb"
    return Path(root) / "ui-prefs.json"


def read_prefs(path):
    try:
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), encoding="utf8") as stream:
            prefs = json.load(stream)
    except FileNotFoundError:
        return {}
    if not isinstance(prefs, dict):
        raise ValueError("invalid desktop preferences")
    return prefs


def save_language(code):
    # Match desktop_prefs_patch: lock the sibling .lock, merge, then replace.
    path = prefs_path()
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    fd = os.open(str(path) + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        prefs = read_prefs(path)
        prefs["orb.voiceLang"] = code
        with tempfile.NamedTemporaryFile(dir=path.parent, mode="w", delete=False) as tmp:
            try:
                json.dump(prefs, tmp, ensure_ascii=False)
                tmp.flush()
                os.replace(tmp.name, path)
            finally:
                Path(tmp.name).unlink(missing_ok=True)


def preferred_language(choices):
    saved = read_prefs(prefs_path()).get("orb.voiceLang")
    if isinstance(saved, str) and saved in choices:
        return saved
    locales = os.getenv("LANGUAGE", "").split(":")
    locales.append(os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or os.getenv("LANG", ""))
    for loc in locales:
        primary = loc.partition(".")[0].partition("@")[0].replace("_", "-").partition("-")[0].lower()
        if primary in choices:
            return primary
    return "en" if "en" in choices else next(iter(choices))


def model_languages(worker, catalog):
    hello = request(worker, {"op": "hello"})
    languages = hello.get("languages")
    if (hello.get("protocol") != 1 or not isinstance(languages, list)
            or not all(isinstance(code, str) for code in languages)):
        raise ValueError("invalid worker capabilities")
    fake = os.getenv("ORB_VOICE_FAKE") == "1" and hello.get("backend") == "fake"
    if hello.get("model_present") is not True and not fake:
        raise ValueError("model unavailable")
    choices = {row["code"]: row["label"] for row in catalog if row["code"] in languages}
    if not choices:
        raise ValueError("no compatible languages")
    return choices


def choose_language(choices, current):
    args = ["zenity", "--list", "--radiolist", "--title=Dictation language",
            "--column=Selected", "--column=Language", "--column=Code",
            "--hide-column=3", "--print-column=3"]
    for code, label in choices.items():
        args.extend(["TRUE" if code == current else "FALSE", label, code])
    result = subprocess.run(args, stdout=subprocess.PIPE, text=True)
    if result.returncode == 1:
        return current
    result.check_returncode()
    code = result.stdout.strip()
    if code not in choices:
        raise ValueError("unsupported language")
    save_language(code)
    return code


def transcribe(worker, pcm, language):
    wav = io.BytesIO()
    with wave.open(wav, "wb") as audio:
        audio.setparams((1, 2, RATE, 0, "NONE", ""))
        audio.writeframes(pcm[:len(pcm) // 2 * 2])
    payload = wav.getvalue()
    header = dict(op="transcribe", language=language, punctuation=True, audio_bytes=len(payload))
    return request(worker, header, payload, timeout=120)["text"]


def main(mode, catalog, selected=None):
    worker = bridge()
    parec = shutil.which("parec")
    if not worker or not parec:
        return 1
    choices = model_languages(worker, catalog)
    language = preferred_language(choices)
    if mode == "probe":
        print(language, "picker" if shutil.which("zenity") else "fixed", sep="\t")
        return 0
    if mode == "choose":
        print(choose_language(choices, language))
        return 0
    if mode != "record":
        return 1
    if selected is not None:
        if selected not in choices:
            raise ValueError("selected language unavailable for this model")
        language = selected
    pcm = capture([parec, "--raw", "--rate=16000", "--channels=1", "--format=s16le"], sys.stdin.buffer)
    if pcm:
        sys.stdout.write(transcribe(worker, pcm, language))
    return 0


if __name__ == "__main__":
    catalog = (json.loads(sys.argv[2]) if len(sys.argv) > 2 else
               json.loads((Path(__file__).resolve().parents[3] / "orb/src/voiceLanguages.json").read_text()))
    sys.exit(main(sys.argv[1], catalog, sys.argv[3] if len(sys.argv) > 3 else None))
