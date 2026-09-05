#!/usr/bin/env bash
# Run one named container with bounded cleanup on CI cancellation. The workflow
# has a second cleanup step for cases where the runner forcibly kills this shell.
set -euo pipefail

ENGINE="$1"
NAME="$2"
shift 2
child=""

cleanup() {
    local status=$? names attempt
    trap - EXIT INT TERM
    if names="$("${ENGINE}" ps -a --format '{{.Names}}' --filter "name=${NAME}")"; then
        if grep -Fxq -- "${NAME}" <<< "${names}"; then
            if ! "${ENGINE}" rm -f "${NAME}"; then
                echo "Error: could not remove build container ${NAME}." >&2
                [ "${status}" -ne 0 ] || status=1
            fi
        fi
    else
        echo "Error: could not check build container ${NAME} during cleanup." >&2
        [ "${status}" -ne 0 ] || status=1
    fi
    if [ -n "${child}" ]; then
        # A failed daemon operation must not leave this shell waiting forever
        # for the attached client. The workflow retries container cleanup.
        if kill -0 "${child}" 2>/dev/null; then
            if ! kill -TERM "${child}" 2>/dev/null; then
                echo "Warning: container client exited during cleanup." >&2
            fi
            for attempt in 1 2 3 4 5; do
                if ! kill -0 "${child}" 2>/dev/null; then break; fi
                sleep 1
            done
            if kill -0 "${child}" 2>/dev/null; then
                if ! kill -KILL "${child}" 2>/dev/null; then
                    echo "Warning: could not force-stop the container client." >&2
                fi
            fi
        fi
        if wait "${child}"; then :; else
            # Preserve the original build failure or cancellation exit status.
            [ "${status}" -ne 0 ] || status=1
        fi
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Keep the engine's graceful-stop budget below the runner's cancellation grace
# period; Podman also applies this timeout to `rm -f`.
"${ENGINE}" run --rm --stop-timeout 2 --name "${NAME}" "$@" &
child=$!
status=0
wait "${child}" || status=$?
child=""
exit "${status}"
