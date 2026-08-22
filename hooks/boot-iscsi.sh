#!/bin/sh
. hooks/shared/head.sh

# iSCSI session from iBFT. Config order must be after modules (and boot-network-ibft).

prepare() { :; }

boot() {
  # iscsistart -b often hangs forever on bad iBFT/target; force a wall clock limit.
  default_value YARAMFS_CFG_BOOT_ISCSI_TIMEOUT "60" ${LINENO}
  timeout "${YARAMFS_CFG_BOOT_ISCSI_TIMEOUT}" iscsistart -b \
    || die ${LINENO} "iscsistart -b failed or timed out after ${YARAMFS_CFG_BOOT_ISCSI_TIMEOUT}s"
}

prepare_or_boot "$@"
