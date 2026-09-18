"""Image staging and build-hook checks for the baked face-login stack, with tool doubles.

The real stage-biometrics.sh, build.py check and 0280-biometrics hook run against
disposable roots; dpkg-deb, curl, dpkg-query, howdy and the desktop tools are
doubles. Nothing here proves a package installs in a chroot or that Howdy accepts
the models: those checks run inside the ISO build.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
TOOLS = REPO / "tools/biometrics"
RUNTIME = ("local_ops.py", "pam_ops.py", "pam_session.py", "recover.py", "tui.py", "wizard.py", "sources.json")
MODELS = {"face_detection_yunet_2026may.onnx": b"yunet fixture bytes",
          "face_recognition_sface_2021dec.onnx": b"sface fixture bytes"}
VERSION = json.loads((TOOLS / "sources.json").read_text())["version"]


def write(path, content, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, bytes):
        path.write_bytes(content)
    else:
        path.write_text(content)
    if executable:
        path.chmod(0o755)


def pins(extra=""):
    lines = [f"HOWDY_NEXT_DEB_VERSION={VERSION}"]
    for prefix, filename in (("YUNET", "face_detection_yunet_2026may.onnx"),
                             ("SFACE", "face_recognition_sface_2021dec.onnx")):
        lines += [f"HOWDY_{prefix}_FILE={filename}", f"HOWDY_{prefix}_COMMIT=deadbeef{prefix.lower()}",
                  f"HOWDY_{prefix}_SHA256={hashlib.sha256(MODELS[filename]).hexdigest()}"]
    return "\n".join(lines) + "\n" + extra


class Staging(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sensible-biometrics-image-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", PYTHONDONTWRITEBYTECODE="1")
        # The staging script derives the repository root from its own location, and
        # build.py check compares the manifest with the tool sources next to it.
        shutil.copytree(TOOLS, self.root / "tools/biometrics", ignore=shutil.ignore_patterns("__pycache__"))
        self.script = self.root / "scripts/stage-biometrics.sh"
        write(self.script, (REPO / "scripts/stage-biometrics.sh").read_text(), executable=True)
        shutil.copy(REPO / "packaging/biometrics/sensible-biometrics.desktop",
                    write(self.root / "packaging/biometrics/.keep", "") or self.root / "packaging/biometrics/sensible-biometrics.desktop")
        write(self.root / "live/pins.env", pins())
        self.dist = self.root / ".build/biometrics/dist"
        self.deb = self.dist / f"howdy-next_{VERSION}_amd64.deb"
        write(self.deb, b"fixture package bytes")
        inputs = subprocess.run([sys.executable, "-B", str(self.root / "tools/biometrics/build.py"), "inputs"],
                                text=True, capture_output=True, check=True).stdout.strip()
        self.manifest = {"package": self.deb.name, "sha256": hashlib.sha256(self.deb.read_bytes()).hexdigest(),
                         "sources": json.loads((TOOLS / "sources.json").read_text()), "inputs": inputs}
        self.write_manifest()
        write(self.bin / "dpkg-deb", f'''#!/bin/sh
[ "$1" = -f ] || exit 88
if [ "$3" = "${{MOCK_DEB_FIELD:-}}" ]; then echo wrong; exit 0; fi
case "$3" in
 Package) echo howdy-next;; Version) echo "{VERSION}";; Architecture) echo amd64;;
 *) exit 88;;
esac
''', True)
        write(self.bin / "curl", '''#!/bin/sh
while [ "$1" != -o ]; do shift; done
out="$2"; url="$3"
printf '%s\\n' "$url" >> "${MOCK_CURL_LOG:-/dev/null}"
if [ "${MOCK_CURL_CORRUPT:-0}" = 1 ]; then printf corrupt > "$out"; exit 0; fi
case "$url" in
 *opencv_zoo/raw/deadbeefyunet/models/face_detection_yunet/face_detection_yunet_2026may.onnx) printf 'yunet fixture bytes' > "$out";;
 *opencv_zoo/raw/deadbeefsface/models/face_recognition_sface/face_recognition_sface_2021dec.onnx) printf 'sface fixture bytes' > "$out";;
 *) exit 22;;
esac
''', True)
        self.chroot = self.root / "live/config/includes.chroot"
        self.staged = self.root / "live/config/packages.chroot/howdy-next_amd64.deb"

    def write_manifest(self):
        write(self.dist / "build.json", json.dumps(self.manifest, indent=2) + "\n")

    def run_script(self):
        return subprocess.run(["bash", str(self.script)], env=self.env, text=True, capture_output=True)

    def test_stages_package_models_tool_launcher_and_provenance(self):
        write(self.staged, b"stale staged package")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.staged.read_bytes(), b"fixture package bytes")
        for filename, content in MODELS.items():
            model = self.chroot / "usr/share/howdy/models" / filename
            self.assertEqual(model.read_bytes(), content)
            self.assertEqual(model.stat().st_mode & 0o777, 0o644)
        tool = self.chroot / "usr/local/lib/sensible/biometrics"
        self.assertEqual(sorted(path.name for path in tool.iterdir()), sorted(RUNTIME + ("sensible-biometrics",)))
        self.assertEqual((tool / "sensible-biometrics").stat().st_mode & 0o777, 0o755)
        self.assertEqual((tool / "wizard.py").read_bytes(), (TOOLS / "wizard.py").read_bytes())
        launcher = self.chroot / "usr/local/bin/sensible-biometrics"
        self.assertEqual(os.readlink(launcher), "../lib/sensible/biometrics/sensible-biometrics")
        self.assertTrue(launcher.resolve().is_file())
        self.assertEqual((self.chroot / "usr/share/applications/sensible-biometrics.desktop").read_bytes(),
                         (REPO / "packaging/biometrics/sensible-biometrics.desktop").read_bytes())
        provenance = (self.chroot / "usr/share/doc/sensible-biometrics/sources.txt").read_text()
        self.assertIn(f"package=howdy-next_{VERSION}_amd64.deb", provenance)
        self.assertIn("package_sha256=" + self.manifest["sha256"], provenance)
        self.assertIn(self.manifest["sources"]["howdy"]["url"], provenance)
        for filename, content in MODELS.items():
            self.assertIn(f"model={filename}\tsha256={hashlib.sha256(content).hexdigest()}", provenance)
        # Cached models must not be fetched again, and a re-run replaces nothing silently.
        write(self.bin / "curl", "#!/bin/sh\nexit 89\n", True)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cached copy matches pin", result.stdout)

    def test_package_must_match_current_inputs_manifest_and_checksum(self):
        good = json.dumps(self.manifest)
        cases = {
            "different patches or packaging": lambda: self.manifest.update(inputs="0000000000000000"),
            "different source pins": lambda: self.manifest["sources"].update(version="9.9.9"),
            "checksum does not match": lambda: write(self.deb, b"tampered package bytes"),
            "No package manifest": lambda: (self.dist / "build.json").unlink(),
        }
        for message, corrupt in cases.items():
            with self.subTest(message=message):
                self.manifest = json.loads(good)
                self.write_manifest()
                write(self.deb, b"fixture package bytes")
                write(self.staged, b"stale staged package")
                corrupt()
                if (self.dist / "build.json").exists():
                    self.write_manifest()
                result = self.run_script()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertIn("build-howdy-package.sh", result.stderr)
                self.assertFalse(self.staged.exists())

    def test_identity_and_version_pin_drift_fail_closed(self):
        self.env["MOCK_DEB_FIELD"] = "Version"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("identity", result.stderr)
        self.assertFalse(self.staged.exists())
        self.env["MOCK_DEB_FIELD"] = ""
        write(self.root / "live/pins.env", pins().replace(f"HOWDY_NEXT_DEB_VERSION={VERSION}", "HOWDY_NEXT_DEB_VERSION=1.0-old"))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from tools/biometrics/sources.json", result.stderr)
        self.assertFalse(self.staged.exists())

    def test_model_pin_mismatch_fails_and_drops_the_download(self):
        self.env["MOCK_CURL_CORRUPT"] = "1"
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the pinned SHA256", result.stderr)
        self.assertFalse(list((self.root / "live/local/pins").glob("*.onnx")))
        self.assertFalse((self.chroot / "usr/share/howdy/models/face_detection_yunet_2026may.onnx").exists())


class BuildManifest(unittest.TestCase):
    def test_inputs_key_changes_when_a_packaging_file_is_renamed(self):
        # Filenames shape the package (debian/rules, patch order), so a rename with
        # identical bytes must not leave a cached package acceptable.
        with tempfile.TemporaryDirectory() as temp:
            tools = Path(temp) / "biometrics"
            shutil.copytree(TOOLS, tools, ignore=shutil.ignore_patterns("__pycache__"))
            key = lambda: subprocess.run([sys.executable, "-B", str(tools / "build.py"), "inputs"],
                                         text=True, capture_output=True, check=True).stdout.strip()
            before = key()
            (tools / "debian/rules").rename(tools / "debian/rules.renamed")
            self.assertNotEqual(before, key())
            # Same content back under the original name restores the identity.
            (tools / "debian/rules.renamed").rename(tools / "debian/rules")
            self.assertEqual(before, key())

    def test_check_and_inputs_use_the_real_build_script(self):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            run = lambda *args: subprocess.run([sys.executable, "-B", str(TOOLS / "build.py"), *args, "--work-dir", str(work)],
                                               text=True, capture_output=True)
            key = run("inputs").stdout.strip()
            self.assertRegex(key, r"^[0-9a-f]{16}$")
            self.assertIn("No package manifest", run("check").stderr)
            package = work / "dist" / f"howdy-next_{VERSION}_amd64.deb"
            write(package, b"package")
            write(work / "dist/build.json", json.dumps({
                "package": package.name, "sha256": hashlib.sha256(b"package").hexdigest(),
                "sources": json.loads((TOOLS / "sources.json").read_text()), "inputs": key}))
            result = run("check")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(package))


class Hook(unittest.TestCase):
    """The production hook runs with only its filesystem roots redirected."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sensible-biometrics-hook-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", PYTHONDONTWRITEBYTECODE="1")
        source = (REPO / "live/config/hooks/live/0280-biometrics.hook.chroot").read_text()
        for prefix in ("/etc/", "/usr/"):
            source = source.replace(prefix, str(self.root) + prefix)
        self.hook = self.root / "0280-biometrics.hook.chroot"
        write(self.hook, source, executable=True)
        write(self.root / "etc/sensible/pins.env", pins())
        write(self.root / "etc/howdy/config.ini", "[core]\ndisabled = false\n[video]\ntimeout = 4\ndevice_path = none\n")
        write(self.root / "etc/pam.d/gdm-password", "@include common-auth\n@include common-account\n")
        write(self.root / "usr/bin/howdy", "#!/bin/sh\n", executable=True)
        for asset in ("usr/lib/x86_64-linux-gnu/security/pam_howdy.so", "usr/share/doc/howdy-next/copyright",
                      "usr/share/doc/sensible-biometrics/sources.txt"):
            write(self.root / asset, "fixture")
        shutil.copy(REPO / "packaging/biometrics/sensible-biometrics.desktop",
                    write(self.root / "usr/share/applications/.keep", "") or self.root / "usr/share/applications/sensible-biometrics.desktop")
        self.tool = self.root / "usr/local/lib/sensible/biometrics"
        for name in RUNTIME + ("sensible-biometrics",):
            shutil.copy(TOOLS / name, write(self.tool / ".keep", "") or self.tool / name)
        (self.tool / "sensible-biometrics").chmod(0o755)
        (self.tool / ".keep").unlink()
        launcher = self.root / "usr/local/bin/sensible-biometrics"
        launcher.parent.mkdir(parents=True)
        launcher.symlink_to("../lib/sensible/biometrics/sensible-biometrics")
        for filename, content in MODELS.items():
            model = self.root / "usr/share/howdy/models" / filename
            write(model, content)
            model.chmod(0o644)
        write(self.bin / "dpkg-query", '''#!/bin/sh
case "$2" in
 *Status*) echo "${MOCK_STATUS:-install ok installed}";;
 *Version*) echo "${MOCK_VERSION:-''' + VERSION + '''}";;
 *Architecture*) echo amd64;;
 *) exit 88;;
esac
''', True)
        write(self.bin / "howdy", '''#!/bin/sh
[ "$1" = download-models ] || exit 88
if [ -n "${MOCK_HOWDY_OUTPUT:-}" ]; then printf '%s\\n' "$MOCK_HOWDY_OUTPUT"; fi
printf 'Model already exists: face_detection_yunet_2026may.onnx\\nModel already exists: face_recognition_sface_2021dec.onnx\\n'
exit "${MOCK_HOWDY_RC:-0}"
''', True)
        write(self.bin / "desktop-file-validate", '#!/bin/sh\nexit "${MOCK_DESKTOP_INVALID:-0}"\n', True)
        write(self.bin / "update-desktop-database", '#!/bin/sh\nexit 0\n', True)
        # pamtester must be baked so the guided service test runs offline; the
        # hook checks the package's /usr/bin/pamtester path (redirected here).
        write(self.root / "usr/bin/pamtester", "#!/bin/sh\n", True)

    def run_hook(self):
        return subprocess.run(["sh", str(self.hook)], env=self.env, text=True, capture_output=True)

    def test_complete_inert_stack_passes(self):
        result = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_every_missing_or_drifted_piece_fails_the_build(self):
        model = self.root / "usr/share/howdy/models/face_recognition_sface_2021dec.onnx"
        cases = [
            ("pinned package identity", {"MOCK_VERSION": "3.0.0-1"}, None, None),
            ("pinned package identity", {"MOCK_STATUS": "deinstall ok config-files"}, None, None),
            ("differs from its pin", {}, lambda: model.write_bytes(b"drifted"), lambda: model.write_bytes(MODELS[model.name])),
            ("ownership or mode", {}, lambda: model.chmod(0o664), lambda: model.chmod(0o644)),
            ("did not accept the pinned recognition models", {"MOCK_HOWDY_OUTPUT": "Downloading face_recognition_sface_2021dec.onnx"}, None, None),
            ("did not accept the pinned recognition models", {"MOCK_HOWDY_RC": "1"}, None, None),
            ("already references pam_howdy", {}, lambda: write(self.root / "etc/pam.d/sudo", "auth sufficient pam_howdy.so\n"),
             lambda: (self.root / "etc/pam.d/sudo").unlink()),
            ("unexpected PAM or polkit profile", {}, lambda: write(self.root / "usr/share/pam-configs/howdy", "Name: Howdy\n"),
             lambda: (self.root / "usr/share/pam-configs/howdy").unlink()),
            ("lacks the [video]", {}, lambda: write(self.root / "etc/howdy/config.ini", "[video]\ntimeout = 4\n"),
             lambda: write(self.root / "etc/howdy/config.ini", "[core]\ndisabled = false\n[video]\ntimeout = 4\ndevice_path = none\n")),
            ("does not launch the staged tool", {}, lambda: (self.root / "usr/local/bin/sensible-biometrics").unlink() or
             (self.root / "usr/local/bin/sensible-biometrics").symlink_to("/bin/true"),
             lambda: (self.root / "usr/local/bin/sensible-biometrics").unlink() or
             (self.root / "usr/local/bin/sensible-biometrics").symlink_to("../lib/sensible/biometrics/sensible-biometrics")),
            ("asset is missing", {}, lambda: (self.tool / "tui.py").unlink(), lambda: shutil.copy(TOOLS / "tui.py", self.tool / "tui.py")),
            ("does not run", {}, lambda: (self.tool / "sensible-biometrics").write_text("#!/bin/sh\nexit 3\n"),
             lambda: shutil.copy(TOOLS / "sensible-biometrics", self.tool / "sensible-biometrics")),
            ("pamtester is not installed", {}, lambda: (self.root / "usr/bin/pamtester").unlink(),
             lambda: write(self.root / "usr/bin/pamtester", "#!/bin/sh\n", True)),
        ]
        for message, env, break_it, restore in cases:
            with self.subTest(message=message, env=env):
                run_env = dict(self.env, **env)
                if break_it:
                    break_it()
                try:
                    result = subprocess.run(["sh", str(self.hook)], env=run_env, text=True, capture_output=True)
                finally:
                    if restore:
                        restore()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
        self.env["MOCK_DESKTOP_INVALID"] = "1"
        self.assertNotEqual(self.run_hook().returncode, 0)
        self.env["MOCK_DESKTOP_INVALID"] = "0"
        self.assertEqual(self.run_hook().returncode, 0)


if __name__ == "__main__":
    unittest.main()
