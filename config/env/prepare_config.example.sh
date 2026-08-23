#!/bin/sh
# yaramfs configuration reference / template.
#
# Copy to prepare_config.sh and uncomment what you need:
#   cp config/env/prepare_config.example.sh config/env/prepare_config.sh
#
# Loaded at prepare (base hook) via yaramfs_load_env prepare.
# CLI env already set wins over values here (preserve/restore).
#
# YARAMFS_CFG_BOOT_* set here are collected by prepare-cpio into
# config/env/boot_config.sh and baked into the image for guest boot.
# Real source of truth for names: grep -R YARAMFS_CFG hooks/
#
# Convention:
#   PREPARE_*  — host-side image build
#   BOOT_*     — guest early boot (also settable at prepare to bake in)

# =============================================================================
# Global / runner (hooks/shared/head.sh)
# =============================================================================

# Staging tree for the initramfs contents (default: build).
#YARAMFS_CFG_PREPARE_BUILD_DIR=build

# Host config dir with numbered hook symlinks (default: config).
# Guest /init sets this to /hooks.
#YARAMFS_CFG_CONFIG_DIR=config

# Append-only exports file between hook processes (default: /tmp/yaramfs_exports).
#YARAMFS_CFG_EXPORTS_FILE=/tmp/yaramfs_exports

# lddtree used by install_binary (default: which lddtree).
#YARAMFS_CFG_PREPARE_LDDTREE=

# =============================================================================
# base
# =============================================================================

# Host busybox binary installed into the image (default: which busybox).
#YARAMFS_CFG_PREPARE_BUSYBOX_PATH=

# Host proot used to run busybox --install inside the build root (default: which proot).
#YARAMFS_CFG_PREPARE_PROOT=

# =============================================================================
# prepare-network
# =============================================================================

# Override NIC modules for the image; disables lsmod autodetection.
# Unset = from lsmod, keep names whose modinfo path contains /net/.
# Set empty = no NIC modules from this hook (8021q is still always added).
# To append without disabling autodetection, use YARAMFS_CFG_PREPARE_MODULES_ADDL.
#YARAMFS_CFG_PREPARE_NETWORK_MODULES="virtio_net virtio_pci"

# =============================================================================
# prepare-input
# =============================================================================

# Override input/hid modules; disables autodetection. Empty = none.
# Unset = from lsmod, keep names whose modinfo path contains /input/ or /hid/.
#YARAMFS_CFG_PREPARE_INPUT_MODULES=

# =============================================================================
# prepare-iscsi
# =============================================================================

# Host iscsistart path (default: which iscsistart). Must be executable.
#YARAMFS_CFG_PREPARE_ISCSITART=

# =============================================================================
# prepare-dropbear
# =============================================================================

# Host dropbear tool paths (default: which <name>). Missing/non-executable fails prepare.
# Installs into /bin in the image (+ shared libs). No host keys, no server start.
#YARAMFS_CFG_PREPARE_DROPBEAR=
#YARAMFS_CFG_PREPARE_DBCLIENT=
#YARAMFS_CFG_PREPARE_DROPBEARKEY=
#YARAMFS_CFG_PREPARE_DROPBEARCONVERT=

# =============================================================================
# modules
# =============================================================================

# Explicit module names (space-separated) always considered for the image.
#YARAMFS_CFG_PREPARE_MODULES="ext4"

# Extra names accumulated by earlier prepare hooks (export_cfg). You can also
# set this yourself to append (e.g. virtio for qemu netroot tests).
#YARAMFS_CFG_PREPARE_MODULES_ADDL="virtio_net virtio_pci"

# Kernel version for the module tree to pack (default: uname -r).
# installkernel sets this to the kernel being installed (may differ from uname -r).
#YARAMFS_CFG_PREPARE_KERNEL_VERSION=

# Modules directory (default: /lib/modules/$YARAMFS_CFG_PREPARE_KERNEL_VERSION).
# Must look like …/lib/modules/<kver>. Resolution uses kmod only:
#   modprobe -d ROOT -S KVER -D   (ROOT = parent of lib/modules/KVER)
# so installkernel/chroot can pack a non-running kver. Busybox modprobe is not used.
#YARAMFS_CFG_PREPARE_MODULES_DIR=

# Optional path to kmod modprobe if not on PATH / shadowed by busybox.
#YARAMFS_CFG_PREPARE_MODPROBE=/sbin/modprobe

# =============================================================================
# boot-provisioned-config
# Optional override of baked boot_config.sh from a local filesystem (e.g. USB).
# =============================================================================

# Filesystem UUID (no UUID= prefix). Empty/unset = hook no-ops.
#YARAMFS_CFG_BOOT_PROVISIONED_UUID=

# Absolute path on that filesystem to a shell env file (same format as boot_config.sh).
# Required when UUID is set.
#YARAMFS_CFG_BOOT_PROVISIONED_PATH=/yaramfs/boot_config.sh

# Seconds to wait for the device via busybox findfs (default: 10).
#YARAMFS_CFG_BOOT_PROVISIONED_DELAY=10

# Temporary mount point inside initramfs (default: /mnt/provisioned).
#YARAMFS_CFG_BOOT_PROVISIONED_MNT=/mnt/provisioned

# =============================================================================
# boot-netroot-network
# NIC config keyed by MAC id: lowercase hex, no colons
#   aa:bb:cc:dd:ee:ff → aabbccddeeff
# Unset fields filled from iBFT ethernet* with the same MAC when present.
# Pre-set CFG always wins. Optional GATEWAY → default route.
# =============================================================================

# iBFT sysfs root (default: /sys/firmware/ibft). Used to discover MACs / fill unset fields.
#YARAMFS_CFG_BOOT_NETROOT_IBFT_DIR=/sys/firmware/ibft

# Per-NIC (replace <macid> with e.g. 525400123456):
#YARAMFS_CFG_BOOT_NETROOT_<macid>_IP=10.0.2.15
#YARAMFS_CFG_BOOT_NETROOT_<macid>_PREFIX=24
#YARAMFS_CFG_BOOT_NETROOT_<macid>_NETMASK=
#YARAMFS_CFG_BOOT_NETROOT_<macid>_GATEWAY=10.0.2.2
#YARAMFS_CFG_BOOT_NETROOT_<macid>_VLAN=

# Example (qemu SLIRP + YARAMFS_CFG_PREPARE_QEMU_NET_MAC=52:54:00:12:34:56):
#YARAMFS_CFG_BOOT_NETROOT_525400123456_IP=10.0.2.15
#YARAMFS_CFG_BOOT_NETROOT_525400123456_PREFIX=24
#YARAMFS_CFG_BOOT_NETROOT_525400123456_GATEWAY=10.0.2.2
#YARAMFS_CFG_BOOT_NETROOT_525400123456_VLAN=100

# =============================================================================
# boot-iscsi
# Manual login when all four of INITIATORNAME / TARGET_NAME / TARGET_IP / TARGET_TPGT
# are set. Leave all unset for iBFT (iscsistart -b). Partial set is an error.
# =============================================================================

# Seconds before killing hung iscsistart (default: 60).
#YARAMFS_CFG_BOOT_ISCSI_TIMEOUT=60

#YARAMFS_CFG_BOOT_ISCSI_INITIATORNAME=iqn.2024-01.local:initiator
#YARAMFS_CFG_BOOT_ISCSI_TARGET_NAME=iqn.2024-01.local:target
#YARAMFS_CFG_BOOT_ISCSI_TARGET_IP=10.0.2.2
#YARAMFS_CFG_BOOT_ISCSI_TARGET_TPGT=1
# Optional portal port for manual mode (iscsistart default 3260 if unset).
#YARAMFS_CFG_BOOT_ISCSI_TARGET_PORT=3260

# =============================================================================
# custom
# Host payload dir copied to build/hooks/env/custom/. Boot runs custom.sh if present.
# =============================================================================

# Host directory to copy (default: $YARAMFS_CFG_CONFIG_DIR/env/custom).
# Missing dir = prepare no-op.
#YARAMFS_CFG_PREPARE_CUSTOM_DIR=

# =============================================================================
# boot-force-debug
# Non-empty → this boot hook dies; guest /init drops to recovery shell.
# Leave unset/empty for normal boot (config/85-boot-force-debug.sh may stay linked).
# =============================================================================

#YARAMFS_CFG_BOOT_FORCE_DEBUG=1

# =============================================================================
# boot-root
# Device selection is mostly kernel cmdline (root=, rootfstype=, rootflags=,
# rootdelay=, init=). busybox findfs: /dev/…, UUID=…, LABEL=… (no PARTUUID).
# These CFG vars can bake defaults; cmdline fills ROOT/ROOTFSTYPE/etc at boot.
# =============================================================================

# Mount point inside initramfs (default: /mnt/root).
#YARAMFS_CFG_BOOT_NEWROOT_MNT=/mnt/root

# Usually filled from cmdline at boot; INIT defaults to /sbin/init if unset.
#YARAMFS_CFG_BOOT_ROOT=
#YARAMFS_CFG_BOOT_ROOTFSTYPE=
#YARAMFS_CFG_BOOT_ROOTFLAGS=ro
#YARAMFS_CFG_BOOT_ROOTDELAY=30
#YARAMFS_CFG_BOOT_INIT=/sbin/init

# Set by boot-root after mount (export_cfg for PID 1); not typically set by hand:
#   YARAMFS_CFG_BOOT_NEWROOT

# =============================================================================
# prepare-cpio
# =============================================================================

# Output initramfs path (default: out/initramfs.cpio.gz).
#YARAMFS_CFG_PREPARE_OUT_CPIO=out/initramfs.cpio.gz

# Compressor binary (default: pigz if present, else gzip).
#YARAMFS_CFG_PREPARE_GZIP=

# =============================================================================
# prepare-qemu
# =============================================================================

# Kernel image path. Unset = skip qemu (image-only prepare).
#YARAMFS_CFG_PREPARE_KERNEL=

# Initrd path (default: out/initramfs.cpio.gz; must exist from prepare-cpio).
#YARAMFS_CFG_PREPARE_OUT_CPIO=out/initramfs.cpio.gz

#YARAMFS_CFG_PREPARE_QEMU_MACHINE=virt
#YARAMFS_CFG_PREPARE_QEMU_CPU=max
#YARAMFS_CFG_PREPARE_QEMU_MEM=1024

# Kernel cmdline (default: console=ttyAMA0 rdinit=/init panic=1).
# Add root=UUID=… etc. for real root tests.
#YARAMFS_CFG_PREPARE_QEMU_APPEND="console=ttyAMA0 rdinit=/init panic=1"

# Optional guest NIC MAC for netroot testing (e.g. 52:54:00:12:34:56).
# Unset = no NIC. Image needs virtio_net (MODULES_ADDL / network override).
# SLIRP guest IP is typically 10.0.2.15/24.
#YARAMFS_CFG_PREPARE_QEMU_NET_MAC=52:54:00:12:34:56
