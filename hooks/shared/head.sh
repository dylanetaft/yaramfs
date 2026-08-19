#!/bin/sh
die() { echo "$0:$1 $2" >&2; exit 1; }

# Defaults needed before default_value exists (and for runme / shared helpers).
# Guest /init sets YARAMFS_CFG_CONFIG_DIR=/hooks before sourcing this file.
: ${YARAMFS_CFG_PREP_BUILD_DIR:=build}
: ${YARAMFS_CFG_CONFIG_DIR:=config}

default_value() {
  var_name="$1"
  default_var_value="$2"
  caller_lineno="$3"

  eval "current_value=\${${var_name}}"

  if [ -z "${default_var_value}" ]; then
    die ${caller_lineno} "default value for ${var_name} is empty"
  fi

  if [ -z "${current_value}" ]; then
    eval "${var_name}=\"\${default_var_value}\""
  fi
}

# Apply default only when VAR is unset. Empty string is kept (blank default OK).
# Usage: default_if_unset VAR_NAME "default words" ${LINENO}
default_if_unset() {
  var_name="$1"
  default_var_value="$2"
  caller_lineno="$3"

  # ${var+x} expands to x if set (even to ""), else nothing.
  eval "is_set=\${${var_name}+x}"
  if [ -z "${is_set}" ]; then
    eval "${var_name}=\"\${default_var_value}\""
  fi
}

list_hooks() {
  if [ ! -d "${YARAMFS_CFG_CONFIG_DIR}" ]; then
    die ${LINENO} "config dir ${YARAMFS_CFG_CONFIG_DIR} does not exist"
  fi
  ls -1 "${YARAMFS_CFG_CONFIG_DIR}" 2>/dev/null | LC_ALL=C sort
}

# Call the prepare or boot function defined by the current hook.
# Hooks end with: prepare_or_boot "$@"
prepare_or_boot() {
  if [ "$1" = "prepare" ]; then
    prepare
  elif [ "$1" = "boot" ]; then
    boot
  else
    die ${LINENO} "phase must be prepare or boot"
  fi
}

# Source each hook with $1=phase. Hooks define prepare/boot and call prepare_or_boot.
# Sourcing (both phases) so boot's exec replaces PID 1 / the runner.
for_each_hook() {
  phase=$1
  if [ -z "${phase}" ]; then
    die ${LINENO} "for_each_hook requires a phase"
  fi
  if [ "${phase}" != "prepare" ] && [ "${phase}" != "boot" ]; then
    die ${LINENO} "phase must be prepare or boot"
  fi

  _feh_any=
  for _feh_name in $(list_hooks); do
    _feh_path="${YARAMFS_CFG_CONFIG_DIR}/${_feh_name}"
    # Files only (skip dirs like hooks/shared on the guest).
    [ -f "${_feh_path}" ] || continue
    _feh_any=1
    echo "=> ${_feh_name} ${phase}" >&2
    set -- "${phase}"
    # shellcheck disable=SC1090
    . "${_feh_path}" || die ${LINENO} "hook ${_feh_name} ${phase} failed"
  done

  if [ -z "${_feh_any}" ]; then
    die ${LINENO} "no hooks found in ${YARAMFS_CFG_CONFIG_DIR}"
  fi
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
