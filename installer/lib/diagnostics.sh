#!/usr/bin/env bash
# Capture only an explicit allowlist; never dump shell variables or commands
# that might contain account/LUKS secrets.
capture_install_diagnostics() {
    local exit_code="$1" value
    local -a args=(--stage "${CURRENT_STAGE:-unknown}" --exit-code "$exit_code"
        --log "$INSTALL_LOG" --target "$MNT")
    for value in "${EFI_PART:-}" "${BOOT_PART:-}" "${ROOT_PART:-}" "${TARGET_ROOT:-}"; do
        [ -n "$value" ] || continue
        args+=(--device "$value")
    done
    if [ -n "${BOOT_PART:-}" ]; then args+=(--boot-device "$BOOT_PART"); fi
    for value in "${FAILED_MOUNT_ARGS[@]}"; do args+=("--mount-arg=$value"); done
    # Collection and export have their own deadlines; this is an outer guard.
    timeout --kill-after=2s 40s python3 "${SCRIPT_DIR}/collect-diagnostics.py" "${args[@]}" \
        2>&1 | tee -a "$INSTALL_LOG"
}
