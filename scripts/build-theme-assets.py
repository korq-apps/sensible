#!/usr/bin/env python3
"""Build selected components from verified theme archives into an image root.

Invoked by stage-themes.sh, never on first login. Upstream installers can change
GDM, application launchers or user settings, so reproduce their GNOME component
layout without running them on the host. Compile Sass or retain upstream CSS as
appropriate, and use Marble's build API. No host desktop settings are changed.
"""
from pathlib import Path
import configparser
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlsplit


GTK_THEMES = ("Qogir", "Qogir-Light", "Qogir-Dark",
              "Matcha-sea", "Matcha-light-sea", "Matcha-dark-sea",
              "Fluent", "Fluent-Light", "Fluent-Dark")
ICON_THEMES = ("Qogir", "Qogir-Light", "Qogir-Dark")
# Present in the pinned upstream Matcha GTK 4 CSS and its manual installation.
# These references do not establish that the theme is unusable. Keep the CSS;
# report this exact, reviewed set while still rejecting new packaging omissions.
MATCHA_GTK4_MISSING = {
    *(f"assets/{base}{state}{dark}{scale}.png"
      for base in ("text-select-start", "text-select-end", "slider-horz-scale-has-marks-above")
      for state in ("", "-hover", "-active") for dark in ("", "-dark") for scale in ("", "@2")),
    "assets/scalable/check-symbolic.svg", "assets/scalable/check-symbolic@2.svg",
    *(f"assets/titlebutton-restore{state}#.png" for state in ("", "-hover", "-active", "-backdrop")),
}
known_missing_assets = set()


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
                # Resolve installed system paths against the image, never the host.
                asset = (destination / reference[len(installed_prefix):]).resolve()
            elif urlsplit(reference).scheme or reference.startswith("/"):
                raise ValueError(f"unexpected external theme asset in {css}: {reference}")
            else:
                asset = (css.parent / reference).resolve()
            if not asset.is_relative_to(destination.resolve()):
                raise ValueError(f"theme CSS asset escapes the collection: {reference} in {css}")
            if not asset.is_file() or not asset.stat().st_size:
                if (destination.name in ("Matcha-sea", "Matcha-light-sea", "Matcha-dark-sea")
                        and css.parent.name == "gtk-4.0" and reference in MATCHA_GTK4_MISSING):
                    known_missing_assets.add(f"{destination.name}/{css.relative_to(destination)}: {reference}")
                    continue
                raise ValueError(f"theme CSS asset is missing or escapes the collection: {reference} in {css}")


def copy_glob(source, pattern, destination):
    files = list(source.glob(pattern))
    if not files:
        raise ValueError(f"required theme assets are missing: {source}/{pattern}")
    for asset in files:
        shutil.copy2(asset, destination / asset.name, follow_symlinks=False)


def install_shell(source, theme, name, mode):
    """Mirror upstream's GNOME Shell component for its default selected style.

    Qogir/Matcha/Fluent map Shell >=48 (including 50) to their latest 48 layout.
    Install it as an optional choice; do not change GDM or activate it by default.
    """
    src = source / "src"
    shell = theme / "gnome-shell"
    shell.mkdir()
    dark = "-Dark" if mode == "-Dark" else ""
    if name == "Graphite":
        art = src / "assets/gnome-shell"
        styles = src / "main/gnome-shell"
        css = styles / f"gnome-shell{mode}.scss"
    else:
        art = styles = src / "gnome-shell"
        css = {"Qogir": art / f"theme-48-0/gnome-shell{dark}.css",
               "Matcha": art / f"48/gnome-shell{dark.lower()}-sea.css",
               "Fluent": art / f"shell-48-0/gnome-shell{mode}.css"}[name]
    shutil.copytree(art / "common-assets", shell / "assets", symlinks=True)
    shutil.copyfile(styles / "pad-osd.css", shell / "pad-osd.css")
    if name == "Graphite":
        subprocess.run(["sassc", "-M", "-t", "expanded", str(css), str(shell / "gnome-shell.css")], check=True)
        copy_glob(art / f"assets{dark}", "*.svg", shell / "assets")
        copy_glob(art / "theme", "*.svg", shell / "assets")
        shutil.copyfile(art / f"background{mode}.png", shell / "background.png")
        shutil.copytree(art / "scalable", shell / "scalable", symlinks=True)
    else:
        shutil.copyfile(css, shell / "gnome-shell.css")
        if name == "Qogir":
            for asset in ("background.jpg", "calendar-today.svg"):
                shutil.copyfile(art / "assets" / asset, shell / "assets" / asset)
            copy_glob(art / f"assets/assets{dark}", "*.svg", shell / "assets")
            shutil.copyfile(art / "logos/logo-qogir.svg", shell / "assets/activities.svg")
        elif name == "Matcha":
            copy_glob(art, "*.svg", shell)
            copy_glob(art / f"assets{dark.lower()}", "*.svg", shell / "assets")
            for asset in ("checkbox", "more-results", "toggle-on"):
                suffix = dark.lower() if asset == "toggle-on" else ""
                shutil.copyfile(art / f"theme-assets/{asset}-sea{suffix}.svg", shell / f"assets/{asset}.svg")
        else:
            copy_glob(art / f"assets{dark}", "*.svg", shell / "assets")
            copy_glob(art / "theme", "*.svg", shell / "assets")
            copy_glob(art / f"assets{dark}/buttons", "*.svg", shell / "assets")
            copy_glob(art / f"assets{dark}/default", "*.svg", shell / "assets")
            activities_dark = "" if mode == "-Light" else "-Dark"
            shutil.copyfile(art / f"assets{activities_dark}/activities/activities-default.svg", shell / "assets/activities.svg")
            if mode == "-Light":
                shutil.copyfile(art / "assets-Dark/activities/activities-default.svg", shell / "assets/activities-white.svg")
        if name in ("Qogir", "Matcha"):
            shutil.copytree(art / "icons", shell / "icons", symlinks=True)
    if name != "Matcha":
        for asset in ("no-events.svg", "process-working.svg", "no-notifications.svg"):
            (shell / asset).symlink_to(f"assets/{asset}")


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
    common = src / "sass/gnome-shell/_common.scss"
    # Reproduce upstream's Shell >=48 Sass imports.
    (common.parent / "_common-temp.scss").write_text("\n".join(
        line.replace("40-0", "48-0") if "widgets" in line else
        line.replace("40-0", "46-0") if "extensions" in line else line
        for line in common.read_text().splitlines()) + "\n")
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
        gtk4 = theme / "gtk-4.0"
        gtk4.mkdir()
        (gtk4 / "assets").symlink_to("../gtk-3.0/assets")
        (gtk4 / "thumbnail.png").symlink_to("../gtk-3.0/thumbnail.png")
        for variant, output in ((color, "gtk.css"), ("Dark", "gtk-dark.css")):
            subprocess.run(["sassc", "-M", "-t", "expanded",
                            str(src / f"main/gtk-4.0/gtk-{variant}.scss"),
                            str(gtk4 / output)], check=True)
        install_shell(source, theme, "Graphite", f"-{color}")
        # Do not reference unshipped icons/cursors or other desktops.
        (theme / "index.theme").write_text(
            f"[Desktop Entry]\nType=X-GNOME-Metatheme\nName={name}\n\n"
            f"[X-GNOME-Metatheme]\nGtkTheme={name}\n")


def install_gtk_collection(source, destination, name):
    """Install GTK 3/4 and Shell globally, without user or GDM overrides."""
    src = source / "src"
    if name in ("Qogir", "Fluent"):
        shutil.copyfile(src / "_sass/_tweaks.scss", src / "_sass/_tweaks-temp.scss")
    for mode in ("", "-Light", "-Dark"):
        if name == "Matcha":
            theme_name = f"Matcha{mode.lower()}-sea"
            styles = src / "gtk/gtk-3.0"
            css_suffix, dark_suffix = f"{mode.lower()}-sea", "-dark-sea"
            assets = src / "gtk/assets-sea"
            thumbnail = src / f"gtk/thumbnail{'-dark' if mode == '-Dark' else ''}-sea.png"
        elif name == "Qogir":
            theme_name = f"Qogir{mode}"
            styles = src / "gtk/theme-3.0"
            css_suffix, dark_suffix = mode, "-Dark"
            assets = src / "gtk/assets/assets"
            thumbnail = src / f"gtk/assets/thumbnail{'-Dark' if mode == '-Dark' else ''}.png"
        else:
            theme_name = f"Fluent{mode}"
            styles = src / "gtk/3.0"
            css_suffix, dark_suffix = mode, "-Dark"
            assets = src / "gtk/assets"
            thumbnail = src / f"gtk/thumbnail{'-Dark' if mode == '-Dark' else ''}.png"
        theme = destination / theme_name
        gtk = theme / "gtk-3.0"
        gtk.mkdir(parents=True)
        shutil.copytree(assets, gtk / "assets", symlinks=True)
        if name == "Qogir":
            shutil.copytree(src / "gtk/assets/assets-common", gtk / "assets",
                            symlinks=True, dirs_exist_ok=True)
            for logo in ("logo", "logo@2"):
                shutil.copyfile(src / f"gtk/assets/logos/{logo}-.svg", gtk / f"assets/{logo}.svg")
        elif name == "Fluent":
            shutil.copytree(src / "gtk/scalable", gtk / "assets/scalable", symlinks=True)
        shutil.copyfile(thumbnail, gtk / "thumbnail.png")
        for suffix, output in ((css_suffix, "gtk.css"), (dark_suffix, "gtk-dark.css")):
            # Build against the pinned source, not stale precompiled CSS.
            subprocess.run(["sassc", "-M", "-t", "expanded",
                            str(styles / f"gtk{suffix}.scss"), str(gtk / output)], check=True)
            css = gtk / output
            # Qogir/Matcha's legacy Documents frame references an absent PNG.
            # Keep its solid border rather than a broken image.
            adapted = css.read_text().replace(
                'border-image: url("assets/thumbnail-frame.png") 3 3 6 4;',
                'border-image: none;')
            if name == "Qogir":
                # The legacy Kooha override also names absent titlebutton PNGs.
                # Drop only those image-only rules; normal GTK window-control
                # icons and Qogir's general button styling remain in effect.
                adapted = re.sub(
                    r'headerbar:not\(\.titlebar\)\.flat button\.titlebutton\.'
                    r'(?:close|maximize|minimize)(?::(?:backdrop|hover|active))?\s*\{\s*'
                    r'background-image:\s*-gtk-scaled\(url\("assets/titlebutton-[^;]+;\s*\}',
                    '', adapted)
            css.write_text(adapted)
            if not (gtk / output).stat().st_size:
                raise ValueError(f"built theme asset is missing: {gtk / output}")
        gtk4 = theme / "gtk-4.0"
        gtk4.mkdir()
        (gtk4 / "assets").symlink_to("../gtk-3.0/assets")
        (gtk4 / "thumbnail.png").symlink_to("../gtk-3.0/thumbnail.png")
        styles4 = Path(str(styles).replace("3.0", "4.0"))
        for suffix, output in ((css_suffix, "gtk.css"), (dark_suffix, "gtk-dark.css")):
            if name == "Matcha":
                # Match the manual installer: retain upstream's GTK 4 CSS.
                shutil.copyfile(styles4 / f"gtk{suffix}.css", gtk4 / output)
            else:
                subprocess.run(["sassc", "-M", "-t", "expanded",
                                str(styles4 / f"gtk{suffix}.scss"), str(gtk4 / output)], check=True)
            if name == "Qogir":
                # The two checkmark SVGs exist, but not in scalable/.
                css = gtk4 / output
                css.write_text(css.read_text().replace(
                    'assets/scalable/check-symbolic', 'assets/check-symbolic'))
            if not (gtk4 / output).stat().st_size:
                raise ValueError(f"built theme asset is missing: {gtk4 / output}")
        install_shell(source, theme, name, mode)
        icon_name = "Qogir-Dark" if mode == "-Dark" else "Qogir"
        (theme / "index.theme").write_text(
            f"[Desktop Entry]\nType=X-GNOME-Metatheme\nName={theme_name}\n\n"
            f"[X-GNOME-Metatheme]\nGtkTheme={theme_name}\nIconTheme={icon_name}\n")
        validate_css_assets(theme)


def validate_icon_theme(theme):
    parser = configparser.ConfigParser(interpolation=None)
    index = theme / "index.theme"
    if not index.is_file() or not index.stat().st_size:
        raise ValueError(f"icon theme index is missing: {theme.name}")
    parser.read(index)
    if not parser.has_section("Icon Theme") or not parser.has_option("Icon Theme", "Directories"):
        raise ValueError(f"icon theme index is invalid: {theme.name}")
    for directory in parser["Icon Theme"]["Directories"].split(","):
        path = (theme / directory).resolve()
        if not path.is_relative_to(theme.resolve()) or not path.is_dir():
            raise ValueError(f"icon theme directory is missing or escapes its theme: {directory}")
    for asset in theme.rglob("*"):
        resolved = asset.resolve()
        if not resolved.is_relative_to(theme.resolve()) or not resolved.exists():
            raise ValueError(f"icon theme asset is missing or escapes its theme: {asset}")


def install_qogir_icons(source, destination):
    # Keep all app/device/mimetype/symbolic icons, not just palette folder icons.
    # Mirror upstream recoloring before merging its aliases; each variant is
    # self-contained, so it cannot inherit a broken link to an unshipped variant.
    sizes = ("16", "22", "24", "32", "48", "96", "128", "scalable", "symbolic")
    index = source / "src/index.theme"
    if not index.is_file() or not index.stat().st_size:
        raise ValueError("icon theme index is missing: Qogir")
    for name in ICON_THEMES:
        theme = destination / name
        theme.mkdir(parents=True)
        for size in sizes:
            shutil.copytree(source / "src" / size, theme / size, symlinks=True)
        recolor = []
        if name == "Qogir-Light":
            recolor = [f"{size}/panel" for size in ("16", "22", "24")]
            old_color, new_color = "#d3dae3", "#5d656b"
        elif name == "Qogir-Dark":
            recolor = ([f"{size}/actions" for size in ("16", "22", "24", "32")]
                       + [f"{size}/{kind}" for size in ("16", "22", "24") for kind in ("places", "devices")]
                       + ["22/apps"])
            old_color, new_color = "#5d656b", "#d3dae3"
        for directory in recolor:
            for svg in (theme / directory).glob("*.svg"):
                if not svg.is_symlink():
                    svg.write_text(svg.read_text().replace(old_color, new_color))
        for size in sizes:
            aliases = source / "links" / size
            if not aliases.is_dir():
                raise ValueError(f"icon alias directory is missing: {size}")
            for alias in aliases.rglob("*"):
                target = theme / size / alias.relative_to(aliases)
                if not target.parent.resolve().is_relative_to(theme.resolve()):
                    raise ValueError(f"icon alias parent escapes its theme: {alias}")
                if alias.is_dir() and not alias.is_symlink():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    # Upstream aliases intentionally replace some source files.
                    if target.is_file() or target.is_symlink():
                        target.unlink()
                    shutil.copy2(alias, target, follow_symlinks=False)
        for size in sizes[:-1]:
            (theme / f"{size}@2x").symlink_to(size)
        # This pinned alias points at a nonexistent generic microphone icon.
        # Use the shipped muted icon; the 'none' alias then resolves through it.
        muted = theme / "symbolic/status/microphone-sensitivity-muted-symbolic.svg"
        if not muted.is_symlink() or muted.readlink() != Path("audio-input-microphone-symbolic.svg"):
            raise ValueError("Qogir microphone alias changed; review the pinned fix")
        muted.unlink()
        muted.symlink_to("audio-input-microphone-muted-symbolic.svg")
        index_text, names = re.subn(r"^Name=.*$", f"Name={name}", index.read_text(), flags=re.M)
        index_text, inherits = re.subn(r"^Inherits=.*$", "Inherits=Papirus,Adwaita,hicolor",
                                      index_text, flags=re.M)
        if names != 1 or inherits != 1:
            raise ValueError(f"icon theme index lacks unique name/fallbacks: {name}")
        (theme / "index.theme").write_text(index_text)
        for credit in ("COPYING", "AUTHORS"):
            copy_license(source / credit, theme / credit)
        validate_icon_theme(theme)


def main():
    chroot, *archives = map(Path, sys.argv[1:])
    if len(archives) != 6:
        raise ValueError("expected image root and six verified theme archives")
    destination = chroot / "usr/share/themes"
    docs = chroot / "usr/share/doc/sensible-themes"
    destination.mkdir(parents=True, exist_ok=True)
    docs.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sensible-theme-build-") as work:
        work = Path(work)
        marble, graphite, qogir, icons, matcha, fluent = [
            unpack(archive, work / str(index)) for index, archive in enumerate(archives)
        ]
        for source, filename, label in ((marble, "LICENSE", "Marble"), (graphite, "LICENSE", "Graphite"),
                                        (qogir, "COPYING", "Qogir"), (icons, "COPYING", "Qogir-icons"),
                                        (matcha, "LICENSE", "Matcha"), (fluent, "COPYING", "Fluent")):
            copy_license(source / filename, docs / f"{label}.LICENSE")
            if (source / "AUTHORS").is_file():
                copy_license(source / "AUTHORS", docs / f"{label}.AUTHORS")
        build_marble(marble, destination, work / "marble-build")
        build_graphite(graphite, destination)
        for source, name in ((qogir, "Qogir"), (matcha, "Matcha"), (fluent, "Fluent")):
            install_gtk_collection(source, destination, name)
        install_qogir_icons(icons, chroot / "usr/share/icons")
    for name in ("Graphite-Light/gtk-3.0/gtk.css", "Graphite-Dark/gtk-3.0/gtk.css",
                 *(f"Marble-{color}-{mode}/gnome-shell/gnome-shell.css"
                   for color in ("red", "yellow", "green", "blue", "purple", "gray")
                   for mode in ("light", "dark"))):
        if not (destination / name).is_file() or not (destination / name).stat().st_size:
            raise ValueError(f"built theme asset is missing: {name}")
    # Limit the check to our collection; unrelated workspace themes are not ours
    # to validate or remove during edition changes.
    for name in (*GTK_THEMES, "Graphite-Light", "Graphite-Dark",
                 *(f"Marble-{color}-{mode}"
                   for color in ("red", "yellow", "green", "blue", "purple", "gray")
                   for mode in ("light", "dark"))):
        validate_css_assets(destination / name)
    if known_missing_assets:
        (docs / "known-upstream-assets.txt").write_text(
            "Known missing references retained from pinned Matcha GTK 4 CSS.\n"
            "This is not a finding that the whole theme fails to render.\n"
            + "\n".join(sorted(known_missing_assets)) + "\n")
        print("Note: retained known upstream Matcha GTK 4 references; see sensible-themes/known-upstream-assets.txt.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, configparser.Error, tarfile.TarError, subprocess.CalledProcessError) as error:
        sys.exit(f"Error: could not stage the pinned theme collection: {error}")
