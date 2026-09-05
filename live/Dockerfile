FROM debian:testing-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    live-build \
    debootstrap \
    syslinux-utils \
    isolinux \
    xorriso \
    squashfs-tools \
    mtools \
    dosfstools \
    grub-pc-bin \
    grub-efi-amd64-bin \
    grub-efi-amd64-signed \
    grub-efi-ia32-bin \
    shim-signed \
    sbsigntool \
    rsync \
    curl \
    ca-certificates \
    git \
    unzip \
    coreutils \
    util-linux \
    findutils \
    cpio \
    bc \
    procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/live
