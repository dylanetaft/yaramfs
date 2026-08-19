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
