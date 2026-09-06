"""Tiny upstream-input doubles; production extraction and build adapter stay real."""
import hashlib
import io
from pathlib import Path
import shutil
import tarfile


def seed_themes(repo, root, pins, binary_dir, problem=None):
    for name in ("stage-themes.sh", "build-theme-assets.py"):
        shutil.copyfile(repo / "scripts" / name, root / "scripts" / name)
    builder = '''from pathlib import Path
from scripts import config
class GnomeShellThemeBuilder:
    def __init__(self, colors): pass
    def build(self): return self
    def prepare(self):
        assert config.gnome_version_override == "50"
    def install(self, hue, name, saturation):
        for mode in ("light", "dark"):
            dest = Path(config.themes_folder) / f"Marble-{name}-{mode}/gnome-shell"
            dest.mkdir(parents=True)
            (dest / "gnome-shell.css").write_text("/* fixture */")
'''
    marble = {"LICENSE": "Marble license", "scripts/__init__.py": "",
              "scripts/config.py": "colors_json = 'fixture'",
              "scripts/install/__init__.py": "", "scripts/utils/__init__.py": "",
              "scripts/utils/theme/__init__.py": "",
              "scripts/utils/theme/gnome_shell_theme_builder.py": builder,
              "scripts/install/colors_definer.py": '''class ColorsDefiner:
    def __init__(self, path):
        self.colors = {name: {"h": 200} for name in ("red", "yellow", "green", "blue", "purple", "gray")}
'''}
    graphite = {"LICENSE": "Graphite license", "src/sass/_tweaks.scss": "/* fixture */",
                "src/assets/gtk/assets/asset.svg": "svg",
                "src/assets/gtk/scalable/asset.svg": "svg",
                "src/assets/gtk/thumbnail.png": "png",
                "src/assets/gtk/thumbnail-Dark.png": "png",
                "src/main/gtk-3.0/gtk-Light.scss": "/* fixture */",
                "src/main/gtk-3.0/gtk-Dark.scss": "/* fixture */"}
    old = {f"gnome-shell/{name}": "fixture" for name in
           ("gnome-shell.css", "overview-wallpaper.png", "login-dialog-frame.png", "gdm-wallpaper.png")}
    old["extension/good-old-shell@mx-2/extension.js"] = "must not ship"
    old["utils/install-gdm-ext.py"] = "must not run"
    if problem == "license":
        del graphite["LICENSE"]
    if problem == "asset":
        del old["gnome-shell/overview-wallpaper.png"]
    if problem == "traversal":
        old["../escaped"] = "unsafe"
    if problem == "css-asset":
        old["gnome-shell/gnome-shell.css"] = 'stage { background-image: url("missing.png"); }'
    pins.update(MARBLE_COMMIT="marble", GRAPHITE_COMMIT="graphite",
                GOOD_OLD_SHELL_VERSION="50.0", GOOD_OLD_SHELL_COMMIT="old")
    bundles = (("marble-marble.tar.gz", "MARBLE_TARBALL_SHA256", marble),
               ("graphite-graphite.tar.gz", "GRAPHITE_TARBALL_SHA256", graphite),
               ("good-old-shell-50.0.tar.gz", "GOOD_OLD_SHELL_TARBALL_SHA256", old),
               ("good-old-shell-source-old.tar.gz", "GOOD_OLD_SHELL_SOURCE_SHA256",
                {"COPYING": "Good-Old-Shell license"}))
    archives = []
    for filename, key, members in bundles:
        archive = root / "live/local/pins" / filename
        with tarfile.open(archive, "w:gz") as bundle:
            for name, content in members.items():
                data = content.encode()
                info = tarfile.TarInfo("root/" + name)
                info.size = len(data)
                bundle.addfile(info, io.BytesIO(data))
        pins[key] = hashlib.sha256(archive.read_bytes()).hexdigest()
        archives.append(archive)
    binary_dir.mkdir(parents=True, exist_ok=True)
    sassc = binary_dir / "sassc"
    sassc.write_text('''#!/bin/sh
[ "${MOCK_SASSC_FAIL:-0}" = 0 ] || exit 67
cp "$4" "$5"
''')
    sassc.chmod(0o755)
    return archives
