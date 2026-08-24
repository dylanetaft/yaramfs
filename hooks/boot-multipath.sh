#!/bin/sh
. hooks/shared/head.sh

# One-shot multipath map setup before boot-root resolves/mounts root.
# Requires prepare-multipath (multipath + kpartx + modules). No multipathd, no udev.
# Config order: after modules and path providers (boot-iscsi), before boot-root.
# boot-root prefers /dev/mapper/* when resolving UUID=/LABEL=.
#
# Required: YARAMFS_CFG_BOOT_MULTIPATH_WWID (space- or comma-separated sysfs wwids).
# Only whole disks whose sysfs wwid matches are passed to multipath.
# Then kpartx maps partitions on mpath disks (…-partN by default).

prepare() { :; }

# Normalize WWID for compare: lower case, strip common prefixes and separators.
_mp_norm_wwid() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed \
    -e 's/^wwn-0x//' \
    -e 's/^0x//' \
    -e 's/^naa\.//' \
    -e 's/^eui\.//' \
    -e 's/^nguid\.//' \
    -e 's/^uuid\.//' \
    -e 's/[:-]//g'
}

# True if two already-normalized WWIDs refer to the same id.
# multipath-tools often prints SCSI NAA as 3 + hex body; sysfs is naa.<body>.
_mp_wwid_eq() {
  [ "$1" = "$2" ] && return 0
  case "$1" in 3"$2") return 0 ;; esac
  case "$2" in 3"$1") return 0 ;; esac
  return 1
}

# Print sysfs wwid for whole-disk name under /sys/block, or empty.
_mp_sysfs_wwid() {
  _n=$1
  if [ -r "/sys/block/${_n}/device/wwid" ]; then
    cat "/sys/block/${_n}/device/wwid" 2>/dev/null
    return
  fi
  if [ -r "/sys/block/${_n}/wwid" ]; then
    cat "/sys/block/${_n}/wwid" 2>/dev/null
    return
  fi
}

# True if $1 is a path disk under /sys/block we may multipath.
# /sys/block is gendisks only (partitions live under the parent / class/block);
# this is an allowlist so we skip dm/loop/md/sr and other non-path types.
_mp_is_whole_disk() {
  case "$1" in
    sd[a-z]*|vd[a-z]*|xvd[a-z]*|nvme*n[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Ensure /dev/mapper/<name> for multipath maps and kpartx partitions (no udevd).
# Whole disk uuid: mpath-… ; kpartx parts: partN-mpath-… (or name already set).
_mp_ensure_mapper_nodes() {
  mkdir -p /dev/mapper 2>/dev/null || true
  [ -e /dev/mapper/control ] || true

  for _dm in /sys/block/dm-*; do
    [ -d "${_dm}" ] || continue
    _uuid=
    [ -r "${_dm}/dm/uuid" ] && _uuid=$(cat "${_dm}/dm/uuid" 2>/dev/null)
    case "${_uuid}" in
      mpath-*|part*-mpath-*) ;;
      *) continue ;;
    esac
    _name=
    [ -r "${_dm}/dm/name" ] && _name=$(cat "${_dm}/dm/name" 2>/dev/null)
    [ -n "${_name}" ] || continue
    _devnode="/dev/$(basename "${_dm}")"
    [ -e "${_devnode}" ] || continue
    _link="/dev/mapper/${_name}"
    if [ -L "${_link}" ] || [ -b "${_link}" ]; then
      continue
    fi
    ln -sf "../$(basename "${_devnode}")" "${_link}" 2>/dev/null \
      || ln -sf "${_devnode}" "${_link}" 2>/dev/null \
      || true
  done
}

boot() {
  if ! command -v multipath >/dev/null 2>&1; then
    echo "yaramfs: multipath binary missing (enable prepare-multipath)" >&2
    die ${LINENO} "multipath not found"
  fi

  # Required allowlist — no "multipath everything" mode.
  _wwid_cfg=${YARAMFS_CFG_BOOT_MULTIPATH_WWID-}
  if [ -z "${_wwid_cfg}" ]; then
    die ${LINENO} "set YARAMFS_CFG_BOOT_MULTIPATH_WWID (sysfs wwid allowlist; required)"
  fi

  default_if_unset YARAMFS_CFG_BOOT_MULTIPATH_KPARTX "1" ${LINENO}
  default_if_unset YARAMFS_CFG_BOOT_MULTIPATH_KPARTX_DELIM "-part" ${LINENO}
  _mp_args=${YARAMFS_CFG_BOOT_MULTIPATH_ARGS-}

  export DM_DISABLE_UDEV=1
  mkdir -p /dev/mapper /etc/multipath /run/multipath /var/lib/multipath 2>/dev/null || true

  # Build normalized allowlist (space/comma separated).
  _allow=
  _tok=
  # tr commas to spaces; split on IFS whitespace
  for _tok in $(printf '%s' "${_wwid_cfg}" | tr ',;' '  '); do
    [ -n "${_tok}" ] || continue
    _n=$(_mp_norm_wwid "${_tok}")
    [ -n "${_n}" ] || continue
    _allow="${_allow} ${_n}"
  done
  _allow=${_allow# }
  if [ -z "${_allow}" ]; then
    die ${LINENO} "YARAMFS_CFG_BOOT_MULTIPATH_WWID has no usable tokens"
  fi

  # Match whole disks in /sys/block against allowlist.
  _paths=
  _matched_n=0
  for _sys in /sys/block/*; do
    [ -d "${_sys}" ] || continue
    _bn=$(basename "${_sys}")
    _mp_is_whole_disk "${_bn}" || continue
    _raw=$(_mp_sysfs_wwid "${_bn}")
    [ -n "${_raw}" ] || continue
    _nw=$(_mp_norm_wwid "${_raw}")
    [ -n "${_nw}" ] || continue

    _ok=
    for _a in ${_allow}; do
      if _mp_wwid_eq "${_nw}" "${_a}"; then
        _ok=1
        break
      fi
    done
    [ -n "${_ok}" ] || continue

    _dev="/dev/${_bn}"
    if [ ! -b "${_dev}" ] && [ ! -e "${_dev}" ]; then
      echo "yaramfs: multipath: matched ${_bn} wwid=${_raw} but ${_dev} missing" >&2
      continue
    fi
    echo "yaramfs: multipath: path ${_dev} wwid=${_raw}" >&2
    _paths="${_paths} ${_dev}"
    _matched_n=$((_matched_n + 1))
  done
  _paths=${_paths# }

  if [ "${_matched_n}" -eq 0 ]; then
    die ${LINENO} "no whole-disk paths match YARAMFS_CFG_BOOT_MULTIPATH_WWID"
  fi

  _ok_n=0
  for _dev in ${_paths}; do
    echo "yaramfs: multipath -v2 ${_mp_args} ${_dev}" >&2
    # shellcheck disable=SC2086
    if multipath -v2 ${_mp_args} "${_dev}"; then
      _ok_n=$((_ok_n + 1))
    else
      echo "yaramfs: multipath failed for ${_dev} (continuing)" >&2
    fi
  done
  if [ "${_ok_n}" -eq 0 ]; then
    die ${LINENO} "multipath failed for all matched paths"
  fi

  _mp_ensure_mapper_nodes

  if [ "${YARAMFS_CFG_BOOT_MULTIPATH_KPARTX}" != "0" ]; then
    if ! command -v kpartx >/dev/null 2>&1; then
      die ${LINENO} "kpartx not found (enable prepare-multipath / install multipath-tools)"
    fi
    _delim=${YARAMFS_CFG_BOOT_MULTIPATH_KPARTX_DELIM}
    # Whole mpath disks only (sysfs uuid mpath-…; skip partition maps).
    for _dmdir in /sys/block/dm-*; do
      [ -d "${_dmdir}" ] || continue
      _uuid=
      [ -r "${_dmdir}/dm/uuid" ] && _uuid=$(cat "${_dmdir}/dm/uuid" 2>/dev/null)
      case "${_uuid}" in
        mpath-*) ;;
        *) continue ;;
      esac
      # Partition maps from kpartx are usually part of-… or name already has delim.
      _name=
      [ -r "${_dmdir}/dm/name" ] && _name=$(cat "${_dmdir}/dm/name" 2>/dev/null)
      [ -n "${_name}" ] || continue
      case "${_name}" in
        *"${_delim}"[0-9]*) continue ;;
      esac
      _m="/dev/mapper/${_name}"
      [ -e "${_m}" ] || _m="/dev/$(basename "${_dmdir}")"
      [ -e "${_m}" ] || continue

      echo "yaramfs: kpartx -a -p ${_delim} ${_m}" >&2
      kpartx -a -p "${_delim}" "${_m}" \
        || die ${LINENO} "kpartx failed for ${_m}"
    done
    _mp_ensure_mapper_nodes
  fi
}

prepare_or_boot "$@"
