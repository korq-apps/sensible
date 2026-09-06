"""Run production staging/hooks against disposable files and external-tool doubles."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from theme_fixtures import seed_themes

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

    def seed_pins(self, include_omb_theme=True, extension_problem=None, theme_problem=None):
        script = self.root / "scripts/fetch-pins.sh"
        script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO / "scripts/fetch-pins.sh", script)
        cache = self.root / "live/local/pins"
        cache.mkdir(parents=True, exist_ok=True)
        pins = {"OH_MY_BASH_COMMIT": "omb", "NERD_FONTS_TAG": "font",
                "LAZYVIM_STARTER_COMMIT": "vim", "LOCALSEND_VERSION": "1.18.2",
                "LOCALSEND_DEB_VERSION": "1.18.2+64"}
        self.theme_archives = seed_themes(REPO, self.root, pins, self.bin, theme_problem)
        for filename, key in (("oh-my-bash-omb.tar.gz", "OH_MY_BASH_TARBALL_SHA256"),
                              ("lazyvim-starter-vim.tar.gz", "LAZYVIM_STARTER_TARBALL_SHA256")):
            with tarfile.open(cache / filename, "w:gz") as archive:
                members = ["root/fixture"]
                if filename.startswith("oh-my-bash") and include_omb_theme:
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
        extensions = (
            ("VITALS", "Vitals@CoreCoding.com", "85", "74743", "LICENSE"),
            ("CLIPBOARD_INDICATOR", "clipboard-indicator@tudmotu.com", "71", "70694", "LICENSE.rst"),
            ("BATTERY_TIME", "batterytime@typeof.pw", "10", "72194", None),
            ("SHOTZY", "shotzy@SamkitJain660.github.io", "8", "71980", "LICENSE"),
        )
        self.extension_uuids = [item[1] for item in extensions]
        self.extension_archives = []
        for key, uuid, version, version_tag, license_file in extensions:
            pins[f"{key}_VERSION"] = version
            pins[f"{key}_VERSION_TAG"] = version_tag
            archive = cache / f"{uuid}-{version_tag}.zip"
            self.extension_archives.append(archive)
            shell_versions = ["49"] if extension_problem == f"{key}-shell" else ["50"]
            metadata = {"uuid": uuid, "version": int(version), "shell-version": shell_versions}
            if extension_problem == f"{key}-version":
                metadata["version"] += 1
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("metadata.json", json.dumps(metadata))
                notice = "// SPDX-License-Identifier: GPL-2.0-or-later\n"
                if extension_problem == f"{key}-notice":
                    notice = "// missing expected notice\n"
                bundle.writestr("extension.js", notice)
                if license_file and extension_problem != f"{key}-license":
                    bundle.writestr(license_file, f"{uuid} license fixture\n")
            pins[f"{key}_ZIP_SHA256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
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
                if variant == "kde":
                    for archive in self.extension_archives + self.theme_archives:
                        archive.unlink()
                result = self.run_script(script)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.staged.read_bytes(), self.deb.read_bytes())
                chroot = self.root / "live/config/includes.chroot"
                themes = chroot / "usr/share/themes"
                self.assertEqual(len(list(themes.iterdir())), 23 if variant == "gnome" else 0)
                icons = chroot / "usr/share/icons"
                self.assertEqual(len(list(icons.iterdir())), 3 if variant == "gnome" else 0)
                if variant == "gnome":
                    for name in ("Qogir", "Qogir-Light", "Qogir-Dark", "Matcha-sea", "Matcha-light-sea",
                                 "Matcha-dark-sea", "Fluent", "Fluent-Light", "Fluent-Dark"):
                        palette = themes / name
                        self.assertIn("assets/test.svg", (palette / "gnome-shell/gnome-shell.css").read_text())
                        self.assertTrue((palette / "gnome-shell/assets/test.svg").is_file())
                        self.assertFalse((palette / "gtk-2.0").exists())
                        self.assertIn("assets/asset.png", (palette / "gtk-4.0/gtk.css").read_text())
                        self.assertTrue((palette / "gtk-4.0/gtk-dark.css").is_file())
                        self.assertTrue((palette / "gtk-4.0/assets/asset.png").is_file())
                        self.assertTrue((palette / "gtk-4.0/thumbnail.png").is_file())
                        self.assertIn("assets/asset.png", (palette / "gtk-3.0/gtk.css").read_text())
                    self.assertIn('text-select-start.png', (themes / 'Matcha-sea/gtk-4.0/gtk.css').read_text())
                    self.assertIn('text-select-start.png', (chroot / 'usr/share/doc/sensible-themes/known-upstream-assets.txt').read_text())
                    self.assertIn('assets/check-symbolic.svg', (themes / 'Qogir/gtk-4.0/gtk.css').read_text())
                    self.assertNotIn('assets/scalable/check-symbolic.svg', (themes / 'Qogir/gtk-4.0/gtk.css').read_text())
                    self.assertNotIn("thumbnail-frame.png", (themes / "Qogir/gtk-3.0/gtk.css").read_text())
                    self.assertNotIn("titlebutton-close.png", (themes / "Qogir/gtk-3.0/gtk.css").read_text())
                    index = (icons / "Qogir/index.theme").read_text()
                    self.assertIn("upstream credits", (icons / "Qogir/AUTHORS").read_text())
                    self.assertIn("Name=Qogir", index)
                    self.assertIn("Inherits=Papirus,Adwaita,hicolor", index)
                    self.assertIn('#d3dae3', (icons / 'Qogir-Dark/16/actions/alias.svg').read_text())
                    self.assertIn('#5d656b', (icons / 'Qogir-Light/16/panel/test.svg').read_text())
                    self.assertTrue((icons / 'Qogir/16@2x/actions/alias.svg').is_file())
                    self.assertTrue((icons / 'Qogir/symbolic/status/microphone-sensitivity-none-symbolic.svg').is_file())
                    for retired in ("Everforest-Light", "Tokyonight-Light", "Osaka-Light", "Catppuccin-Light", "good-old-shell"):
                        self.assertFalse((themes / retired).exists())
                self.assertEqual((themes / "Graphite-Light/gnome-shell/gnome-shell.css").is_file(), variant == "gnome")
                self.assertEqual((themes / "Graphite-Light/gtk-4.0/gtk.css").is_file(), variant == "gnome")
                self.assertFalse((themes / "good-old-shell").exists())
                self.assertEqual((chroot / "usr/share/doc/localsend/copyright").read_bytes(),
                                 self.license.read_bytes())
                self.assertEqual((chroot / "etc/sensible/pins.env").read_bytes(),
                                 (self.root / "live/pins.env").read_bytes())
                self.assertEqual(len(list(self.staged.parent.glob("*.deb"))), 1)
                extension_root = chroot / "usr/share/gnome-shell/extensions"
                docs = chroot / "usr/share/doc/sensible-gnome-extensions"
                if variant == "gnome":
                    self.assertTrue(all((extension_root / uuid / "extension.js").is_file()
                                        for uuid in self.extension_uuids))
                    manifest = (docs / "sources.txt").read_text()
                    self.assertTrue(all(uuid in manifest for uuid in self.extension_uuids))
                    self.assertIn("license=GPL-2.0-or-later", manifest)
                    self.assertIn("license=MIT", manifest)
                    self.assertEqual(len(list(docs.glob("*.LICENSE"))), 3)
                else:
                    self.assertTrue(all(not (extension_root / uuid).exists()
                                        for uuid in self.extension_uuids))
                    self.assertFalse(docs.exists())

    def test_missing_configured_shell_theme_fails_staging(self):
        script = self.seed_pins(include_omb_theme=False)
        # Every cached artifact, including the deliberately incomplete OMB
        # archive, has the checksum recorded by seed_pins(). No download or
        # checksum failure may mask the missing-theme guard under test.
        write(self.bin / "curl", "#!/bin/sh\nexit 89\n", True)
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "pinned oh-my-bash archive lacks the configured powerline-multiline theme",
            result.stderr,
        )
        self.assertFalse(self.staged.exists())

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

    def test_extension_identity_and_license_fail_closed(self):
        for problem in ("SHOTZY-version", "SHOTZY-shell", "VITALS-license",
                        "BATTERY_TIME-notice"):
            with self.subTest(problem=problem):
                script = self.seed_pins(extension_problem=problem)
                write(self.bin / "curl", "#!/bin/sh\nexit 89\n", True)
                result = self.run_script(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(
                    "identity or GNOME Shell compatibility" in result.stderr
                    or "lacks its expected" in result.stderr,
                    result.stderr,
                )
                shutil.rmtree(self.root / "live/config/includes.chroot", ignore_errors=True)

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

    def seed_gnome_profile_hook(self):
        script = self.hook("0260-gnome-profile.hook.chroot")
        write(self.root / "etc/sensible/variant", "gnome\n")
        write(self.bin / "dpkg-query", '''#!/bin/sh
if [ "$3" = "${MOCK_MISSING_PACKAGE:-}" ]; then exit 1; fi
case "$2" in
 *Status*) echo 'install ok installed';;
 *Version*) echo "${MOCK_SHELL_VERSION:-50.4-2}";;
 *) exit 88;;
esac
''', True)
        write(self.bin / "glib-compile-schemas", '''#!/bin/sh
[ "${MOCK_SCHEMA_FAIL:-0}" = 0 ]
''', True)
        for command in ("tesseract", "zbarimg"):
            write(self.bin / command, "#!/bin/sh\nexit 0\n", True)
        uuids = (
            "ubuntu-appindicators@ubuntu.com",
            "gsconnect@andyholmes.github.io",
            "caffeine@patapon.info",
            "dash-to-dock@micxgx.gmail.com",
            "user-theme@gnome-shell-extensions.gcampax.github.com",
            "Vitals@CoreCoding.com",
            "clipboard-indicator@tudmotu.com",
            "batterytime@typeof.pw",
            "shotzy@SamkitJain660.github.io",
        )
        extension_root = self.root / "usr/share/gnome-shell/extensions"
        for uuid in uuids:
            write(extension_root / uuid / "metadata.json",
                  json.dumps({"uuid": uuid, "shell-version": ["50"]}))
            write(extension_root / uuid / "extension.js", "fixture\n")
        write(extension_root / "shotzy@SamkitJain660.github.io/schemas/fixture.gschema.xml",
              "<schemalist/>\n")
        write(self.root / "usr/share/tesseract-ocr/5/tessdata/eng.traineddata", "fixture\n")
        write(self.root / "usr/share/doc/sensible-gnome-extensions/sources.txt", "fixture\n")
        write(self.root / "usr/share/common-licenses/GPL-2", "fixture\n")
        return script

    def test_gnome_profile_hook_validates_and_bridges_tessdata(self):
        script = self.seed_gnome_profile_hook()
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        link = self.root / "usr/share/tessdata"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "tesseract-ocr/5/tessdata")

    def test_gnome_profile_hook_rejects_missing_package_and_shell_jump(self):
        script = self.seed_gnome_profile_hook()
        self.env["MOCK_MISSING_PACKAGE"] = "tesseract-ocr-eng"
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tesseract-ocr-eng", result.stderr)
        del self.env["MOCK_MISSING_PACKAGE"]
        self.env["MOCK_SHELL_VERSION"] = "51.0-1"
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incompatible with GNOME Shell 51", result.stderr)

    def test_gnome_profile_hook_rejects_schema_and_ocr_failures(self):
        script = self.seed_gnome_profile_hook()
        traineddata = self.root / "usr/share/tesseract-ocr/5/tessdata/eng.traineddata"
        traineddata.unlink()
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("English Tesseract data is missing", result.stderr)
        write(traineddata, "fixture\n")
        self.env["MOCK_SCHEMA_FAIL"] = "1"
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not compile GNOME extension schemas", result.stderr)

    def test_gnome_profile_hook_is_inert_on_kde(self):
        script = self.hook("0260-gnome-profile.hook.chroot")
        write(self.root / "etc/sensible/variant", "kde\n")
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "usr/share/tessdata").exists())

    def test_theme_inputs_fail_closed(self):
        for problem, diagnostic in (("license", "theme license is missing"),
                                    ("traversal", "unsafe theme archive member"),
                                    ("css-asset", "theme CSS asset is missing"),
                                    ("replacement-license", "theme license is missing"),
                                    ("replacement-asset", "logo-.svg"),
                                    ("replacement-css", "theme CSS asset is missing"),
                                    ("gtk4-source", "gtk-Dark.scss"),
                                    ("gtk4-asset", "theme CSS asset is missing"),
                                    ("matcha-gtk4-source", "gtk-dark-sea.css"),
                                    ("matcha-gtk4-unknown-asset", "theme CSS asset is missing"),
                                    ("matcha-gtk4-escaping-known", "theme CSS asset escapes"),
                                    ("shell-source", "gnome-shell-dark-sea.css"),
                                    ("shell-asset", "calendar-today.svg"),
                                    ("icon-index", "icon theme index is missing"),
                                    ("icon-index-invalid", "icon theme index is invalid"),
                                    ("icon-directory", "icon theme directory is missing"),
                                    ("icon-link", "icon theme asset is missing or escapes"),
                                    ("icon-dangling", "icon theme asset is missing or escapes")):
            with self.subTest(problem=problem):
                script = self.seed_pins(theme_problem=problem)
                result = self.run_script(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)

    def test_theme_checksum_and_compiler_failures(self):
        script = self.seed_pins()
        self.theme_archives[0].write_text("corrupt")
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Marble does not match the pinned SHA256", result.stderr)
        script = self.seed_pins()
        self.env["MOCK_SASSC_FAIL"] = "1"
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not stage the pinned theme collection", result.stderr)

    def test_replacement_checksums_fail_closed(self):
        for index, name in enumerate(("Qogir-theme", "Qogir-icon-theme", "Matcha-gtk-theme", "Fluent-gtk-theme"), 2):
            with self.subTest(name=name):
                script = self.seed_pins()
                self.theme_archives[index].write_text("corrupt")
                result = self.run_script(script)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{name} does not match the pinned SHA256", result.stderr)

    def test_sources_and_themes_hook(self):
        result = self.run_script(self.seed_pins())
        self.assertEqual(result.returncode, 0, result.stderr)
        shutil.copytree(self.root / "live/config/includes.chroot/usr", self.root / "usr")
        script = self.hook("0270-desktop-sources-and-themes.hook.chroot")
        write(self.bin / "flatpak", '#!/bin/sh\nprintf "%s\\n" "$MOCK_REMOTES"\nexit "${MOCK_FLATPAK_FAIL:-0}"\n', True)
        write(self.bin / "dpkg-query", '''#!/bin/sh
if [ "$3" = "${MOCK_MISSING_PACKAGE:-}" ]; then exit 1; fi
case "$2" in
 *Status*) echo 'install ok installed';;
 *) echo "${MOCK_SHELL_VERSION:-50.2-1}";;
esac
''', True)
        write(self.bin / "gtk-update-icon-cache", '#!/bin/sh\nexit "${MOCK_ICON_CACHE_FAIL:-0}"\n', True)
        for asset in ("themes/Orchis/gtk-3.0/gtk.css", "themes/Orchis/index.theme",
                      *(f"icons/{name}/index.theme" for name in ("Paper", "Papirus", "Papirus-Light", "Papirus-Dark"))):
            write(self.root / "usr/share" / asset, "fixture")
        self.env["MOCK_REMOTES"] = "flathub\thttps://dl.flathub.org/repo/\t"
        for variant in ("gnome", "kde"):
            write(self.root / "etc/sensible/variant", variant)
            result = self.run_script(script)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.env["MOCK_REMOTES"] += "disabled"
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("enabled system Flathub remote is missing", result.stderr)
        self.env["MOCK_REMOTES"] = ""
        self.assertNotEqual(self.run_script(script).returncode, 0)
        self.env["MOCK_REMOTES"] = "flathub\thttps://example.invalid/repo/\t"
        self.assertNotEqual(self.run_script(script).returncode, 0)
        self.env["MOCK_REMOTES"] = "flathub\thttps://dl.flathub.org/repo/\t"
        self.env["MOCK_FLATPAK_FAIL"] = "1"
        result = self.run_script(script)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not initialize the preconfigured Flatpak remotes", result.stderr)
        del self.env["MOCK_FLATPAK_FAIL"]
        write(self.root / "etc/sensible/variant", "gnome")
        for package in ("orchis-gtk-theme", "librsvg2-common"):
            self.env["MOCK_MISSING_PACKAGE"] = package
            result = self.run_script(script)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f"required GNOME appearance package is not installed: {package}", result.stderr)
        del self.env["MOCK_MISSING_PACKAGE"]
        self.env["MOCK_ICON_CACHE_FAIL"] = "1"
        self.assertIn("could not build icon cache", self.run_script(script).stderr)
        del self.env["MOCK_ICON_CACHE_FAIL"]
        self.env["MOCK_SHELL_VERSION"] = "51.0-1"
        result = self.run_script(script)
        self.assertIn("pinned themes require GNOME Shell 50", result.stderr)
        self.assertNotEqual(result.returncode, 0)
        self.env["MOCK_SHELL_VERSION"] = "1:50.2-1"
        asset = self.root / "usr/share/themes/Marble-gray-dark/gnome-shell/gnome-shell.css"
        asset.unlink()
        result = self.run_script(script)
        self.assertIn("desktop theme asset is missing", result.stderr)
        self.assertNotEqual(result.returncode, 0)

    def test_flathub_static_definition(self):
        import base64
        import configparser
        config = configparser.ConfigParser()
        config.read(REPO / "live/config/includes.chroot/usr/share/flatpak/remotes.d/flathub.flatpakrepo")
        remote = config["Flatpak Repo"]
        self.assertEqual(remote["Url"], "https://dl.flathub.org/repo/")
        self.assertGreater(len(base64.b64decode(remote["GPGKey"], validate=True)), 1000)
        self.assertNotEqual(remote.get("Enable", "true"), "false")
        # Exact reviewed upstream definition, including the key (2026-09-06).
        definition = REPO / "live/config/includes.chroot/usr/share/flatpak/remotes.d/flathub.flatpakrepo"
        self.assertEqual(hashlib.sha256(definition.read_bytes()).hexdigest(),
                         "3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a")

    def test_theme_cleanup_preserves_unrelated_assets(self):
        script = self.seed_pins()
        themes = self.root / "live/config/includes.chroot/usr/share/themes"
        write(themes / "Custom/gnome-shell/gnome-shell.css", "keep")
        removed_themes = ("Marble-blue-dark", "good-old-shell", "Everforest-Light", "Tokyonight-Dark",
                          "Osaka-Light", "Catppuccin-Dark", "Qogir", "Matcha-sea", "Fluent")
        for name in removed_themes:
            write(themes / name / "index.theme", "remove")
        icons = self.root / "live/config/includes.chroot/usr/share/icons"
        write(icons / "Custom/index.theme", "keep")
        removed_icons = ("Everforest-Light", "Tokyonight-Dark", "Osaka_Light", "Catppuccin-Mocha", "Qogir")
        for name in removed_icons:
            write(icons / name / "index.theme", "remove")
        self.env["SENSIBLE_VARIANT"] = "kde"
        result = self.run_script(script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((themes / "Custom/gnome-shell/gnome-shell.css").read_text(), "keep")
        for name in removed_themes:
            self.assertFalse((themes / name).exists(), name)
        self.assertEqual((icons / "Custom/index.theme").read_text(), "keep")
        for name in removed_icons:
            self.assertFalse((icons / name).exists(), name)

    def test_manual_describes_optional_origin_and_theme_selection(self):
        manual = (REPO / "manual/applications.html").read_text()
        self.assertIn('id="brave-origin"', manual)
        self.assertIn("curl -fsS https://dl.brave.com/install.sh | FLAVOR=origin sh", manual)
        self.assertIn("not a preinstalled browser", manual)
        self.assertIn('id="themes"', manual)
        self.assertIn("gsettings reset org.gnome.desktop.interface gtk-theme", manual)
        self.assertIn("gsettings reset org.gnome.desktop.interface icon-theme", manual)
        self.assertIn("gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita'", manual)
        self.assertIn("gsettings set org.gnome.desktop.interface icon-theme 'Adwaita'", manual)
        for name in ("Qogir-theme", "Qogir-icon-theme", "Matcha-gtk-theme", "Fluent-gtk-theme"):
            self.assertIn(f"https://github.com/vinceliuice/{name}", manual)
        for name in ("Qogir-Light", "Qogir-Dark", "Matcha-light-sea", "Matcha-dark-sea", "Fluent-Light", "Fluent-Dark"):
            self.assertIn(name, manual)
        self.assertIn("GTK 3, GTK 4 and GNOME Shell components", manual)
        self.assertIn("gsettings set org.gnome.shell.extensions.user-theme name 'Matcha-dark-sea'", manual)
        self.assertIn("sudo cp -a --no-clobber ~/Downloads/MyTheme /usr/share/themes/", manual)
        self.assertIn("~/.local/share/themes/", manual)
        self.assertNotIn("Legacy Applications", manual)
        self.assertNotIn("Fausto-Korpsvart", manual)
        self.assertNotIn("good-old-shell", manual)

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
                         "gnome-shell-extension-gsconnect", "gnome-shell-extension-caffeine",
                         "gnome-shell-extension-dashtodock", "gnome-shell-extension-user-theme",
                         "gir1.2-gtop-2.0", "lm-sensors", "tesseract-ocr",
                         "tesseract-ocr-eng", "zbar-tools", "sshfs", "python3-nautilus"} <= gnome)
        appearance = {"paper-icon-theme", "papirus-icon-theme", "orchis-gtk-theme", "gtk-update-icon-cache", "librsvg2-common"}
        self.assertTrue(appearance <= gnome)
        self.assertFalse(appearance & kde)
        self.assertNotIn("gtk2-engines-murrine", gnome | kde)
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
