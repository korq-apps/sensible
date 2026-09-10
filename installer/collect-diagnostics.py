#!/usr/bin/env python3
"""Bounded, read-only installer evidence; no answers, environment or key files."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

LIMIT = 1024 * 1024
PORT = "/dev/virtio-ports/org.sensible.diagnostics"


def probe(argv, seconds=2, limit=LIMIT):
    """Drain bounded output without letting a stalled/noisy child block cleanup."""
    result = {"argv": argv}
    output = bytearray()
    try:
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                start_new_session=True, env={"PATH": os.defpath + ":/sbin:/usr/sbin",
                                                             "LC_ALL": "C"})
    except OSError as error:
        return {**result, "error": str(error)}, b""
    deadline = time.monotonic() + seconds
    with selectors.DefaultSelector() as selector:
        selector.register(proc.stdout, selectors.EVENT_READ)
        try:
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    result["timed_out"] = True
                    break
                if not selector.select(left):
                    result["timed_out"] = True
                    break
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    try:
                        proc.wait(timeout=max(0.001, deadline - time.monotonic()))
                    except subprocess.TimeoutExpired:
                        result["timed_out"] = True
                    break
                output.extend(chunk)
                if len(output) > limit:
                    result["truncated"] = True
                    # Keep the most recent evidence, especially late dmesg
                    # entries. The deadline bounds even a continuous producer.
                    del output[:-limit]
        finally:
            # Also terminate descendants retaining the output pipe.
            if proc.returncode is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            proc.wait()
            proc.stdout.close()
    result["returncode"] = proc.returncode
    return result, bytes(output[:limit])


def export(archive, port=PORT, seconds=8):
    data = archive.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    frame = (f"SENSIBLE_DIAGNOSTICS_BEGIN v1 {digest} {len(data)}\n".encode()
             + base64.encodebytes(data) + b"SENSIBLE_DIAGNOSTICS_END\n")
    fd = os.open(port, os.O_WRONLY | os.O_NONBLOCK | os.O_NOCTTY)
    try:
        deadline = time.monotonic() + seconds
        with selectors.DefaultSelector() as selector:
            selector.register(fd, selectors.EVENT_WRITE)
            view = memoryview(frame)
            while view:
                left = deadline - time.monotonic()
                if left <= 0 or not selector.select(left):
                    raise TimeoutError("diagnostic channel did not drain")
                try:
                    view = view[os.write(fd, view):]
                except BlockingIOError:
                    continue
    finally:
        os.close(fd)


def collect(args):
    os.umask(0o077)
    # mkdtemp ensures an existing guest-controlled path is never overwritten.
    directory = Path(tempfile.mkdtemp(prefix="sensible-diagnostics-", dir=args.output))
    report = {"version": 1, "stage": args.stage, "exit_code": args.exit_code,
              "failed_mount_argv": args.mount_arg, "target": args.target,
              "devices": args.device, "probes": []}
    started = time.monotonic()

    def capture(name, argv):
        remaining = 25 - (time.monotonic() - started)
        if remaining <= 0:
            report["probes"].append({"argv": argv, "skipped": "collection deadline"})
            return
        status, data = probe(argv, seconds=min(2, remaining))
        report["probes"].append({"file": name, **status})
        (directory / name).write_bytes(data)

    # Preserve first-failure evidence BEFORE direct device probes or cleanup.
    capture("kernel.txt", ["dmesg", "--color=never"])
    for name, path in [
        ("installer.log", args.log), ("mountinfo.txt", "/proc/self/mountinfo"),
        ("filesystems.txt", "/proc/filesystems"), ("swaps.txt", "/proc/swaps"),
        ("os-release.txt", "/etc/os-release"), ("fstab.txt", "/etc/fstab"),
        ("mount-types.txt", "/etc/filesystems"), ("utab.txt", "/run/mount/utab"),
        ("blkid-cache.txt", "/run/blkid/blkid.tab"),
        ("blkid-cache-etc.txt", "/etc/blkid.tab"), ("mke2fs.conf", "/etc/mke2fs.conf"),
    ]:
        # tail is bounded by probe even for unexpected FIFO/device paths.
        capture(name, ["tail", "-c", str(LIMIT), "--", str(path)])
    capture("mounts.txt", ["findmnt", "--all", "--output", "TARGET,SOURCE,FSTYPE,OPTIONS"])
    capture("devices.txt", ["lsblk", "-o", "NAME,PATH,MAJ:MIN,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINTS"])
    for index, device in enumerate(args.device):
        capture(f"udev-{index}.txt", ["udevadm", "info", "--query=all", "--name", device])
    for name, argv in [("mount-version.txt", ["mount", "--version"]),
                       ("kernel-version.txt", ["uname", "-a"]),
                       ("mkfs-version.txt", ["mke2fs", "-V"]),
                       ("blkid-version.txt", ["blkid", "--version"])]:
        capture(name, argv)
    for index, device in enumerate(args.device):
        capture(f"signature-{index}.txt", ["blkid", "-c", "/dev/null", "-p", "--", device])
    if args.boot_device:
        capture("boot-superblock.txt", ["dumpe2fs", "-h", args.boot_device])
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    # Keep the archive inside the private directory too, including when the
    # caller explicitly uses a shared temporary output parent.
    archive = directory / "bundle.tar.gz"
    members = list(directory.iterdir())
    with tarfile.open(archive, "w:gz") as bundle:
        for member in members:
            bundle.add(member, arcname=f"diagnostics/{member.name}")
    print(f"Diagnostic bundle: {archive}", flush=True)
    try:
        export(archive)
    except FileNotFoundError:
        print("No QEMU diagnostic channel; bundle remains in the live system.", file=sys.stderr)
    except (OSError, TimeoutError) as error:
        print(f"Diagnostic export failed; local bundle retained: {error}", file=sys.stderr)
    else:
        print("Diagnostic bundle exported to the QEMU host.")
    return archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="/run", help="existing private output parent")
    parser.add_argument("--log", default="/var/log/sensible-install.log")
    parser.add_argument("--stage", default="manual collection (possibly after cleanup)")
    parser.add_argument("--exit-code", type=int, default=0)
    parser.add_argument("--target", default="/mnt")
    parser.add_argument("--device", action="append", default=[])
    parser.add_argument("--boot-device")
    parser.add_argument("--mount-arg", action="append", default=[])
    args = parser.parse_args()
    if len(args.device) > 4 or any(not dev.startswith("/dev/") for dev in args.device):
        parser.error("provide at most four /dev/ paths")
    if args.boot_device and not args.boot_device.startswith("/dev/"):
        parser.error("boot device must be a /dev/ path")
    try:
        collect(args)
    except (OSError, tarfile.TarError) as error:
        print(f"Diagnostic collection failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
