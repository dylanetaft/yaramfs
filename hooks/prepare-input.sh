#!/bin/sh
. hooks/shared/head.sh

# Host input drivers → YARAMFS_CFG_PREPARE_MODULES_ADDL for the modules hook.
# Default: lsmod names whose modinfo -n path contains "/input/" or "/hid/"
# (e.g. …/drivers/input/…/hyperv_keyboard.ko, …/drivers/hid/hid-hyperv.ko).
# ensure_modules pulls deps via kmod modprobe -d/-S -D. No root required.
# Override: YARAMFS_CFG_PREPARE_INPUT_MODULES="usbhid atkbd" (empty = none).

prepare() {
  _in_mods=

  if eval "[ -n \"\${YARAMFS_CFG_PREPARE_INPUT_MODULES+x}\" ]"; then
    _in_mods=${YARAMFS_CFG_PREPARE_INPUT_MODULES}
  else
    # NR>1: skip lsmod header.
    while read -r _in_name || [ -n "${_in_name}" ]; do
      [ -n "${_in_name}" ] || continue

      _in_path=$(modinfo -n "${_in_name}" 2>/dev/null) || continue
      [ -n "${_in_path}" ] || continue

      case "${_in_path}" in
        */input/*|*/hid/*) ;;
        *) continue ;;
      esac

      case " ${_in_mods} " in
        *" ${_in_name} "*) continue ;;
      esac
      _in_mods="${_in_mods} ${_in_name}"
    done <<EOF
$(lsmod | awk 'NR > 1 { print $1 }')
EOF
  fi

  _in_mods=${_in_mods# }

  if [ -n "${_in_mods}" ]; then
    echo "input: modules: ${_in_mods}" >&2
    YARAMFS_CFG_PREPARE_MODULES_ADDL="${YARAMFS_CFG_PREPARE_MODULES_ADDL} ${_in_mods}"
    YARAMFS_CFG_PREPARE_MODULES_ADDL=${YARAMFS_CFG_PREPARE_MODULES_ADDL# }
    export_cfg YARAMFS_CFG_PREPARE_MODULES_ADDL
  else
    echo "input: no input modules (built-in, override empty, or none loaded)" >&2
  fi
}

boot() { :; }

prepare_or_boot "$@"
