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
    for mode in ("Light", "Dark"):
        graphite[f"src/main/gtk-4.0/gtk-{mode}.scss"] = 'window { background: url("assets/asset.svg"); }'
        graphite[f"src/main/gnome-shell/gnome-shell-{mode}.scss"] = 'stage { background: url("assets/test.svg"); }'
        graphite[f"src/assets/gnome-shell/background-{mode}.png"] = "png"
    graphite["src/assets/gnome-shell/scalable/test.svg"] = "svg"
    graphite["src/main/gnome-shell/pad-osd.css"] = "/* fixture */"
    graphite["src/sass/gnome-shell/_common.scss"] = "/* widgets/40-0 */\n/* extensions/40-0 */"
    for path in ("common-assets/test.svg", "common-assets/no-events.svg", "common-assets/process-working.svg",
                 "common-assets/no-notifications.svg", "assets/test.svg", "assets-Dark/test.svg", "theme/test.svg"):
        graphite[f"src/assets/gnome-shell/{path}"] = "svg"
    if problem == "license":
        del graphite["LICENSE"]
    if problem == "traversal":
        graphite["../escaped"] = "unsafe"
    if problem == "css-asset":
        graphite["src/main/gtk-3.0/gtk-Light.scss"] = 'stage { background: url("missing.png"); }'
    pins.update(MARBLE_COMMIT="marble", GRAPHITE_COMMIT="graphite",
                QOGIR_COMMIT="qogir", QOGIR_ICONS_COMMIT="icons",
                MATCHA_COMMIT="matcha", FLUENT_COMMIT="fluent")
    bundles = [("marble-marble.tar.gz", "MARBLE_TARBALL_SHA256", marble),
               ("graphite-graphite.tar.gz", "GRAPHITE_TARBALL_SHA256", graphite)]
    qogir = {"COPYING": "Qogir license", "src/_sass/_tweaks.scss": "/* fixture */",
             "src/gtk/assets/assets/asset.png": "png",
             "src/gtk/assets/assets-common/extra.png": "png",
             "src/gtk/assets/assets-common/check-symbolic.svg": "svg",
             "src/gtk/assets/assets-common/check-symbolic@2.svg": "svg",
             "src/gtk/assets/logos/logo-.svg": "svg", "src/gtk/assets/logos/logo@2-.svg": "svg"}
    matcha = {"LICENSE": "Matcha license", "src/gtk/assets-sea/asset.png": "png"}
    fluent = {"COPYING": "Fluent license", "src/_sass/_tweaks.scss": "/* fixture */",
              "src/gtk/assets/asset.png": "png",
              "src/gtk/scalable/asset.svg": "svg"}
    for mode in ("", "-Light", "-Dark"):
        css = 'window { background-image: url("assets/asset.png"); }\n'
        qogir[f"src/gtk/theme-3.0/gtk{mode}.scss"] = css + (
            '.content-view.document-page { border-image: url("assets/thumbnail-frame.png") 3 3 6 4; }\n'
            'headerbar:not(.titlebar).flat button.titlebutton.close { '
            'background-image: -gtk-scaled(url("assets/titlebutton-close.png"), '
            'url("assets/titlebutton-close@2.png")); }')
        matcha[f"src/gtk/gtk-3.0/gtk{mode.lower()}-sea.scss"] = css
        fluent[f"src/gtk/3.0/gtk{mode}.scss"] = css
        qogir[f"src/gtk/theme-4.0/gtk{mode}.scss"] = css + (
            'check { background: url("assets/scalable/check-symbolic.svg"); }')
        matcha[f"src/gtk/gtk-4.0/gtk{mode.lower()}-sea.css"] = css + (
            'cursor-handle { background: url("assets/text-select-start.png"); }')
        fluent[f"src/gtk/4.0/gtk{mode}.scss"] = css
        suffix = "-Dark" if mode == "-Dark" else ""
        qogir[f"src/gtk/assets/thumbnail{suffix}.png"] = "png"
        matcha[f"src/gtk/thumbnail{suffix.lower()}-sea.png"] = "png"
        fluent[f"src/gtk/thumbnail{suffix}.png"] = "png"
    for bundle in (qogir, matcha, fluent):
        for path in ("pad-osd.css", "icons/test.svg", "common-assets/test.svg", "common-assets/no-events.svg",
                     "common-assets/process-working.svg", "common-assets/no-notifications.svg"):
            bundle[f"src/gnome-shell/{path}"] = "/* fixture */" if path.endswith(".css") else "svg"
    shell_css = 'stage { background: url("assets/test.svg"); }'
    for dark in ("", "-Dark"):
        qogir[f"src/gnome-shell/theme-48-0/gnome-shell{dark}.css"] = shell_css
        qogir[f"src/gnome-shell/assets/assets{dark}/test.svg"] = "svg"
        matcha[f"src/gnome-shell/48/gnome-shell{dark.lower()}-sea.css"] = shell_css
        matcha[f"src/gnome-shell/assets{dark.lower()}/test.svg"] = "svg"
        matcha[f"src/gnome-shell/theme-assets/toggle-on-sea{dark.lower()}.svg"] = "svg"
        for kind in ("", "buttons/", "default/", "activities/"):
            filename = "activities-default.svg" if kind == "activities/" else "test.svg"
            fluent[f"src/gnome-shell/assets{dark}/{kind}{filename}"] = "svg"
    for mode in ("", "-Light", "-Dark"):
        fluent[f"src/gnome-shell/shell-48-0/gnome-shell{mode}.css"] = shell_css
    fluent["src/gnome-shell/theme/test.svg"] = "svg"
    for path in ("assets/background.jpg", "assets/calendar-today.svg", "logos/logo-qogir.svg"):
        qogir[f"src/gnome-shell/{path}"] = "svg"
    for path in ("test.svg", "theme-assets/checkbox-sea.svg", "theme-assets/more-results-sea.svg"):
        matcha[f"src/gnome-shell/{path}"] = "svg"
    icons = {"COPYING": "Icon license", "AUTHORS": "upstream credits",
             "src/index.theme": "[Icon Theme]\nName=Qogir\nInherits=hicolor,breeze\n"
             "Directories=scalable/places,16/actions\n\n"
             "[scalable/places]\nSize=64\nType=Scalable\nMinSize=16\nMaxSize=256\n"
             "[16/actions]\nSize=16\nType=Fixed\n"}
    for size in ("16", "22", "24", "32", "48", "96", "128", "scalable", "symbolic"):
        icons[f"src/{size}/actions/test.svg"] = '<svg fill="#5d656b"/>'
        icons[f"src/{size}/actions/alias.svg"] = '<svg fill="red"/>'
        icons[f"src/{size}/panel/test.svg"] = '<svg fill="#d3dae3"/>'
        icons[f"links/{size}/actions/alias.svg"] = ("symlink", "test.svg")
    icons["src/scalable/places/folder.svg"] = "svg"
    icons["src/symbolic/status/audio-input-microphone-muted-symbolic.svg"] = "svg"
    icons["links/symbolic/status/microphone-sensitivity-muted-symbolic.svg"] = (
        "symlink", "audio-input-microphone-symbolic.svg")
    icons["links/symbolic/status/microphone-sensitivity-none-symbolic.svg"] = (
        "symlink", "microphone-sensitivity-muted-symbolic.svg")
    if problem == "replacement-license":
        del qogir["COPYING"]
    if problem == "replacement-asset":
        del qogir["src/gtk/assets/logos/logo-.svg"]
    if problem == "replacement-css":
        qogir["src/gtk/theme-3.0/gtk.scss"] += 'entry { background: url("absent.svg"); }'
    if problem == "gtk4-source":
        del fluent["src/gtk/4.0/gtk-Dark.scss"]
    if problem == "gtk4-asset":
        fluent["src/gtk/4.0/gtk.scss"] += 'entry { background: url("absent-gtk4.svg"); }'
    if problem == "matcha-gtk4-source":
        del matcha["src/gtk/gtk-4.0/gtk-dark-sea.css"]
    if problem == "matcha-gtk4-unknown-asset":
        matcha["src/gtk/gtk-4.0/gtk-sea.css"] += 'entry { background: url("unknown.svg"); }'
    if problem == "matcha-gtk4-escaping-known":
        matcha["src/gtk/assets-sea/text-select-start.png"] = ("symlink", "../../../LICENSE")
    if problem == "shell-source":
        del matcha["src/gnome-shell/48/gnome-shell-dark-sea.css"]
    if problem == "shell-asset":
        del qogir["src/gnome-shell/assets/calendar-today.svg"]
    if problem == "icon-index":
        del icons["src/index.theme"]
    if problem == "icon-index-invalid":
        icons["src/index.theme"] = "[Icon Theme]\nName=Qogir\nInherits=hicolor\n"
    if problem == "icon-directory":
        icons["src/index.theme"] = icons["src/index.theme"].replace("16/actions", "missing")
    if problem == "icon-link":
        icons["links/16/actions/alias.svg"] = ("symlink", "../../../../COPYING")
    if problem == "icon-dangling":
        icons["links/16/actions/alias.svg"] = ("symlink", "missing.svg")
    bundles += [("Qogir-theme-qogir.tar.gz", "QOGIR_TARBALL_SHA256", qogir),
                ("Qogir-icon-theme-icons.tar.gz", "QOGIR_ICONS_TARBALL_SHA256", icons),
                ("Matcha-gtk-theme-matcha.tar.gz", "MATCHA_TARBALL_SHA256", matcha),
                ("Fluent-gtk-theme-fluent.tar.gz", "FLUENT_TARBALL_SHA256", fluent)]
    archives = []
    for filename, key, members in bundles:
        archive = root / "live/local/pins" / filename
        with tarfile.open(archive, "w:gz") as bundle:
            for name, content in members.items():
                if isinstance(content, tuple):
                    info = tarfile.TarInfo("root/" + name)
                    info.type = tarfile.SYMTYPE
                    info.linkname = content[1]
                    bundle.addfile(info)
                    continue
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
