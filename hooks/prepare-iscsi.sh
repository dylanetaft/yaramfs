#!/bin/sh
. hooks/shared/head.sh

# Software iSCSI image bits (NIC drivers come from the network hook).

# Boot session is boot-iscsi.sh (after modules).
ISCSI_MODULES="iscsi_boot_sysfs iscsi_ibft scsi_transport_iscsi libiscsi libiscsi_tcp iscsi_tcp"

prepare() {
  default_value YARAMFS_CFG_P_ISCSITART "$(which iscsistart)" ${LINENO}
  BUILD_DIR=${YARAMFS_CFG_PREP_BUILD_DIR}

  if [ ! -x "${YARAMFS_CFG_P_ISCSITART}" ]; then
    die ${LINENO} "iscsistart not executable: ${YARAMFS_CFG_P_ISCSITART}"
  fi

  # Sourced into the same shell as later hooks — assignment is enough (no export).
  YARAMFS_CFG_MODULES_ADDL="${YARAMFS_CFG_MODULES_ADDL} ${ISCSI_MODULES}"

  install_binary "${YARAMFS_CFG_P_ISCSITART}" /sbin/iscsistart

  mkdir -p "${BUILD_DIR}/var/lib/iscsi"
  mkdir -p "${BUILD_DIR}/etc/iscsi"

  # iscsid.conf is often mode 0600 root-only; skip if unreadable.
  if [ -r /etc/iscsi/iscsid.conf ]; then
    cp -a /etc/iscsi/iscsid.conf "${BUILD_DIR}/etc/iscsi/iscsid.conf"
  elif [ -e /etc/iscsi/iscsid.conf ]; then
    echo "prepare-iscsi: /etc/iscsi/iscsid.conf not readable, skipping" >&2
  fi
}

boot() { :; }

prepare_or_boot "$@"
