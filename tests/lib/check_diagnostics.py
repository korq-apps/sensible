#!/usr/bin/env python3
"""No privileged mounts, host probes or real disks; transport and runner fixtures."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


guest = module("guest", "installer/collect-diagnostics.py")
host = module("host", "scripts/collect-vm-logs.py")


def frame(data):
    return (f"SENSIBLE_DIAGNOSTICS_BEGIN v1 {hashlib.sha256(data).hexdigest()} {len(data)}\n".encode()
            + base64.encodebytes(data) + b"SENSIBLE_DIAGNOSTICS_END\n")


class DiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stream = self.root / "diagnostics.stream"

    def test_receive_private_archive_without_extracting(self):
        self.stream.write_bytes(frame(b"untrusted archive content"))
        paths = host.receive(self.root)
        self.assertEqual(paths[0].read_bytes(), b"untrusted archive content")
        self.assertEqual(paths[0].stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(host.receive(self.root)), 1)
        self.assertFalse((self.root / "diagnostics").exists())

    def test_multiple_reports(self):
        self.stream.write_bytes(frame(b"first") + frame(b"second"))
        self.assertEqual(len(host.receive(self.root)), 2)

    def test_reject_bad_frames_without_publishing(self):
        valid = frame(b"sample")
        for data in [b"", valid[:-5], valid.replace(b"c2FtcGxl", b"d2FtcGxl"),
                     valid.replace(b"c2FtcGxl", b"!!!!!!!!"),
                     valid.replace(b" 6\n", b" 99999999\n"),
                     b"SENSIBLE_DIAGNOSTICS_BEGIN v1 ../../oops 6\n",
                     frame(b"first") + valid[:-1]]:
            with self.subTest(data=data):
                self.stream.write_bytes(data)
                with self.assertRaises(ValueError):
                    host.receive(self.root)
                self.assertEqual(list(self.root.glob("*.tar.gz")), [])

    def test_existing_symlink_is_not_followed(self):
        data = b"bundle"
        other = self.root / "unrelated"
        other.write_text("unchanged")
        target = self.root / f"diagnostics-{hashlib.sha256(data).hexdigest()}.tar.gz"
        target.symlink_to(other)
        self.stream.write_bytes(frame(data))
        host.receive(self.root)
        self.assertEqual(other.read_text(), "unchanged")
        self.assertFalse(target.is_symlink())

    def test_probe_records_failure_timeout_missing_tool_and_output_limit(self):
        status, output = guest.probe([sys.executable, "-c", "print('ok')"])
        self.assertEqual(status["returncode"], 0)
        self.assertEqual(output, b"ok\n")
        status, _ = guest.probe([sys.executable, "-c", "raise SystemExit(32)"])
        self.assertEqual(status["returncode"], 32)
        status, _ = guest.probe(["/nonexistent-sensible-tool"])
        self.assertIn("error", status)
        start = time.monotonic()
        status, _ = guest.probe([sys.executable, "-c", "import time; time.sleep(10)"], seconds=0.1)
        self.assertTrue(status["timed_out"])
        self.assertLess(time.monotonic() - start, 2)
        status, output = guest.probe([sys.executable, "-c", "print('x'*10000 + 'FINAL EVIDENCE')"], limit=128)
        self.assertTrue(status["truncated"])
        self.assertEqual(len(output), 128)
        self.assertTrue(output.endswith(b"FINAL EVIDENCE\n"))

    def test_shell_bridge_passes_only_explicit_metadata_and_preserves_failure(self):
        script = r'''
set -euo pipefail
source "$1/installer/lib/diagnostics.sh"
SCRIPT_DIR="$1/installer"
INSTALL_LOG="$2/install.log"
MNT=/mnt
CURRENT_STAGE='formatting and mounting filesystems'
EFI_PART=/dev/vda1
BOOT_PART=/dev/vda2
ROOT_PART=/dev/vda3
TARGET_ROOT=/dev/mapper/cryptroot
FAILED_MOUNT_ARGS=(-o noatime /dev/vda2 /mnt/boot)
USERPASS='DO-NOT-LOG'
timeout() { printf '%s\n' "$@"; return 124; }
capture_install_diagnostics 32
'''
        run = subprocess.run(["bash", "-c", script, "bridge-test", str(ROOT), str(self.root)],
                             capture_output=True, text=True)
        self.assertEqual(run.returncode, 124, run.stderr)
        output = (self.root / "install.log").read_text()
        self.assertIn("--mount-arg=-o\n--mount-arg=noatime", output)
        self.assertIn("--exit-code\n32", output)
        self.assertIn("--device\n/dev/mapper/cryptroot", output)
        self.assertNotIn("DO-NOT-LOG", output)

    def test_collector_allowlist_order_and_export_failure(self):
        args = argparse.Namespace(output=str(self.root), log="/test/install.log", stage="formatting",
                                  exit_code=32, target="/mnt", device=["/dev/vda2"],
                                  boot_device="/dev/vda2", mount_arg=["-o", "noatime", "/dev/vda2", "/mnt/boot"])
        calls = []

        def fake_probe(argv, **kwargs):
            calls.append(argv)
            return {"argv": argv, "returncode": 0}, b"fixture evidence\n"

        old_umask = os.umask(0o077)
        self.addCleanup(os.umask, old_umask)
        with patch.object(guest, "probe", side_effect=fake_probe), \
                patch.object(guest, "export", side_effect=TimeoutError("blocked")):
            archive = guest.collect(args)
        self.assertEqual(calls[0][0], "dmesg")
        direct = next(i for i, argv in enumerate(calls) if "-p" in argv)
        udev = next(i for i, argv in enumerate(calls) if argv[0] == "udevadm")
        self.assertLess(udev, direct)
        with tarfile.open(archive) as bundle:
            report = json.load(bundle.extractfile("diagnostics/report.json"))
            self.assertEqual(report["failed_mount_argv"], args.mount_arg)
            self.assertEqual(report["exit_code"], 32)
            self.assertFalse(any("answers" in name or "shadow" in name for name in bundle.getnames()))
        self.assertEqual(archive.stat().st_mode & 0o777, 0o600)
        self.assertFalse(any(argv[0] in ("mount", "fsck", "udevadm") and
                                 any(word in argv for word in ("--bind", "settle", "trigger")) for argv in calls))

    def test_export_stream_roundtrip(self):
        archive = self.root / "fixture.tar.gz"
        archive.write_bytes(os.urandom(100000))
        fifo = self.root / "port"
        os.mkfifo(fifo)
        # Opening RDWR keeps the read end ready without a blocking open.
        reader = os.open(fifo, os.O_RDWR)
        received = bytearray()

        def drain():
            while not received.endswith(host.END):
                received.extend(os.read(reader, 4096))

        thread = threading.Thread(target=drain, daemon=True)
        thread.start()
        try:
            guest.export(archive, str(fifo), seconds=2)
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
        finally:
            os.close(reader)
        self.stream.write_bytes(received)
        self.assertEqual(host.receive(self.root)[0].read_bytes(), archive.read_bytes())

    def test_export_blocked_channel_times_out(self):
        archive = self.root / "large.tar.gz"
        archive.write_bytes(os.urandom(100000))
        fifo = self.root / "port"
        os.mkfifo(fifo)
        reader = os.open(fifo, os.O_RDWR)
        try:
            with self.assertRaises(TimeoutError):
                guest.export(archive, str(fifo), seconds=0.1)
        finally:
            os.close(reader)

    def test_runner_logging_installed_boot_and_persistent_vars(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        qemu = bin_dir / "qemu-system-x86_64"
        qemu.write_text("#!/bin/bash\nif [ \"${1:-}\" = --version ]; then echo fixture-qemu; exit 0; fi\nprintf '%s\\n' \"$@\" > \"$ARGS_FILE\"\necho qemu-fixture >&2\nexit \"${QEMU_FIXTURE_RC:-0}\"\n")
        qemu.chmod(0o755)
        iso, disk = self.root / "image.iso", self.root / "disk.qcow2"
        code, variables = self.root / "OVMF_CODE.4m.fd", self.root / "OVMF_VARS.4m.fd"
        for path in [iso, disk, code, variables]:
            path.write_text("fixture")
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
               "QEMU_OVMF_CODE": str(code), "QEMU_LOG_ROOT": str(self.root / "logs"),
               "ARGS_FILE": str(self.root / "args")}
        run = subprocess.run(["bash", str(ROOT / "scripts/run-qemu.sh"), "--offline", str(iso), str(disk)],
                             env=env, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        args = (self.root / "args").read_text().splitlines()
        self.assertIn("virtserialport,chardev=diagnostics,name=org.sensible.diagnostics", args)
        self.assertIn("none", args)
        self.assertIn("-cdrom", args)
        directory = next((self.root / "logs").iterdir())
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertIn(hashlib.sha256(iso.read_bytes()).hexdigest(), (directory / "host.txt").read_text())
        self.assertIn("qemu-fixture", (directory / "qemu.log").read_text())
        vars_copy = Path(str(disk) + ".ovmf-vars.fd")
        vars_copy.write_text("installed boot entries")
        env["QEMU_FIXTURE_RC"] = "7"
        run = subprocess.run(["bash", str(ROOT / "scripts/run-qemu.sh"), "--installed", str(disk)],
                             env=env, capture_output=True, text=True)
        self.assertEqual(run.returncode, 7)
        self.assertNotIn("-cdrom", (self.root / "args").read_text().splitlines())
        self.assertEqual(vars_copy.read_text(), "installed boot entries")
        self.assertEqual(len(list((self.root / "logs").iterdir())), 2)
        run = subprocess.run(["bash", str(ROOT / "scripts/run-qemu.sh"), "--installed", str(self.root / "absent")],
                             env=env, capture_output=True, text=True)
        self.assertNotEqual(run.returncode, 0)

        env.pop("QEMU_FIXTURE_RC")
        git = bin_dir / "git"
        for scenario in ("git-unavailable", "status-failure", "source-archive"):
            with self.subTest(scenario=scenario):
                launcher = ROOT / "scripts/run-qemu.sh"
                if scenario == "source-archive":
                    git.unlink()
                    launcher = self.root / "unpacked/scripts/run-qemu.sh"
                    launcher.parent.mkdir(parents=True)
                    shutil.copyfile(ROOT / "scripts/run-qemu.sh", launcher)
                else:
                    body = "exit 127\n" if scenario == "git-unavailable" else (
                        'if [ "$3" = rev-parse ]; then echo fixture-revision; exit 0; fi\nexit 128\n')
                    git.write_text("#!/bin/bash\n" + body)
                    git.chmod(0o755)
                previous_runs = set((self.root / "logs").iterdir())
                run = subprocess.run(["bash", str(launcher), "--installed", str(disk)],
                                     env=env, capture_output=True, text=True)
                self.assertEqual(run.returncode, 0, run.stderr)
                directory, = set((self.root / "logs").iterdir()) - previous_runs
                metadata = (directory / "host.txt").read_text()
                self.assertIn("Repository status: unavailable", metadata)
                self.assertIn("Repository commit: " + (
                    "fixture-revision" if scenario == "status-failure" else "unavailable"), metadata)
                self.assertIn("qemu-fixture", (directory / "qemu.log").read_text())


if __name__ == "__main__":
    unittest.main()
