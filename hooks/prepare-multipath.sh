#!/bin/sh
. hooks/shared/head.sh

# dm-multipath image bits: modules + multipath CLI + kpartx + plugins (not multipathd).
# Prepare-only (config/NN-prepare-multipath.sh). Must run before modules so
# MODULES_ADDL is packed. Guest boot is boot-multipath.sh (after iscsi, before
# boot-root).
# Clean room by default: no host multipath.conf / wwids / bindings / conf.d.
# multipath uses libdevmapper (via install_binary). kpartx is packed so boot can
# map partitions on multipath disks (root on …-partN) without udevd.
# Path checkers/prioritizers are dlopen plugins under …/multipath/ (e.g. tur →
# libchecktur.so); not ELF NEEDED of the multipath binary — packed separately.
# The multipath CLI alone builds DM maps at boot; multipathd is only needed later
# for ongoing path monitoring (not in this image).
# Boot filters paths by YARAMFS_CFG_BOOT_MULTIPATH_WWID (sysfs wwid; required).

# Default module set; kmod pulls further deps. Extra modules: YARAMFS_CFG_PREPARE_MODULES_ADDL.
MULTIPATH_MODULES_DEFAULT="dm_mod dm_multipath dm_round_robin dm_service_time dm_queue_length scsi_dh_alua scsi_dh_rdac"

# Print host multipath plugin dir (checkers/prios), or fail.
# Override: YARAMFS_CFG_PREPARE_MULTIPATH_LIBDIR. Else first candidate with libcheck*.so.
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
    # Prefer a real checker plugin dir over an empty placeholder.
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

  # kpartx: partition maps on multipath whole disks (boot-multipath, after multipath).
  default_value YARAMFS_CFG_PREPARE_KPARTX "$(which kpartx 2>/dev/null)" ${LINENO}
  if [ ! -x "${YARAMFS_CFG_PREPARE_KPARTX}" ]; then
    die ${LINENO} "kpartx not executable: ${YARAMFS_CFG_PREPARE_KPARTX:-"(unset)"} (install multipath-tools or set YARAMFS_CFG_PREPARE_KPARTX)"
  fi
  install_binary "${YARAMFS_CFG_PREPARE_KPARTX}" /sbin/kpartx

  # Plugins (tur, alua prio, …): same absolute path in the image so compile-time
  # MULTIPATH_DIR matches. install_binary also flattens each plugin's ELF deps.
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
  echo "prepare-multipath: ${_mp_nplug} plugin(s) from ${_mp_plug}" >&2

  # Runtime dirs only (empty). boot-multipath also mkdir -p these before multipath -v2.
  mkdir -p "${BUILD_DIR}/etc/multipath"
  mkdir -p "${BUILD_DIR}/var/lib/multipath"

  # Opt-in conf only (unset/empty = clean room, multipath built-in defaults).
  # Path to a multipath.conf to bake as /etc/multipath.conf (blacklist,
  # find_multipaths, etc. are applied by the multipath CLI without multipathd).
  if [ -n "${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}" ]; then
    [ -r "${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}" ] \
      || die ${LINENO} "multipath conf not readable: ${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}"
    [ -f "${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}" ] \
      || die ${LINENO} "multipath conf not a regular file: ${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}"
    cp -a "${YARAMFS_CFG_PREPARE_MULTIPATH_CONF}" "${BUILD_DIR}/etc/multipath.conf" \
      || die ${LINENO} "failed to copy multipath conf"
    echo "prepare-multipath: baked ${YARAMFS_CFG_PREPARE_MULTIPATH_CONF} -> /etc/multipath.conf" >&2
  fi
}

boot() { :; }

prepare_or_boot "$@"
