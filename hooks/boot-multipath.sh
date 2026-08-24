#!/bin/sh
. hooks/shared/head.sh

# One-shot multipath map setup before boot-root resolves/mounts root.
# Requires prepare-multipath (multipath + kpartx + modules). No multipathd, no udev.
# Config order: after modules and path providers (boot-iscsi), before boot-root.
# boot-root prefers /dev/mapper/* when resolving UUID=/LABEL=.
#
# Required: YARAMFS_CFG_BOOT_MULTIPATH_WWID (space- or comma-separated sysfs wwids).
# Only path disks whose sysfs wwid matches are passed to multipath.
# Waits up to YARAMFS_CFG_BOOT_MULTIPATH_SETTLE seconds for paths (iSCSI/NVMe
# often appear after session start). Then kpartx on mpath disks (…-partN).
# After maps: seed /run/udev/data so real-root coldplug can build by-uuid links
# (DM_DISABLE_UDEV skips libdevmapper cookies; see _mp_seed_udev_db).

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

# Scan /sys/block for allowlisted path disks. Sets _paths and _matched_n.
# $1 = space-separated already-normalized allowlist tokens.
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
      echo "yaramfs: multipath: matched ${_bn} wwid=${_raw} but ${_dev} missing" >&2
      continue
    fi
    _paths="${_paths} ${_dev}"
    _matched_n=$((_matched_n + 1))
  done
  _paths=${_paths# }
}

# Ensure /etc/multipath/bindings has the exact header multipath-tools expects.
#
# Newer multipath (≈0.11+) fread()s a fixed BINDINGS_FILE_HEADER and strcmp()s
# it; missing or empty file → "_check_bindings_file: failed to read header" and
# a non-zero exit on the *first* multipath run.  That run often still rewrites a
# good skeleton, so a manual re-run succeeds — classic initramfs footgun.
# See Ubuntu LP#2120444 (same message with multipathd -B; CLI multipath -v2 too).
# touch is not enough: header must match alias.c BINDINGS_FILE_HEADER byte-for-byte.
# No alias/wwid lines required for the check; leave an existing good file alone.
_mp_ensure_bindings_file() {
  _bf=/etc/multipath/bindings
  mkdir -p /etc/multipath 2>/dev/null || true

  # Already has the Version header line → multipath can parse it.
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
    echo "yaramfs: multipath: warning: could not write ${_bf} skeleton" >&2
    return 0
  }
  mv -f "${_tmp}" "${_bf}" 2>/dev/null || {
    rm -f "${_tmp}" 2>/dev/null || true
    echo "yaramfs: multipath: warning: could not install ${_bf} skeleton" >&2
    return 0
  }
  chmod 0600 "${_bf}" 2>/dev/null || true
  echo "yaramfs: multipath: seeded ${_bf} header (LP#2120444)" >&2
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

# Seed udev database entries for multipath DM nodes created under DM_DISABLE_UDEV.
#
# Why: multipath/kpartx run with DM_DISABLE_UDEV=1 so libdevmapper never emits
# udev cookies/uevents.  Real-root systemd-udevd later coldplugs existing dm-*
# with ACTION=add.  10-dm.rules only treats that add as a full activation when
# the persisted db already has DM_UDEV_PRIMARY_SOURCE_FLAG=1 (and RULES_VSN).
# Without that, coldplug hits dm_disable → no 13-dm-disk blkid → no
# /dev/disk/by-uuid (systemd UUID=/PARTUUID= fstab waits and times out even
# though blkid on /dev/mapper/…-partN works).
#
# Distros with udevd-in-initrd get PRIMARY from libdevmapper automatically and
# OPTIONS+="db_persist" keeps /run/udev/data across switch_root.  We have no
# udevd here, so plant the minimal db files ourselves.  Sticky bit (+t) is
# udev's db_persist so cleanup-db on switch_root keeps the entries when /run
# is moved into the real root.
#
# Not an env var you can export: PRIMARY is a cookie bit / udev property only.
_mp_seed_udev_db() {
  _seed_n=0
  mkdir -p /run/udev/data 2>/dev/null || true

  for _dm in /sys/block/dm-*; do
    [ -d "${_dm}" ] || continue

    _uuid=
    [ -r "${_dm}/dm/uuid" ] && _uuid=$(cat "${_dm}/dm/uuid" 2>/dev/null)
    # Only maps we created: whole multipath + kpartx partitions.
    case "${_uuid}" in
      mpath-*|part*-mpath-*) ;;
      *) continue ;;
    esac

    _name=
    [ -r "${_dm}/dm/name" ] && _name=$(cat "${_dm}/dm/name" 2>/dev/null)
    [ -n "${_name}" ] || continue

    _majmin=
    [ -r "${_dm}/dev" ] && _majmin=$(cat "${_dm}/dev" 2>/dev/null)
    # udev db key is b<major>:<minor> (e.g. b253:2).
    case "${_majmin}" in
      [0-9]*:[0-9]*) ;;
      *) continue ;;
    esac

    _bn=$(basename "${_dm}")
    _devnode="/dev/${_bn}"
    [ -e "${_devnode}" ] || _devnode="/dev/mapper/${_name}"
    [ -e "${_devnode}" ] || continue

    # Optional FS/PART probe so coldplug can import IDs; empty is fine —
    # 13-dm-disk will blkid once PRIMARY allows the rule path.
    _fs_uuid=
    _fs_type=
    _fs_usage=
    _part_uuid=
    if command -v blkid >/dev/null 2>&1; then
      _fs_uuid=$(blkid -s UUID -o value "${_devnode}" 2>/dev/null) || true
      _fs_type=$(blkid -s TYPE -o value "${_devnode}" 2>/dev/null) || true
      _part_uuid=$(blkid -s PARTUUID -o value "${_devnode}" 2>/dev/null) || true
      if [ -n "${_fs_type}" ]; then
        case "${_fs_type}" in
          swap) _fs_usage=other ;;
          crypto_LUKS|*_crypt) _fs_usage=crypto ;;
          *) _fs_usage=filesystem ;;
        esac
      fi
    fi

    _db="/run/udev/data/b${_majmin}"
    _tmp="${_db}.tmp.$$"
    {
      # Symlink records udev would store (actual /dev/disk links appear on coldplug).
      printf 'S:mapper/%s\n' "${_name}"
      printf 'S:disk/by-id/dm-name-%s\n' "${_name}"
      printf 'S:disk/by-id/dm-uuid-%s\n' "${_uuid}"
      [ -n "${_fs_uuid}" ] && printf 'S:disk/by-uuid/%s\n' "${_fs_uuid}"
      [ -n "${_part_uuid}" ] && printf 'S:disk/by-partuuid/%s\n' "${_part_uuid}"

      # Core flags: PRIMARY lets add coldplug skip dm_disable (see 10-dm.rules).
      printf 'E:DM_UDEV_PRIMARY_SOURCE_FLAG=1\n'
      printf 'E:DM_UDEV_RULES_VSN=3\n'
      printf 'E:DM_ACTIVATION=1\n'
      printf 'E:DM_NAME=%s\n' "${_name}"
      printf 'E:DM_UUID=%s\n' "${_uuid}"

      if [ -n "${_fs_uuid}" ]; then
        printf 'E:ID_FS_UUID=%s\n' "${_fs_uuid}"
        # ENC form: udev escapes some chars; plain UUID/vfat XXXX-XXXX is fine.
        printf 'E:ID_FS_UUID_ENC=%s\n' "${_fs_uuid}"
      fi
      [ -n "${_fs_type}" ] && printf 'E:ID_FS_TYPE=%s\n' "${_fs_type}"
      [ -n "${_fs_usage}" ] && printf 'E:ID_FS_USAGE=%s\n' "${_fs_usage}"
      [ -n "${_part_uuid}" ] && printf 'E:ID_PART_ENTRY_UUID=%s\n' "${_part_uuid}"
    } >"${_tmp}" 2>/dev/null || {
      rm -f "${_tmp}" 2>/dev/null || true
      continue
    }

    mv -f "${_tmp}" "${_db}" 2>/dev/null || {
      rm -f "${_tmp}" 2>/dev/null || true
      continue
    }
    chmod 0644 "${_db}" 2>/dev/null || true
    # Sticky bit == udev OPTIONS+="db_persist" (survive cleanup-db / switch_root).
    chmod +t "${_db}" 2>/dev/null || true

    _seed_n=$((_seed_n + 1))
    echo "yaramfs: multipath: udev db seed b${_majmin} name=${_name}" >&2
  done

  if [ "${_seed_n}" -eq 0 ]; then
    echo "yaramfs: multipath: udev db seed: no mpath/part maps found" >&2
  else
    echo "yaramfs: multipath: udev db seed: ${_seed_n} device(s)" >&2
  fi
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
  # Seconds to wait for allowlisted path disks after iSCSI/NVMe (default 30).
  default_if_unset YARAMFS_CFG_BOOT_MULTIPATH_SETTLE "30" ${LINENO}
  _mp_args=${YARAMFS_CFG_BOOT_MULTIPATH_ARGS-}
  _settle=${YARAMFS_CFG_BOOT_MULTIPATH_SETTLE}

  export DM_DISABLE_UDEV=1
  mkdir -p /dev/mapper /etc/multipath /run/multipath /var/lib/multipath 2>/dev/null || true
  # Before first multipath -v2: valid bindings header (see _mp_ensure_bindings_file).
  _mp_ensure_bindings_file

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

  # Retry until at least one path matches or settle budget expires (like rootdelay).
  _n=0
  while :; do
    _mp_collect_paths "${_allow}"
    if [ "${_matched_n}" -gt 0 ]; then
      break
    fi
    if [ "${_n}" -ge "${_settle}" ]; then
      die ${LINENO} "no path disks match YARAMFS_CFG_BOOT_MULTIPATH_WWID after ${_settle}s"
    fi
    sleep 1
    _n=$((_n + 1))
    if [ $((_n % 5)) -eq 0 ] || [ "${_n}" -eq 1 ]; then
      echo "yaramfs: multipath: waiting for WWID paths (${_n}/${_settle}s)" >&2
    fi
  done

  for _dev in ${_paths}; do
    _bn=$(basename "${_dev}")
    _raw=$(_mp_sysfs_wwid "${_bn}")
    echo "yaramfs: multipath: path ${_dev} wwid=${_raw}" >&2
  done

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

  # After all DM nodes exist: plant PRIMARY for real-root udev coldplug.
  _mp_seed_udev_db
}

prepare_or_boot "$@"
