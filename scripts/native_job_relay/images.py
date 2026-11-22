"""Build disposable test images from the operator-selected native binaries."""
from pathlib import Path
import shutil
import subprocess


def executable(image, source, name):
    shutil.copy2(source, image / "bin" / name)
    # Called only for known trusted test binaries and system tools.
    dependencies = subprocess.run(["ldd", source], capture_output=True, text=True)
    if dependencies.returncode:
        if "not a dynamic executable" in dependencies.stdout + dependencies.stderr:
            return
        raise RuntimeError("unable to resolve native image dependencies")
    for line in dependencies.stdout.splitlines():
        if "=> not found" in line:
            raise RuntimeError("missing native image dependency")
        paths = [word for word in line.split() if word.startswith("/")]
        if paths:
            lib = Path(paths[0])
            target = image / lib.relative_to("/")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(lib, target)


def prepared_images(runtime, agy, workspace_mcp, socat, ca):
    profile = runtime / "profile-image"
    workspace = runtime / "workspace-image"
    for image, directories in [(profile, ["bin", "session/.agents", "dev", "proc", "tmp", "home/orb",
                                         "ipc", "etc/ssl/certs"]),
                               (workspace, ["bin", "dev", "workspace"])]:
        for directory in directories:
            (image / directory).mkdir(parents=True)
        executable(image, shutil.which("setpriv"), "setpriv")
    executable(profile, agy, "agy")
    executable(profile, socat, "socat")
    executable(workspace, workspace_mcp, "workspace-mcp")
    shutil.copyfile(ca, profile / "etc/ssl/certs/ca-certificates.crt")
    (profile / "session/.agents/mcp_config.json").touch()
    # A private supervisor umask must not make the image untraversable once
    # bubblewrap has dropped to the profile or workspace UID.
    for tree in (profile, workspace):
        tree.chmod(0o755)
        for entry in tree.rglob("*"):
            if entry.is_dir():
                entry.chmod(0o755)
    (profile / "etc/ssl/certs/ca-certificates.crt").chmod(0o644)
    (runtime / "sessions").mkdir(mode=0o700)
