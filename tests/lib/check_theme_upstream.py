"""Compare Matcha's staged GNOME files with a separate upstream installation.

Read-only. Run upstream install.sh only in a disposable container, then pass
its destination and the staged image's usr/share/themes as the two arguments.
GTK 3 CSS is compiled/adapted by Sensible; all other GNOME files must match.
"""
if not __debug__:
    raise SystemExit(
        "Error: theme validation requires Python assertions; "
        "unset PYTHONOPTIMIZE and run without -O or -OO."
    )

from pathlib import Path
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("upstream", type=Path)
parser.add_argument("staged", type=Path)
args = parser.parse_args()
for name in ("Matcha-sea", "Matcha-light-sea", "Matcha-dark-sea"):
    checked = 0
    for component in ("gtk-3.0", "gtk-4.0", "gnome-shell"):
        original = args.upstream / name / component
        assert original.is_dir(), f"missing upstream installation: {original}"
        primary = original / ("gnome-shell.css" if component == "gnome-shell" else "gtk.css")
        assert primary.is_file() and primary.stat().st_size, f"incomplete upstream installation: {primary}"
        for file in original.rglob("*"):
            target = args.staged / name / component / file.relative_to(original)
            if file.is_symlink():
                assert target.is_symlink() and target.readlink() == file.readlink(), target
            elif file.is_dir():
                assert target.is_dir(), target
            else:
                assert target.is_file(), target
                if component != "gtk-3.0" or file.suffix != ".css":
                    assert target.read_bytes() == file.read_bytes(), f"differs from upstream: {target}"
            checked += 1
    print(f"Upstream GNOME component parity: {name}, {checked} paths", flush=True)
