#!/bin/sh
. hooks/shared/head.sh

# Host input drivers → YARAMFS_CFG_MODULES_ADDL for the modules hook.
# Default: unique driver basenames bound under /sys/class/input/*/device/driver
# (keyboards, mice, etc. that are actually in use — no root required).
# Override: YARAMFS_CFG_INPUT_MODULES="usbhid atkbd i8042" (empty = none).

prepare() {
  _in_mods=

  if eval "[ -n \"\${YARAMFS_CFG_INPUT_MODULES+x}\" ]"; then
    _in_mods=${YARAMFS_CFG_INPUT_MODULES}
  else
    for _in_dev in /sys/class/input/input*; do
      [ -e "${_in_dev}" ] || continue

      _in_drv_link="${_in_dev}/device/driver"
      # Bound driver is a symlink; -e fails if the target is gone, -L is enough.
      [ -L "${_in_drv_link}" ] || continue

      _in_drv=$(basename "$(readlink -f "${_in_drv_link}" 2>/dev/null || readlink "${_in_drv_link}")")
      [ -n "${_in_drv}" ] || continue

      case " ${_in_mods} " in
        *" ${_in_drv} "*) continue ;;
      esac
      _in_mods="${_in_mods} ${_in_drv}"
    done
  fi

  # Trim leading space from the loop accumulation.
  _in_mods=${_in_mods# }

  if [ -n "${_in_mods}" ]; then
    echo "input: modules: ${_in_mods}" >&2
    YARAMFS_CFG_MODULES_ADDL="${YARAMFS_CFG_MODULES_ADDL} ${_in_mods}"
    YARAMFS_CFG_MODULES_ADDL=${YARAMFS_CFG_MODULES_ADDL# }
    export_cfg YARAMFS_CFG_MODULES_ADDL
  else
    echo "input: no input modules (built-in, override empty, or nothing bound)" >&2
  fi
}

boot() { :; }

prepare_or_boot "$@"
