"""Local configuration, package install and isolated PAM test primitives."""
import base64
import configparser
from contextlib import contextmanager, nullcontext
import difflib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import tempfile

CONFIG = Path("/etc/howdy/config.ini")
STATE = Path("/var/lib/sensible-biometrics")
PAM_PATH = Path("/etc/pam.d/sensible-howdy-test")
PAM_MODULE = Path("/usr/lib/x86_64-linux-gnu/security/pam_howdy.so")
PAM_FACE = b"# Sensible temporary Howdy test; never included by login services\nauth required pam_howdy.so\n@include common-account\n"
PAM_FALLBACK = b"# Sensible temporary Howdy test; never included by login services\nauth sufficient pam_howdy.so\n@include common-auth\n@include common-account\n"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def checked_read(path, owner=None):
    owner = os.geteuid() if owner is None else owner
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != owner or info.st_nlink != 1 or info.st_mode & 0o022:
            raise ValueError(f"Expected a regular, owner-controlled file: {path}")
        if info.st_size > 1024 * 1024:
            raise ValueError(f"File is unexpectedly large: {path}")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            return stream.read(), info
    finally:
        os.close(fd)


def check_directory(path, owner=None):
    owner = os.geteuid() if owner is None else owner
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != owner or info.st_mode & 0o022:
        raise ValueError(f"Expected an owner-controlled directory: {path}")


def atomic_write(path, data, mode, uid=None, gid=None):
    uid = os.geteuid() if uid is None else uid
    gid = os.getegid() if gid is None else gid
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), mode)
            os.fchown(stream.fileno(), uid, gid)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fd = os.open(path.parent, os.O_DIRECTORY | os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


@contextmanager
def locked_state():
    check_directory(STATE.parent)
    STATE.mkdir(mode=0o700, exist_ok=True)
    check_directory(STATE)
    fd = os.open(STATE / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or info.st_mode & 0o022:
            raise ValueError("Unsafe state lock")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def configured_bytes(original, device, timeout):
    """Validate INI structure, then replace only the two selected keys."""
    if not re.fullmatch(r"/dev/v4l/by-(?:id|path)/[A-Za-z0-9_.:+-]+", device):
        raise ValueError("Use a stable /dev/v4l/by-id or by-path camera link")
    if not 1 <= timeout <= 20:
        raise ValueError("Camera timeout must be between 1 and 20 seconds")
    text = original.decode("utf-8")
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.read_string(text)
    if not parser.has_section("video"):
        raise ValueError("No [video] section in the installed Howdy configuration")
    changes = {"device_path": device, "timeout": str(timeout)}
    output, section, found = [], None, set()
    for line in text.splitlines(keepends=True):
        header = re.fullmatch(r"\s*\[([^]]+)\]\s*(?:[#;].*)?", line.strip())
        if header:
            section = header[1]
        match = re.match(r"(\s*)(device_path|timeout)\s*=", line)
        if section == "video" and match:
            key = match[2]
            output.append(f"{match[1]}{key} = {changes[key]}\n")
            found.add(key)
        else:
            output.append(line)
    if found != set(changes):
        raise ValueError("Expected device_path and timeout keys in [video]; inspect the configuration first")
    return "".join(output).encode()


def configure(device, timeout=4, dry_run=False):
    check_directory(CONFIG.parent)
    with nullcontext() if dry_run else locked_state():
        original, info = checked_read(CONFIG)
        updated = configured_bytes(original, device, timeout)
        if updated == original:
            print("Camera configuration already matches.")
            return
        print("".join(difflib.unified_diff(original.decode().splitlines(True), updated.decode().splitlines(True),
                                         fromfile=str(CONFIG), tofile=str(CONFIG) + " (proposed)")), end="")
        if dry_run:
            return
        state_path = STATE / "config.json"
        baseline, metadata = original, info
        if state_path.exists() or state_path.is_symlink():
            state = json.loads(checked_read(state_path)[0])
            if sha(original) != state["applied_sha256"] or (
                stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid
            ) != (state["mode"], state["uid"], state["gid"]):
                raise ValueError("Configuration changed outside this tool; restore/reconcile it before configuring again")
            baseline = base64.b64decode(state["original"], validate=True)
            mode, uid, gid = state["mode"], state["uid"], state["gid"]
        else:
            mode, uid, gid = stat.S_IMODE(metadata.st_mode), metadata.st_uid, metadata.st_gid
        state = {"original": base64.b64encode(baseline).decode(), "applied_sha256": sha(updated),
                 "previous_sha256": sha(original), "mode": mode, "uid": uid, "gid": gid}
        # Save rollback data before changing config; restore also handles a
        # crash between these two atomic replacements.
        atomic_write(state_path, json.dumps(state).encode(), 0o600)
        if checked_read(CONFIG)[0] != original:
            raise ValueError("Configuration changed during setup; no configuration write performed")
        atomic_write(CONFIG, updated, stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
        print("Camera configured. Use restore-config to undo these changes.")


def restore_config():
    check_directory(CONFIG.parent)
    with locked_state():
        state_path = STATE / "config.json"
        state = json.loads(checked_read(state_path)[0])
        current, info = checked_read(CONFIG)
        original = base64.b64decode(state["original"], validate=True)
        if sha(current) not in (state["applied_sha256"], state["previous_sha256"], sha(original)) or (
            stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid
        ) != (state["mode"], state["uid"], state["gid"]):
            raise ValueError("Configuration changed outside this tool; refusing to overwrite it")
        atomic_write(CONFIG, original, state["mode"], state["uid"], state["gid"])
        state_path.unlink()
        print("Original camera configuration restored.")


def target_user(explicit=None):
    name = explicit or os.environ.get("SUDO_USER") or pwd.getpwuid(os.getuid()).pw_name
    user = pwd.getpwnam(name)
    if user.pw_uid < 1000 or user.pw_shell.endswith(("/nologin", "/false")):
        raise ValueError("Choose a normal desktop account with --user; root/system accounts cannot be enrolled")
    return user.pw_name


def howdy(command, user=None, timeout=None):
    executable = Path("/usr/bin/howdy")
    info = executable.stat()
    if info.st_uid != 0 or info.st_mode & 0o022:
        raise ValueError("Installed Howdy executable is not root-controlled")
    args = [str(executable)]
    if user:
        args += ["-U", user]
    subprocess.run([*args, command], check=True, timeout=timeout)


def pam_test(user, password_fallback=False, timeout=30):
    check_directory(PAM_MODULE.parent)
    module = PAM_MODULE.lstat()
    if not stat.S_ISREG(module.st_mode) or module.st_uid != os.geteuid() or module.st_mode & 0o022:
        raise ValueError("Expected a root-controlled PAM module")
    content = PAM_FALLBACK if password_fallback else PAM_FACE
    with locked_state():
        run_pam_service(content, user, timeout)


def run_pam_service(content, user, timeout, *, structured=False, account=True):
    check_directory(PAM_PATH.parent)
    fd = os.open(PAM_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if structured:
            import pam_session
            return pam_session.run(PAM_PATH.name, user, timeout, account=account)
        subprocess.run(["pamtester", PAM_PATH.name, user, "authenticate", "acct_mgmt"], check=True, timeout=timeout)
    finally:
        if checked_read(PAM_PATH)[0] == content:
            PAM_PATH.unlink()
        else:
            raise ValueError(f"Temporary PAM service changed; inspect {PAM_PATH}")


def pam_cleanup():
    with locked_state():
        if checked_read(PAM_PATH)[0] not in (PAM_FACE, PAM_FALLBACK):
            raise ValueError("Refusing to remove an unrecognized PAM test service")
        PAM_PATH.unlink()
        print("Removed the interrupted PAM test service.")


def install_package(package, checksum):
    if not re.fullmatch(r"[a-f0-9]{64}", checksum):
        raise ValueError("A SHA256 checksum is required")
    # Copy into a root-private directory so a user-owned build artifact cannot
    # change after verification but before apt reads it.
    with tempfile.TemporaryDirectory(prefix="sensible-howdy-install-", dir="/var/tmp") as root:
        copy = Path(root) / "howdy-next.deb"
        fd = os.open(package, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as source, copy.open("wb") as dest:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise ValueError("Package is not a regular file")
            shutil.copyfileobj(source, dest)
        with copy.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != checksum:
                raise ValueError("Package checksum mismatch")
        fields = subprocess.check_output(["dpkg-deb", "-f", str(copy), "Package", "Version", "Architecture"], text=True)
        expected = "Package: howdy-next\nVersion: 3.4.0-6+sensible1\nArchitecture: amd64\n"
        if fields != expected:
            raise ValueError("Unexpected package identity; build the local Howdy-next package first")
        subprocess.run(["apt-get", "--simulate", "--no-remove", "install", str(copy)], check=True)
        subprocess.run(["apt-get", "--no-remove", "install", str(copy)], check=True)
