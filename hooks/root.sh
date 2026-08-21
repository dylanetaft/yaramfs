#!/bin/sh
. hooks/shared/head.sh

# Resolve root= from the kernel cmdline (busybox findfs: UUID= / LABEL=),
# mount it on /mnt/root, and export paths so PID 1 /init can switch_root.
# PARTUUID/PARTLABEL are not supported (busybox findfs has no partition tags).

prepare() { :; }

# Parse one KEY=value (or bare flag) from a cmdline token into globals.
_root_parse_token() {
  _tok=$1
  case "${_tok}" in
    root=*)
      YARAMFS_CFG_ROOT=${_tok#root=}
      ;;
    rootfstype=*)
      YARAMFS_CFG_ROOTFSTYPE=${_tok#rootfstype=}
      ;;
    rootflags=*)
      YARAMFS_CFG_ROOTFLAGS=${_tok#rootflags=}
      ;;
    rootdelay=*)
      YARAMFS_CFG_ROOTDELAY=${_tok#rootdelay=}
      ;;
    init=*)
      YARAMFS_CFG_INIT=${_tok#init=}
      ;;
  esac
}

_root_parse_cmdline() {
  if [ ! -r /proc/cmdline ]; then
    die ${LINENO} "/proc/cmdline not readable"
  fi
  # Word-split is intentional: kernel cmdline is space-separated tokens.
  # shellcheck disable=SC2013
  for _tok in $(cat /proc/cmdline); do
    _root_parse_token "${_tok}"
  done
}

# Print block device path for ROOT spec, or fail.
# Supports /dev/*, UUID=, LABEL= (busybox findfs).
_root_resolve() {
  _spec=$1
  if [ -z "${_spec}" ]; then
    return 1
  fi

  case "${_spec}" in
    /dev/*)
      if [ -b "${_spec}" ]; then
        printf '%s\n' "${_spec}"
        return 0
      fi
      return 1
      ;;
    UUID=*|LABEL=*)
      _dev=$(findfs "${_spec}" 2>/dev/null) || return 1
      if [ -n "${_dev}" ] && [ -b "${_dev}" ]; then
        printf '%s\n' "${_dev}"
        return 0
      fi
      return 1
      ;;
    PARTUUID=*|PARTLABEL=*)
      die ${LINENO} "root=${_spec}: busybox findfs supports UUID=/LABEL= only"
      ;;
    *)
      die ${LINENO} "unsupported root= spec: ${_spec}"
      ;;
  esac
}

# Wait until _root_resolve succeeds, up to rootdelay=N seconds (default 30).
_root_wait_resolve() {
  _spec=$1
  _delay=${YARAMFS_CFG_ROOTDELAY:-30}
  _n=0
  _dev=

  while :; do
    if _dev=$(_root_resolve "${_spec}"); then
      printf '%s\n' "${_dev}"
      return 0
    fi

    if [ "${_n}" -ge "${_delay}" ]; then
      return 1
    fi

    sleep 1
    _n=$((_n + 1))
    # Progress every 5s so serial consoles are not silent on slow iSCSI.
    if [ $((_n % 5)) -eq 0 ]; then
      echo "yaramfs: waiting for root=${_spec} (${_n}s)" >&2
    fi
  done
}

boot() {
  default_value YARAMFS_CFG_NEWROOT_MNT "/mnt/root" ${LINENO}

  _root_parse_cmdline

  if [ -z "${YARAMFS_CFG_ROOT}" ]; then
    echo "yaramfs: no root= on cmdline, skipping mount" >&2
    return 0
  fi

  echo "yaramfs: root=${YARAMFS_CFG_ROOT}" >&2

  _dev=$(_root_wait_resolve "${YARAMFS_CFG_ROOT}") \
    || die ${LINENO} "root device not found: ${YARAMFS_CFG_ROOT}"

  echo "yaramfs: resolved root -> ${_dev}" >&2

  mkdir -p "${YARAMFS_CFG_NEWROOT_MNT}" \
    || die ${LINENO} "mkdir ${YARAMFS_CFG_NEWROOT_MNT} failed"

  # Kernel default is ro when rootflags= is absent.
  default_if_unset YARAMFS_CFG_ROOTFLAGS "ro" ${LINENO}
  [ -n "${YARAMFS_CFG_ROOTFLAGS}" ] || YARAMFS_CFG_ROOTFLAGS=ro

  _mnt_args=
  if [ -n "${YARAMFS_CFG_ROOTFSTYPE}" ]; then
    _mnt_args="-t ${YARAMFS_CFG_ROOTFSTYPE}"
  fi
  # shellcheck disable=SC2086
  mount ${_mnt_args} -o "${YARAMFS_CFG_ROOTFLAGS}" "${_dev}" "${YARAMFS_CFG_NEWROOT_MNT}" \
    || die ${LINENO} "mount ${_dev} on ${YARAMFS_CFG_NEWROOT_MNT} failed"

  default_value YARAMFS_CFG_INIT "/sbin/init" ${LINENO}

  if [ ! -e "${YARAMFS_CFG_NEWROOT_MNT}${YARAMFS_CFG_INIT}" ]; then
    die ${LINENO} "init not found on new root: ${YARAMFS_CFG_INIT}"
  fi

  YARAMFS_CFG_NEWROOT=${YARAMFS_CFG_NEWROOT_MNT}
  export_cfg YARAMFS_CFG_NEWROOT YARAMFS_CFG_INIT
  echo "yaramfs: mounted ${_dev} at ${YARAMFS_CFG_NEWROOT} (init=${YARAMFS_CFG_INIT})" >&2
}

prepare_or_boot "$@"
