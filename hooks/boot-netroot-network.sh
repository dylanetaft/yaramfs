#!/bin/sh
. hooks/shared/head.sh

# Bring up NIC(s) for netroot (static CFG and/or iBFT).
# Config keys use MAC id = lowercase hex, no separators (aa:bb:… → aabb…).
#   YARAMFS_CFG_BOOT_NETROOT_<macid>_IP
#   YARAMFS_CFG_BOOT_NETROOT_<macid>_PREFIX
#   YARAMFS_CFG_BOOT_NETROOT_<macid>_NETMASK
#   YARAMFS_CFG_BOOT_NETROOT_<macid>_GATEWAY
#   YARAMFS_CFG_BOOT_NETROOT_<macid>_VLAN
#   YARAMFS_CFG_BOOT_NETROOT_<macid>_MTU             (optional decimal; L3 iface + parent if VLAN)
#   YARAMFS_CFG_BOOT_NETROOT_<macid>_IPV6_ENABLE_RA  (exactly 1 → RA/SLAAC sysctls)
# L3: static IPv4 (IP + PREFIX/NETMASK) and/or IPV6_ENABLE_RA=1. Need at least one.
# Unset IPv4/VLAN fields may be filled from iBFT ethernet* with the same MAC.
# Shared apply: match iface → up → optional VLAN → optional MTU → optional v4 → optional RA.
# Then settle: ping iface brd (IPv4) or ff02::1 (IPv6) until any reply (self OK).
# YARAMFS_CFG_BOOT_NETROOT_SETTLE = wall-clock seconds per iface (default 30; 0 = skip).
# Config order: after modules, before boot-iscsi.

prepare() { :; }

# Lowercase; strip whitespace and common MAC separators.
_netroot_norm_mac() {
  echo "$1" | tr 'A-F' 'a-f' | tr -d ' \t\n\r:.-'
}

_netroot_trim() {
  echo "$1" | tr -d ' \t\n\r'
}

# True if $1 is a 12-char lowercase hex MAC id (safe in CFG var names).
_netroot_is_macid() {
  printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{12}$'
}

# Print iface name whose address matches macid, or fail.
_netroot_find_iface_by_macid() {
  _want=$1
  for _p in /sys/class/net/*; do
    [ -e "${_p}/address" ] || continue
    _n=${_p##*/}
    [ "${_n}" = "lo" ] && continue
    _have=$(_netroot_norm_mac "$(cat "${_p}/address")")
    if [ "${_have}" = "${_want}" ]; then
      echo "${_n}"
      return 0
    fi
  done
  return 1
}

# Common dotted masks → prefix length (fallback when prefix-len is empty).
_netroot_mask_to_prefix() {
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

# Append macid to ${_netroot_macids} once (space-separated).
_netroot_macids_add() {
  _m=$1
  _netroot_is_macid "${_m}" || return 1
  case " ${_netroot_macids} " in
    *" ${_m} "*) ;;
    *) _netroot_macids="${_netroot_macids}${_netroot_macids:+ }${_m}" ;;
  esac
}

# Read YARAMFS_CFG_BOOT_NETROOT_<macid>_<SUFFIX> into stdout (macid must be valid).
_netroot_cfg_get() {
  _m=$1
  _suf=$2
  _netroot_is_macid "${_m}" || die ${LINENO} "invalid macid for cfg get: ${_m}"
  yaramfs_get_var "YARAMFS_CFG_BOOT_NETROOT_${_m}_${_suf}"
}

# Empty OK; otherwise must be a net token (no spaces, slashes, shell metacharacters).
_netroot_require_net_token() {
  _nrt_label=$1
  _nrt_val=$2
  [ -z "${_nrt_val}" ] && return 0
  yaramfs_is_net_token "${_nrt_val}" \
    || die ${LINENO} "netroot: unsafe ${_nrt_label}"
}

# If CFG field unset, set from $3 after yaramfs_is_net_token (firmware path).
_netroot_default_from_fw() {
  _m=$1
  _suf=$2
  _fw=$3
  _name="YARAMFS_CFG_BOOT_NETROOT_${_m}_${_suf}"
  yaramfs_var_is_set "${_name}" && return 0
  [ -n "${_fw}" ] || return 0
  yaramfs_is_net_token "${_fw}" \
    || die ${LINENO} "unsafe iBFT value for ${_name}"
  default_if_unset "${_name}" "${_fw}" ${LINENO}
}

# Fill unset NETROOT_<macid>_* from iBFT ethernet* with matching MAC (if any).
_netroot_ibft_fill_macid() {
  _m=$1
  _ibft_root=${YARAMFS_CFG_BOOT_NETROOT_IBFT_DIR}
  [ -d "${_ibft_root}" ] || return 0

  for _eth in "${_ibft_root}"/ethernet*; do
    [ -d "${_eth}" ] || continue
    _fw_mac=$(_netroot_norm_mac "$(cat "${_eth}/mac" 2>/dev/null)")
    [ "${_fw_mac}" = "${_m}" ] || continue

    _fw_ip=$(_netroot_trim "$(cat "${_eth}/ip-addr" 2>/dev/null)")
    _fw_prefix=$(_netroot_trim "$(cat "${_eth}/prefix-len" 2>/dev/null)")
    _fw_mask=$(_netroot_trim "$(cat "${_eth}/subnet-mask" 2>/dev/null)")
    _fw_gw=$(_netroot_trim "$(cat "${_eth}/gateway" 2>/dev/null)")
    _fw_vlan=$(_netroot_trim "$(cat "${_eth}/vlan" 2>/dev/null)")

    _netroot_default_from_fw "${_m}" IP "${_fw_ip}"
    _netroot_default_from_fw "${_m}" PREFIX "${_fw_prefix}"
    _netroot_default_from_fw "${_m}" NETMASK "${_fw_mask}"
    _netroot_default_from_fw "${_m}" GATEWAY "${_fw_gw}"
    _netroot_default_from_fw "${_m}" VLAN "${_fw_vlan}"
    return 0
  done
  return 0
}

# Print one settle target for DEV: IPv4 brd from ip if present, else ff02::1.
_get_netdev_broadcast_addr() {
  _dev=$1
  _brd=$(ip -o -4 addr show dev "${_dev}" 2>/dev/null \
    | sed -n 's/.* brd \([^ ]*\).*/\1/p' | head -n1)
  if [ -n "${_brd}" ]; then
    printf '%s\n' "${_brd}"
    return 0
  fi
  printf '%s\n' 'ff02::1'
  return 0
}

# One settle probe: -W 1 caps a single try (not the settle budget).
# IPv6 targets (ff02::1, etc.): prefer ping -6, fall back to plain ping.
_netroot_settle_ping() {
  _dev=$1
  _tgt=$2
  case "${_tgt}" in
    *:*)
      ping -6 -c 1 -W 1 -I "${_dev}" "${_tgt}" >/dev/null 2>&1 \
        || ping -c 1 -W 1 -I "${_dev}" "${_tgt}" >/dev/null 2>&1
      ;;
    *)
      ping -c 1 -W 1 -I "${_dev}" "${_tgt}" >/dev/null 2>&1
      ;;
  esac
}

# Ping brd/ff02::1 on DEV until any reply or SETTLE wall-clock seconds (0 = skip).
# Budget is date +%s deadline (instant ping fail must not burn the budget).
# sleep 1 between failures rate-limits probes.
_netroot_wait_settle() {
  _dev=$1
  _settle=${YARAMFS_CFG_BOOT_NETROOT_SETTLE}
  [ "${_settle}" -eq 0 ] 2>/dev/null && return 0

  _tgt=$(_get_netdev_broadcast_addr "${_dev}")
  [ -n "${_tgt}" ] || die ${LINENO} "netroot: ${_dev}: empty settle target"

  _start=$(date +%s) || die ${LINENO} "date +%s failed"
  _deadline=$((_start + _settle))
  _n=0
  _last_log=-1

  while :; do
    if _netroot_settle_ping "${_dev}" "${_tgt}"; then
      echo "netroot: ${_dev} settled (ping ${_tgt})" >&2
      return 0
    fi

    _now=$(date +%s) || die ${LINENO} "date +%s failed"
    _elapsed=$((_now - _start))
    _n=$((_n + 1))

    # Progress: first fail, then when elapsed crosses 5s boundaries.
    if [ "${_n}" -eq 1 ] || {
      [ "${_elapsed}" -ge 5 ] \
        && [ $((_elapsed / 5)) -gt $((_last_log / 5)) ]
    }; then
      echo "yaramfs: netroot: waiting for ${_dev} ping ${_tgt} (${_elapsed}/${_settle}s)" >&2
      _last_log=${_elapsed}
    fi

    if [ "${_now}" -ge "${_deadline}" ]; then
      die ${LINENO} "netroot: ${_dev} not ready after ${_settle}s (ping ${_tgt})"
    fi

    sleep 1
  done
}

# Shared path: CFG for macid → find iface → up → vlan → optional MTU → optional v4 → optional RA → settle.
_netroot_apply_macid() {
  _m=$1
  _netroot_is_macid "${_m}" || die ${LINENO} "invalid macid: ${_m}"

  _netroot_ibft_fill_macid "${_m}"

  _ip=$(_netroot_trim "$(_netroot_cfg_get "${_m}" IP)")
  _prefix=$(_netroot_trim "$(_netroot_cfg_get "${_m}" PREFIX)")
  _mask=$(_netroot_trim "$(_netroot_cfg_get "${_m}" NETMASK)")
  _gw=$(_netroot_trim "$(_netroot_cfg_get "${_m}" GATEWAY)")
  _vlan=$(_netroot_trim "$(_netroot_cfg_get "${_m}" VLAN)")
  _mtu=$(_netroot_trim "$(_netroot_cfg_get "${_m}" MTU)")
  _ra=$(_netroot_trim "$(_netroot_cfg_get "${_m}" IPV6_ENABLE_RA)")

  _netroot_require_net_token "${_m} IP" "${_ip}"
  _netroot_require_net_token "${_m} NETMASK" "${_mask}"
  _netroot_require_net_token "${_m} GATEWAY" "${_gw}"

  if [ -n "${_prefix}" ]; then
    printf '%s\n' "${_prefix}" | grep -Eq '^[0-9]+$' \
      || die ${LINENO} "netroot ${_m}: PREFIX must be a decimal integer"
  fi
  if [ -n "${_vlan}" ]; then
    printf '%s\n' "${_vlan}" | grep -Eq '^[0-9]+$' \
      || die ${LINENO} "netroot ${_m}: VLAN must be a decimal integer"
  fi
  if [ -n "${_mtu}" ]; then
    printf '%s\n' "${_mtu}" | grep -Eq '^[0-9]+$' \
      || die ${LINENO} "netroot ${_m}: MTU must be a decimal integer"
  fi
  if [ -n "${_ra}" ] && [ "${_ra}" != "1" ]; then
    die ${LINENO} "netroot ${_m}: IPV6_ENABLE_RA must be 1 if set"
  fi

  _ra_on=0
  [ "${_ra}" = "1" ] && _ra_on=1
  _v4_on=0
  [ -n "${_ip}" ] && _v4_on=1

  if [ "${_v4_on}" -eq 0 ] && [ "${_ra_on}" -eq 0 ]; then
    die ${LINENO} "netroot ${_m}: need IP and/or IPV6_ENABLE_RA=1"
  fi
  if [ "${_v4_on}" -eq 0 ]; then
    if [ -n "${_prefix}" ] || [ -n "${_mask}" ] || [ -n "${_gw}" ]; then
      die ${LINENO} "netroot ${_m}: PREFIX/NETMASK/GATEWAY require IP"
    fi
  fi

  if [ "${_v4_on}" -eq 1 ]; then
    if [ -z "${_prefix}" ]; then
      if [ -n "${_mask}" ]; then
        _prefix=$(_netroot_mask_to_prefix "${_mask}") \
          || die ${LINENO} "netroot ${_m}: cannot map netmask ${_mask} to prefix"
      else
        die ${LINENO} "netroot ${_m}: need PREFIX or NETMASK"
      fi
    fi
  fi

  _ifname=$(_netroot_find_iface_by_macid "${_m}") \
    || die ${LINENO} "netroot ${_m}: no netdev with that mac"

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

  if [ -n "${_mtu}" ]; then
    # VLAN MTU cannot exceed parent; set parent first when both differ.
    if [ "${_addr_dev}" != "${_ifname}" ]; then
      ip link set dev "${_ifname}" mtu "${_mtu}" \
        || die ${LINENO} "ip link set ${_ifname} mtu ${_mtu} failed"
    fi
    ip link set dev "${_addr_dev}" mtu "${_mtu}" \
      || die ${LINENO} "ip link set ${_addr_dev} mtu ${_mtu} failed"
  fi

  if [ "${_v4_on}" -eq 1 ]; then
    # Idempotent: already-assigned address is OK.
    if ! ip addr show dev "${_addr_dev}" 2>/dev/null | grep -F " ${_ip}/" >/dev/null 2>&1; then
      ip addr add "${_ip}/${_prefix}" dev "${_addr_dev}" \
        || die ${LINENO} "ip addr add ${_ip}/${_prefix} dev ${_addr_dev} failed"
    fi

    # Optional default route via this NIC's gateway (iBFT or CFG).
    if [ -n "${_gw}" ]; then
      if ! ip route show default 2>/dev/null | grep -F " via ${_gw} " >/dev/null 2>&1; then
        ip route replace default via "${_gw}" dev "${_addr_dev}" \
          || die ${LINENO} "ip route default via ${_gw} dev ${_addr_dev} failed"
      fi
    fi
  fi

  if [ "${_ra_on}" -eq 1 ]; then
    _nr6="/proc/sys/net/ipv6/conf/${_addr_dev}"
    for _nr6_key in disable_ipv6 accept_ra autoconf; do
      [ -e "${_nr6}/${_nr6_key}" ] \
        || die ${LINENO} "netroot ${_m}: missing ${_nr6}/${_nr6_key} (ipv6 disabled?)"
    done
    printf '0\n' > "${_nr6}/disable_ipv6" \
      || die ${LINENO} "netroot ${_m}: disable_ipv6=0 failed"
    printf '1\n' > "${_nr6}/accept_ra" \
      || die ${LINENO} "netroot ${_m}: accept_ra=1 failed"
    printf '1\n' > "${_nr6}/autoconf" \
      || die ${LINENO} "netroot ${_m}: autoconf=1 failed"
  fi

  if [ "${_v4_on}" -eq 1 ]; then
    _nr_l3="${_ip}/${_prefix}"
  else
    _nr_l3="none"
  fi
  echo "netroot: mac=${_m} if=${_ifname} addr=${_addr_dev} ${_nr_l3} gw=${_gw:-none} vlan=${_vlan:-0} mtu=${_mtu:-default} ipv6_ra=${_ra_on}" >&2

  _netroot_wait_settle "${_addr_dev}"
}

# macids from iBFT ethernet* (if present).
_netroot_collect_ibft_macids() {
  _ibft_root=${YARAMFS_CFG_BOOT_NETROOT_IBFT_DIR}
  [ -d "${_ibft_root}" ] || return 0
  for _eth in "${_ibft_root}"/ethernet*; do
    [ -d "${_eth}" ] || continue
    _mid=$(_netroot_norm_mac "$(cat "${_eth}/mac" 2>/dev/null)")
    if _netroot_is_macid "${_mid}"; then
      _netroot_macids_add "${_mid}" || true
    else
      echo "netroot: skip iBFT ${_eth##*/}: bad mac '${_mid}'" >&2
    fi
  done
}

# macids from any YARAMFS_CFG_BOOT_NETROOT_<macid>_* already set.
_netroot_collect_cfg_macids() {
  for _var in $(set); do
    case "${_var}" in
      YARAMFS_CFG_BOOT_NETROOT_*=*)
        _name=${_var%%=*}
        _rest=${_name#YARAMFS_CFG_BOOT_NETROOT_}
        # rest is macid_FIELD or IBFT_DIR etc.
        case "${_rest}" in
          IBFT_*) continue ;;
        esac
        _mid=${_rest%%_*}
        _netroot_is_macid "${_mid}" || continue
        _netroot_macids_add "${_mid}" || true
        ;;
    esac
  done
}

boot() {
  default_if_unset YARAMFS_CFG_BOOT_NETROOT_IBFT_DIR "/sys/firmware/ibft" ${LINENO}
  default_if_unset YARAMFS_CFG_BOOT_NETROOT_SETTLE "30" ${LINENO}
  printf '%s\n' "${YARAMFS_CFG_BOOT_NETROOT_SETTLE}" | grep -Eq '^[0-9]+$' \
    || die ${LINENO} "YARAMFS_CFG_BOOT_NETROOT_SETTLE must be a non-negative integer"

  _netroot_macids=
  _netroot_collect_ibft_macids
  _netroot_collect_cfg_macids

  [ -n "${_netroot_macids}" ] \
    || die ${LINENO} "netroot: no MACs from iBFT or YARAMFS_CFG_BOOT_NETROOT_*"

  for _m in ${_netroot_macids}; do
    _netroot_apply_macid "${_m}"
  done
}

prepare_or_boot "$@"
