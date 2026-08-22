#!/bin/sh
. hooks/shared/head.sh

prepare() {
  default_value YARAMFS_CFG_PREPARE_OUT_CPIO "out/initramfs.cpio.gz" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_QEMU_MACHINE "virt" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_QEMU_CPU "max" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_QEMU_MEM "1024" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_QEMU_APPEND "console=ttyAMA0 rdinit=/init panic=1" ${LINENO}

  OUT=${YARAMFS_CFG_PREPARE_OUT_CPIO}

  # Opt-in: skip quietly when no kernel is configured (image-only prepare).
  if [ -z "${YARAMFS_CFG_PREPARE_KERNEL}" ]; then
    echo "qemu: YARAMFS_CFG_PREPARE_KERNEL unset, skipping" >&2
    return 0
  fi
  if [ ! -f "${YARAMFS_CFG_PREPARE_KERNEL}" ]; then
    die ${LINENO} "kernel not found: ${YARAMFS_CFG_PREPARE_KERNEL}"
  fi
  if [ ! -f "${OUT}" ]; then
    die ${LINENO} "missing ${OUT} (cpio prepare must run first)"
  fi

  # Optional NIC with fixed MAC for netroot / iscsi smoke tests.
  # Unset = no network device (previous behavior). Set e.g. 52:54:00:12:34:56
  # → user (SLIRP) netdev + virtio-net-pci. Guest needs virtio_net in the image.
  _qemu_net=
  if [ -n "${YARAMFS_CFG_PREPARE_QEMU_NET_MAC}" ]; then
    _qemu_net="-netdev user,id=net0 -device virtio-net-pci,netdev=net0,mac=${YARAMFS_CFG_PREPARE_QEMU_NET_MAC}"
  fi

  # Console-only: no GUI. Exit qemu from serial mon with Ctrl-A then X.
  # word-split intentional for optional _qemu_net pair.
  # shellcheck disable=SC2086
  exec qemu-system-aarch64 \
    -M "${YARAMFS_CFG_PREPARE_QEMU_MACHINE}" \
    -cpu "${YARAMFS_CFG_PREPARE_QEMU_CPU}" \
    -m "${YARAMFS_CFG_PREPARE_QEMU_MEM}" \
    -nographic \
    -serial mon:stdio \
    ${_qemu_net} \
    -kernel "${YARAMFS_CFG_PREPARE_KERNEL}" \
    -initrd "${OUT}" \
    -append "${YARAMFS_CFG_PREPARE_QEMU_APPEND}"
}

boot() { :; }

prepare_or_boot "$@"
