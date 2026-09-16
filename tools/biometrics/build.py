#!/usr/bin/env python3
"""Build a local Howdy-next Debian package, independently of the ISO."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

HERE = Path(__file__).resolve().parent
DEFAULT_WORK = HERE.parents[1] / ".build/biometrics"
DEPENDENCIES = [
    "build-essential", "cmake", "ninja-build", "pkgconf", "gettext",
    "debhelper", "dpkg-dev", "patch", "libpam0g-dev", "libevdev-dev",
    "libacl1-dev", "libcurl4-openssl-dev", "libssl-dev", "libinih-dev",
    "libyyjson-dev", "libgtk-3-dev", "libjpeg-dev", "libpng-dev",
    "libtiff-dev", "libwebp-dev", "zlib1g-dev", "pamtester",
]


def run(args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), check=True, umask=0o022, **kwargs)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(pin, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        if digest(target) != pin["sha256"]:
            raise ValueError(f"Cached source checksum mismatch: {target}")
        return target
    temp = None
    try:
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as out:
            temp = Path(out.name)
            with urllib.request.urlopen(pin["url"], timeout=60) as response:
                shutil.copyfileobj(response, out)
        if digest(temp) != pin["sha256"]:
            raise ValueError(f"Source checksum mismatch: {pin['url']}")
        temp.replace(target)
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)
    return target


def secure_build_path(work):
    # Upstream tests validate every component of their fixture paths.
    for directory in reversed((work, *work.parents)):
        directory.mkdir(mode=0o755, exist_ok=True)
        if directory.stat().st_mode & 0o022:
            raise ValueError(f"Build directory must not be group/world writable: {directory}. "
                             "Correct its permissions or choose a secure --work-dir.")


def source_filter(member, destination):
    member = tarfile.data_filter(member, destination)
    if member is not None:
        if member.isdir():
            member = member.replace(mode=0o755)
        elif member.mode is not None:
            member = member.replace(mode=member.mode & ~0o022)
    return member


def inputs_key():
    """Identity of everything that shapes the package: pins, this script, patches, packaging."""
    # rglob + is_file so a future debian/ subdirectory (e.g. debian/source/)
    # is included rather than crashing digest() on a directory.
    debian_files = sorted(p for p in (HERE / "debian").rglob("*") if p.is_file())
    inputs = [HERE / "sources.json", Path(__file__),
              *sorted((HERE / "patches").glob("*.patch")), *debian_files]
    return hashlib.sha256("".join(digest(p) for p in inputs).encode()).hexdigest()[:16]


def check(work):
    """Return the built package when dist matches the current inputs; raise ValueError otherwise."""
    dist = work / "dist"
    manifest_path = dist / "build.json"
    if not manifest_path.is_file():
        raise ValueError(f"No package manifest at {manifest_path}")
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("sources") != json.loads((HERE / "sources.json").read_text()):
        raise ValueError("Package was built from different source pins; rebuild it")
    if manifest.get("inputs") != inputs_key():
        raise ValueError("Package was built from different patches or packaging files; rebuild it")
    package = dist / Path(manifest["package"]).name
    if not package.is_file():
        raise ValueError(f"Package file is missing: {package}")
    if digest(package) != manifest["sha256"]:
        raise ValueError(f"Package checksum does not match its manifest: {package}")
    return package


def prepare(work):
    secure_build_path(work)
    pins = json.loads((HERE / "sources.json").read_text())
    key = inputs_key()
    sources = work / f"source-{key}"
    if (sources / ".prepared").is_file():
        return sources, pins
    if sources.exists():
        raise ValueError(f"Incomplete source directory: {sources}. Move it aside and retry prepare.")
    archives = {name: download(pins[name], work / "downloads" / f"{name}-{pins[name]['sha256']}.tar.gz")
                for name in ("howdy", "opencv")}
    sources.mkdir(mode=0o755)
    for archive in archives.values():
        with tarfile.open(archive) as tar:
            tar.extractall(sources, filter=source_filter)
    howdy = sources / pins["howdy"]["directory"]
    for patch in sorted((HERE / "patches").glob("*.patch")):
        run(["patch", "--batch", "--fuzz=0", "-p1", "-i", patch], cwd=howdy)
    shutil.copytree(HERE / "debian", howdy / "debian")
    (howdy / "debian/rules").chmod(0o755)
    (sources / ".prepared").write_text(key + "\n")
    return sources, pins


def build(work, jobs):
    if os.geteuid() == 0:
        raise ValueError("Build as your normal user; only deps and install use sudo.")
    for command in ("cmake", "ninja", "pkg-config", "dpkg-buildpackage", "dh", "g++"):
        if not shutil.which(command):
            raise ValueError(f"Missing {command}; run sensible-biometrics deps first.")
    for requirement in ("INIReader >= 59", "yyjson >= 0.12.0", "gtk+-3.0", "libevdev", "libacl"):
        run(["pkg-config", "--exists", requirement])
    sources, pins = prepare(work)
    prefix = sources / "opencv-prefix"
    opencv = sources / pins["opencv"]["directory"]
    opencv_build = sources / "opencv-build"
    if not (prefix / ".complete").is_file():
        run([
            "cmake", "-S", opencv, "-B", opencv_build, "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={prefix}",
            "-DCMAKE_INSTALL_LIBDIR=lib", "-DCMAKE_INSTALL_RPATH=/usr/lib/howdy-next",
            "-DBUILD_SHARED_LIBS=ON", "-DBUILD_LIST=core,imgproc,imgcodecs,videoio,highgui,dnn,objdetect",
            "-DBUILD_TESTS=OFF", "-DBUILD_PERF_TESTS=OFF", "-DBUILD_EXAMPLES=OFF",
            "-DBUILD_opencv_apps=OFF", "-DBUILD_opencv_python3=OFF", "-DBUILD_JAVA=OFF",
            "-DWITH_QT=OFF", "-DWITH_GTK=ON", "-DWITH_FFMPEG=OFF", "-DWITH_GSTREAMER=OFF",
            "-DWITH_V4L=ON", "-DWITH_OPENCL=OFF", "-DWITH_IPP=OFF", "-DWITH_ITT=OFF",
            "-DWITH_CUDA=OFF", "-DWITH_1394=OFF", "-DWITH_VTK=OFF",
            "-DWITH_UNIFONT=OFF",
            "-DOPENCV_GENERATE_PKGCONFIG=ON",
        ])
        run(["cmake", "--build", opencv_build, "--parallel", jobs])
        run(["cmake", "--install", opencv_build])
        (prefix / ".complete").write_text("OpenCV 5\n")
    env = dict(os.environ, HOWDY_DEPS_PREFIX=str(prefix), HOWDY_OPENCV_LICENSE=str(opencv / "LICENSE"),
               DEB_BUILD_OPTIONS=f"parallel={jobs}")
    howdy = sources / pins["howdy"]["directory"]
    # dh_shlibdeps calculates dependencies against this host, not trixie.
    run(["dpkg-buildpackage", "-us", "-uc", "-b"], cwd=howdy, env=env)
    package = sources / f"howdy-next_{pins['version']}_amd64.deb"
    if not package.is_file():
        raise ValueError(f"Build did not produce {package}")
    output = work / "dist"
    output.mkdir(exist_ok=True)
    target = output / package.name
    shutil.copy2(package, target)
    checksum = digest(target)
    target.with_suffix(".deb.sha256").write_text(f"{checksum}  {target.name}\n")
    (output / "build.json").write_text(json.dumps({"package": target.name, "sha256": checksum, "sources": pins,
                                                    "inputs": inputs_key()}, indent=2) + "\n")
    print(f"Built {target}")
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("deps", "prepare", "build", "check", "inputs"),
                        help="check: print the package built from the current inputs, or fail; "
                             "inputs: print the identity of those inputs")
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK)
    parser.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    parser.add_argument("--yes", action="store_true", help="deps: answer apt-get's prompt (unattended container builds)")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if args.action == "deps":
        prefix = [] if os.geteuid() == 0 else ["sudo"]
        run([*prefix, "apt-get", "update"])
        run([*prefix, "apt-get", "--no-remove", *(["--assume-yes"] if args.yes else []), "install", *DEPENDENCIES])
    elif args.action == "prepare":
        print(prepare(args.work_dir.resolve())[0])
    elif args.action == "check":
        print(check(args.work_dir.resolve()))
    elif args.action == "inputs":
        print(inputs_key())
    else:
        build(args.work_dir.resolve(), args.jobs)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
