#!/usr/bin/env bash
# Portable, unprivileged artifact/rule tests; real APT/runtime checks are separate.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 "${REPO_ROOT}/tests/lib/check_desktop_apps.py" "${REPO_ROOT}"
