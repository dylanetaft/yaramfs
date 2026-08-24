#!/bin/sh
. hooks/shared/head.sh

# dm-multipath image bits for use **with** the udev hook (real udev cookies).
# Prepare-only (config/NN-prepare-multipath-udev.sh). Must run before modules.
# Guest boot is boot-multipath-udev.sh (after iscsi, before boot-root).
#
# Requires udev (config/NN-udev.sh). Do **not** also link legacy
# prepare-multipath / boot-multipath (DM_DISABLE_UDEV path).
#
# Same packing as prepare-multipath: multipath CLI + kpartx + plugins + modules.
# No multipathd. Rules stay in the udev hook (not here).

MULTIPATH_MODULES_DEFAULT="dm_mod dm_multipath dm_round_robin dm_service_time dm_queue_length scsi_dh_alua scsi_dh_rdac"

_multipath_find_plugindir() {
  if [ -n "${YARAMFS_CFG_PREPARE_MULTIPATH_LIBDIR}" ]; then
    if [ ! -d "${YARAMFS_CFG_PREPARE_MULTIPATH_LIBDIR}" ]; then
      die ${LINENO} "MULTIPATH_LIBDIR not a directory: ${YARAMFS_CFG_PREPARE_MULTIPATH_LIBDIR}"
    fi
    printf '%s\n' "${YARAMFS_CFG_PREPARE_MULTIPATH_LIBDIR}"
    return 0
  fi

  for _mp_d in \
    /lib64/multipath \
    /usr/lib64/multipath \
    /lib/multipath \
    /usr/lib/multipath \
    /usr/lib/x86_64-linux-gnu/multipath \
    /usr/lib/aarch64-linux-gnu/multipath
  do
    [ -d "${_mp_d}" ] || continue
    for _mp_c in "${_mp_d}"/libcheck*.so; do
      if [ -f "${_mp_c}" ]; then
        printf '%s\n' "${_mp_d}"
        return 0
      fi
      break
    done
  done
  return 1
}

prepare() {
  BUILD_DIR=${YARAMFS_CFG_PREPARE_BUILD_DIR}

  default_value YARAMFS_CFG_PREPARE_MULTIPATH "$(which multipath 2>/dev/null)" ${LINENO}
  if [ ! -x "${YARAMFS_CFG_PREPARE_MULTIPATH}" ]; then
    die ${LINENO} "multipath not executable: ${YARAMFS_CFG_PREPARE_MULTIPATH:-"(unset)"}"
  fi

  YARAMFS_CFG_PREPARE_MODULES_ADDL="${YARAMFS_CFG_PREPARE_MODULES_ADDL} ${MULTIPATH_MODULES_DEFAULT}"
  YARAMFS_CFG_PREPARE_MODULES_ADDL=${YARAMFS_CFG_PREPARE_MODULES_ADDL# }
  export_cfg YARAMFS_CFG_PREPARE_MODULES_ADDL

  install_binary "${YARAMFS_CFG_PREPARE_MULTIPATH}" /sbin/multipath

  default_value YARAMFS_CFG_PREPARE_KPARTX "$(which kpartx 2>/dev/null)" ${LINENO}
  if [ ! -x "${YARAMFS_CFG_PREPARE_KPARTX}" ]; then
    die ${LINENO} "kpartx not executable: ${YARAMFS_CFG_PREPARE_KPARTX:-"(unset)"} (install multipath-tools or set YARAMFS_CFG_PREPARE_KPARTX)"
  fi
  install_binary "${YARAMFS_CFG_PREPARE_KPARTX}" /sbin/kpartx

  if ! _mp_plug=$(_multipath_find_plugindir); then
    die ${LINENO} "multipath plugin dir not found (libcheck*.so); set YARAMFS_CFG_PREPARE_MULTIPATH_LIBDIR"
  fi
  _mp_nplug=0
  for _mp_so in "${_mp_plug}"/*.so; do
    [ -f "${_mp_so}" ] || continue
    install_binary "${_mp_so}" "${_mp_so}"
    _mp_nplug=$((_mp_nplug + 1))
  done
  if [ "${_mp_nplug}" -eq 0 ]; then
    die ${LINENO} "no *.so plugins in ${_mp_plug}"
  fi
  echo "prepare-multipath-udev: ${_mp_nplug} plugin(s) from ${_mp_plug}" >&2

  mkdir -p "${BUILD_DIR}/etc/multipath"
  mkdir -p "${BUILD_DIR}/var/lib/multipath"

  if [ -n "${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}" ]; then
    [ -r "${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}" ] \
      || die ${LINENO} "multipath conf not readable: ${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}"
    [ -f "${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}" ] \
      || die ${LINENO} "multipath conf not a regular file: ${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}"
    cp -a "${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}" "${BUILD_DIR}/etc/multipath.conf" \
      || die ${LINENO} "failed to copy multipath conf"
    echo "prepare-multipath-udev: baked ${YARAMFS_CFG_PREPARE_MULTIPATH_CONF} -> /etc/multipath.conf" >&2
  fi
}

boot() { :; }

prepare_or_boot "$@"
