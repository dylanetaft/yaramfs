#!/bin/sh
. hooks/shared/head.sh

# Optional override of hooks/env/boot_config.sh from a local filesystem.
# Runs after modules (drivers up) and before network/iscsi so overrides apply.
# Config: YARAMFS_CFG_BOOT_PROVISIONED_UUID + _PATH (from baked boot_config).

prepare() { :; }

boot() {
  # Unset UUID → hook disabled (may sit in config/ unused).
  [ -n "${YARAMFS_CFG_BOOT_PROVISIONED_UUID}" ] || return 0
  [ -n "${YARAMFS_CFG_BOOT_PROVISIONED_PATH}" ] \
    || die ${LINENO} "YARAMFS_CFG_BOOT_PROVISIONED_PATH required when UUID is set"

  default_value YARAMFS_CFG_BOOT_PROVISIONED_DELAY "10" ${LINENO}
  default_value YARAMFS_CFG_BOOT_PROVISIONED_MNT "/mnt/provisioned" ${LINENO}

  _spec="UUID=${YARAMFS_CFG_BOOT_PROVISIONED_UUID}"
  _delay=${YARAMFS_CFG_BOOT_PROVISIONED_DELAY}
  _mnt=${YARAMFS_CFG_BOOT_PROVISIONED_MNT}
  _path=${YARAMFS_CFG_BOOT_PROVISIONED_PATH}
  _n=0
  _dev=

  # busybox blkid: first block node with matching UUID (no findfs).
  _want=$(printf '%s' "${YARAMFS_CFG_BOOT_PROVISIONED_UUID}" | tr 'A-F' 'a-f')
  while :; do
    _dev=
    _blkid_out=$(blkid 2>/dev/null) || true
    if [ -n "${_blkid_out}" ]; then
      while IFS= read -r _line || [ -n "${_line}" ]; do
        [ -n "${_line}" ] || continue
        case "${_line}" in
          /dev/*:*) ;;
          *) continue ;;
        esac
        _cand=${_line%%:*}
        [ -b "${_cand}" ] || continue
        _got=$(printf '%s\n' "${_line}" | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')
        [ -n "${_got}" ] || continue
        _got=$(printf '%s' "${_got}" | tr 'A-F' 'a-f')
        if [ "${_got}" = "${_want}" ]; then
          _dev=${_cand}
          break
        fi
      done <<EOF
${_blkid_out}
EOF
    fi
    if [ -n "${_dev}" ] && [ -b "${_dev}" ]; then
      break
    fi
    if [ "${_n}" -ge "${_delay}" ]; then
      die ${LINENO} "provisioned config device not found: ${_spec}"
    fi
    sleep 1
    _n=$((_n + 1))
    if [ $((_n % 5)) -eq 0 ]; then
      echo "yaramfs: waiting for provisioned ${_spec} (${_n}s)" >&2
    fi
  done

  echo "yaramfs: provisioned config ${_spec} -> ${_dev}" >&2

  mkdir -p "${_mnt}" || die ${LINENO} "mkdir ${_mnt} failed"
  mount -o ro "${_dev}" "${_mnt}" \
    || die ${LINENO} "mount ${_dev} on ${_mnt} failed"

  _src="${_mnt}${_path}"
  if [ ! -f "${_src}" ]; then
    umount "${_mnt}" 2>/dev/null || true
    die ${LINENO} "provisioned config file missing: ${_src}"
  fi

  _dst="${YARAMFS_CFG_CONFIG_DIR}/env/boot_config.sh"
  mkdir -p "$(dirname "${_dst}")" \
    || { umount "${_mnt}" 2>/dev/null || true; die ${LINENO} "mkdir for ${_dst} failed"; }
  if ! cp -f "${_src}" "${_dst}"; then
    umount "${_mnt}" 2>/dev/null || true
    die ${LINENO} "copy ${_src} -> ${_dst} failed"
  fi

  umount "${_mnt}" 2>/dev/null || true

  echo "yaramfs: installed provisioned boot_config from ${_src}" >&2

  # Provisioned file is authoritative for boot knobs: drop inherited BOOT_* first.
  for _var in $(set); do
    case "${_var}" in
      YARAMFS_CFG_BOOT_*)
        _name=$(echo "${_var}" | cut -d= -s -f1)
        [ -n "${_name}" ] || continue
        unset "${_name}"
        ;;
    esac
  done

  yaramfs_load_env "boot"
  export_cfg
}

prepare_or_boot "$@"
