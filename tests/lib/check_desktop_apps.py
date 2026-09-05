"""Run production staging/hooks against disposable files and external-tool doubles."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

REPO = Path(sys.argv.pop(1)).resolve()


def write(path, content, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if executable:
        path.chmod(0o755)


class DesktopApps(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sensible-desktop-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}")
        self.env.update(SENSIBLE_VARIANT="gnome", MOCK_FIELD="", MOCK_UFW_FAIL="0")

    def run_script(self, script):
        return subprocess.run(["bash", str(script)], env=self.env,
                              text=True, capture_output=True)

    def seed_pins(self):
        script = self.root / "scripts/fetch-pins.sh"
        script.parent.mkdir(parents=True)
        shutil.copyfile(REPO / "scripts/fetch-pins.sh", script)
        cache = self.root / "live/local/pins"
        cache.mkdir(parents=True)
        pins = {"OH_MY_BASH_COMMIT": "omb", "NERD_FONTS_TAG": "font",
                "LAZYVIM_STARTER_COMMIT": "vim", "LOCALSEND_VERSION": "1.18.2",
                "LOCALSEND_DEB_VERSION": "1.18.2+64"}
        for filename, key in (("oh-my-bash-omb.tar.gz", "OH_MY_BASH_TARBALL_SHA256"),
                              ("lazyvim-starter-vim.tar.gz", "LAZYVIM_STARTER_TARBALL_SHA256")):
            with tarfile.open(cache / filename, "w:gz") as archive:
                members = ["root/fixture"]
                if filename.startswith("oh-my-bash"):
                    members.append("root/themes/powerline-multiline/powerline-multiline.theme.sh")
                for member in members:
                    info = tarfile.TarInfo(member)
                    info.size = 4
                    archive.addfile(info, io.BytesIO(b"test"))
            pins[key] = hashlib.sha256((cache / filename).read_bytes()).hexdigest()
        with zipfile.ZipFile(cache / "JetBrainsMono-font.zip", "w") as archive:
            for face in ("Regular", "Italic", "Bold", "BoldItalic"):
                archive.writestr(f"JetBrainsMonoNerdFont-{face}.ttf", "font fixture")
            archive.writestr("OFL.txt", "license fixture")
        pins["NERD_FONTS_JETBRAINS_MONO_ZIP_SHA256"] = hashlib.sha256(
            (cache / "JetBrainsMono-font.zip").read_bytes()).hexdigest()
        self.deb = cache / "LocalSend-1.18.2-linux-x86-64.deb"
        self.license = cache / "LocalSend-1.18.2-LICENSE"
        for path, key in ((self.deb, "LOCALSEND_DEB_SHA256"),
                          (self.license, "LOCALSEND_LICENSE_SHA256")):
            write(path, "verified fixture " + key)
            pins[key] = hashlib.sha256(path.read_bytes()).hexdigest()
        write(self.root / "live/pins.env", "\n".join(f"{k}={v}" for k, v in pins.items()) + "\n")
        for name in ("omb-bashrc", "gitconfig", "keyd-default.conf"):
            write(self.root / "configs" / name, "fixture\n")
        # Cache hits must not use the network. In corruption tests this double
        # returns untrusted bytes so the real checksum failure path runs.
        write(self.bin / "curl", '#!/bin/sh\nwhile [ "$1" != -o ]; do shift; done\nprintf corrupt > "$2"\n', True)
        write(self.bin / "dpkg-deb", '''#!/bin/sh
if [ "$3" = "$MOCK_FIELD" ]; then echo wrong; exit 0; fi
case "$3" in
 Package) echo localsend;; Version) echo 1.18.2+64;; Architecture) echo amd64;;
 *) exit 88;;
esac
''', True)
        self.staged = self.root / "live/config/packages.chroot/localsend_amd64.deb"
        return script

    def test_pinned_staging_and_cached_rebuild(self):
        script = self.seed_pins()
        # Any network attempt here is a test failure, including unrelated pins.
        write(self.bin / "curl", "#!/bin/sh\nexit 89\n", True)
        for variant in ("gnome", "kde"):
            with self.subTest(variant=variant):
                self.env["SENSIBLE_VARIANT"] = variant
                result = self.run_script(script)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.staged.read_bytes(), self.deb.read_bytes())
                chroot = self.root / "live/config/includes.chroot"
                self.assertEqual((chroot / "usr/share/doc/localsend/copyright").read_bytes(),
                                 self.license.read_bytes())
                self.assertEqual((chroot / "etc/sensible/pins.env").read_bytes(),
                                 (self.root / "live/pins.env").read_bytes())
                self.assertEqual(len(list(self.staged.parent.glob("*.deb"))), 1)

    def test_wrong_package_identity_fails_before_staging(self):
        script = self.seed_pins()
        for field in ("Package", "Version", "Architecture"):
            with self.subTest(field=field):
                self.env["MOCK_FIELD"] = field
                result = self.run_script(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("identity", result.stderr)
                self.assertFalse(self.staged.exists())

    def test_corrupt_package_rejected(self):
        script = self.seed_pins()
        write(self.deb, "damaged cache")
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match the pinned SHA256", result.stderr)
        self.assertFalse(self.staged.exists())
        self.assertFalse(self.deb.exists())

    def test_corrupt_license_rejected(self):
        script = self.seed_pins()
        write(self.license, "damaged cache")
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LocalSend license does not match", result.stderr)

    def hook(self, name):
        # Only redirect filesystem roots; run the actual production control flow.
        source = (REPO / "live/config/hooks/live" / name).read_text()
        for prefix in ("/etc/", "/usr/"):
            source = source.replace(prefix, str(self.root) + prefix)
        script = self.root / name
        write(script, source)
        return script

    def test_build_hook_checks_installed_package_and_assets(self):
        script = self.hook("0250-desktop-apps.hook.chroot")
        write(self.root / "etc/sensible/pins.env", "LOCALSEND_DEB_VERSION=1.18.2+64\n")
        write(self.bin / "dpkg-query", '''#!/bin/sh
case "$2" in
 *Status*) echo "${MOCK_STATUS:-install ok installed}";;
 *Version*) echo "${MOCK_VERSION:-1.18.2+64}";;
 *) exit 88;;
esac
''', True)
        assets = ("usr/bin/localsend_app", "usr/share/applications/localsend_app.desktop",
                  "usr/share/doc/localsend/copyright")
        for asset in assets:
            write(self.root / asset, "fixture", executable=True)
        self.assertEqual(self.run_script(script).returncode, 0)
        for key, value in (("MOCK_VERSION", "old"), ("MOCK_STATUS", "deinstall ok config-files")):
            self.env[key] = value
            self.assertNotEqual(self.run_script(script).returncode, 0)
            del self.env[key]
        for asset in assets:
            with self.subTest(asset=asset):
                path = self.root / asset
                path.unlink()
                self.assertNotEqual(self.run_script(script).returncode, 0)
                write(path, "fixture", executable=True)

    def test_firewall_both_editions_and_failure(self):
        script = self.hook("0300-ufw.hook.chroot")
        log = self.root / "calls"
        self.env["MOCK_LOG"] = str(log)
        write(self.bin / "ufw", '''#!/bin/sh
printf 'ufw %s\n' "$*" >> "$MOCK_LOG"
[ "$MOCK_UFW_FAIL" = 0 ]
''', True)
        write(self.bin / "systemctl", '#!/bin/sh\nprintf "systemctl %s\\n" "$*" >> "$MOCK_LOG"\n', True)
        for variant in ("gnome", "kde", "invalid"):
            write(log, "")
            write(self.root / "etc/sensible/variant", variant)
            config = self.root / "etc/ufw/ufw.conf"
            write(config, "ENABLED=no\n")
            result = self.run_script(script)
            if variant == "invalid":
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(log.read_text(), "")
                self.assertEqual(config.read_text(), "ENABLED=no\n")
                continue
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(log.read_text().splitlines(), [
                "ufw allow 1714:1764/tcp", "ufw allow 1714:1764/udp",
                "ufw allow 53317/tcp", "ufw allow 53317/udp", "systemctl enable ufw.service"])
            self.assertEqual(config.read_text(), "ENABLED=yes\n")
        write(self.root / "etc/sensible/variant", "gnome")
        self.env["MOCK_UFW_FAIL"] = "1"
        self.assertNotEqual(self.run_script(script).returncode, 0)
        self.assertEqual(config.read_text(), "ENABLED=no\n")

    def test_package_edition_ownership(self):
        def packages(relative):
            return {line.split("#", 1)[0].strip() for line in
                    (REPO / relative).read_text().splitlines()} - {""}
        gnome = packages("live/variants/gnome.list")
        kde = packages("live/variants/kde.list")
        self.assertTrue({"shotwell", "gnome-shell-extension-manager", "gnome-tweaks",
                         "gnome-shell-extension-gsconnect", "sshfs", "python3-nautilus"} <= gnome)
        self.assertTrue({"digikam", "gwenview", "kdeconnect", "plasma-systemmonitor"} <= kde)
        self.assertNotIn("kdeconnect", gnome)
        self.assertNotIn("gnome-shell-extension-gsconnect", kde)
        self.assertTrue({"libgtk-3-0t64", "libsecret-1-0", "libegl1", "libgles2",
                         "libegl-mesa0", "libgl1-mesa-dri", "xdg-desktop-portal"} <= packages(
                             "live/config/package-lists/sensible-target.list.chroot"))
        self.assertIn("fonts-powerline", packages(
            "live/config/package-lists/sensible-target.list.chroot"))
        self.assertNotIn("snapper", gnome | kde | packages(
            "live/config/package-lists/sensible-target.list.chroot"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
