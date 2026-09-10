#!/usr/bin/env bash
# Noninteractive input adapter. Output travels through a private pipe, never a
# temporary file or shell evaluation. The caller must check root first.
load_unattended_config() {
    local path="$1" input_fd parser_pid status=0
    exec {input_fd}< <(python3 -I "${LIB_DIR}/read-config.py" "$path")
    parser_pid=$!
    mapfile -d '' -t UNATTENDED_FIELDS <&"$input_fd" || status=$?
    exec {input_fd}<&-
    wait "$parser_pid" || status=$?
    if [ "$status" -ne 0 ] || [ "${#UNATTENDED_FIELDS[@]}" -ne 14 ]; then
        UNATTENDED_FIELDS=()
        log_err "Invalid unattended configuration; no disk was changed."
        return 1
    fi
    if ! valid_hostname "${UNATTENDED_FIELDS[4]}" \
        || ! valid_username "${UNATTENDED_FIELDS[5]}" \
        || ! valid_optional_identity "${UNATTENDED_FIELDS[6]}" \
        || ! valid_optional_identity "${UNATTENDED_FIELDS[7]}" \
        || ! valid_timezone "${UNATTENDED_FIELDS[8]}" \
        || ! valid_locale "${UNATTENDED_FIELDS[9]}" \
        || ! validate_keyboard_layout "${UNATTENDED_FIELDS[10]}" \
        || ! valid_password "${UNATTENDED_FIELDS[11]}"; then
        UNATTENDED_FIELDS=()
        log_err "Invalid account, password, identity, timezone, locale or keyboard; no disk was changed."
        return 1
    fi
}

# Escape rsync glob syntax so an input filename is excluded literally.
input_copy_exclusion() {
    local path="$1"
    path=${path//\\/\\\\}
    path=${path//\*/\\*}
    path=${path//\?/\\?}
    path=${path//\[/\\[}
    path=${path//\]/\\]}
    printf '%s' "$path"
}
