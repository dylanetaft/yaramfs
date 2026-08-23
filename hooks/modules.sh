#!/bin/sh
. hooks/shared/head.sh

prepare() {
  default_value YARAMFS_CFG_PREPARE_KERNEL_VERSION "$(uname -r)" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_MODULES_DIR "/lib/modules/${YARAMFS_CFG_PREPARE_KERNEL_VERSION}" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_BUSYBOX_PATH "$(which busybox)" ${LINENO}

  # Roots: optional explicit list + ADDL from earlier hooks (network, input, iscsi, …).
  # shellcheck disable=SC2086
  set -- ${YARAMFS_CFG_PREPARE_MODULES} ${YARAMFS_CFG_PREPARE_MODULES_ADDL}

  ensure_modules "$@"
}

boot() {
  [ -f /etc/yaramfs-modules ] || return 0
  while read -r m || [ -n "${m}" ]; do
    [ -n "${m}" ] || continue
    # Soft-fail: list may include host-autodetected drivers (e.g. virtio from a
    # VM build) that are absent or irrelevant on this machine. Needed hardware
    # still fails later (network/iscsi/root) with a clearer error.
    if ! modprobe "${m}"; then
      echo "modules: modprobe ${m} failed (continuing)" >&2
    fi
  done < /etc/yaramfs-modules
}

# ensure_modules NAME [NAME...]
# Resolve each root against YARAMFS_CFG_PREPARE_MODULES_DIR (target kver tree),
# copy unique .ko paths into the build tree, write boot roots to
# $BUILD_DIR/etc/yaramfs-modules, depmod if needed.
#
# Dep resolution uses host **kmod** modprobe only (not busybox — no useful -d):
#   modprobe -d ROOT -S KVER -D -q NAME
# ROOT is the parent of lib/modules/KVER (e.g. / or /mnt/gentoo).
#
# If kmod yields no insmod lines, safety fallback: find NAME.ko* under MODULES_DIR
# and copy that leaf only (no deps — list soft deps in PREPARE_MODULES* if needed).
#
# Builtin/missing roots are skipped. Missing .ko files are caught at copy time.
# Caller must set YARAMFS_CFG_PREPARE_KERNEL_VERSION, YARAMFS_CFG_PREPARE_MODULES_DIR,
# YARAMFS_CFG_PREPARE_BUSYBOX_PATH (busybox is used for depmod -b only).
# Optional: YARAMFS_CFG_PREPARE_MODPROBE = path to kmod modprobe.
ensure_modules() {
  _em_kver=${YARAMFS_CFG_PREPARE_KERNEL_VERSION}
  _em_moddir=${YARAMFS_CFG_PREPARE_MODULES_DIR}
  _em_bb=${YARAMFS_CFG_PREPARE_BUSYBOX_PATH}
  _em_build=${YARAMFS_CFG_PREPARE_BUILD_DIR}

  if [ -z "${_em_kver}" ] || [ -z "${_em_moddir}" ] || [ -z "${_em_bb}" ]; then
    die ${LINENO} "ensure_modules: set YARAMFS_CFG_PREPARE_KERNEL_VERSION, YARAMFS_CFG_PREPARE_MODULES_DIR, YARAMFS_CFG_PREPARE_BUSYBOX_PATH first"
  fi
  if [ ! -d "${_em_moddir}" ]; then
    die ${LINENO} "modules dir not found: ${_em_moddir}"
  fi
  if [ ! -x "${_em_bb}" ]; then
    die ${LINENO} "busybox not executable: ${_em_bb}"
  fi
  if [ "$#" -eq 0 ]; then
    return 0
  fi

  # kmod: modules live at $ROOT/lib/modules/$KVER.
  _em_mod_root=
  _em_mod_base=${_em_moddir%/}
  case "${_em_mod_base}" in
    */lib/modules/"${_em_kver}")
      _em_mod_root=${_em_mod_base%/lib/modules/"${_em_kver}"}
      [ -n "${_em_mod_root}" ] || _em_mod_root=/
      ;;
    */lib/modules/*)
      _em_mod_ver=$(basename "${_em_mod_base}")
      _em_mod_root=${_em_mod_base%/lib/modules/"${_em_mod_ver}"}
      [ -n "${_em_mod_root}" ] || _em_mod_root=/
      ;;
    *)
      die ${LINENO} "MODULES_DIR must look like …/lib/modules/<kver>: ${_em_moddir}"
      ;;
  esac

  _em_modprobe=$(_em_find_kmod_modprobe) \
    || die ${LINENO} "kmod modprobe not found (need sys-apps/kmod; busybox modprobe cannot target another kver). Set YARAMFS_CFG_PREPARE_MODPROBE if needed."

  _em_deps=
  _em_roots=

  for _em_name in "$@"; do
    [ -n "${_em_name}" ] || continue

    _em_out=
    _em_how=

    _em_out=$("${_em_modprobe}" -d "${_em_mod_root}" -S "${_em_kver}" -D -q "${_em_name}" 2>/dev/null) || true
    if _em_insmod_lines_ok "${_em_out}"; then
      _em_how=kmod
    else
      _em_out=
    fi

    # Safety: locate NAME.ko* under MODULES_DIR (leaf only, no dep resolution).
    if [ -z "${_em_out}" ]; then
      _em_ko=$(_em_find_ko "${_em_name}") || true
      if [ -n "${_em_ko}" ] && [ -f "${_em_ko}" ]; then
        _em_out="insmod ${_em_ko}"
        _em_how=find
        echo "modules: ${_em_name}: found ${_em_ko} (leaf only; add soft deps to PREPARE_MODULES* if needed)" >&2
      fi
    fi

    if [ -n "${_em_out}" ]; then
      _em_deps="${_em_deps}${_em_out}
"
      _em_roots="${_em_roots}${_em_name}
"
      [ "${_em_how}" = kmod ] && echo "modules: ${_em_name}: resolved via kmod (${_em_modprobe} -d ${_em_mod_root} -S ${_em_kver})" >&2
    else
      echo "modules: skip ${_em_name} (builtin, missing, or no .ko under ${_em_moddir})" >&2
    fi
  done

  # Unique ko paths and root names (order irrelevant; modprobe resolves deps at boot).
  _em_paths=$(printf '%s\n' "${_em_deps}" | awk '$1 == "insmod" && $2 != "" && !seen[$2]++ { print $2 }')
  _em_boot=$(printf '%s\n' "${_em_roots}" | awk 'NF && !seen[$0]++')

  _em_dest_root="${_em_build}/lib/modules/${_em_kver}"
  mkdir -p "${_em_dest_root}"

  _em_ncopy=0
  while read -r _em_ko || [ -n "${_em_ko}" ]; do
    [ -n "${_em_ko}" ] || continue

    if [ ! -f "${_em_ko}" ]; then
      die ${LINENO} "module file missing: ${_em_ko}"
    fi

    # Prefix checks via ${var#pat}: non-match leaves the string unchanged.
    if [ "${_em_ko}" != "${_em_ko#"${_em_moddir}"/}" ]; then
      _em_rel=${_em_ko#"${_em_moddir}"/}
    elif [ "${_em_ko}" != "${_em_ko#*/lib/modules/"${_em_kver}"/}" ]; then
      _em_rel=${_em_ko#*/lib/modules/"${_em_kver}"/}
    else
      die ${LINENO} "module path not under ${_em_moddir}: ${_em_ko}"
    fi

    _em_dest="${_em_dest_root}/${_em_rel}"
    if [ -e "${_em_dest}" ]; then
      continue
    fi
    mkdir -p "$(dirname "${_em_dest}")"
    cp -a "${_em_ko}" "${_em_dest}" || die ${LINENO} "cp ${_em_ko} failed"
    _em_ncopy=$((_em_ncopy + 1))
  done <<EOF
${_em_paths}
EOF

  if [ "${_em_ncopy}" -gt 0 ]; then
    "${_em_bb}" depmod -b "${_em_build}" "${_em_kver}" \
      || die ${LINENO} "busybox depmod -b ${_em_build} ${_em_kver} failed"
  fi

  mkdir -p "${_em_build}/etc"
  _em_bootfile="${_em_build}/etc/yaramfs-modules"
  if [ -f "${_em_bootfile}" ]; then
    _em_boot=$(printf '%s\n%s\n' "${_em_boot}" "$(cat "${_em_bootfile}")" | awk 'NF && !seen[$0]++')
  fi
  printf '%s\n' "${_em_boot}" > "${_em_bootfile}"
  chmod 0644 "${_em_bootfile}"

  _em_nboot=$(grep -c . "${_em_bootfile}" 2>/dev/null || echo 0)
  echo "modules: ensure copied ${_em_ncopy} new ko, boot list ${_em_nboot} (kver ${_em_kver})" >&2
}

# Locate kmod's modprobe (not a busybox applet). Prints path or returns 1.
_em_find_kmod_modprobe() {
  _ef_cand=
  if [ -n "${YARAMFS_CFG_PREPARE_MODPROBE:-}" ]; then
    _ef_cand=${YARAMFS_CFG_PREPARE_MODPROBE}
    if [ -x "${_ef_cand}" ] && "${_ef_cand}" -V 2>&1 | head -n1 | grep -qi kmod; then
      printf '%s\n' "${_ef_cand}"
      return 0
    fi
    return 1
  fi
  for _ef_cand in /sbin/modprobe /usr/sbin/modprobe /bin/modprobe /usr/bin/modprobe; do
    [ -x "${_ef_cand}" ] || continue
    # busybox applets often report "BusyBox v..." — reject those.
    if "${_ef_cand}" -V 2>&1 | head -n1 | grep -qi kmod; then
      printf '%s\n' "${_ef_cand}"
      return 0
    fi
  done
  # Last resort: PATH, still require kmod banner.
  _ef_cand=$(command -v modprobe 2>/dev/null) || true
  if [ -n "${_ef_cand}" ] && [ -x "${_ef_cand}" ] \
    && "${_ef_cand}" -V 2>&1 | head -n1 | grep -qi kmod; then
    printf '%s\n' "${_ef_cand}"
    return 0
  fi
  return 1
}

# True if arg has at least one "insmod path" line.
_em_insmod_lines_ok() {
  [ -n "$(echo "$1" | grep -e '^insmod[[:space:]]\{1,\}[^[:space:]]')" ]
}

# Find NAME.ko / NAME.ko.gz / … under $_em_moddir. Prints one absolute path.
_em_find_ko() {
  _ef_name=$1
  find "${_em_moddir}" -type f \( \
      -name "${_ef_name}.ko" -o \
      -name "${_ef_name}.ko.gz" -o \
      -name "${_ef_name}.ko.xz" -o \
      -name "${_ef_name}.ko.zst" -o \
      -name "${_ef_name}.ko.bz2" \
    \) 2>/dev/null | head -n1
}

prepare_or_boot "$@"
