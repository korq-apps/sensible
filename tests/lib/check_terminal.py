"""PTY checks for static styling followed by user input; no real credentials.

The fixture models Gum 0.17's stdout-TTY background probe. Set
SENSIBLE_TEST_GUM to an ISO's extracted Gum binary to check that build too.
"""
import errno
import fcntl
import os
from pathlib import Path
import select
import subprocess
import tempfile
import termios
import time
import unittest

REPO = Path(__file__).resolve().parents[2]
QUERY = b"\x1b]11;?\x1b\\"
RESPONSE = b"\x1b]11;rgb:2323/2626/2727\x1b\\"


class TerminalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="sensible-terminal-")
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name)
        stub = self.bin / "gum"
        stub.write_text(r'''#!/usr/bin/env bash
if [ "${STYLE_FAIL:-0}" = 1 ]; then exit 1; fi
if [ -t 1 ]; then printf '\e]11;?\e\\'; fi
if IFS= read -r -t .05 unexpected; then
    printf 'STYLE_CONSUMED_INPUT\n' >&2
fi
printf '\e[1m%s\e[0m\n' "${!#}"
''')
        stub.chmod(0o755)

    def exercise(self, *, password=False, queued=False, failure=False, real=False):
        if real:
            (self.bin / "gum").unlink()
            (self.bin / "gum").symlink_to(Path(os.environ["SENSIBLE_TEST_GUM"]).resolve())
        master, slave = os.openpty()
        # Set a real size so layout measurement does not depend on host defaults.
        termios.tcsetwinsize(slave, (30, 100))

        def session():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        script = r'''
source "$1/installer/lib/ui.sh"
prepare_terminal
trap restore_terminal EXIT
printf 'STYLE_READY\n' >/dev/tty
# Synchronize the driver before drawing; queued characters arrive with this ack.
IFS= read -r ack </dev/tty
output=$(ui_style --bold 'Computer name')
[ -z "$output" ]
printf 'INPUT_READY\n' >/dev/tty
if [ "$3" = password ]; then
    IFS= read -r -s answer </dev/tty
else
    IFS= read -r answer </dev/tty
fi
[ "$answer" = "$2" ]
printf 'INPUT_OK\n'
'''
        sample = r"test-$\;[] word" if password else "sensible-test"
        env = dict(os.environ, TERM="xterm-256color", PATH=f"{self.bin}:{os.environ['PATH']}",
                   STYLE_FAIL="1" if failure else "0")
        for key in ("NO_COLOR", "CLICOLOR_FORCE", "SENSIBLE_UNATTENDED"):
            env.pop(key, None)
        proc = subprocess.Popen(
            ["bash", "-eu", "-c", script, "_", str(REPO), sample,
             "password" if password else "normal"], stdin=slave, stdout=subprocess.PIPE,
            stderr=slave, env=env, preexec_fn=session)
        os.close(slave)
        transcript = b""
        acknowledged = submitted = responded = False
        reply_at = input_at = None
        deadline = time.monotonic() + 8
        try:
            while time.monotonic() < deadline:
                now = time.monotonic()
                if reply_at is not None and now >= reply_at:
                    os.write(master, RESPONSE)
                    reply_at = None
                if input_at is not None and now >= input_at:
                    os.write(master, sample.encode() + b"\n")
                    input_at = None
                if not select.select([master], [], [], .01)[0]:
                    if proc.poll() is not None:
                        break
                    continue
                try:
                    data = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                transcript += data
                if b"STYLE_READY" in transcript and not acknowledged:
                    os.write(master, b"go\n" + (sample.encode() + b"\n" if queued else b""))
                    acknowledged = True
                    submitted = queued
                if QUERY in transcript and not responded:
                    # Model a reply arriving after a short-lived styling process.
                    reply_at = time.monotonic() + .02
                    responded = True
                if b"INPUT_READY" in transcript and not submitted:
                    input_at = time.monotonic() + .1
                    submitted = True
            else:
                self.fail("terminal check timed out")
            stdout, _ = proc.communicate(timeout=2)
            self.assertEqual(proc.returncode, 0, transcript)
            self.assertEqual(stdout, b"INPUT_OK\n")
            self.assertNotIn(QUERY, transcript)
            self.assertNotIn(b"STYLE_CONSUMED_INPUT", transcript)
            self.assertIn(b"Computer name", transcript)
            if not failure:
                self.assertIn(b"\x1b[1m", transcript, "bold styling must survive")
            else:
                self.assertIn(b"Terminal styling is unavailable", transcript)
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.communicate()
            os.close(master)

    def test_style_then_hostname(self):
        self.exercise()

    def test_style_then_password(self):
        self.exercise(password=True)

    def test_typeahead_is_preserved(self):
        self.exercise(password=True, queued=True)

    def test_style_failure_still_falls_back(self):
        self.exercise(failure=True)

    @unittest.skipUnless(os.environ.get("SENSIBLE_TEST_GUM"), "optional ISO Gum binary")
    def test_real_iso_gum(self):
        self.exercise(real=True, password=True, queued=True)


if __name__ == "__main__":
    unittest.main()
