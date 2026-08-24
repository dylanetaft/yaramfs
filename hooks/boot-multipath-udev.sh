#!/bin/sh
. hooks/shared/head.sh

# One-shot multipath map setup with real udevd (no DM_DISABLE_UDEV).
# Requires: udev hook (config/NN-udev.sh), prepare-multipath-udev (multipath + kpartx).
# Config order: after boot-iscsi, before boot-root. Do not also run legacy
# boot-multipath (seeds db / disables udev).
#
# Same WWID allowlist as legacy boot-multipath (YARAMFS_CFG_BOOT_MULTIPATH_WWID).
# libdevmapper talks to udevd → PRIMARY + mapper links + by-uuid without hand seed.
# _mp_try_map is one pass/fail attempt; boot() retries until SETTLE seconds.

prepare() { :; }

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

_mp_wwid_eq() {
  [ "$1" = "$2" ] && return 0
  case "$1" in 3"$2") return 0 ;; esac
  case "$2" in 3"$1") return 0 ;; esac
  return 1
}

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

_mp_is_whole_disk() {
  case "$1" in
    sd[a-z]*|vd[a-z]*|xvd[a-z]*|nvme*n[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

_mp_collect_paths() {
  _allow=$1
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
      echo "yaramfs: multipath-udev: matched ${_bn} wwid=${_raw} but ${_dev} missing" >&2
      continue
    fi
    _paths="${_paths} ${_dev}"
    _matched_n=$((_matched_n + 1))
  done
  _paths=${_paths# }
}

# multipath-tools LP#2120444: first run needs BINDINGS_FILE_HEADER byte-for-byte.
_mp_ensure_bindings_file() {
  _bf=/etc/multipath/bindings
  mkdir -p /etc/multipath 2>/dev/null || true

  if [ -f "${_bf}" ] && grep -q 'Multipath bindings, Version' "${_bf}" 2>/dev/null; then
    return 0
  fi

  _tmp="${_bf}.tmp.$$"
  {
    printf '%s\n' \
      '# Multipath bindings, Version : 1.0' \
      '# NOTE: this file is automatically maintained by the multipath program.' \
      '# You should not need to edit this file in normal circumstances.' \
      '#' \
      '# Format:' \
      '# alias wwid' \
      '#'
  } >"${_tmp}" 2>/dev/null || {
    rm -f "${_tmp}" 2>/dev/null || true
    echo "yaramfs: multipath-udev: warning: could not write ${_bf} skeleton" >&2
    return 0
  }
  mv -f "${_tmp}" "${_bf}" 2>/dev/null || {
    rm -f "${_tmp}" 2>/dev/null || true
    echo "yaramfs: multipath-udev: warning: could not install ${_bf} skeleton" >&2
    return 0
  }
  chmod 0600 "${_bf}" 2>/dev/null || true
  echo "yaramfs: multipath-udev: seeded ${_bf} header (LP#2120444)" >&2
}

# One attempt: collect WWID paths → udev settle → multipath -v2.
# Uses: _allow, _mp_args. Sets _paths / _matched_n via _mp_collect_paths.
# Returns 0 if at least one multipath succeeded, 1 otherwise (caller retries).
# No udevadm trigger: udevd already watches kernel uevents; re-ADD can hurt.
_mp_try_map() {
  _mp_collect_paths "${_allow}"
  [ "${_matched_n}" -gt 0 ] || return 1

  for _dev in ${_paths}; do
    _bn=$(basename "${_dev}")
    _raw=$(_mp_sysfs_wwid "${_bn}")
    echo "yaramfs: multipath-udev: path ${_dev} wwid=${_raw}" >&2
  done
  # Wait for in-flight udev work on paths that just appeared (iscsi, etc.).
  udevadm settle --timeout=5 2>/dev/null || true

  _ok_n=0
  for _dev in ${_paths}; do
    echo "yaramfs: multipath -v2 ${_mp_args} ${_dev}" >&2
    # shellcheck disable=SC2086
    if multipath -v2 ${_mp_args} "${_dev}"; then
      _ok_n=$((_ok_n + 1))
    else
      echo "yaramfs: multipath-udev: multipath failed for ${_dev}" >&2
    fi
  done
  [ "${_ok_n}" -gt 0 ]
}

boot() {
  if ! command -v multipath >/dev/null 2>&1; then
    echo "yaramfs: multipath binary missing (enable prepare-multipath-udev)" >&2
    die ${LINENO} "multipath not found"
  fi

  # Require udev path — do not silently fall back to DM_DISABLE_UDEV.
  if ! command -v udevadm >/dev/null 2>&1; then
    die ${LINENO} "boot-multipath-udev requires udev hook (udevadm missing)"
  fi
  if [ ! -d /run/udev ]; then
    die ${LINENO} "boot-multipath-udev requires udev hook (/run/udev missing; start udevd first)"
  fi
  # Clear if something exported it; udev cookies must work.
  unset DM_DISABLE_UDEV

  _wwid_cfg=${YARAMFS_CFG_BOOT_MULTIPATH_WWID-}
  if [ -z "${_wwid_cfg}" ]; then
    die ${LINENO} "set YARAMFS_CFG_BOOT_MULTIPATH_WWID (sysfs wwid allowlist; required)"
  fi

  default_if_unset YARAMFS_CFG_BOOT_MULTIPATH_KPARTX "1" ${LINENO}
  default_if_unset YARAMFS_CFG_BOOT_MULTIPATH_KPARTX_DELIM "-part" ${LINENO}
  default_if_unset YARAMFS_CFG_BOOT_MULTIPATH_SETTLE "30" ${LINENO}
  default_if_unset YARAMFS_CFG_BOOT_UDEV_SETTLE_TIMEOUT "30" ${LINENO}
  _mp_args=${YARAMFS_CFG_BOOT_MULTIPATH_ARGS-}
  _settle=${YARAMFS_CFG_BOOT_MULTIPATH_SETTLE}
  _udev_settle=${YARAMFS_CFG_BOOT_UDEV_SETTLE_TIMEOUT}

  mkdir -p /dev/mapper /etc/multipath /run/multipath /var/lib/multipath 2>/dev/null || true
  _mp_ensure_bindings_file

  _allow=
  _tok=
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

  # Paths may appear late (iSCSI); first multipath may fail until udev/TUR settle.
  # One attempt function; outer loop only waits and retries.
  _n=0
  while ! _mp_try_map; do
    if [ "${_n}" -ge "${_settle}" ]; then
      die ${LINENO} "multipath did not map allowlisted WWIDs after ${_settle}s"
    fi
    sleep 1
    _n=$((_n + 1))
    if [ $((_n % 5)) -eq 0 ] || [ "${_n}" -eq 1 ]; then
      echo "yaramfs: multipath-udev: waiting for multipath maps (${_n}/${_settle}s)" >&2
    fi
  done

  # Let udev process DM cookies / mapper links before kpartx and boot-root.
  if ! udevadm settle --timeout="${_udev_settle}" 2>/dev/null; then
    echo "yaramfs: multipath-udev: udev settle after multipath timed out (continuing)" >&2
  fi

  if [ "${YARAMFS_CFG_BOOT_MULTIPATH_KPARTX}" != "0" ]; then
    if ! command -v kpartx >/dev/null 2>&1; then
      die ${LINENO} "kpartx not found (enable prepare-multipath-udev / install multipath-tools)"
    fi
    _delim=${YARAMFS_CFG_BOOT_MULTIPATH_KPARTX_DELIM}
    for _dmdir in /sys/block/dm-*; do
      [ -d "${_dmdir}" ] || continue
      _uuid=
      [ -r "${_dmdir}/dm/uuid" ] && _uuid=$(cat "${_dmdir}/dm/uuid" 2>/dev/null)
      case "${_uuid}" in
        mpath-*) ;;
        *) continue ;;
      esac
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

    if ! udevadm settle --timeout="${_udev_settle}" 2>/dev/null; then
      echo "yaramfs: multipath-udev: udev settle after kpartx timed out (continuing)" >&2
    fi
  fi
}

prepare_or_boot "$@"
