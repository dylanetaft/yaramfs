#!/bin/sh
. hooks/shared/head.sh

prepare() {
  default_value YARAMFS_CFG_KERNEL_VERSION "$(uname -r)" ${LINENO}
  default_value YARAMFS_CFG_MODULES_DIR "/lib/modules/${YARAMFS_CFG_KERNEL_VERSION}" ${LINENO}
  default_value YARAMFS_CFG_P_BUSYBOX_PATH "$(which busybox)" ${LINENO}

  # Roots: optional explicit list + ADDL from earlier hooks (network, input, iscsi, …).
  # shellcheck disable=SC2086
  set -- ${YARAMFS_CFG_MODULES} ${YARAMFS_CFG_MODULES_ADDL}

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
# Resolve each root with busybox modprobe -D -q, copy unique .ko paths into the
# build tree, write boot roots to $BUILD_DIR/etc/yaramfs-modules, depmod if needed.
# Builtin/missing roots are skipped (-q yields no insmod lines). Missing .ko files
# are caught at copy time.
# Caller must set YARAMFS_CFG_KERNEL_VERSION, YARAMFS_CFG_MODULES_DIR,
# YARAMFS_CFG_P_BUSYBOX_PATH.
ensure_modules() {
  _em_kver=${YARAMFS_CFG_KERNEL_VERSION}
  _em_moddir=${YARAMFS_CFG_MODULES_DIR}
  _em_bb=${YARAMFS_CFG_P_BUSYBOX_PATH}
  _em_build=${YARAMFS_CFG_PREP_BUILD_DIR}

  if [ -z "${_em_kver}" ] || [ -z "${_em_moddir}" ] || [ -z "${_em_bb}" ]; then
    die ${LINENO} "ensure_modules: set YARAMFS_CFG_KERNEL_VERSION, YARAMFS_CFG_MODULES_DIR, YARAMFS_CFG_P_BUSYBOX_PATH first"
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

  _em_deps=
  _em_roots=

  for _em_name in "$@"; do
    [ -n "${_em_name}" ] || continue

    # -q: builtin/missing → no output + fail; real modules still print insmod lines.
    _em_out=$("${_em_bb}" modprobe -D -q "${_em_name}" 2>&1) || true

    if [ -n "$(echo "${_em_out}" | grep -e '^insmod')" ]; then
      _em_deps="${_em_deps}${_em_out}
"
      _em_roots="${_em_roots}${_em_name}
"
    else
      echo "modules: skip ${_em_name} (builtin, missing, or no insmod paths)" >&2
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

prepare_or_boot "$@"
