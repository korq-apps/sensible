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
# is not, and is a no-op when the nodes are already correct (rootful docker, as
# CI uses, creates them properly -- which is why this only ever failed locally).
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
    local n
    for n in ${DEV_NODES}; do
        umount "chroot/dev/${n}" 2>/dev/null || true
    done
}
trap release_dev_nodes EXIT

# Hard-remove the build state first; `lb clean --purge` alone leaves a
# populated chroot/ and a .build/ stagefile set out of sync with cache/, and
# the next run then dies in debootstrap or in `lb installer`.
rm -rf chroot binary .build cache
lb clean --purge >/dev/null 2>&1 || true

lb config
lb bootstrap
repair_dev_nodes
lb chroot
release_dev_nodes
lb installer
lb binary
