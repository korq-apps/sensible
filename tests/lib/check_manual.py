"""Check offline chapter links and package coverage using only the stdlib."""
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.ids = set()
        self.links = []
        self.packages = set()
        self.feed(path.read_text(encoding="utf-8"))

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            assert attrs["id"] not in self.ids, f"duplicate id: {attrs['id']}"
            self.ids.add(attrs["id"])
        self.packages.update(attrs.get("data-packages", "").split())
        for key in ("href", "src"):
            if key in attrs:
                self.links.append((tag, attrs[key]))


def check(manual, repo):
    pages = {path.resolve(): Page(path) for path in manual.glob("*.html")}
    assert len(pages) >= 3, "missing manual chapters"
    for path, page in pages.items():
        for tag, link in page.links:
            url = urlsplit(link)
            if url.scheme or url.netloc:
                assert tag == "a" and url.scheme == "https", f"remote asset: {link}"
                continue  # Optional online references, not required assets.
            target = (path.parent / unquote(url.path)).resolve() if url.path else path
            assert target.is_relative_to(manual.resolve()), f"link escapes manual: {link}"
            assert target.is_file(), f"broken link in {path.name}: {link}"
            if url.fragment:
                assert target in pages and unquote(url.fragment) in pages[target].ids, (
                    f"broken anchor in {path.name}: {link}"
                )

    # Cover the baked default-app section plus each edition's application list.
    # Do not treat inactive helper edits or hardware/boot dependencies as shipped apps.
    common = (repo / "live/config/package-lists/sensible-target.list.chroot").read_text(encoding="utf-8")
    sections = [common.split("# Apps — default set", 1)[1].split("# dconf-cli", 1)[0]]
    for variant in ("gnome", "kde"):
        source = (repo / f"live/variants/{variant}.list").read_text(encoding="utf-8")
        sections.append(source.split("# Applications", 1)[1].split("# Boot stack", 1)[0])
    required = {
        line.strip() for section in sections for line in section.splitlines()
        if re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", line.strip())
    }
    # xdg-utils is launcher plumbing, documented through the manual itself.
    required.discard("xdg-utils")
    covered = set().union(*(page.packages for page in pages.values()))
    assert not required - covered, f"default apps lack guidance: {sorted(required - covered)}"
    print(f"Manual: {len(pages)} pages; links and {len(required)} default packages checked")


if __name__ == "__main__":
    check(Path(sys.argv[1]), Path(sys.argv[2]))
