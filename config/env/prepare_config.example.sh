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

# NIC modules come from lsmod (modinfo path contains /net/); 8021q always added.
# Extra names: YARAMFS_CFG_PREPARE_MODULES_ADDL (see modules section).

# =============================================================================
# prepare-input
# =============================================================================

# Input/hid modules come from lsmod (modinfo path contains /input/ or /hid/).
# Extra names: YARAMFS_CFG_PREPARE_MODULES_ADDL (see modules section).

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

# Seconds to wait for the device via busybox blkid (default: 10).
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
# Non-empty → this boot hook dies; guest /init opens a child recovery shell
# (PID 1 stays /init; exit shell to retry switch_root). Works even after
# boot-root mounted root (failed hooks force recovery before switch_root).
# Leave unset/empty for normal boot (config/65-boot-force-debug.sh may stay linked).
# Put this in provisioned boot_config.sh (or prepare_config so it is saved to
# boot_config.sh) — only YARAMFS_CFG_BOOT_* reach the guest.
# =============================================================================

#YARAMFS_CFG_BOOT_FORCE_DEBUG=1

# =============================================================================
# multipath (opt-in pair; both recommended together)
#   config/20-prepare-multipath.sh  — before modules (MODULES_ADDL + binary)
#   config/55-boot-multipath.sh     — after boot-iscsi, before boot-root
# Packs multipath CLI + kpartx + modules (no multipathd, no udevd).
# boot-multipath: WWID allowlist → multipath on matching whole disks → kpartx.
# failure → recovery shell. multipathd not required; CLI reads multipath.conf.
# boot-root still prefers /dev/mapper/* for UUID=/LABEL= resolve.
# Do not mount root from path partitions (/dev/sdb2); use mapper …-partN.
# =============================================================================

#YARAMFS_CFG_PREPARE_MULTIPATH=          # path to multipath (default: which)
#YARAMFS_CFG_PREPARE_KPARTX=             # path to kpartx (default: which)
# Built-in multipath modules are always appended to MODULES_ADDL.
# Extra names: YARAMFS_CFG_PREPARE_MODULES_ADDL (see modules section).

# Plugin dir (libchecktur.so, libprio*.so, …). Default: first of
# /lib64/multipath, /usr/lib64/multipath, /lib/multipath, … with libcheck*.so.
# Packed at the same absolute path in the image (dlopen / MULTIPATH_DIR).
#YARAMFS_CFG_PREPARE_MULTIPATH_LIBDIR=/lib64/multipath

# Opt-in: bake a multipath.conf into the image (default: unset = none / clean room).
# Use a dedicated file or host /etc/multipath.conf. Filtering (blacklist,
# find_multipaths, …) applies when boot-multipath runs multipath -v2.
#YARAMFS_CFG_PREPARE_MULTIPATH_CONF=/etc/multipath.conf

# --- boot-multipath (baked into boot_config via YARAMFS_CFG_BOOT_*) ---
# Required when boot-multipath is linked. Space- or comma-separated.
# Read from a path: cat /sys/block/sdX/device/wwid  or  …/nvme0n1/wwid
# Same WWID on every path to one LUN/namespace (both iscsi paths → one entry).
# Unset/empty → die (no multipath-all mode).
#YARAMFS_CFG_BOOT_MULTIPATH_WWID="naa.60060160deadbeef eui.0123…"
# Optional extra multipath CLI args (e.g. -i).
#YARAMFS_CFG_BOOT_MULTIPATH_ARGS=
# kpartx after maps (default 1). Set 0 to skip (whole-disk root/LVM only).
#YARAMFS_CFG_BOOT_MULTIPATH_KPARTX=1
# kpartx -p delimiter (default -part → /dev/mapper/<id>-part2).
#YARAMFS_CFG_BOOT_MULTIPATH_KPARTX_DELIM=-part

# =============================================================================
# boot-root
# Device selection is mostly kernel cmdline (root=, rootfstype=, rootflags=,
# rootdelay=, init=). busybox blkid: /dev/…, UUID=…, LABEL=… (no PARTUUID).
# UUID/LABEL: blkid hits; prefer /dev/mapper/* (multipath maps), else first other.
# /dev/* as-is. These CFG vars can bake defaults; cmdline fills ROOT/… at boot.
# =============================================================================

# Mount point inside initramfs (default: /mnt/root).
# Also the default path /init probes after a recovery shell exits.
#YARAMFS_CFG_BOOT_NEWROOT_MNT=/mnt/root

# Usually filled from cmdline at boot; INIT defaults to /sbin/init if unset.
#YARAMFS_CFG_BOOT_ROOT=
#YARAMFS_CFG_BOOT_ROOTFSTYPE=
#YARAMFS_CFG_BOOT_ROOTFLAGS=ro
#YARAMFS_CFG_BOOT_ROOTDELAY=30
#YARAMFS_CFG_BOOT_INIT=/sbin/init

# Set by boot-root after mount (export_cfg for PID 1); not typically set by hand:
#   YARAMFS_CFG_BOOT_NEWROOT
#
# Recovery shell (child of /init): mount root on NEWROOT_MNT, then exit.
# Optional markers if not using the default path/init:
#   /tmp/yaramfs_newroot  — first line = mount path
#   /tmp/yaramfs_init     — first line = init path on that root (e.g. /sbin/init)

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
# Unset = no NIC. Image needs virtio_net (YARAMFS_CFG_PREPARE_MODULES_ADDL).
# SLIRP guest IP is typically 10.0.2.15/24.
#YARAMFS_CFG_PREPARE_QEMU_NET_MAC=52:54:00:12:34:56
