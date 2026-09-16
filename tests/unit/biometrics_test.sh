#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "${REPO_ROOT}/tests/lib/check_biometrics.py"
PYTHONDONTWRITEBYTECODE=1 python3 "${REPO_ROOT}/tests/lib/check_biometrics_local.py"
PYTHONDONTWRITEBYTECODE=1 python3 "${REPO_ROOT}/tests/lib/check_biometrics_pam.py"
PYTHONDONTWRITEBYTECODE=1 python3 "${REPO_ROOT}/tests/lib/check_biometrics_image.py"
