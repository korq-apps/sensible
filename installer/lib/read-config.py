#!/usr/bin/env python3
"""Read protected installer TOML as data; emit a fixed, NUL-delimited record.

The installer checks root before invoking this helper. Checking file ownership
against the effective UID also permits unprivileged fixture tests. Never print
input values or exception text: TOML diagnostics can contain secret material.
"""

import os
from pathlib import Path
import stat
import sys

try:
    import tomllib
except ImportError:
    sys.exit("Error: unattended input requires Python 3.11+ with tomllib.")


class InvalidConfig(Exception):
    pass


def protected_read(path, limit):
    """Walk without symlinks, check the opened inode, then read bounded bytes."""
    if not isinstance(path, str) or not path or any(ord(c) < 32 or ord(c) == 127 for c in path):
        raise InvalidConfig("Invalid input file path.")
    path = os.path.abspath(path)
    parts = Path(path).parts[1:]
    if not parts:
        raise InvalidConfig("Input must be a regular file.")
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                            dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                     dir_fd=directory)
    finally:
        os.close(directory)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) not in (0o600, 0o400) or info.st_nlink != 1):
            raise InvalidConfig("Input files must be caller-owned regular files with mode 0600 or 0400 and no hard links.")
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise InvalidConfig("Input file exceeds its size limit.")
    return path, data


def read_config(path):
    config_path, raw = protected_read(path, 65536)
    try:
        data = tomllib.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeError):
        raise InvalidConfig("Malformed UTF-8 TOML configuration.") from None
    strings = {"disk", "filesystem", "hostname", "username", "timezone", "locale", "keyboard", "password_file"}
    booleans = {"confirm_wipe", "luks", "autologin"}
    optional = {"full_name", "email"}
    if set(data) - (strings | booleans | optional) or (strings | booleans) - set(data):
        raise InvalidConfig("Unknown or missing configuration keys.")
    for key in strings | optional:
        value = data.get(key, "")
        if type(value) is not str or (key in strings and not value) or any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise InvalidConfig("Invalid string field in configuration.")
    if any(type(data[key]) is not bool for key in booleans):
        raise InvalidConfig("Boolean fields require TOML true or false.")
    if not data["confirm_wipe"]:
        raise InvalidConfig("Explicit confirm_wipe = true is required; no disk was changed.")
    if data["autologin"] and not data["luks"]:
        raise InvalidConfig("Autologin requires LUKS encryption.")
    if data["filesystem"] not in {"btrfs", "ext4"}:
        raise InvalidConfig("Filesystem must be btrfs or ext4.")
    if not data["disk"].startswith("/dev/") or not os.path.isabs(data["password_file"]):
        raise InvalidConfig("Disk and password_file must be explicit absolute paths.")
    secret_path, secret = protected_read(data["password_file"], 4096)
    if secret.endswith(b"\n"):
        secret = secret[:-1]
    if not secret or any(c in secret for c in (b"\n", b"\r", b"\0")):
        raise InvalidConfig("Password file must contain one non-empty line.")
    try:
        password = secret.decode("utf-8")
    except UnicodeError:
        raise InvalidConfig("Password must be valid UTF-8.") from None
    # Semantic account/password/platform validation is shared with the TUI in Bash.
    fields = [data["disk"], data["filesystem"], str(data["luks"]).lower(),
              str(data["autologin"]).lower(), data["hostname"], data["username"],
              data.get("full_name", ""), data.get("email", ""), data["timezone"],
              data["locale"], data["keyboard"], password, config_path, secret_path]
    return fields


def main():
    if len(sys.argv) != 2:
        sys.exit("Error: expected one configuration file path.")
    try:
        fields = read_config(sys.argv[1])
    except InvalidConfig as error:
        sys.exit("Error: " + str(error))
    except (OSError, ValueError):
        sys.exit("Error: cannot safely read configuration or password file.")
    # No partial record is emitted on a validation error.
    sys.stdout.buffer.write(b"\0".join(field.encode("utf-8") for field in fields) + b"\0")


if __name__ == "__main__":
    main()
