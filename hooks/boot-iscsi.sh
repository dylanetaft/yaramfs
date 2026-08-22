#!/bin/sh
. hooks/shared/head.sh

# iSCSI session: explicit CFG or iBFT (-b).
# Config order must be after modules (and boot-netroot-network).
#
# Manual mode when all of these are non-empty:
#   YARAMFS_CFG_BOOT_ISCSI_INITIATORNAME
#   YARAMFS_CFG_BOOT_ISCSI_TARGET_NAME
#   YARAMFS_CFG_BOOT_ISCSI_TARGET_IP
#   YARAMFS_CFG_BOOT_ISCSI_TARGET_TPGT
# Optional: YARAMFS_CFG_BOOT_ISCSI_TARGET_PORT (default iscsistart 3260).
# If none of the four are set → iscsistart -b (iBFT).
# Partial set → die (do not fall through to -b).

prepare() { :; }

boot() {
  # iscsistart often hangs forever on bad target/iBFT; force a wall clock limit.
  default_value YARAMFS_CFG_BOOT_ISCSI_TIMEOUT "60" ${LINENO}

  _ini=${YARAMFS_CFG_BOOT_ISCSI_INITIATORNAME-}
  _tname=${YARAMFS_CFG_BOOT_ISCSI_TARGET_NAME-}
  _tip=${YARAMFS_CFG_BOOT_ISCSI_TARGET_IP-}
  _tpgt=${YARAMFS_CFG_BOOT_ISCSI_TARGET_TPGT-}
  _tport=${YARAMFS_CFG_BOOT_ISCSI_TARGET_PORT-}

  _n=0
  [ -n "${_ini}" ] && _n=$((_n + 1))
  [ -n "${_tname}" ] && _n=$((_n + 1))
  [ -n "${_tip}" ] && _n=$((_n + 1))
  [ -n "${_tpgt}" ] && _n=$((_n + 1))

  if [ "${_n}" -eq 4 ]; then
    set -- iscsistart \
      -i "${_ini}" \
      -t "${_tname}" \
      -g "${_tpgt}" \
      -a "${_tip}"
    [ -n "${_tport}" ] && set -- "$@" -p "${_tport}"
    timeout "${YARAMFS_CFG_BOOT_ISCSI_TIMEOUT}" "$@" \
      || die ${LINENO} "iscsistart (manual) failed or timed out after ${YARAMFS_CFG_BOOT_ISCSI_TIMEOUT}s"
  elif [ "${_n}" -gt 0 ]; then
    die ${LINENO} "incomplete YARAMFS_CFG_BOOT_ISCSI_* (need INITIATORNAME TARGET_NAME TARGET_IP TARGET_TPGT, or leave all unset for iBFT -b)"
  else
    timeout "${YARAMFS_CFG_BOOT_ISCSI_TIMEOUT}" iscsistart -b \
      || die ${LINENO} "iscsistart -b failed or timed out after ${YARAMFS_CFG_BOOT_ISCSI_TIMEOUT}s"
  fi
}

prepare_or_boot "$@"
