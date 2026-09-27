"""Materialize an uploaded conversation snapshot inside the harness workspace.

Both inputs are selected by Core, never shell-expanded paths from a prompt.
All descendant opens reject symlinks; snapshots are immutable and retryable.
"""
import json
import os
import stat
import sys
import uuid
from pathlib import PurePath


def directory(parent, name, create=False):
    if create:
        try:
            os.mkdir(name, mode=0o700, dir_fd=parent)
        except FileExistsError:
            pass
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)


def read_file(parent, name):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 20 * 1024 * 1024:
            raise ValueError('Invalid conversation archive file')
        return stream.read()


def write_file(parent, name, content):
    try:
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
    except FileExistsError:
        if read_file(parent, name) != content:
            raise ValueError('Conversation snapshot collision')
        return
    with os.fdopen(fd, 'wb') as stream:
        stream.write(content)


def stage(upload_root, identifier):
    identifier = str(uuid.UUID(identifier))
    uploads = os.open(upload_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    manifest_dir = directory(uploads, identifier)
    manifest = json.loads(read_file(manifest_dir, 'conversation.json'))
    os.close(manifest_dir)
    target = os.open('.', os.O_RDONLY | os.O_DIRECTORY)
    for name in ('.paloma', 'conversation', identifier):
        child = directory(target, name, create=True)
        os.close(target)
        target = child
    for key, prefix in (('transcript_parts', 'transcript.md.'), ('event_parts', 'events.jsonl.'), ('previous_side_history_parts', 'side-history.md.')):
        staged = []
        for raw in manifest.get(key, []):
            relative = PurePath(raw).relative_to(PurePath(upload_root))
            if len(relative.parts) != 2:
                raise ValueError('Archive path is not an upload receipt')
            upload, name = relative.parts
            if str(uuid.UUID(upload)) != upload or not name.startswith(prefix) or not name[len(prefix):].isdigit():
                raise ValueError('Invalid conversation part')
            part_dir = directory(uploads, upload)
            content = read_file(part_dir, name)
            os.close(part_dir)
            write_file(target, name, content)
            staged.append(f'.paloma/conversation/{identifier}/{name}')
        manifest[key] = staged
    write_file(target, 'conversation.json', json.dumps(manifest, ensure_ascii=False, indent=2).encode())
    os.close(target)
    os.close(uploads)


if __name__ == '__main__':
    stage(sys.argv[1], sys.argv[2])
