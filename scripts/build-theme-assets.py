#!/usr/bin/env python3
"""Build selected components from verified theme archives into an image root.

Invoked by stage-themes.sh, never on first login. Upstream installers can change
GDM, application launchers or user settings, so use Marble's build API and compile
Graphite's GTK 3 Sass directly. No host desktop settings are read or written.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit


def unpack(archive, destination):
    if not hasattr(tarfile, "data_filter"):
        raise ValueError("Python's tarfile data filter is required; update the builder's Python")
    with tarfile.open(archive, "r:gz") as bundle:
        # Graphite includes relative asset symlinks. Reject escaping paths and
        # special files; the data filter also checks link destinations.
        members = bundle.getmembers()
        for member in members:
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or not (
                    member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError(f"unsafe theme archive member: {member.name}")
        bundle.extractall(destination, members=members, filter="data")
    roots = list(destination.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise ValueError(f"theme archive must have one top-level directory: {archive}")
    return roots[0]


def copy_license(source, destination):
    if not source.is_file() or not source.stat().st_size:
        raise ValueError(f"theme license is missing: {source}")
    shutil.copyfile(source, destination)


def validate_css_assets(destination):
    for css in destination.rglob("*.css"):
        for reference in re.findall(r"url\(([^)]+)\)", css.read_text()):
            reference = reference.strip().strip("\"'")
            if reference.startswith("resource:///"):
                continue  # Provided by GNOME Shell/GTK, not a theme-local file.
            installed_prefix = f"file:///usr/share/themes/{destination.name}/"
            if reference.startswith(installed_prefix):
                # Good-Old-Shell references two of its shipped PNGs by their
                # final system path. Resolve against the image, never the host.
                asset = (destination / reference[len(installed_prefix):]).resolve()
            elif urlsplit(reference).scheme or reference.startswith("/"):
                raise ValueError(f"unexpected external theme asset in {css}: {reference}")
            else:
                asset = (css.parent / reference).resolve()
            if not asset.is_relative_to(destination.resolve()) or not asset.is_file() or not asset.stat().st_size:
                raise ValueError(f"theme CSS asset is missing or escapes the collection: {reference}")


def build_marble(source, destination, temporary):
    sys.path.insert(0, str(source))
    from scripts import config
    from scripts.install.colors_definer import ColorsDefiner
    from scripts.utils.theme.gnome_shell_theme_builder import GnomeShellThemeBuilder

    config.gnome_version_override = "50"
    config.temp_folder = str(temporary)
    config.themes_folder = str(destination)
    colors = ColorsDefiner(config.colors_json)
    theme = GnomeShellThemeBuilder(colors).build()
    theme.prepare()
    for name in ("red", "yellow", "green", "blue", "purple", "gray"):
        values = colors.colors[name]
        theme.install(values["h"], name, values.get("s"))


def build_graphite(source, destination):
    src = source / "src"
    shutil.copyfile(src / "sass/_tweaks.scss", src / "sass/_tweaks-temp.scss")
    for color in ("Light", "Dark"):
        name = f"Graphite-{color}"
        theme = destination / name
        gtk = theme / "gtk-3.0"
        gtk.mkdir(parents=True)
        shutil.copytree(src / "assets/gtk/assets", gtk / "assets")
        shutil.copytree(src / "assets/gtk/scalable", gtk / "assets/scalable")
        thumbnail = "thumbnail-Dark.png" if color == "Dark" else "thumbnail.png"
        shutil.copyfile(src / "assets/gtk" / thumbnail, gtk / "thumbnail.png")
        for variant, output in ((color, "gtk.css"), ("Dark", "gtk-dark.css")):
            subprocess.run(["sassc", "-M", "-t", "expanded",
                            str(src / f"main/gtk-3.0/gtk-{variant}.scss"),
                            str(gtk / output)], check=True)
        # Do not reference unshipped icons/cursors, other desktops or GTK 4.
        (theme / "index.theme").write_text(
            f"[Desktop Entry]\nType=X-GNOME-Metatheme\nName={name}\n\n"
            f"[X-GNOME-Metatheme]\nGtkTheme={name}\n")


def main():
    chroot, *archives = map(Path, sys.argv[1:])
    if len(archives) != 4:
        raise ValueError("expected image root and four verified theme archives")
    destination = chroot / "usr/share/themes"
    docs = chroot / "usr/share/doc/sensible-themes"
    destination.mkdir(parents=True, exist_ok=True)
    docs.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sensible-theme-build-") as work:
        work = Path(work)
        marble, graphite, old_shell, old_source = [
            unpack(archive, work / str(index)) for index, archive in enumerate(archives)
        ]
        copy_license(marble / "LICENSE", docs / "Marble.LICENSE")
        copy_license(graphite / "LICENSE", docs / "Graphite.LICENSE")
        copy_license(old_source / "COPYING", docs / "Good-Old-Shell.LICENSE")
        build_marble(marble, destination, work / "marble-build")
        build_graphite(graphite, destination)
        # Only session theme data; omit the release's GDM extension and helper.
        old_destination = destination / "good-old-shell/gnome-shell"
        old_destination.mkdir(parents=True)
        for name in ("gnome-shell.css", "overview-wallpaper.png",
                     "login-dialog-frame.png", "gdm-wallpaper.png"):
            source = old_shell / "gnome-shell" / name
            if not source.is_file() or not source.stat().st_size:
                raise ValueError(f"Good-Old-Shell asset is missing: {name}")
            shutil.copyfile(source, old_destination / name)
    for name in ("Graphite-Light/gtk-3.0/gtk.css", "Graphite-Dark/gtk-3.0/gtk.css",
                 *(f"Marble-{color}-{mode}/gnome-shell/gnome-shell.css"
                   for color in ("red", "yellow", "green", "blue", "purple", "gray")
                   for mode in ("light", "dark"))):
        if not (destination / name).is_file() or not (destination / name).stat().st_size:
            raise ValueError(f"built theme asset is missing: {name}")
    # Limit the check to our collection; unrelated workspace themes are not ours
    # to validate or remove during edition changes.
    for name in ("good-old-shell", "Graphite-Light", "Graphite-Dark",
                 *(f"Marble-{color}-{mode}"
                   for color in ("red", "yellow", "green", "blue", "purple", "gray")
                   for mode in ("light", "dark"))):
        validate_css_assets(destination / name)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        sys.exit(f"Error: could not stage the pinned theme collection: {error}")
