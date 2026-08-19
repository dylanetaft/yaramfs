#!/bin/sh
. hooks/shared/head.sh

prepare() {
  default_value YARAMFS_CFG_KERNEL_VERSION "$(uname -r)" ${LINENO}
  default_value YARAMFS_CFG_MODULES_DIR "/lib/modules/${YARAMFS_CFG_KERNEL_VERSION}" ${LINENO}
  default_value YARAMFS_CFG_P_BUSYBOX_PATH "$(which busybox)" ${LINENO}

  # Roots: optional explicit list + ADDL from earlier hooks (network, iscsi, …).
  # shellcheck disable=SC2086
  set -- ${YARAMFS_CFG_MODULES} ${YARAMFS_CFG_MODULES_ADDL}

  ensure_modules "$@"
}

boot() {
  [ -f /etc/yaramfs-modules ] || return 0
  while read -r m || [ -n "${m}" ]; do
    [ -n "${m}" ] || continue
    modprobe "${m}" || die ${LINENO} "modprobe ${m} failed"
  done < /etc/yaramfs-modules
}


# ensure_modules NAME [NAME...]
# Copy each root module + hard deps into the build tree, merge roots into
# $BUILD_DIR/etc/yaramfs-modules, and run busybox depmod when anything was copied.
# Caller must set YARAMFS_CFG_KERNEL_VERSION, YARAMFS_CFG_MODULES_DIR,
# YARAMFS_CFG_P_BUSYBOX_PATH.
# Use _em_* locals-by-convention so we do not clobber for_each_hook's name=.
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

  _em_paths=$(mktemp)
  _em_bootlist=$(mktemp)
  _em_ncopy=0

  : > "${_em_paths}"
  : > "${_em_bootlist}"

  for _em_name in "$@"; do
    [ -n "${_em_name}" ] || continue

    if ! _em_dep_out=$("${_em_bb}" modprobe -D "${_em_name}" 2>&1); then
      rm -f "${_em_paths}" "${_em_bootlist}"
      die ${LINENO} "busybox modprobe -D ${_em_name} failed: ${_em_dep_out}"
    fi

    printf '%s\n' "${_em_name}" >> "${_em_bootlist}"

    # Avoid pipe subshell so die aborts prepare.
    while read -r _em_cmd _em_ko _em_rest || [ -n "${_em_cmd}" ]; do
      [ "${_em_cmd}" = "insmod" ] || continue
      [ -n "${_em_ko}" ] || continue
      if [ ! -f "${_em_ko}" ]; then
        rm -f "${_em_paths}" "${_em_bootlist}"
        die ${LINENO} "module file missing for ${_em_name}: ${_em_ko}"
      fi
      if ! grep -qxF "${_em_ko}" "${_em_paths}" 2>/dev/null; then
        printf '%s\n' "${_em_ko}" >> "${_em_paths}"
      fi
    done <<EOF
${_em_dep_out}
EOF
  done

  _em_dest_root="${_em_build}/lib/modules/${_em_kver}"
  mkdir -p "${_em_dest_root}"

  while read -r _em_ko || [ -n "${_em_ko}" ]; do
    [ -n "${_em_ko}" ] || continue
    case "${_em_ko}" in
      "${_em_moddir}"/*)
        _em_rel=${_em_ko#"${_em_moddir}"/}
        ;;
      *)
        case "${_em_ko}" in
          */lib/modules/"${_em_kver}"/*)
            _em_rel=${_em_ko#*/lib/modules/"${_em_kver}"/}
            ;;
          *)
            rm -f "${_em_paths}" "${_em_bootlist}"
            die ${LINENO} "module path not under ${_em_moddir}: ${_em_ko}"
            ;;
        esac
        ;;
    esac
    _em_dest="${_em_dest_root}/${_em_rel}"
    if [ -e "${_em_dest}" ]; then
      continue
    fi
    mkdir -p "$(dirname "${_em_dest}")"
    cp -a "${_em_ko}" "${_em_dest}"
    _em_ncopy=$((_em_ncopy + 1))
  done < "${_em_paths}"

  if [ "${_em_ncopy}" -gt 0 ]; then
    "${_em_bb}" depmod -b "${_em_build}" "${_em_kver}" || {
      rm -f "${_em_paths}" "${_em_bootlist}"
      die ${LINENO} "busybox depmod -b ${_em_build} ${_em_kver} failed"
    }
  fi

  mkdir -p "${_em_build}/etc"
  _em_bootfile="${_em_build}/etc/yaramfs-modules"
  if [ -f "${_em_bootfile}" ]; then
    cat "${_em_bootfile}" >> "${_em_bootlist}"
  fi
  LC_ALL=C sort -u "${_em_bootlist}" > "${_em_bootfile}"
  chmod 0644 "${_em_bootfile}"

  _em_nboot=$(wc -l < "${_em_bootfile}" | tr -d ' ')
  echo "modules: ensure copied ${_em_ncopy} new ko, boot list ${_em_nboot} (kver ${_em_kver})" >&2

  rm -f "${_em_paths}" "${_em_bootlist}"
}


prepare_or_boot "$@"
