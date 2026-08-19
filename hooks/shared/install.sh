#!/bin/sh
# Shared prepare helpers. Source after hooks/shared/head.sh (host prepare only).

# Normalize module name: dashes to underscores (lsmod / modules.dep style).
modules_norm() {
  echo "$1" | tr '-' '_'
}

# True if $1 is in the blacklist (dash/underscore insensitive).
modules_blacklisted() {
  want=$(modules_norm "$1")
  for b in ${YARAMFS_CFG_MODULES_BLACKLIST}; do
    [ "$(modules_norm "${b}")" = "${want}" ] && return 0
  done
  return 1
}

# Basename of a .ko path → module name (strip compression suffix).
modules_name_from_ko() {
  n=$(basename "$1")
  case "${n}" in
    *.ko.gz)  n=${n%.ko.gz} ;;
    *.ko.xz)  n=${n%.ko.xz} ;;
    *.ko.zst) n=${n%.ko.zst} ;;
    *.ko.bz2) n=${n%.ko.bz2} ;;
    *.ko)     n=${n%.ko} ;;
  esac
  modules_norm "${n}"
}

# Resolve KVER/MODDIR/BB/blacklist defaults used by ensure_modules.
modules_prepare_defaults() {
  default_value YARAMFS_CFG_KERNEL_VERSION "$(uname -r)" ${LINENO}
  default_value YARAMFS_CFG_MODULES_DIR "/lib/modules/${YARAMFS_CFG_KERNEL_VERSION}" ${LINENO}
  # unset → GPU defaults; "" → no blacklist; set → that list only.
  default_if_unset YARAMFS_CFG_MODULES_BLACKLIST \
    "nvidia nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nouveau amdgpu radeon i915 xe" \
    ${LINENO}
  default_value YARAMFS_CFG_P_BUSYBOX_PATH "$(which busybox)" ${LINENO}
}

# ensure_modules NAME [NAME...]
# Copy each root module + hard deps into the build tree, merge roots into
# $BUILD_DIR/etc/yaramfs-modules, and run busybox depmod when anything was copied.
# Use _em_* locals-by-convention so we do not clobber for_each_hook's name=.
ensure_modules() {
  modules_prepare_defaults
  _em_kver=${YARAMFS_CFG_KERNEL_VERSION}
  _em_moddir=${YARAMFS_CFG_MODULES_DIR}
  _em_bb=${YARAMFS_CFG_P_BUSYBOX_PATH}
  _em_build=${YARAMFS_CFG_PREP_BUILD_DIR}

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
    if modules_blacklisted "${_em_name}"; then
      echo "modules: skip blacklisted ${_em_name}" >&2
      continue
    fi

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
      _em_depname=$(modules_name_from_ko "${_em_ko}")
      if modules_blacklisted "${_em_depname}"; then
        rm -f "${_em_paths}" "${_em_bootlist}"
        die ${LINENO} "${_em_name} depends on blacklisted module ${_em_depname} (${_em_ko})"
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

# install_binary SRC DEST
# Copy ELF SRC into the build root at DEST (absolute image path, e.g. /sbin/iscsistart)
# and all shared libraries from lddtree -l (flat list), preserving host paths.
install_binary() {
  _ib_src=$1
  _ib_dest=$2
  _ib_build=${YARAMFS_CFG_PREP_BUILD_DIR}

  if [ -z "${_ib_src}" ] || [ -z "${_ib_dest}" ]; then
    die ${LINENO} "install_binary requires SRC and DEST"
  fi
  if [ ! -f "${_ib_src}" ]; then
    die ${LINENO} "install_binary: source not found: ${_ib_src}"
  fi
  case "${_ib_dest}" in
    /*) ;;
    *) die ${LINENO} "install_binary DEST must be absolute image path: ${_ib_dest}" ;;
  esac

  default_value YARAMFS_CFG_P_LDDTREE "$(which lddtree)" ${LINENO}
  _ib_lddtree=${YARAMFS_CFG_P_LDDTREE}
  if [ ! -x "${_ib_lddtree}" ]; then
    die ${LINENO} "lddtree not executable: ${_ib_lddtree}"
  fi

  mkdir -p "${_ib_build}/$(dirname "${_ib_dest}")"
  install -m 0755 "${_ib_src}" "${_ib_build}${_ib_dest}"

  # Flat dependency list: binary path, interpreter, then libs.
  if ! _ib_deps=$("${_ib_lddtree}" -l "${_ib_src}" 2>&1); then
    die ${LINENO} "lddtree -l ${_ib_src} failed: ${_ib_deps}"
  fi

  _ib_nlib=0
  while read -r _ib_p || [ -n "${_ib_p}" ]; do
    [ -n "${_ib_p}" ] || continue
    # Skip the binary itself (already installed at DEST).
    [ "${_ib_p}" = "${_ib_src}" ] && continue
    case "${_ib_p}" in
      /*) ;;
      *) continue ;;
    esac
    if [ ! -e "${_ib_p}" ]; then
      die ${LINENO} "shared library missing for ${_ib_src}: ${_ib_p}"
    fi
    mkdir -p "${_ib_build}/$(dirname "${_ib_p}")"
    # Dereference so soname paths become real files at the expected path.
    cp -aL "${_ib_p}" "${_ib_build}${_ib_p}"
    _ib_nlib=$((_ib_nlib + 1))
  done <<EOF
${_ib_deps}
EOF

  # Loader often lives at /lib/ld-linux-*.so via symlink to /lib64; ensure /lib64 → usr/lib64.
  if [ -L /lib64 ] && [ ! -e "${_ib_build}/lib64" ]; then
    mkdir -p "${_ib_build}"
    cp -a /lib64 "${_ib_build}/lib64"
  fi
  if [ -L /lib/ld-linux-aarch64.so.1 ] || [ -e /lib/ld-linux-aarch64.so.1 ]; then
    if [ ! -e "${_ib_build}/lib/ld-linux-aarch64.so.1" ]; then
      mkdir -p "${_ib_build}/lib"
      cp -a /lib/ld-linux-aarch64.so.1 "${_ib_build}/lib/ld-linux-aarch64.so.1"
    fi
  fi

  echo "install_binary: ${_ib_src} -> ${_ib_dest} (+${_ib_nlib} libs)" >&2
}
