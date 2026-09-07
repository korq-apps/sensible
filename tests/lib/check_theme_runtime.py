"""Optional real GTK smoke check; run under Xvfb in a disposable image/container.

Requires the production assets installed under /usr/share, python3-gi,
GTK introspection and the image's icon/SVG dependencies. Does not change settings.
Not part of the dependency-free fixture runner; see tests/README.md.
"""
# Fail before importing GTK or touching a display if validation would be skipped.
if not __debug__:
    raise SystemExit(
        "Error: theme validation requires Python assertions; "
        "unset PYTHONOPTIMIZE and run without -O or -OO."
    )

from pathlib import Path
import argparse
import gi

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--gtk", choices=("3", "4"), default="3")
toolkit = parser.parse_args().gtk
gi.require_version("Gtk", f"{toolkit}.0")
from gi.repository import Gtk


def main():
    if toolkit == "3":
        Gtk.init([])
    else:
        Gtk.init()
    print(f"GTK runtime: {Gtk.get_major_version()}.{Gtk.get_minor_version()}.{Gtk.get_micro_version()}", flush=True)
    themes = ("Qogir", "Qogir-Light", "Qogir-Dark", "Matcha-sea",
              "Matcha-light-sea", "Matcha-dark-sea", "Fluent", "Fluent-Light", "Fluent-Dark",
              "Graphite-Light", "Graphite-Dark")
    for name in themes:
        for variant in (None, "dark"):
            path = Path("/usr/share/themes") / name / f"gtk-{toolkit}.0" / (
                "gtk-dark.css" if variant else "gtk.css")
            errors = []
            provider = Gtk.CssProvider()
            provider.connect("parsing-error", lambda _provider, _section, error: errors.append(error))
            provider.load_from_path(str(path))
            if toolkit == "3":
                fatal = [error for error in errors if error.code != Gtk.CssProviderError.DEPRECATED]
            else:
                fatal = [error for error in errors if not error.matches(
                    Gtk.css_parser_warning_quark(), Gtk.CssParserWarning.DEPRECATED)]
            assert not fatal, f"{name}: CSS parsing errors: {fatal}"
            # Named loading uses GTK's real search path. Compare with the exact
            # payload so a silent fallback to Adwaita cannot pass this check.
            if toolkit == "3":
                named = Gtk.CssProvider.get_named(name, variant)
            else:
                named = Gtk.CssProvider()
                named.load_named(name, variant)
            assert named.to_string() == provider.to_string(), f"{name}: named theme discovery failed"
        print(f"GTK theme loaded: {name}", flush=True)

    if toolkit == "4":
        return  # Icon rendering is exercised by the GTK 3 pass below.

    samples = ("folder", "user-home", "org.gnome.Nautilus", "firefox", "chromium",
               "thunderbird", "libreoffice-writer", "utilities-terminal", "document-open",
               "window-close-symbolic", "audio-volume-muted-symbolic",
               "microphone-sensitivity-muted-symbolic", "microphone-sensitivity-none-symbolic")
    for name in ("Qogir", "Qogir-Light", "Qogir-Dark"):
        icons = Gtk.IconTheme.new()
        icons.set_search_path(["/usr/share/icons"])
        icons.set_custom_theme(name)
        for sample in samples:
            for size, scale in ((16, 1), (32, 2), (64, 1)):
                icon = icons.lookup_icon_for_scale(sample, size, scale, Gtk.IconLookupFlags.FORCE_SIZE)
                assert icon is not None, f"{name}: icon missing: {sample}"
                pixbuf = icon.load_icon()
                assert pixbuf.get_width() > 0, f"{name}: cannot render {sample}"
                if sample in ("folder", "microphone-sensitivity-none-symbolic"):
                    assert f"/icons/{name}/" in icon.get_filename(), f"{name}: own asset not found: {sample}"
        # Exercise real inheritance separately from Qogir's own coverage.
        fallback = Gtk.IconTheme.new()
        fallback.set_search_path(["/usr/share/icons"])
        fallback.set_custom_theme("Papirus")
        own = Path("/usr/share/icons") / name
        inherited = next((icon_name for icon_name in sorted(fallback.list_icons(None))
                          if (info := icons.lookup_icon(icon_name, 32, Gtk.IconLookupFlags.FORCE_SIZE))
                          and info.get_filename()
                          and not Path(info.get_filename()).is_relative_to(own)), None)
        assert inherited is not None, f"{name}: no working fallback found"
        assert icons.load_icon(inherited, 32, Gtk.IconLookupFlags.FORCE_SIZE).get_width() > 0
        print(f"GTK icons loaded: {name}; {len(samples)} names x 3 sizes/scales; fallback {inherited}", flush=True)


if __name__ == "__main__":
    main()
