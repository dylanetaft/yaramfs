#!/bin/sh
. hooks/shared/head.sh

# Early udev: pack at prepare, start daemon at boot (after base mounts /dev
# /sys /run, before modules). Opt-in via config/NN-udev.sh (not NN-prepare-*
# so the same file is installed in the guest for boot).
#
# Prepare: udevadm (+ libs), symlink systemd-udevd, dmsetup, curated host rules.
# Boot: systemd-udevd --daemon, coldplug trigger, settle. Leave daemon running
# through switch_root; /run tmpfs is moved to newroot with the udev db.
# Downstream: multipath-udev (no DM_DISABLE_UDEV). Rules for DM/multipath live
# here — not in multipath hooks.
#
# Host needs systemd (udevadm) and device-mapper (dmsetup). Modern systemd uses
# one multi-call binary; systemd-udevd is a symlink to udevadm in the image.

# Host rule basenames to pack when present (DM/block + multipath/kpartx).
# Override with YARAMFS_CFG_PREPARE_UDEV_RULES (space-separated). Missing names
# are skipped (log only) — bake whatever the host has installed.
UDEV_RULES_COPYLIST="50-udev-default.rules 60-block.rules 10-dm.rules 13-dm-disk.rules 95-dm-notify.rules 11-dm-mpath.rules 40-multipath.rules 56-multipath.rules 62-multipath.rules 65-multipath.rules 66-kpartx.rules"

# Print host udev rules directory, or empty.
_udev_find_rules_dir() {
  if [ -n "${YARAMFS_CFG_PREPARE_UDEV_RULES_DIR}" ]; then
    if [ ! -d "${YARAMFS_CFG_PREPARE_UDEV_RULES_DIR}" ]; then
      die ${LINENO} "UDEV_RULES_DIR not a directory: ${YARAMFS_CFG_PREPARE_UDEV_RULES_DIR}"
    fi
    printf '%s\n' "${YARAMFS_CFG_PREPARE_UDEV_RULES_DIR}"
    return 0
  fi
  for _ud in /lib/udev/rules.d /usr/lib/udev/rules.d; do
    if [ -d "${_ud}" ]; then
      printf '%s\n' "${_ud}"
      return 0
    fi
  done
  return 1
}

prepare() {
  BUILD_DIR=${YARAMFS_CFG_PREPARE_BUILD_DIR}

  default_value YARAMFS_CFG_PREPARE_UDEVADM "$(which udevadm 2>/dev/null)" ${LINENO}
  if [ ! -x "${YARAMFS_CFG_PREPARE_UDEVADM}" ]; then
    die ${LINENO} "udevadm not executable: ${YARAMFS_CFG_PREPARE_UDEVADM:-"(unset)"}"
  fi

  # install_binary packs udevadm + deps (libsystemd-shared lands in /lib64).
  # RUNPATH may point at /usr/lib64/systemd; glibc falls through to /lib64.
  # Absolute symlinks: build uses lib -> usr/lib, so relative ../../bin from
  # lib/systemd would resolve to usr/bin (wrong) instead of /bin.
  install_binary "${YARAMFS_CFG_PREPARE_UDEVADM}" /bin/udevadm
  mkdir -p "${BUILD_DIR}/lib/systemd" "${BUILD_DIR}/sbin"
  ln -sfn /bin/udevadm "${BUILD_DIR}/lib/systemd/systemd-udevd"
  ln -sfn /bin/udevadm "${BUILD_DIR}/sbin/udevadm"

  # Rules hardcode /sbin/dmsetup (10-dm.rules, 95-dm-notify.rules).
  default_value YARAMFS_CFG_PREPARE_DMSETUP "$(which dmsetup 2>/dev/null)" ${LINENO}
  if [ ! -x "${YARAMFS_CFG_PREPARE_DMSETUP}" ]; then
    die ${LINENO} "dmsetup not executable: ${YARAMFS_CFG_PREPARE_DMSETUP:-"(unset)"} (device-mapper)"
  fi
  install_binary "${YARAMFS_CFG_PREPARE_DMSETUP}" /sbin/dmsetup

  if ! _rules_dir=$(_udev_find_rules_dir); then
    die ${LINENO} "udev rules dir not found (set YARAMFS_CFG_PREPARE_UDEV_RULES_DIR)"
  fi

  mkdir -p "${BUILD_DIR}/lib/udev/rules.d"
  mkdir -p "${BUILD_DIR}/etc/udev/rules.d"
  mkdir -p "${BUILD_DIR}/run/udev"

  _rule_list=${YARAMFS_CFG_PREPARE_UDEV_RULES:-${UDEV_RULES_COPYLIST}}
  _ncopied=0
  _nskipped=0
  for _bn in ${_rule_list}; do
    [ -n "${_bn}" ] || continue
    _src="${_rules_dir}/${_bn}"
    if [ ! -r "${_src}" ]; then
      echo "udev: skip rule (not on host): ${_bn}" >&2
      _nskipped=$((_nskipped + 1))
      continue
    fi
    cp -a "${_src}" "${BUILD_DIR}/lib/udev/rules.d/${_bn}" \
      || die ${LINENO} "failed to copy ${_src}"
    echo "udev: copied rule ${_bn}" >&2
    _ncopied=$((_ncopied + 1))
  done

  # Portable db_persist for dm-* across switch_root (some 10-dm.rules already
  # set this; duplicate OPTIONS+ is harmless). Sticky-bit hand-seed not needed
  # when boot runs a real daemon.
  cat >"${BUILD_DIR}/lib/udev/rules.d/11-dm-yaramfs.rules" <<'EOF' \
    || die ${LINENO} "failed to write 11-dm-yaramfs.rules"
# yaramfs: keep dm-* udev db entries across switch_root (/run moved to newroot).
SUBSYSTEM=="block", KERNEL=="dm-[0-9]*", OPTIONS+="db_persist"
EOF

  echo "udev: prepare: ${_ncopied} rule(s) copied, ${_nskipped} skipped from ${_rules_dir}" >&2
  echo "udev: prepare: udevadm + systemd-udevd symlink + dmsetup packed" >&2
}

boot() {
  if ! command -v udevadm >/dev/null 2>&1; then
    die ${LINENO} "udevadm not found (enable udev hook)"
  fi

  _udevd=
  for _c in /lib/systemd/systemd-udevd /usr/lib/systemd/systemd-udevd systemd-udevd; do
    if [ -x "${_c}" ]; then
      _udevd=${_c}
      break
    fi
    # command -v for bare name
    case "${_c}" in
      /*) ;;
      *)
        _v=$(command -v "${_c}" 2>/dev/null) || true
        if [ -n "${_v}" ] && [ -x "${_v}" ]; then
          _udevd=${_v}
          break
        fi
        ;;
    esac
  done
  if [ -z "${_udevd}" ]; then
    die ${LINENO} "systemd-udevd not found (enable udev hook)"
  fi

  default_if_unset YARAMFS_CFG_BOOT_UDEV_SETTLE_TIMEOUT "30" ${LINENO}
  _settle=${YARAMFS_CFG_BOOT_UDEV_SETTLE_TIMEOUT}

  # /run is tmpfs from base; db lives under here and survives switch_root move.
  mkdir -p /run/udev /dev/mapper /etc/udev/rules.d 2>/dev/null || true

  echo "yaramfs: udev: starting ${_udevd} --daemon" >&2
  "${_udevd}" --daemon \
    || die ${LINENO} "systemd-udevd --daemon failed"

  # Coldplug nodes already created by devtmpfs (and any early buses).
  udevadm trigger --type=subsystems --action=add 2>/dev/null \
    || udevadm trigger --action=add 2>/dev/null \
    || true
  udevadm trigger --type=devices --action=add 2>/dev/null \
    || true

  if ! udevadm settle --timeout="${_settle}" 2>/dev/null; then
    echo "yaramfs: udev: settle timeout after ${_settle}s (continuing)" >&2
  else
    echo "yaramfs: udev: settle ok" >&2
  fi

  # So multipath-udev (and others) can assert udev was started this boot.
  YARAMFS_CFG_BOOT_UDEV=1
  export_cfg YARAMFS_CFG_BOOT_UDEV
}

prepare_or_boot "$@"
