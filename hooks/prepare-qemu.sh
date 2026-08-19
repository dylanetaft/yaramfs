#!/bin/sh
. hooks/shared/head.sh

prepare() {
  default_value YARAMFS_CFG_OUT_CPIO "out/initramfs.cpio.gz" ${LINENO}
  default_value YARAMFS_CFG_QEMU_MACHINE "virt" ${LINENO}
  default_value YARAMFS_CFG_QEMU_CPU "max" ${LINENO}
  default_value YARAMFS_CFG_QEMU_MEM "1024" ${LINENO}
  default_value YARAMFS_CFG_QEMU_APPEND "console=ttyAMA0 rdinit=/init panic=1" ${LINENO}

  OUT=${YARAMFS_CFG_OUT_CPIO}

  # Opt-in: skip quietly when no kernel is configured (image-only prepare).
  if [ -z "${YARAMFS_CFG_KERNEL}" ]; then
    echo "qemu: YARAMFS_CFG_KERNEL unset, skipping" >&2
    return 0
  fi
  if [ ! -f "${YARAMFS_CFG_KERNEL}" ]; then
    die ${LINENO} "kernel not found: ${YARAMFS_CFG_KERNEL}"
  fi
  if [ ! -f "${OUT}" ]; then
    die ${LINENO} "missing ${OUT} (cpio prepare must run first)"
  fi

  # Console-only: no GUI. Exit qemu from serial mon with Ctrl-A then X.
  exec qemu-system-aarch64 \
    -M "${YARAMFS_CFG_QEMU_MACHINE}" \
    -cpu "${YARAMFS_CFG_QEMU_CPU}" \
    -m "${YARAMFS_CFG_QEMU_MEM}" \
    -nographic \
    -serial mon:stdio \
    -kernel "${YARAMFS_CFG_KERNEL}" \
    -initrd "${OUT}" \
    -append "${YARAMFS_CFG_QEMU_APPEND}"
}

boot() { :; }

prepare_or_boot "$@"
