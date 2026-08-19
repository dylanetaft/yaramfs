#!/bin/sh
. hooks/shared/head.sh

# Host NIC drivers → YARAMFS_CFG_MODULES_ADDL for the modules hook.
# Default: unique driver basenames bound under /sys/class/net/*/device/driver
# (skips lo and ifaces with no backing device, e.g. bare bridges).
# Override: YARAMFS_CFG_NETWORK_MODULES="mlx5_core igb" (empty = none).

prepare() {
  _net_mods=

  if eval "[ -n \"\${YARAMFS_CFG_NETWORK_MODULES+x}\" ]"; then
    _net_mods=${YARAMFS_CFG_NETWORK_MODULES}
  else
    for _net_iface in /sys/class/net/*; do
      [ -e "${_net_iface}" ] || continue
      _net_name=${_net_iface##*/}
      [ "${_net_name}" = "lo" ] && continue

      _net_drv_link="${_net_iface}/device/driver"
      # Bound driver is a symlink; -e fails if the target is gone, -L is enough.
      [ -L "${_net_drv_link}" ] || continue

      _net_drv=$(basename "$(readlink -f "${_net_drv_link}" 2>/dev/null || readlink "${_net_drv_link}")")
      [ -n "${_net_drv}" ] || continue

      case " ${_net_mods} " in
        *" ${_net_drv} "*) continue ;;
      esac
      _net_mods="${_net_mods} ${_net_drv}"
    done
  fi

  # Trim leading space from the loop accumulation.
  _net_mods=${_net_mods# }

  if [ -n "${_net_mods}" ]; then
    echo "network: NIC modules: ${_net_mods}" >&2
    YARAMFS_CFG_MODULES_ADDL="${YARAMFS_CFG_MODULES_ADDL} ${_net_mods}"
  else
    echo "network: no NIC modules (built-in, override empty, or nothing bound)" >&2
  fi
}

boot() { :; }

prepare_or_boot "$@"
