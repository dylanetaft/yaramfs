#!/bin/sh
die() { echo "$0:$1 $2" >&2; exit 1; }

# Defaults needed before default_value exists (and for runme / shared helpers).
# Guest /init sets YARAMFS_CFG_CONFIG_DIR=/hooks before sourcing this file.
: ${YARAMFS_CFG_PREPARE_BUILD_DIR:=build}
: ${YARAMFS_CFG_CONFIG_DIR:=config}
: ${YARAMFS_CFG_EXPORTS_FILE:=/tmp/yaramfs_exports}

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

# Single-quote VALUE for safe re-parse by . (shell).
sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# True (exit 0) if $1 is safe to interpolate into eval assignments.
# Allowlist: alnum, underscore, quotes, space, slash, dot, colon
# (dot/colon for IPs, netmasks, MAC strings before normalization).
yaramfs_is_eval_safe() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_'\''" /.:-]*$'
}

# export_cfg [VAR_NAME...]
# Append export lines to YARAMFS_CFG_EXPORTS_FILE so the parent runner can
# source them after this (child) hook exits. Creates parent dirs if needed.
# No args: dump every YARAMFS_CFG_* currently set (same discovery as preserve_env).
# With names: append only those variables.
export_cfg() {
  default_if_unset YARAMFS_CFG_EXPORTS_FILE "/tmp/yaramfs_exports" ${LINENO}
  _ec_file=${YARAMFS_CFG_EXPORTS_FILE}
  mkdir -p "$(dirname "${_ec_file}")" || die ${LINENO} "mkdir for ${_ec_file} failed"

  if [ "$#" -eq 0 ]; then
    for var in $(set); do
      case "${var}" in
        YARAMFS_CFG_*)
          _ec_name=$(echo "${var}" | cut -d= -s -f1)
          ;;
        *) continue ;;
      esac
      [ -n "${_ec_name}" ] || continue
      eval "_ec_val=\${${_ec_name}}"
      printf 'export %s=%s\n' "${_ec_name}" "$(sh_quote "${_ec_val}")" >> "${_ec_file}" \
        || die ${LINENO} "write ${_ec_file} failed"
    done
  else
    for _ec_name in "$@"; do
      [ -n "${_ec_name}" ] || continue
      eval "_ec_val=\${${_ec_name}}"
      printf 'export %s=%s\n' "${_ec_name}" "$(sh_quote "${_ec_val}")" >> "${_ec_file}" \
        || die ${LINENO} "write ${_ec_file} failed"
    done
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

# Run each hook as its own process (sequential). Success/failure is only the
# child exit status (die → 1). After success, if YARAMFS_CFG_EXPORTS_FILE
# exists, source it so the next child inherits any export_cfg vars. The file
# is cleared once at phase start and then append-only for the run (not deleted
# between hooks). Missing exports file is normal (nothing published yet).
# On failure: prepare aborts (die); boot returns 1 so guest /init can recover.
for_each_hook() {
  phase=$1
  if [ -z "${phase}" ]; then
    die ${LINENO} "for_each_hook requires a phase"
  fi
  if [ "${phase}" != "prepare" ] && [ "${phase}" != "boot" ]; then
    die ${LINENO} "phase must be prepare or boot"
  fi

  default_if_unset YARAMFS_CFG_EXPORTS_FILE "/tmp/yaramfs_exports" ${LINENO}
  mkdir -p "$(dirname "${YARAMFS_CFG_EXPORTS_FILE}")" \
    || die ${LINENO} "mkdir for ${YARAMFS_CFG_EXPORTS_FILE} failed"
  rm -f "${YARAMFS_CFG_EXPORTS_FILE}"

  # Children inherit these (defaults live in the runner shell otherwise).
  export YARAMFS_CFG_PREPARE_BUILD_DIR YARAMFS_CFG_CONFIG_DIR YARAMFS_CFG_EXPORTS_FILE

  _feh_any=
  for _feh_name in $(list_hooks); do
    _feh_path="${YARAMFS_CFG_CONFIG_DIR}/${_feh_name}"
    # Files only (skip dirs like hooks/shared on the guest).
    [ -f "${_feh_path}" ] || continue
    _feh_any=1
    echo "=> ${_feh_name} ${phase}" >&2

    if ! sh "${_feh_path}" "${phase}"; then
      echo "yaramfs: hook ${_feh_name} ${phase} failed" >&2
      if [ "${phase}" = "boot" ]; then
        return 1
      fi
      die ${LINENO} "hook ${_feh_name} ${phase} failed"
    fi

    if [ -f "${YARAMFS_CFG_EXPORTS_FILE}" ]; then
      # shellcheck disable=SC1090
      . "${YARAMFS_CFG_EXPORTS_FILE}" \
        || die ${LINENO} "sourcing ${YARAMFS_CFG_EXPORTS_FILE} after ${_feh_name} failed"
    fi
  done

  if [ -z "${_feh_any}" ]; then
    die ${LINENO} "no hooks found in ${YARAMFS_CFG_CONFIG_DIR}"
  fi
}

# Pick image lib dir for a host ELF path: one copy under /lib or /lib64 (etc).
# Path wins when it already says lib64/lib32; else ELF e_ident[EI_CLASS]
# (byte 4: 1=ELF32, 2=ELF64) for nested gcc dirs. Basename is enough for
# ld.so default search (no ld.so.cache, no host path tree in the image).
_install_binary_libdir() {
  case "$1" in
    */lib64/*) printf '%s' /lib64; return ;;
    */lib32/*) printf '%s' /lib32; return ;;
    */libx32/*) printf '%s' /libx32; return ;;
  esac
  # od -j4 -N1: ELF class byte (portable; no readelf required).
  _ib_ei=$(od -An -t u1 -N 1 -j 4 "$1" 2>/dev/null | tr -d ' \t\n')
  if [ "${_ib_ei}" = "2" ]; then
    printf '%s' /lib64
    return
  fi
  printf '%s' /lib
}

# install_binary SRC DEST
# Copy ELF SRC into the build root at DEST (absolute image path, e.g. /sbin/iscsistart)
# and shared libraries from lddtree -l. Each dep is a single copy at
# /lib{,64,…}/$(basename) so the dynamic linker finds it without host gcc paths
# or ld.so.cache. PT_INTERP names like /lib64/ld-linux-*.so stay valid.
install_binary() {
  _ib_src=$1
  _ib_dest=$2
  _ib_build=${YARAMFS_CFG_PREPARE_BUILD_DIR}

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

  default_value YARAMFS_CFG_PREPARE_LDDTREE "$(which lddtree)" ${LINENO}
  _ib_lddtree=${YARAMFS_CFG_PREPARE_LDDTREE}
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
    _ib_dir=$(_install_binary_libdir "${_ib_p}")
    _ib_base=$(basename "${_ib_p}")
    # build/lib -> usr/lib (base); mkdir -p follows the symlink.
    mkdir -p "${_ib_build}${_ib_dir}"
    # Dereference host symlinks so the image gets a real file (ld-linux, .so links).
    cp -aL "${_ib_p}" "${_ib_build}${_ib_dir}/${_ib_base}"
    # PT_INTERP is often /lib/ld-linux-*.so while the flat copy lands in /lib64
    # (ELF64). aarch64 Gentoo and others need the interpreter at the exact path.
    case "${_ib_base}" in
      ld-linux*.so*)
        case "${_ib_p}" in
          /*)
            if [ ! -e "${_ib_build}${_ib_p}" ]; then
              mkdir -p "${_ib_build}/$(dirname "${_ib_p}")"
              cp -aL "${_ib_p}" "${_ib_build}${_ib_p}"
            fi
            ;;
        esac
        ;;
    esac
    _ib_nlib=$((_ib_nlib + 1))
  done <<EOF
${_ib_deps}
EOF

  echo "install_binary: ${_ib_src} -> ${_ib_dest} (+${_ib_nlib} libs in /lib*)" >&2
}

# Config helpers
# The timing of when they run differs between boot and prepare
# so we are putting in shared helper
# We load variables from a script but don't want to 
# clobber manually set ones - those will override config loaded ones
# We only support single line environment variables
yaramfs_preserve_env() {
  for var in $(set); do
    case "${var}" in
      YARAMFS_CFG_*)
        var_name=$(echo "${var}" | cut -d= -s -f1)
      ;;
      *) continue ;;
    esac
    var_val=$(echo "${var}" | cut -d= -s -f2-)
    var_name="_${var_name}"

    # paranoid, as we will pass to eval (see yaramfs_is_eval_safe)
    if ! yaramfs_is_eval_safe "${var_name}"; then
      die ${LINENO} "invalid variable name: ${var_name}"
    fi
    if ! yaramfs_is_eval_safe "${var_val}"; then
      die ${LINENO} "invalid variable value: ${var_name}"
    fi
    eval "${var_name}=\"${var_val}\""
  done
}

yaramfs_load_env() {
  _cfgtype=$1
  if [ -f "${YARAMFS_CFG_CONFIG_DIR}/env/${_cfgtype}_config.sh" ]; then
    . "${YARAMFS_CFG_CONFIG_DIR}/env/${_cfgtype}_config.sh"
  fi
}

yaramfs_restore_env() {
  for var in $(set); do
    case "${var}" in
      _YARAMFS_CFG_*)
        var_name=$(echo "${var}" | cut -d= -s -f1)
      ;;
      *) continue ;;
    esac
    var_val=$(echo "${var}" | cut -d= -s -f2-)
    var_name=${var_name#_} # remove leading underscore
    # paranoid, as we will pass to eval (see yaramfs_is_eval_safe)
    if ! yaramfs_is_eval_safe "${var_name}"; then
      die ${LINENO} "invalid variable name: ${var_name}"
    fi
    if ! yaramfs_is_eval_safe "${var_val}"; then
      die ${LINENO} "invalid variable value: ${var_name}"
    fi
    eval "${var_name}=\"${var_val}\""
    unset "_${var_name}" # cleanup preserved variable
  done
}

yaramfs_save_boot_env() {
  cfg_file="${YARAMFS_CFG_CONFIG_DIR}/env/boot_config.sh"
  echo "#!/bin/sh" > "${cfg_file}"
  for var in $(set); do
    case "${var}" in
      YARAMFS_CFG_BOOT_*)
        printf "saving %s\n" "${var}" >&2
        var_name=$(echo "${var}" | cut -d= -s -f1)
      ;;
      *) continue ;;
    esac
    var_val=$(echo "${var}" | cut -d= -s -f2-)
    echo "${var_name}=\"${var_val}\"" >> "${cfg_file}"
  done
}
