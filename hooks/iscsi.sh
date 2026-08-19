#!/bin/sh
. hooks/shared/head.sh
. hooks/shared/install.sh

# Software iSCSI + iBFT (no NIC drivers — those come from the modules hook).
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
    echo "iscsi: /etc/iscsi/iscsid.conf not readable, skipping" >&2
  fi
}

boot() {
  # Config order is before modules (ADDL at prepare); load the prepared list first.
  if [ -f /etc/yaramfs-modules ]; then
    while read -r m || [ -n "${m}" ]; do
      [ -n "${m}" ] || continue
      modprobe "${m}" || die ${LINENO} "modprobe ${m} failed"
    done < /etc/yaramfs-modules
  fi

  # Hard-fail iBFT network + session (hook is opt-in via config symlink).
  iscsistart -N || die ${LINENO} "iscsistart -N (iBFT network) failed"
  iscsistart -b || die ${LINENO} "iscsistart -b (iBFT connect) failed"
}

prepare_or_boot "$@"
