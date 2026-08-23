#!/bin/sh
. hooks/shared/head.sh

# Resolve root= from the kernel cmdline, mount on /mnt/root, export for /init.
# UUID=/LABEL= via busybox blkid (may list several hits); prefer /dev/mapper/*
# (so multipath maps from boot-multipath win over underlying path devices).
# Absolute /dev/* is never rewritten. PARTUUID/PARTLABEL not supported.

prepare() { :; }

_root_parse_token() {
  _tok=$1
  case "${_tok}" in
    root=*) YARAMFS_CFG_BOOT_ROOT=${_tok#root=} ;;
    rootfstype=*) YARAMFS_CFG_BOOT_ROOTFSTYPE=${_tok#rootfstype=} ;;
    rootflags=*) YARAMFS_CFG_BOOT_ROOTFLAGS=${_tok#rootflags=} ;;
    rootdelay=*) YARAMFS_CFG_BOOT_ROOTDELAY=${_tok#rootdelay=} ;;
    init=*) YARAMFS_CFG_BOOT_INIT=${_tok#init=} ;;
  esac
}

_root_parse_cmdline() {
  if [ ! -r /proc/cmdline ]; then
    die ${LINENO} "/proc/cmdline not readable"
  fi
  # shellcheck disable=SC2013
  for _tok in $(cat /proc/cmdline); do
    _root_parse_token "${_tok}"
  done
}

# Print preferred block dev for UUID=… or LABEL=… from blkid, or fail.
_root_resolve_tag() {
  _spec=$1
  _kind=${_spec%%=*}
  _want=${_spec#*=}
  [ -n "${_want}" ] || return 1

  if [ "${_kind}" = "UUID" ]; then
    _want=$(printf '%s' "${_want}" | tr 'A-F' 'a-f')
  fi

  _pick_mapper=
  _pick_other=
  _blkid_out=$(blkid 2>/dev/null) || true
  [ -n "${_blkid_out}" ] || return 1

  while IFS= read -r _line || [ -n "${_line}" ]; do
    [ -n "${_line}" ] || continue
    case "${_line}" in
      /dev/*:*) ;;
      *) continue ;;
    esac

    _dev=${_line%%:*}
    [ -b "${_dev}" ] || continue

    case "${_kind}" in
      UUID)
        _got=$(printf '%s\n' "${_line}" | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')
        [ -n "${_got}" ] || continue
        _got=$(printf '%s' "${_got}" | tr 'A-F' 'a-f')
        [ "${_got}" = "${_want}" ] || continue
        ;;
      LABEL)
        _got=$(printf '%s\n' "${_line}" | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p')
        [ -n "${_got}" ] || continue
        [ "${_got}" = "${_want}" ] || continue
        ;;
      *) return 1 ;;
    esac

    case "${_dev}" in
      /dev/mapper/*) [ -z "${_pick_mapper}" ] && _pick_mapper=${_dev} ;;
      *) [ -z "${_pick_other}" ] && _pick_other=${_dev} ;;
    esac
  done <<EOF
${_blkid_out}
EOF

  if [ -n "${_pick_mapper}" ]; then
    printf '%s\n' "${_pick_mapper}"
    return 0
  fi
  if [ -n "${_pick_other}" ]; then
    printf '%s\n' "${_pick_other}"
    return 0
  fi
  return 1
}

_root_resolve() {
  _spec=$1
  [ -n "${_spec}" ] || return 1

  case "${_spec}" in
    /dev/*)
      [ -b "${_spec}" ] || return 1
      printf '%s\n' "${_spec}"
      ;;
    UUID=*|LABEL=*)
      _root_resolve_tag "${_spec}"
      ;;
    PARTUUID=*|PARTLABEL=*)
      die ${LINENO} "root=${_spec}: PARTUUID/PARTLABEL not supported"
      ;;
    *)
      die ${LINENO} "unsupported root= spec: ${_spec}"
      ;;
  esac
}

_root_wait_resolve() {
  _spec=$1
  _delay=${YARAMFS_CFG_BOOT_ROOTDELAY:-30}
  _n=0

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
    if [ $((_n % 5)) -eq 0 ]; then
      echo "yaramfs: waiting for root=${_spec} (${_n}s)" >&2
    fi
  done
}

boot() {
  default_value YARAMFS_CFG_BOOT_NEWROOT_MNT "/mnt/root" ${LINENO}

  _root_parse_cmdline

  if [ -z "${YARAMFS_CFG_BOOT_ROOT}" ]; then
    echo "yaramfs: no root= on cmdline, skipping mount" >&2
    return 0
  fi

  echo "yaramfs: root=${YARAMFS_CFG_BOOT_ROOT}" >&2

  _dev=$(_root_wait_resolve "${YARAMFS_CFG_BOOT_ROOT}") \
    || die ${LINENO} "root device not found: ${YARAMFS_CFG_BOOT_ROOT}"

  echo "yaramfs: resolved root -> ${_dev}" >&2

  mkdir -p "${YARAMFS_CFG_BOOT_NEWROOT_MNT}" \
    || die ${LINENO} "mkdir ${YARAMFS_CFG_BOOT_NEWROOT_MNT} failed"

  default_if_unset YARAMFS_CFG_BOOT_ROOTFLAGS "ro" ${LINENO}
  [ -n "${YARAMFS_CFG_BOOT_ROOTFLAGS}" ] || YARAMFS_CFG_BOOT_ROOTFLAGS=ro

  _mnt_args=
  if [ -n "${YARAMFS_CFG_BOOT_ROOTFSTYPE}" ]; then
    _mnt_args="-t ${YARAMFS_CFG_BOOT_ROOTFSTYPE}"
  fi
  # shellcheck disable=SC2086
  mount ${_mnt_args} -o "${YARAMFS_CFG_BOOT_ROOTFLAGS}" "${_dev}" "${YARAMFS_CFG_BOOT_NEWROOT_MNT}" \
    || die ${LINENO} "mount ${_dev} on ${YARAMFS_CFG_BOOT_NEWROOT_MNT} failed"

  default_value YARAMFS_CFG_BOOT_INIT "/sbin/init" ${LINENO}

  if [ ! -e "${YARAMFS_CFG_BOOT_NEWROOT_MNT}${YARAMFS_CFG_BOOT_INIT}" ]; then
    die ${LINENO} "init not found on new root: ${YARAMFS_CFG_BOOT_INIT}"
  fi

  YARAMFS_CFG_BOOT_NEWROOT=${YARAMFS_CFG_BOOT_NEWROOT_MNT}
  export_cfg YARAMFS_CFG_BOOT_NEWROOT YARAMFS_CFG_BOOT_INIT
  echo "yaramfs: mounted ${_dev} at ${YARAMFS_CFG_BOOT_NEWROOT} (init=${YARAMFS_CFG_BOOT_INIT})" >&2
}

prepare_or_boot "$@"
