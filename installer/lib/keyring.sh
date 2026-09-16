# Installer helper: pre-create an auto-unlocking GNOME login keyring for
# autologin accounts, so saved-secret access never prompts and apps never fork
# a second "Default keyring".
#
# Why this exists. GNOME Keyring is normally created and unlocked by
# pam_gnome_keyring from the account password at login. Autologin never gives
# PAM that password, so the first session has no login keyring; the first app
# to store a secret then makes its own keyring with a separate password, and
# every later app prompts again. Under LUKS + autologin the disk passphrase is
# already the access boundary, so we ship an empty-password login keyring: the
# daemon auto-unlocks it and it is the default collection from the first login.
#
# Scope, matching the agreed posture (docs/PLAN.md "Desktop credentials"):
#   - GNOME only. KDE Wallet is separate work.
#   - Autologin accounts only. A password login still gets an encrypted,
#     PAM-unlocked keyring; a face-login account without autologin keeps an
#     encrypted keyring and is asked once per session.
#
# The empty-password keyring is a plaintext INI with no secrets, so it is
# written directly (no daemon needed in the chroot) and is race-free: it exists
# before the first session's apps start. gnome-keyring rewrites ctime/mtime on
# first real use.

# Emit the on-disk bytes of an empty, unlocked login keyring. Kept as one
# function so the format has a single source and the tests assert against it.
sensible_login_keyring_bytes() {
    printf '[keyring]\ndisplay-name=Login\nctime=%s\nmtime=0\nlock-on-idle=false\nlock-after=false\n' "${1:-0}"
}

configure_user_login_keyring() { # desktop autologin username
    local desktop_env="$1" autologin="$2" username="$3"

    # Only the GNOME autologin path is handled here; every other combination
    # keeps the stock encrypted, password-unlocked keyring.
    if [ "$desktop_env" != "gnome" ] || [ "$autologin" != "true" ]; then
        return 0
    fi
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || [ "${#username}" -gt 32 ]; then
        log_err "configure_user_login_keyring requires a valid username."
        return 1
    fi
    if [ ! -d "${MNT}/home/${username}" ] || [ -L "${MNT}/home/${username}" ]; then
        log_err "Login keyring setup requires an existing user home directory."
        return 1
    fi

    log_info "Creating an auto-unlocking GNOME login keyring for ${username} (autologin)..."
    local keyring_dir="${MNT}/home/${username}/.local/share/keyrings"
    local directory
    # Own only the parents we create; never chown existing unrelated files, and
    # never follow a symlink planted in the path.
    for directory in \
        "${MNT}/home/${username}/.local" \
        "${MNT}/home/${username}/.local/share" \
        "$keyring_dir"; do
        if [ -L "$directory" ]; then
            log_err "Refusing a symlink in the keyring path: ${directory}."
            return 1
        fi
        if [ ! -d "$directory" ]; then
            mkdir "$directory" || return 1
            chroot "$MNT" chown "${username}:${username}" "${directory#"${MNT}"}" || return 1
        fi
    done
    # keyrings/ holds secret material for other users; keep it private.
    chmod 0700 "$keyring_dir" || return 1

    local keyring_file="${keyring_dir}/login.keyring"
    local default_file="${keyring_dir}/default"
    if [ -e "$keyring_file" ] || [ -L "$keyring_file" ] || [ -e "$default_file" ] || [ -L "$default_file" ]; then
        # A pre-existing keyring is not ours to reinterpret; leave it and let
        # the diagnostic/manual guide any reconciliation.
        log_warn "A keyring already exists for ${username}; leaving it unchanged."
        return 0
    fi

    local now
    now="$(date +%s 2>/dev/null || echo 0)"
    sensible_login_keyring_bytes "$now" > "$keyring_file" || return 1
    printf 'login' > "$default_file" || return 1
    chmod 0600 "$keyring_file" "$default_file" || return 1
    chroot "$MNT" chown "${username}:${username}" \
        "/home/${username}/.local/share/keyrings/login.keyring" \
        "/home/${username}/.local/share/keyrings/default" || return 1
}
