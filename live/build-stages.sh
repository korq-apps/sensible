#!/bin/bash
# live-build driver, run inside the builder container.
#
# Runs the stages individually rather than `lb build`, because the chroot's
# device nodes have to be repaired between bootstrap and package installation.
#
# Rootless podman cannot mknod: the kernel refuses device-node creation in an
# unprivileged user namespace, so debootstrap silently leaves a *regular file*
# at chroot/dev/null. Everything redirected there accumulates in a real file
# instead of being discarded, and anything reading it back gets that content.
# That is not theoretical -- it is how the dictionaries-common trigger failed
# the GNOME build: aspell is invoked with --per-conf=/dev/null, read the
# accumulated text, and reported
#     /dev/null:1: The key "/usr/bin/aspell" is unknown.
# Bind-mounting the container's real nodes over them is permitted where mknod
# is not, and is a no-op wherever the nodes are already correct. CI is not
# exempt: the GitHub runners have podman and build.sh prefers it, so CI ran
# rootless too and failed identically.
set -e

DEV_NODES="null zero full random urandom tty"

repair_dev_nodes() {
    local n
    for n in ${DEV_NODES}; do
        [ -c "chroot/dev/${n}" ] && continue
        rm -f "chroot/dev/${n}"
        : > "chroot/dev/${n}"
        mount --bind "/dev/${n}" "chroot/dev/${n}"
        echo "==> repaired chroot/dev/${n} (bind-mounted; mknod unavailable)"
    done
}

release_dev_nodes() {
    # Must happen before the image is built, or the bind-mounted host nodes are
    # captured into the squashfs; and before `lb installer`, which moves the
    # chroot aside and would fail on a busy mount point.
    local n failed=0
    for n in ${DEV_NODES}; do
        if mountpoint -q "chroot/dev/${n}"; then
            if ! umount "chroot/dev/${n}"; then
                echo "Error: could not unmount chroot/dev/${n}." >&2
                failed=1
            fi
        fi
    done
    return "${failed}"
}

# live-build writes everything under live/ as root inside the container, which
# is also root on the host when the container is --privileged (no userns
# remap). On a self-hosted runner the next workflow run's `actions/checkout`
# calls `git clean -ffdx`, and if the workspace is owned by a user the runner
# can't become, every chroot/ subdirectory logs
#     warning: could not open directory 'live/chroot/...': Permission denied
# and the checkout step fails before any build runs. The bind mount surfaces
# the host's UID/GID on /workspace; chown the build outputs back to that
# identity before the container exits so the runner can clean them later.
restore_host_ownership() {
    local host_uid host_gid
    # /workspace is the bind mount of the repo root; its owner on the host
    # is the user the runner runs as.
    host_uid="$(stat -c '%u' /workspace 2>/dev/null || echo 0)"
    host_gid="$(stat -c '%g' /workspace 2>/dev/null || echo 0)"
    if [ "${host_uid}" = "0" ] && [ "${host_gid}" = "0" ]; then
        # Host user is already root (or stat failed); nothing to reset.
        return 0
    fi
    # -R for directories live-build owns, -h so bind-mounts and symlinks
    # don't follow into the chroot rootfs. chown the cwd too so live-build's
    # top-level metadata files (chroot.files, *.iso, etc.) are also reachable.
    if ! chown -R -h "${host_uid}:${host_gid}" .; then
        echo "Error: could not restore build-output ownership to ${host_uid}:${host_gid}." >&2
        return 1
    fi
    # chroot/ can contain mountpoints (we bind-mounted /dev nodes above);
    # chown is harmless on the dir itself, but a busy mount would block it.
    # release_dev_nodes runs before this in the EXIT trap, so this is safe.
}

cleanup_build() {
    local status=$?
    if ! release_dev_nodes; then
        status=1
    fi
    if ! restore_host_ownership; then
        status=1
    fi
    trap - EXIT
    exit "${status}"
}
trap cleanup_build EXIT

# Hard-remove the build state first; `lb clean --purge` alone leaves a
# populated chroot/ and a .build/ stagefile set out of sync with cache/, and
# the next run then dies in debootstrap or in `lb installer`.
rm -rf chroot binary .build cache
lb clean --purge

# Phase 6 extras: fetch pinned oh-my-bash / Nerd Font and stage the shell and
# git defaults into includes.chroot, so every user of the installed system
# inherits them. Fails the build on a rotted pin (see live/pins.env).
bash /workspace/scripts/fetch-pins.sh

lb config
lb bootstrap
repair_dev_nodes
lb chroot
release_dev_nodes
lb installer
lb binary
