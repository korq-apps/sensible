#!/usr/bin/env bash
# Runner: executes every *_test.sh under tests/ and aggregates results.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED_SUITES=0
TOTAL_SUITES=0

for suite in "${REPO_ROOT}"/tests/unit/*_test.sh "${REPO_ROOT}"/tests/integration/*_test.sh; do
    [ -f "$suite" ] || { echo "No test suites found." >&2; exit 1; }
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    echo "=== $(basename "${suite}") ==="
    if bash "$suite"; then
        :
    else
        FAILED_SUITES=$((FAILED_SUITES + 1))
    fi
    echo
done

echo "Suites: ${TOTAL_SUITES}, failed: ${FAILED_SUITES}"
[ "${FAILED_SUITES}" -eq 0 ]
