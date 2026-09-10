#!/usr/bin/env python3
"""Receive QEMU diagnostic archives without extracting untrusted guest content."""

import argparse
import base64
import binascii
import hashlib
import os
from pathlib import Path
import re
import sys
import tempfile

MAX_ARCHIVE = 32 * 1024 * 1024
MAX_STREAM = 128 * 1024 * 1024
HEADER = re.compile(rb"SENSIBLE_DIAGNOSTICS_BEGIN v1 ([0-9a-f]{64}) ([0-9]{1,9})\n")
END = b"SENSIBLE_DIAGNOSTICS_END\n"


def receive(run):
    stream = run / "diagnostics.stream"
    # Snapshot a bounded prefix; another report may be arriving while we read.
    with stream.open("rb") as source:
        data = source.read(MAX_STREAM + 1)
    if len(data) > MAX_STREAM:
        raise ValueError("diagnostic stream exceeds 128 MiB; refusing to process it")
    archives = []
    position = 0
    while position < len(data):
        header = HEADER.match(data, position)
        if not header:
            raise ValueError("invalid or incomplete diagnostic header; retry after export finishes")
        digest = header[1].decode("ascii")
        size = int(header[2])
        if not 0 < size <= MAX_ARCHIVE:
            raise ValueError("invalid diagnostic archive size")
        end = data.find(END, header.end())
        if end < 0:
            raise ValueError("incomplete diagnostic transfer; retry after export finishes")
        encoded = data[header.end():end].replace(b"\n", b"")
        if len(encoded) != 4 * ((size + 2) // 3):
            raise ValueError("diagnostic transfer length mismatch")
        try:
            archive = base64.b64decode(encoded, validate=True)
        except binascii.Error as error:
            raise ValueError("invalid diagnostic base64") from error
        if len(archive) != size or hashlib.sha256(archive).hexdigest() != digest:
            raise ValueError("diagnostic checksum mismatch")
        # Fixed hash-derived names only; never extract guest-controlled paths.
        archives.append((run / f"diagnostics-{digest}.tar.gz", archive))
        position = end + len(END)
    if not archives:
        raise ValueError("no diagnostic bundle received (guest must contain the updated collector)")
    # Validate all frames before publishing any; avoid following existing symlinks.
    for destination, archive in archives:
        fd, temporary = tempfile.mkstemp(prefix=".diagnostics-", dir=run)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(archive)
            os.replace(temporary, destination)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print(destination)
    return [path for path, _ in archives]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_directory", type=Path, help="directory printed by run-qemu.sh")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        receive(args.run_directory)
    except (OSError, ValueError) as error:
        print(f"Cannot collect VM logs: {error}", file=sys.stderr)
        return 1
    print("Archives saved, not extracted. Review logs for identifiers before sharing.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
