#!/bin/sh
. hooks/shared/head.sh

# Bring up NIC(s) from iBFT sysfs (/sys/firmware/ibft/ethernetN).
# Per entry: firmware values → YARAMFS_CFG_BOOT_IBFT_<N>_* via default_if_unset
# (pre-set CFG wins), match MAC with ip/sysfs, rename to ibftN, optional VLAN,
# then ip addr from iBFT. Config order: after modules, before boot-iscsi.

prepare() { :; }

# Lowercase, strip whitespace/newlines (sysfs often has a trailing \n).
_ibft_norm_mac() {
  echo "$1" | tr 'A-F' 'a-f' | tr -d ' \t\n\r'
}

_ibft_trim() {
  echo "$1" | tr -d ' \t\n\r'
}

# Print iface name whose /sys address matches normalized MAC, or fail.
_ibft_find_iface_by_mac() {
  _want=$1
  for _p in /sys/class/net/*; do
    [ -e "${_p}/address" ] || continue
    _n=${_p##*/}
    [ "${_n}" = "lo" ] && continue
    _have=$(_ibft_norm_mac "$(cat "${_p}/address")")
    if [ "${_have}" = "${_want}" ]; then
      echo "${_n}"
      return 0
    fi
  done
  return 1
}

# Common dotted masks → prefix length (fallback when prefix-len is empty).
_ibft_mask_to_prefix() {
  case "$1" in
    255.255.255.255) echo 32 ;;
    255.255.255.254) echo 31 ;;
    255.255.255.252) echo 30 ;;
    255.255.255.248) echo 29 ;;
    255.255.255.240) echo 28 ;;
    255.255.255.224) echo 27 ;;
    255.255.255.192) echo 26 ;;
    255.255.255.128) echo 25 ;;
    255.255.255.0)   echo 24 ;;
    255.255.254.0)   echo 23 ;;
    255.255.252.0)   echo 22 ;;
    255.255.248.0)   echo 21 ;;
    255.255.240.0)   echo 20 ;;
    255.255.224.0)   echo 19 ;;
    255.255.192.0)   echo 18 ;;
    255.255.128.0)   echo 17 ;;
    255.255.0.0)     echo 16 ;;
    255.0.0.0)       echo 8 ;;
    *) return 1 ;;
  esac
}

# Apply one /sys/firmware/ibft/ethernetN directory.
_ibft_apply_ethernet() {
  _eth=$1
  _base=${_eth##*/}
  _idx=${_base#ethernet}
  _ifname="ibft${_idx}"

  _fw_mac=$(_ibft_norm_mac "$(cat "${_eth}/mac" 2>/dev/null)")
  _fw_ip=$(_ibft_trim "$(cat "${_eth}/ip-addr" 2>/dev/null)")
  _fw_prefix=$(_ibft_trim "$(cat "${_eth}/prefix-len" 2>/dev/null)")
  _fw_mask=$(_ibft_trim "$(cat "${_eth}/subnet-mask" 2>/dev/null)")
  _fw_vlan=$(_ibft_trim "$(cat "${_eth}/vlan" 2>/dev/null)")

  # Firmware fills CFG only when unset; empty overrides stay empty.
  default_if_unset "YARAMFS_CFG_BOOT_IBFT_${_idx}_MAC" "${_fw_mac}" ${LINENO}
  default_if_unset "YARAMFS_CFG_BOOT_IBFT_${_idx}_IP" "${_fw_ip}" ${LINENO}
  default_if_unset "YARAMFS_CFG_BOOT_IBFT_${_idx}_PREFIX" "${_fw_prefix}" ${LINENO}
  default_if_unset "YARAMFS_CFG_BOOT_IBFT_${_idx}_NETMASK" "${_fw_mask}" ${LINENO}
  default_if_unset "YARAMFS_CFG_BOOT_IBFT_${_idx}_VLAN" "${_fw_vlan}" ${LINENO}

  eval "_mac=\${YARAMFS_CFG_BOOT_IBFT_${_idx}_MAC}"
  eval "_ip=\${YARAMFS_CFG_BOOT_IBFT_${_idx}_IP}"
  eval "_prefix=\${YARAMFS_CFG_BOOT_IBFT_${_idx}_PREFIX}"
  eval "_mask=\${YARAMFS_CFG_BOOT_IBFT_${_idx}_NETMASK}"
  eval "_vlan=\${YARAMFS_CFG_BOOT_IBFT_${_idx}_VLAN}"

  _mac=$(_ibft_norm_mac "${_mac}")
  _ip=$(_ibft_trim "${_ip}")
  _prefix=$(_ibft_trim "${_prefix}")
  _mask=$(_ibft_trim "${_mask}")
  _vlan=$(_ibft_trim "${_vlan}")

  [ -n "${_mac}" ] || die ${LINENO} "iBFT ${_base}: empty mac"
  [ -n "${_ip}" ] || die ${LINENO} "iBFT ${_base}: empty ip-addr"

  if [ -z "${_prefix}" ]; then
    if [ -n "${_mask}" ]; then
      _prefix=$(_ibft_mask_to_prefix "${_mask}") \
        || die ${LINENO} "iBFT ${_base}: cannot map netmask ${_mask} to prefix"
    else
      die ${LINENO} "iBFT ${_base}: need prefix-len or subnet-mask"
    fi
  fi

  _cur=$(_ibft_find_iface_by_mac "${_mac}") \
    || die ${LINENO} "iBFT ${_base}: no netdev with mac ${_mac}"

  if [ "${_cur}" != "${_ifname}" ]; then
    if [ -e "/sys/class/net/${_ifname}" ]; then
      die ${LINENO} "iBFT ${_base}: ${_ifname} already exists (not mac ${_mac})"
    fi
    ip link set dev "${_cur}" down \
      || die ${LINENO} "ip link set ${_cur} down failed"
    ip link set dev "${_cur}" name "${_ifname}" \
      || die ${LINENO} "ip link set ${_cur} name ${_ifname} failed"
  fi

  ip link set dev "${_ifname}" up \
    || die ${LINENO} "ip link set ${_ifname} up failed"

  _addr_dev=${_ifname}
  if [ -n "${_vlan}" ] && [ "${_vlan}" != "0" ]; then
    _vname="${_ifname}.${_vlan}"
    if [ ! -e "/sys/class/net/${_vname}" ]; then
      ip link add link "${_ifname}" name "${_vname}" type vlan id "${_vlan}" \
        || die ${LINENO} "ip link add vlan ${_vname} failed"
    fi
    ip link set dev "${_vname}" up \
      || die ${LINENO} "ip link set ${_vname} up failed"
    _addr_dev=${_vname}
  fi

  # Idempotent: already-assigned address is OK.
  if ! ip addr show dev "${_addr_dev}" 2>/dev/null | grep -F " ${_ip}/" >/dev/null 2>&1; then
    ip addr add "${_ip}/${_prefix}" dev "${_addr_dev}" \
      || die ${LINENO} "ip addr add ${_ip}/${_prefix} dev ${_addr_dev} failed"
  fi

  echo "ibft: ${_base} mac=${_mac} ${_cur}->${_ifname} addr=${_addr_dev} ${_ip}/${_prefix} vlan=${_vlan:-0}" >&2
}

boot() {
  default_if_unset YARAMFS_CFG_BOOT_IBFT_DIR "/sys/firmware/ibft" ${LINENO}

  _ibft_root=${YARAMFS_CFG_BOOT_IBFT_DIR}
  if [ ! -d "${_ibft_root}" ]; then
    die ${LINENO} "iBFT not present: ${_ibft_root} (load iscsi_ibft first?)"
  fi

  _ibft_any=
  for _eth in "${_ibft_root}"/ethernet*; do
    [ -d "${_eth}" ] || continue
    _ibft_any=1
    _ibft_apply_ethernet "${_eth}"
  done

  [ -n "${_ibft_any}" ] \
    || die ${LINENO} "no ethernet* under ${_ibft_root}"
}

prepare_or_boot "$@"
