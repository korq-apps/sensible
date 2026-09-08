#!/usr/bin/env python3
"""Production parser tests, using caller-owned private fixtures (no root)."""
import importlib.util
import json
import os
from pathlib import Path
import pty
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
PARSER = REPO / "installer/lib/read-config.py"
spec = importlib.util.spec_from_file_location("read_config", PARSER)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="sensible-config-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.secret = self.root / "password"
        self.secret.write_bytes(b"test $ecret ' \\ password\n")
        self.secret.chmod(0o600)
        self.config = self.root / "answers.toml"
        self.values = dict(disk="/dev/vda", confirm_wipe=True, filesystem="btrfs",
                           luks=True, autologin=True, hostname="sensible-box",
                           username="alice", timezone="UTC", locale="en_US.UTF-8",
                           keyboard="us", password_file=str(self.secret))
        self.write_config()

    def write_config(self, extra=""):
        self.config.write_text("\n".join(f"{k} = {json.dumps(v)}" for k, v in self.values.items()) + "\n" + extra)
        self.config.chmod(0o600)

    def run_parser(self):
        return subprocess.run([sys.executable, "-I", str(PARSER), str(self.config)],
                              capture_output=True, timeout=5)

    def reject(self):
        result = self.run_parser()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(b"test $ecret", result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)
        return result

    def test_complete_record_and_literal_secret(self):
        result = self.run_parser()
        self.assertEqual(result.returncode, 0, result.stderr)
        fields = result.stdout.split(b"\0")
        self.assertEqual(len(fields), 15)
        self.assertEqual(fields[6:8], [b"", b""])
        self.assertEqual(fields[11], self.secret.read_bytes()[:-1])

    def test_shipped_example_does_not_authorize_wipe_or_include_secrets(self):
        example = reader.tomllib.loads((REPO / "configs/answers.example.toml").read_text())
        self.assertIs(example["confirm_wipe"], False)
        self.assertNotIn("user_password", example)
        self.assertNotIn("luks_passphrase", example)
        self.assertTrue(example["password_file"].startswith("/run/"))

    def test_required_keys(self):
        original = self.values.copy()
        for key in original:
            with self.subTest(key=key):
                self.values = {k: v for k, v in original.items() if k != key}
                self.write_config()
                self.reject()

    def test_unknown_keys_and_malformed_toml_are_redacted(self):
        for extra in ['user_password = "test $ecret"', 'luks_passphrase = "test $ecret"',
                      'desktop = "gnome"', 'disk = "duplicate"',
                      'test $ecret = [', '[nested]\na = 1']:
            with self.subTest(extra=extra):
                self.write_config(extra)
                self.reject()

    def test_invalid_types_and_combinations(self):
        original = self.values.copy()
        for key, value in [("confirm_wipe", False), ("confirm_wipe", "true"),
                           ("luks", 1), ("luks", False), ("autologin", "false"),
                           ("filesystem", "xfs"), ("disk", "vda"),
                           ("password_file", "relative"), ("hostname", ["abc"]),
                           ("username", "alice\nroot"), ("email", "a\u0000b")]:
            with self.subTest(key=key, value=value):
                self.values = original | {key: value}
                self.write_config()
                self.reject()

    def test_private_files_only(self):
        for path in [self.config, self.secret]:
            for mode in [0o644, 0o640, 0o660, 0o700, 0o200, 0o4600]:
                with self.subTest(path=path.name, mode=mode):
                    path.chmod(mode)
                    self.reject()
                    path.chmod(0o600)
            path.chmod(0o400)
            self.assertEqual(self.run_parser().returncode, 0)
            path.chmod(0o600)

    def test_foreign_owner_is_rejected_on_open_inode(self):
        with patch.object(reader.os, "geteuid", return_value=os.geteuid() + 1):
            with self.assertRaises(reader.InvalidConfig):
                reader.protected_read(str(self.config), 65536)

    def test_symlinks_and_hardlinks(self):
        for path in [self.config, self.secret]:
            saved = path.with_suffix(".saved")
            path.rename(saved)
            path.symlink_to(saved)
            self.reject()
            path.unlink()
            os.link(saved, path)
            self.reject()
            path.unlink()
            saved.rename(path)
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.values["password_file"] = str(alias / "password")
        self.write_config()
        self.reject()

    def test_nonregular_and_missing_files_never_block(self):
        self.secret.unlink()
        self.reject()
        os.mkfifo(self.secret, 0o600)
        self.reject()
        self.secret.unlink()
        self.secret.mkdir(mode=0o700)
        self.reject()

    def test_invalid_password_encoding_and_lines(self):
        for value in [b"", b"\n", b"abc\0password", b"abc\rpassword", b"abc\npassword",
                      b"test-password\n\n", b"bad\xffpassword", b"x" * 4097]:
            with self.subTest(value=value[:20]):
                self.secret.write_bytes(value)
                self.reject()
        self.secret.write_bytes(b"password-no-final-newline")
        self.assertEqual(self.run_parser().returncode, 0)

    def test_config_size_and_encoding(self):
        for value in [b"\xff", b"#" + b"x" * 65536]:
            self.config.write_bytes(value)
            self.reject()

    def test_replacing_path_after_open_does_not_replace_checked_input(self):
        original = self.config.read_bytes()
        real_fstat = reader.os.fstat

        def replace(fd):
            result = real_fstat(fd)
            self.config.rename(self.root / "original")
            self.config.write_text("malicious replacement")
            return result

        with patch.object(reader.os, "fstat", side_effect=replace):
            _, data = reader.protected_read(str(self.config), 65536)
        self.assertEqual(data, original)

    def test_error_paths_do_not_wait_even_with_tty_stdin(self):
        master, slave = pty.openpty()
        try:
            script = '''
source "$1/installer/lib/ui.sh"
source "$1/installer/lib/verify.sh"
SENSIBLE_UNATTENDED=true
UI_TOOL=whiptail
whiptail() { echo UNEXPECTED_DIALOG; return 1; }
ui_menu() { echo UNEXPECTED_MENU; return 1; }
prepare_terminal
ui_msgbox Error "diagnostic"
show_failure_screen test 1 /nonexistent
echo FINISHED
'''
            result = subprocess.run(["bash", "-eu", "-c", script, "_", str(REPO)],
                                    stdin=slave, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"FINISHED", result.stdout)
            self.assertNotIn(b"UNEXPECTED", result.stdout + result.stderr)
        finally:
            os.close(master)
            os.close(slave)

    def test_real_rsync_excludes_only_literal_input_paths(self):
        source = self.root / "source"
        target = self.root / "target"
        source.mkdir()
        target.mkdir()
        name = "input[a]*?\\file"
        (source / name).write_text("secret")
        (source / "keep").write_text("ordinary payload")
        result = subprocess.run(["bash", "-eu", "-c", '''
source "$1/installer/lib/config.sh"
rsync -a --exclude="$(input_copy_exclusion "/$4")" "$2/" "$3/"
''', "_", str(REPO), str(source), str(target), name], capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((target / name).exists())
        self.assertTrue((target / "keep").is_file())


if __name__ == "__main__":
    unittest.main()
