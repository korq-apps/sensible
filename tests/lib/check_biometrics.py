"""Offline discovery regression tests, including misleading RGB device names."""

import contextlib
import errno
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
COMMAND = REPO / "tools/biometrics/sensible-biometrics"
sys.path.insert(0, str(COMMAND.parent))
loader = importlib.machinery.SourceFileLoader("biometrics", str(COMMAND))
spec = importlib.util.spec_from_loader(loader.name, loader)
bio = importlib.util.module_from_spec(spec)
loader.exec_module(bio)
import tui  # noqa: E402

ANSI = re.compile(r"\x1b\[[0-9;]*m")
REPORT = {
    "schema_version": 1, "mode": "read_only", "kernel": "6.16.0-fixture",
    "cameras": [
        {"node": "/dev/video0", "name": "Integrated RGB Camera", "usb_id": "04f2:b7d3", "stable_paths": ["/dev/v4l/by-path/pci-camera-0"],
         "capture": True, "formats": ["MJPG", "YUYV"], "ir_candidate": False, "status": "capture"},
        {"node": "/dev/video1", "name": "Integrated RGB Camera", "usb_id": "04f2:b7d3", "stable_paths": [],
         "capture": False, "formats": [], "ir_candidate": False, "status": "not_capture"},
        {"node": "/dev/video2", "name": "Integrated IR Camera", "usb_id": "04f2:b7d3", "stable_paths": ["/dev/v4l/by-path/pci-camera-2"],
         "capture": True, "formats": ["GREY"], "ir_candidate": True, "status": "capture"},
        {"node": "/dev/video4", "name": None, "usb_id": None, "stable_paths": [],
         "capture": None, "formats": [], "ir_candidate": False, "status": "permission_denied"},
    ],
    "face": {"status": "needs_verification", "suggested_device_path": "/dev/v4l/by-path/pci-camera-2",
             "verified_ir": False, "emitter": "unknown"},
    "fingerprint": {"status": "detected", "device_count": 1},
    "pam": {"display_manager": "gdm3", "services": {}, "assessment": "inventory_only"},
    "packages": {"biopass": {"status": "not_installed", "version": None},
                 "howdy": {"status": "unknown", "version": None},
                 "howdy-next": {"status": "installed", "version": "3.4.0-6+sensible1"},
                 "fprintd": {"status": "installed", "version": "1.94.5-4+b1"},
                 "libpam-fprintd": {"status": "installed", "version": "1.94.5-4+b1"}},
    "setup_available": True, "login_activation_available": True,
}


class Tty:
    """Only the attributes Style consults: a terminal with a given encoding."""
    def __init__(self, encoding="utf-8"):
        self.encoding = encoding
    def isatty(self):
        return True


def render(**style):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        bio.print_report(REPORT, tui.Style(**style))
    return out.getvalue()


class PresentationTests(unittest.TestCase):
    def test_piped_or_no_color_output_is_plain_text(self):
        with patch.dict(os.environ, {"TERM": "xterm-256color"}, clear=False):
            os.environ.pop("NO_COLOR", None)
            self.assertFalse(tui.Style(stream=io.StringIO()).color)
            self.assertTrue(tui.Style(stream=Tty()).color)
            self.assertFalse(tui.Style(stream=Tty(encoding=None)).glyphs is tui.GLYPHS["utf8"])
            self.assertIs(tui.Style(stream=Tty("UTF-8")).glyphs, tui.GLYPHS["utf8"])
        with patch.dict(os.environ, {"TERM": "xterm-256color", "NO_COLOR": "1"}):
            self.assertFalse(tui.Style(stream=Tty()).color)
        with patch.dict(os.environ, {"TERM": "dumb"}, clear=False):
            os.environ.pop("NO_COLOR", None)
            self.assertFalse(tui.Style(stream=Tty()).color)
        plain = render(color=False, unicode=False, width=80)
        self.assertNotIn("\x1b", plain)
        self.assertTrue(plain.isascii(), plain)
        for fact in ("/dev/video2", "GREY", "IR candidate", "permission denied", "/dev/v4l/by-path/pci-camera-2",
                     "detected (1 device)", "howdy-next", "3.4.0-6+sensible1", "not installed", "gdm3", "6.16.0-fixture",
                     "authentication behavior has not been tested"):
            self.assertIn(fact, plain)
        self.assertNotIn("IR candidate", plain.split("/dev/video0", 1)[1].split("\n", 1)[0])

    def test_colour_only_adds_escape_codes_around_the_same_text(self):
        colored, plain = render(color=True, unicode=True, width=80), render(color=False, unicode=True, width=80)
        self.assertIn("\x1b[32m", colored)
        self.assertIn("── Cameras ──", colored)
        self.assertIn("● IR candidate", colored)
        self.assertEqual(ANSI.sub("", colored), plain)

    def test_logo_is_the_shipped_ascii_art_or_a_plain_word(self):
        lines = tui.logo_lines()
        self.assertTrue(all(line.isascii() and line.isprintable() for line in lines))
        self.assertLessEqual(max(map(len, lines)), tui.MAX_WIDTH)
        with patch.object(tui, "LOGO_PATHS", (Path("/nonexistent/logo.txt"),)):
            self.assertEqual(tui.logo_lines(), ["Sensible"])
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            handle.write("evil\x1b[31mlogo\n")
        try:
            with patch.object(tui, "LOGO_PATHS", (Path(handle.name),)):
                self.assertEqual(tui.logo_lines(), ["Sensible"])
        finally:
            os.unlink(handle.name)

    def test_step_boxes_stay_aligned_at_any_width(self):
        for width in (30, 40, 64, 120):
            for title in ("Check the camera", "Verify face recognition for this account before enabling login services"):
                out = io.StringIO()
                tui.step(tui.Style(color=True, unicode=True, width=width), 4, 6, title,
                         "Keep this setup window open while the lock screen is tested.", out=out)
                lines = [ANSI.sub("", line) for line in out.getvalue().splitlines() if line]
                self.assertEqual(len({len(line) for line in lines}), 1, (width, title, lines))
                self.assertLessEqual(len(lines[0]), max(width, tui.MIN_WIDTH + 2 * len(tui.GUTTER)))
                self.assertIn("●●●●○○", out.getvalue())
                self.assertIn("Step 4 of 6", out.getvalue())

    def test_messages_wrap_and_keep_glyph_indent(self):
        out = io.StringIO()
        tui.say(tui.Style(color=False, unicode=False, width=40), "word " * 20 + "\n\nsecond paragraph", "warn", out=out)
        lines = out.getvalue().splitlines()
        self.assertTrue(lines[1].startswith("  ! word"))
        self.assertTrue(all(len(line) <= 40 for line in lines))
        self.assertTrue(all(line.startswith("    ") for line in lines[2:] if line))
        self.assertIn("    second paragraph", lines)


class CameraTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sys = self.root / "sys"
        self.dev = self.root / "dev"
        self.results = {}

    def camera(self, number, formats, capture=True, stable=True, name="Integrated RGB Camera: Integrat", error=None):
        key = f"video{number}"
        entry = self.sys / "class/video4linux" / key
        entry.mkdir(parents=True)
        (entry / "name").write_text(name)
        self.dev.mkdir(exist_ok=True)
        (self.dev / key).touch()
        if stable:
            links = self.dev / "v4l/by-path"
            links.mkdir(parents=True, exist_ok=True)
            (links / f"pci-camera-{number}").symlink_to(f"../../{key}")
        self.results[key] = error or {"formats": formats, "capture": capture}

    def discover(self):
        def query(node):
            result = self.results[node.name]
            if isinstance(result, Exception):
                raise result
            return result
        return bio.discover_cameras(self.sys, self.dev, query)

    def test_mono_node_uses_by_path_despite_rgb_name(self):
        self.camera(0, ["MJPG", "YUYV"])
        self.camera(1, [], capture=False)
        self.camera(2, ["GREY"])
        self.camera(3, [], capture=False)
        links = self.dev / "v4l/by-id"
        links.mkdir(parents=True)
        (links / "rgb-index0").symlink_to("../../video0")
        cameras = self.discover()
        self.assertEqual([c["ir_candidate"] for c in cameras], [False, False, True, False])
        choice = bio.camera_selection(cameras)
        self.assertEqual(choice["suggested_device_path"], "/dev/v4l/by-path/pci-camera-2")
        self.assertEqual(choice["status"], "needs_verification")
        self.assertFalse(choice["verified_ir"])
        self.assertEqual(choice["emitter"], "unknown")

    def test_no_rgb_fallback(self):
        self.camera(0, ["YUYV"])
        choice = bio.camera_selection(self.discover())
        self.assertEqual(choice["status"], "no_ir_candidate")
        self.assertIsNone(choice["suggested_device_path"])

    def test_ambiguous_cameras_need_selection(self):
        self.camera(2, ["GREY"])
        self.camera(4, ["Y16 "])
        choice = bio.camera_selection(self.discover())
        self.assertEqual(choice["status"], "ambiguous")
        self.assertIsNone(choice["suggested_device_path"])

    def test_unreadable_peer_prevents_selection(self):
        for code, expected in ((errno.EACCES, "permission_denied"), (errno.ENOENT, "unavailable"),
                               (errno.EBUSY, "busy"), (errno.EIO, "query_failed")):
            with self.subTest(code=code):
                self.results.clear()
                with tempfile.TemporaryDirectory() as root:
                    self.sys, self.dev = Path(root) / "sys", Path(root) / "dev"
                    self.camera(0, [], error=OSError(code, "fixture"))
                    self.camera(2, ["GREY"])
                    cameras = self.discover()
                    self.assertEqual(cameras[0]["status"], expected)
                    choice = bio.camera_selection(cameras)
                    self.assertEqual(choice["status"], "incomplete")
                    self.assertIsNone(choice["suggested_device_path"])

    def test_missing_stable_path_does_not_fall_back_to_video_number(self):
        self.camera(2, ["GREY"], stable=False)
        choice = bio.camera_selection(self.discover())
        self.assertEqual(choice["status"], "missing_stable_path_or_formats")
        self.assertIsNone(choice["suggested_device_path"])

    def test_only_matching_links_and_prefer_by_id(self):
        self.camera(2, ["GREY"])
        links = self.dev / "v4l/by-id"
        links.mkdir(parents=True)
        (links / "broken").symlink_to("../../video99")
        (links / "ir").symlink_to("../../video2")
        paths = self.discover()[0]["stable_paths"]
        self.assertEqual(paths, ["/dev/v4l/by-id/ir", "/dev/v4l/by-path/pci-camera-2"])

    def test_ir_name_is_only_a_hint_and_metadata_is_never_selected(self):
        self.camera(0, ["YUYV"], name="Integrated IR Camera")
        self.camera(1, [], capture=False, name="Integrated IR Camera")
        self.assertEqual([c["ir_candidate"] for c in self.discover()], [True, False])
        self.assertFalse(bio.camera_selection(self.discover())["verified_ir"])

    def test_missing_formats_prevents_suggestion(self):
        self.camera(0, [], name="IR Camera")
        self.assertIsNone(bio.camera_selection(self.discover())["suggested_device_path"])

    def test_no_devices(self):
        self.assertEqual(self.discover(), [])
        self.assertIsNone(bio.camera_selection([])["suggested_device_path"])

    def test_usb_id_from_ancestor_without_serial(self):
        self.camera(0, ["GREY"])
        usb = self.sys / "devices/usb1/1-1"
        interface = usb / "1-1:1.2"
        interface.mkdir(parents=True)
        (usb / "idVendor").write_text("1234\n")
        (usb / "idProduct").write_text("5678\n")
        (usb / "serial").write_text("DO-NOT-EXPORT")
        (self.sys / "class/video4linux/video0/device").symlink_to(interface)
        cameras = self.discover()
        self.assertEqual(cameras[0]["usb_id"], "1234:5678")
        self.assertNotIn("DO-NOT-EXPORT", str(cameras))


class IoctlTests(unittest.TestCase):
    def query(self, capabilities, device_caps, formats=(), error=None):
        calls = []
        def ioctl(fd, request, data, mutate):
            calls.append(request)
            self.assertEqual(fd, 42)
            if request == bio.VIDIOC_QUERYCAP:
                self.assertEqual(len(data), 104)
                struct.pack_into("=II", data, 84, capabilities, device_caps)
            elif request == bio.VIDIOC_ENUM_FMT:
                self.assertEqual(len(data), 64)
                index, buffer_type = struct.unpack_from("=II", data)
                self.assertIn(buffer_type, (1, 9))
                if error:
                    raise OSError(error, "fixture")
                if index >= len(formats):
                    raise OSError(errno.EINVAL, "end")
                data[44:48] = formats[index].encode("ascii")
            else:
                self.fail("Unexpected ioctl; probe must not stream or change controls")
        with patch.object(bio.os, "open", return_value=42) as opened, \
             patch.object(bio.os, "fstat") as fstat, \
             patch.object(bio.os, "close") as closed, \
             patch.object(bio.fcntl, "ioctl", side_effect=ioctl):
            fstat.return_value.st_mode = stat.S_IFCHR
            try:
                return bio.query_video(Path("/dev/video2")), calls
            finally:
                opened.assert_called_once_with(Path("/dev/video2"), bio.os.O_RDONLY | bio.os.O_NONBLOCK | bio.os.O_CLOEXEC)
                closed.assert_called_once_with(42)

    def test_metadata_node_uses_device_caps(self):
        result, calls = self.query(bio.DEVICE_CAPS | bio.VIDEO_CAPTURE, 0x04A00000)
        self.assertEqual(result, {"capture": False, "formats": []})
        self.assertEqual(calls, [bio.VIDIOC_QUERYCAP])

    def test_capture_and_mplane_formats(self):
        for cap in (bio.VIDEO_CAPTURE, bio.VIDEO_CAPTURE_MPLANE):
            with self.subTest(cap=cap):
                result, _ = self.query(bio.DEVICE_CAPS | cap, cap, ["GREY"])
                self.assertEqual(result, {"capture": True, "formats": ["GREY"]})

    def test_legacy_caps(self):
        result, _ = self.query(bio.VIDEO_CAPTURE, 0, ["MJPG", "YUYV"])
        self.assertEqual(result["formats"], ["MJPG", "YUYV"])

    def test_query_error_is_not_end_of_formats(self):
        with self.assertRaises(OSError):
            self.query(bio.DEVICE_CAPS, bio.VIDEO_CAPTURE, error=errno.EIO)


class SystemTests(unittest.TestCase):
    def test_fingerprint_device_count_and_empty(self):
        for paths, status in (([], "none"), (["/net/reactivated/Fprint/Device/0"], "detected")):
            def run(command, **kwargs):
                self.assertEqual(command[-1], "GetDevices")
                self.assertLessEqual(kwargs["timeout"], 5)
                return subprocess.CompletedProcess(command, 0, bio.json.dumps({"type": "ao", "data": [paths]}), "")
            self.assertEqual(bio.fingerprint_status(run), {"status": status, "device_count": len(paths)})

    def test_failed_or_malformed_fprintd_is_unknown(self):
        for response in ("bad json", '{}', '{"type":"ao","data":["wrong"]}', '{"type":"ao","data":[[42]]}'):
            self.assertEqual(bio.fingerprint_status(lambda *a, **k: subprocess.CompletedProcess([], 0, response))["status"], "unknown")
        self.assertEqual(bio.fingerprint_status(lambda *a, **k: subprocess.CompletedProcess([], 1, ""))["status"], "unknown")

    def test_fprintd_missing_and_timeout(self):
        for exc, expected in ((FileNotFoundError(), "unavailable"), (subprocess.TimeoutExpired("busctl", 5), "unknown")):
            def run(*args, **kwargs):
                raise exc
            self.assertEqual(bio.fingerprint_status(run)["status"], expected)

    def test_pam_inventory_is_read_only_and_does_not_export_arguments(self):
        with tempfile.TemporaryDirectory() as root:
            etc = Path(root)
            (etc / "pam.d").mkdir()
            content = b"# auth sufficient pam_howdy.so\nauth required pam_fprintd.so private-argument\n"
            path = etc / "pam.d/common-auth"
            path.write_bytes(content)
            report = bio.pam_inventory(etc, etc / "vendor")
            self.assertFalse(report["services"]["common-auth"]["howdy_reference"])
            self.assertTrue(report["services"]["common-auth"]["fingerprint_reference"])
            self.assertNotIn("private-argument", str(report))
            self.assertEqual(path.read_bytes(), content)
            path.write_text("auth sufficient pam_howdy.so\n")
            self.assertTrue(bio.pam_inventory(etc, etc / "vendor")["services"]["common-auth"]["howdy_reference"])

    def test_vendor_pam_and_etc_override(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            etc, vendor = root / "etc", root / "vendor"
            (etc / "pam.d").mkdir(parents=True)
            vendor.mkdir()
            (vendor / "polkit-1").write_text("auth sufficient libbiopass_pam.so\n")
            service = bio.pam_inventory(etc, vendor)["services"]["polkit-1"]
            self.assertEqual(service["source"], "vendor")
            self.assertTrue(service["biopass_reference"])
            (etc / "pam.d/polkit-1").write_text("@include common-auth\n")
            service = bio.pam_inventory(etc, vendor)["services"]["polkit-1"]
            self.assertEqual(service["source"], "etc")
            self.assertFalse(service["biopass_reference"])

    def test_installed_backend_is_distinct_from_pam_activation(self):
        def run(*args, **kwargs):
            return subprocess.CompletedProcess([], 1, "biopass\thold ok installed\t1.4.1\nlibpam-fprintd:amd64\tinstall ok installed\t1.94.5-4+b1\nhowdy\tdeinstall ok config-files\t2.6.1\n")
        packages = bio.package_inventory(run)
        self.assertEqual(packages["biopass"]["status"], "installed")
        self.assertEqual(packages["libpam-fprintd"]["status"], "installed")
        self.assertEqual(packages["howdy"]["status"], "not_installed")
        self.assertEqual(packages["howdy-next"]["status"], "unknown")

    def test_cli_has_no_login_activation_command(self):
        result = subprocess.run(["python3", str(COMMAND), "activate-login"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid choice", result.stderr)


if __name__ == "__main__":
    unittest.main()
