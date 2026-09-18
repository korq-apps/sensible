"""Exercise the standalone tools against temporary files, never host PAM."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[2] / "tools/biometrics"


def module(name, path):
    spec = importlib.util.spec_from_loader(name, importlib.machinery.SourceFileLoader(name, str(path)))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


ops = module("local_ops", TOOLS / "local_ops.py")
builder = module("biometric_build", TOOLS / "build.py")
ORIGINAL = b"# Keep this comment\n[core]\ndisabled = false\n[video]\ntimeout = 4\ndevice_path = none\n[face]\nsface_threshold = 0.6942\n"
DEVICE = "/dev/v4l/by-path/pci-fixture-video-index0"


class LocalFiles(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "howdy/config.ini"
        self.config.parent.mkdir()
        self.config.parent.chmod(0o755)
        self.config.write_bytes(ORIGINAL)
        self.config.chmod(0o640)
        self.pam = self.root / "pam.d/sensible-howdy-test"
        self.pam.parent.mkdir()
        self.pam.parent.chmod(0o755)
        self.common = self.pam.parent / "common-auth"
        self.common.write_text("auth required pam_unix.so\n")
        self.pam_module = self.root / "pam_howdy.so"
        self.pam_module.write_bytes(b"fixture module")
        self.pam_module.chmod(0o644)
        self.state = self.root / "state"
        for name, value in (("CONFIG", self.config), ("STATE", self.state), ("PAM_PATH", self.pam), ("PAM_MODULE", self.pam_module),
                            ('PACKAGE_LOCKS', (self.root / 'lock-frontend', self.root / 'lock-dpkg'))):
            patcher = patch.object(ops, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.addCleanup(patch.stopall)
        self.quiet = contextlib.redirect_stdout(io.StringIO())
        self.quiet.__enter__()
        self.addCleanup(self.quiet.__exit__, None, None, None)

    def test_configure_and_restore_preserve_other_settings_and_modes(self):
        ops.configure(DEVICE, 6)
        result = self.config.read_bytes()
        self.assertIn(b"# Keep this comment", result)
        self.assertIn(b"sface_threshold = 0.6942", result)
        self.assertIn(b"timeout = 6", result)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        self.assertEqual((self.state / "config.json").stat().st_mode & 0o777, 0o600)
        ops.restore_config()
        self.assertEqual(self.config.read_bytes(), ORIGINAL)
        self.assertFalse((self.state / "config.json").exists())

    def test_repeated_configuration_keeps_initial_backup(self):
        ops.configure(DEVICE, 5)
        ops.configure(DEVICE, 5)
        ops.configure(DEVICE, 8)
        ops.restore_config()
        self.assertEqual(self.config.read_bytes(), ORIGINAL)

    def test_dry_run_keeps_config_and_does_not_save_backup(self):
        ops.configure(DEVICE, dry_run=True)
        self.assertEqual(self.config.read_bytes(), ORIGINAL)
        self.assertFalse(self.state.exists())

    def test_external_edit_blocks_restore_and_reconfigure(self):
        ops.configure(DEVICE)
        edited = self.config.read_bytes() + b"# admin change\n"
        self.config.write_bytes(edited)
        with self.assertRaises(ValueError):
            ops.restore_config()
        with self.assertRaises(ValueError):
            ops.configure(DEVICE, 8)
        self.assertEqual(self.config.read_bytes(), edited)

    def test_external_permission_change_is_preserved(self):
        ops.configure(DEVICE)
        self.config.chmod(0o600)
        with self.assertRaises(ValueError):
            ops.restore_config()
        with self.assertRaises(ValueError):
            ops.configure(DEVICE, 8)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_interruption_between_backup_and_config_is_recoverable(self):
        write = ops.atomic_write
        def interrupted(path, *args, **kwargs):
            if path == self.config:
                raise OSError("simulated crash before config write")
            write(path, *args, **kwargs)
        with patch.object(ops, "atomic_write", interrupted), self.assertRaises(OSError):
            ops.configure(DEVICE)
        ops.restore_config()
        self.assertEqual(self.config.read_bytes(), ORIGINAL)

    def test_symlink_and_hardlink_config_are_rejected(self):
        real = self.config.parent / "real.ini"
        self.config.rename(real)
        self.config.symlink_to(real)
        with self.assertRaises(OSError):
            ops.configure(DEVICE)
        self.config.unlink()
        os.link(real, self.config)
        with self.assertRaises(ValueError):
            ops.configure(DEVICE)
        self.assertEqual(real.read_bytes(), ORIGINAL)

    def test_writable_config_or_state_is_rejected(self):
        self.config.chmod(0o666)
        with self.assertRaises(ValueError):
            ops.configure(DEVICE)
        self.config.chmod(0o640)
        self.state.chmod(0o777)
        with self.assertRaises(ValueError):
            ops.configure(DEVICE)

    def test_invalid_device_or_ini_does_not_write(self):
        for device in ("/dev/video2", DEVICE + "\n[core]\ndisabled=false", "/tmp/camera"):
            with self.subTest(device=device), self.assertRaises(ValueError):
                ops.configure(device)
        self.assertEqual(self.config.read_bytes(), ORIGINAL)
        for bad in (b"[video]\ndevice_path=none\n", b"[video]\ntimeout=4\ntimeout=5\ndevice_path=none\n"):
            self.config.write_bytes(bad)
            with self.assertRaises((ValueError, ops.configparser.Error)):
                ops.configure(DEVICE)
            self.assertEqual(self.config.read_bytes(), bad)

    def test_concurrent_operation_is_rejected(self):
        with ops.locked_state(), self.assertRaises(BlockingIOError):
            ops.configure(DEVICE)

    def test_configuration_waits_for_both_package_manager_locks(self):
        code = ('import fcntl,sys,os; f=open(sys.argv[1], "a+"); os.fchmod(f.fileno(), 0o640); '
                'fcntl.lockf(f, fcntl.LOCK_EX); print("locked", flush=True); sys.stdin.read(1)')
        for path in ops.PACKAGE_LOCKS:
            child = subprocess.Popen([sys.executable, '-c', code, str(path)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(child.stdout.readline().strip(), 'locked')
                with self.assertRaises(BlockingIOError): ops.configure(DEVICE)
                self.assertEqual(self.config.read_bytes(), ORIGINAL)
                self.assertFalse((self.state / 'config.json').exists())
            finally:
                child.communicate('x', timeout=5)
        ops.configure(DEVICE)

    def test_late_configuration_edit_is_not_overwritten(self):
        write = ops.atomic_write
        edited = ORIGINAL + b'# intervening edit\n'
        def concurrent(path, *args, **kwargs):
            if path == self.config:
                self.config.write_bytes(edited)
            return write(path, *args, **kwargs)
        with patch.object(ops, 'atomic_write', concurrent), self.assertRaises(ValueError):
            ops.configure(DEVICE)
        self.assertEqual(self.config.read_bytes(), edited)

    def test_replacement_with_identical_bytes_or_new_mode_invalidates_snapshot(self):
        for change in ('inode', 'mode'):
            with self.subTest(change=change):
                before = ops.checked_read(self.config)
                if change == 'inode':
                    replacement = self.config.with_suffix('.new')
                    replacement.write_bytes(before[0])
                    replacement.chmod(0o640)
                    replacement.replace(self.config)
                else:
                    self.config.chmod(0o600)
                with self.assertRaises(ValueError):
                    ops.atomic_write(self.config, b'new data', 0o640, expected=before)
                self.assertEqual(self.config.read_bytes(), before[0])

    def test_running_pam_test_allows_state_access_but_prevents_cleanup(self):
        def prompt(*args, **kwargs):
            with ops.locked_state(): pass
            with self.assertRaises(BlockingIOError): ops.pam_cleanup()
            with self.assertRaises(BlockingIOError): ops.pam_test('fixture')
        with patch.object(ops.subprocess, 'run', side_effect=prompt):
            ops.pam_test('fixture', timeout=300)
        self.assertFalse(self.pam.exists())

    def run_pam(self, failure=None, fallback=False):
        def run(args, **kwargs):
            self.assertEqual(args, ["pamtester", "sensible-howdy-test", "fixture", "authenticate", "acct_mgmt"])
            self.assertEqual(self.pam.read_bytes(), ops.PAM_FALLBACK if fallback else ops.PAM_FACE)
            self.assertEqual(kwargs["timeout"], 30)
            if failure:
                raise failure
        with patch.object(ops.subprocess, "run", run):
            ops.pam_test("fixture", fallback)

    def test_pam_service_success_and_password_fallback_cleanup(self):
        for fallback in (False, True):
            self.run_pam(fallback=fallback)
            self.assertFalse(self.pam.exists())
        self.assertEqual(self.common.read_text(), "auth required pam_unix.so\n")

    def test_pam_failures_timeout_and_cancel_cleanup(self):
        for error in (subprocess.CalledProcessError(1, "pamtester"), subprocess.TimeoutExpired("pamtester", 30), KeyboardInterrupt()):
            with self.subTest(error=type(error).__name__), self.assertRaises(type(error)):
                self.run_pam(error)
            self.assertFalse(self.pam.exists())
        self.assertEqual(self.common.read_text(), "auth required pam_unix.so\n")

    def test_pam_collision_is_not_overwritten(self):
        self.pam.write_bytes(b"admin content")
        with self.assertRaises(FileExistsError):
            self.run_pam()
        with self.assertRaises(ValueError):
            ops.pam_cleanup()
        self.assertEqual(self.pam.read_bytes(), b"admin content")

    def test_interrupted_pam_service_can_be_cleaned(self):
        self.pam.write_bytes(ops.PAM_FACE)
        self.pam.chmod(0o644)
        ops.pam_cleanup()
        self.assertFalse(self.pam.exists())

    def test_install_checks_hash_and_identity_before_apt(self):
        package = self.root / "fixture.deb"
        package.write_bytes(b"fixture")
        temp_class = tempfile.TemporaryDirectory
        with patch.object(ops.tempfile, "TemporaryDirectory", lambda **kw: temp_class(dir=self.root)), \
             patch.object(ops.subprocess, "check_output") as identity, \
             patch.object(ops.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                ops.install_package(package, "0" * 64)
            identity.assert_not_called()
            run.assert_not_called()
            identity.return_value = "Package: wrong\n"
            with self.assertRaises(ValueError):
                ops.install_package(package, ops.sha(b"fixture"))
            run.assert_not_called()
            # Derive the expected version from the same pin the tool reads, so a
            # version bump in sources.json alone keeps this test honest.
            version = json.loads((TOOLS / "sources.json").read_text())["version"]
            identity.return_value = f"Package: howdy-next\nVersion: {version}\nArchitecture: amd64\n"
            ops.install_package(package, ops.sha(b"fixture"))
            self.assertIn("--simulate", run.call_args_list[0].args[0])
            self.assertTrue(all("--no-remove" in call.args[0] for call in run.call_args_list))


class BuildAndIdentity(unittest.TestCase):
    @contextlib.contextmanager
    def cached_build(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            tools = root / 'tools/biometrics'
            shutil.copytree(TOOLS, tools, ignore=shutil.ignore_patterns('__pycache__'))
            build = module('fixture_build', tools / 'build.py')
            cli = module('fixture_cli', tools / 'sensible-biometrics')
            dist = build.DEFAULT_WORK / 'dist'
            dist.mkdir(parents=True)
            package = dist / 'howdy-next.deb'
            package.write_bytes(b'fixture package')
            manifest = {'package': package.name, 'sha256': ops.sha(package.read_bytes()),
                        'sources': json.loads((tools / 'sources.json').read_text()),
                        'inputs': build.inputs_key()}
            (dist / 'build.json').write_text(json.dumps(manifest))
            yield SimpleNamespace(tools=tools, build=build, cli=cli, dist=dist,
                                  package=package, manifest=manifest)

    def install_default(self, fixture):
        with patch.dict(sys.modules, {'build': fixture.build, 'local_ops': ops}), \
             patch.object(fixture.cli, 'os', SimpleNamespace(geteuid=lambda: 0)), \
             patch.object(sys, 'argv', ['sensible-biometrics', 'install']):
            fixture.cli.main()

    def test_default_install_accepts_only_artifact_from_current_inputs(self):
        changes = {
            'pins': lambda f: (f.tools / 'sources.json').write_text(json.dumps(
                dict(f.manifest['sources'], howdy={'sha256': 'changed without a version bump'}))),
            'patch': lambda f: (f.tools / 'patches/new.patch').write_text('new patch'),
            'packaging': lambda f: (f.tools / 'debian/rules').write_text('changed packaging'),
            'artifact': lambda f: f.package.write_bytes(b'changed package'),
            'missing artifact': lambda f: f.package.unlink(),
            'missing manifest': lambda f: (f.dist / 'build.json').unlink(),
            'invalid manifest': lambda f: (f.dist / 'build.json').write_text('{'),
        }
        for name, change in changes.items():
            with self.subTest(change=name), self.cached_build() as fixture, \
                 patch.object(ops, 'install_package') as install:
                change(fixture)
                with self.assertRaises((ValueError, OSError)):
                    self.install_default(fixture)
                install.assert_not_called()
        with self.cached_build() as fixture, patch.object(ops, 'install_package') as install:
            self.install_default(fixture)
            install.assert_called_once_with(fixture.package, fixture.manifest['sha256'])

    def test_explicit_artifact_does_not_require_checkout_build_recipe(self):
        with self.cached_build() as fixture, patch.object(ops, 'install_package') as install:
            (fixture.tools / 'build.py').unlink()
            with patch.dict(sys.modules, {'local_ops': ops, 'build': None}), \
                 patch.object(fixture.cli, 'os', SimpleNamespace(geteuid=lambda: 0)), \
                 patch.object(sys, 'argv', ['sensible-biometrics', 'install', '--package',
                              str(fixture.package), '--sha256', fixture.manifest['sha256']]):
                fixture.cli.main()
            install.assert_called_once_with(fixture.package, fixture.manifest['sha256'])

    def test_package_install_stages_companion_opencv_license_notices(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            prefix = root / 'prefix'
            (prefix / 'lib').mkdir(parents=True)
            (prefix / 'lib/libopencv_core.so.5').write_bytes(b'fixture library')
            notices = prefix / 'share/licenses/opencv5'
            notices.mkdir(parents=True)
            (notices / 'protobuf-LICENSE').write_text('fixture third-party notice')
            license = root / 'LICENSE'
            license.write_text('fixture OpenCV license')
            fake_bin = root / 'bin'
            fake_bin.mkdir()
            install = fake_bin / 'dh_auto_install'
            install.write_text('#!/bin/sh\nexit 0\n')
            install.chmod(0o755)
            subprocess.run(['make', '-f', str(TOOLS / 'debian/rules'), 'override_dh_auto_install',
                            'DEB_HOST_MULTIARCH=x86_64-linux-gnu', f'HOWDY_DEPS_PREFIX={prefix}',
                            f'HOWDY_OPENCV_LICENSE={license}'], cwd=root, check=True, capture_output=True,
                           env=dict(os.environ, PATH=str(fake_bin) + ':' + os.environ['PATH']))
            doc = root / 'debian/howdy-next/usr/share/doc/howdy-next'
            self.assertEqual((doc / 'OpenCV-LICENSE').read_text(), 'fixture OpenCV license')
            self.assertEqual((doc / 'opencv-licenses/protobuf-LICENSE').read_text(), 'fixture third-party notice')

    def test_source_permissions_and_build_umask(self):
        with tempfile.TemporaryDirectory() as root:
            directory = tarfile.TarInfo("fixture")
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o777
            self.assertEqual(builder.source_filter(directory, root).mode, 0o755)
            regular = tarfile.TarInfo("fixture/file")
            regular.mode = 0o666
            self.assertEqual(builder.source_filter(regular, root).mode, 0o644)
        with patch.object(builder.subprocess, "run") as run:
            builder.run(["true"])
            self.assertEqual(run.call_args.kwargs["umask"], 0o022)

    def test_cached_download_checks_hash(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "source.tar.gz"
            path.write_bytes(b"fixture")
            with patch.object(builder.urllib.request, "urlopen") as network:
                self.assertEqual(builder.download({"sha256": ops.sha(b"fixture")}, path), path)
                with self.assertRaises(ValueError):
                    builder.download({"sha256": "0" * 64}, path)
                network.assert_not_called()

    def test_root_and_service_accounts_rejected(self):
        for uid, shell in ((0, "/bin/bash"), (999, "/bin/bash"), (1000, "/usr/sbin/nologin")):
            with patch.object(ops.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=uid, pw_shell=shell)), self.assertRaises(ValueError):
                ops.target_user("fixture")
        with patch.object(ops.pwd, "getpwnam", return_value=SimpleNamespace(pw_uid=1000, pw_shell="/bin/bash", pw_name="fixture")):
            self.assertEqual(ops.target_user("fixture"), "fixture")


if __name__ == "__main__":
    unittest.main()
