#!/bin/sh
. hooks/shared/head.sh

# Host network drivers → YARAMFS_CFG_PREPARE_MODULES_ADDL for the modules hook.
# Default: lsmod names whose modinfo -n path contains "/net/"
# (e.g. …/drivers/net/ethernet/…/igb.ko, …/net/8021q/8021q.ko).
# ensure_modules pulls deps via kmod modprobe -d/-S -D. No root required.
# Override: YARAMFS_CFG_PREPARE_NETWORK_MODULES="mlx5_core igb" (empty = none).

prepare() {
  _net_mods=

  if eval "[ -n \"\${YARAMFS_CFG_PREPARE_NETWORK_MODULES+x}\" ]"; then
    _net_mods=${YARAMFS_CFG_PREPARE_NETWORK_MODULES}
  else
    # NR>1: skip lsmod header.
    while read -r _net_name || [ -n "${_net_name}" ]; do
      [ -n "${_net_name}" ] || continue

      _net_path=$(modinfo -n "${_net_name}" 2>/dev/null) || continue
      [ -n "${_net_path}" ] || continue

      case "${_net_path}" in
        */net/*) ;;
        *) continue ;;
      esac

      case " ${_net_mods} " in
        *" ${_net_name} "*) continue ;;
      esac
      _net_mods="${_net_mods} ${_net_name}"
    done <<EOF
$(lsmod | awk 'NR > 1 { print $1 }')
EOF
  fi

  # Trim leading space from the loop accumulation.
  _net_mods=${_net_mods# }

  # 8021q for iBFT (and other) VLAN bring-up; must be before modules hook.
  _net_mods="${_net_mods} 8021q"
  _net_mods=${_net_mods# }

  if [ -n "${_net_mods}" ]; then
    echo "network: NIC modules: ${_net_mods}" >&2
    YARAMFS_CFG_PREPARE_MODULES_ADDL="${YARAMFS_CFG_PREPARE_MODULES_ADDL} ${_net_mods}"
    # Trim leading space if ADDL was empty before append.
    YARAMFS_CFG_PREPARE_MODULES_ADDL=${YARAMFS_CFG_PREPARE_MODULES_ADDL# }
    export_cfg YARAMFS_CFG_PREPARE_MODULES_ADDL
  else
    echo "network: no NIC modules (built-in, override empty, or none loaded)" >&2
  fi
}

boot() { :; }

prepare_or_boot "$@"
