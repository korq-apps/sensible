"""Run both pre-checkout cleanup steps with modeled container/host ownership."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

REPO = Path(__file__).resolve().parents[2]
WORKFLOW = (REPO / ".github/workflows/build-iso.yml").read_text()
STEPS = re.findall(
    r"^      - name: Clean live-build leftovers from prior runs\n"
    r".*?^        run: \|\n((?:^          [^\n]*\n|^\n)+)",
    WORKFLOW,
    re.MULTILINE | re.DOTALL,
)

# Filesystem operations run for real in a private fixture. Only the engine and
# UID queries are doubled: container root maps to the runner for rootless runs,
# while rootful runs can remove host-root-owned entries.
DOUBLES = r'''
podman() {
    if [ "$CLEANUP_MODE" = engine_failure ]; then return 42; fi
    local script="${!#}"
    script="${script//\/workspace/$WORKSPACE}"
    (
        stat() {
            if [ "$CLEANUP_MODE" = rootful_stale ]; then echo 1000; else echo 0; fi
        }
        find() {
            if [ "$CLEANUP_MODE" != rootful_stale ]; then
                echo 'Unexpected root-owned sweep in a rootless container' >&2
                return 99
            fi
            if [[ "$*" == *'-exec'* ]]; then
                rm -f "$ROOT_ARTIFACT"
            elif [ -e "$ROOT_ARTIFACT" ]; then
                printf '%s\n' "$ROOT_ARTIFACT"
            fi
            return 0
        }
        export -f stat find
        bash -e -o pipefail -c "$script"
    )
}
find() {
    if [ "$CLEANUP_MODE" = host_error ]; then
        echo 'fixture: ownership traversal failed' >&2
        return 1
    fi
    if [ -e "$ROOT_ARTIFACT" ]; then printf '%s\n' "$ROOT_ARTIFACT"; fi
    return 0
}
'''


class CleanupTests(unittest.TestCase):
    def exercise(self, mode, status):
        self.assertEqual(len(STEPS), 2, "exercise both package and ISO cleanup")
        for index, step in enumerate(STEPS):
            with self.subTest(step=index, mode=mode), tempfile.TemporaryDirectory(
                prefix="sensible-ci-cleanup-"
            ) as temp:
                workspace = Path(temp) / "workspace"
                live = workspace / "live/chroot"
                live.mkdir(parents=True)
                (live / "stale").write_text("old build output")
                runner = workspace / "runner-owned-source"
                runner.write_text("preserve")
                artifact = workspace / ".build/biometrics/root-owned"
                if mode.endswith("_stale"):
                    artifact.parent.mkdir(parents=True)
                    artifact.write_text("old Howdy output")
                env = dict(
                    os.environ,
                    WORKSPACE=str(workspace),
                    ROOT_ARTIFACT=str(artifact),
                    CLEANUP_MODE=mode,
                )
                result = subprocess.run(
                    ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c",
                     DOUBLES + textwrap.dedent(step)],
                    env=env, capture_output=True, text=True, timeout=15,
                )
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, status, output)
                self.assertEqual(runner.read_text(), "preserve")
                self.assertEqual(live.exists(), mode == "engine_failure")
                if mode == "rootless_stale":
                    self.assertTrue(artifact.exists())
                    self.assertIn("Host-root-owned workspace entries remain", output)
                if mode == "rootful_stale":
                    self.assertFalse(artifact.exists())
                if mode == "host_error":
                    self.assertIn("Cannot verify workspace ownership on the host", output)
                if status:
                    self.assertNotIn("==> workspace clean", output)
                else:
                    self.assertIn("==> workspace clean", output)

    def test_clean_rootless_workspace(self):
        self.exercise("rootless_clean", 0)

    def test_rootless_cannot_hide_howdy_leftovers(self):
        self.exercise("rootless_stale", 1)

    def test_rootful_sweep_removes_howdy_leftovers(self):
        self.exercise("rootful_stale", 0)

    def test_host_inspection_failure_refuses_checkout(self):
        self.exercise("host_error", 1)

    def test_container_failure_stops_cleanup(self):
        self.exercise("engine_failure", 42)


if __name__ == "__main__":
    unittest.main()
