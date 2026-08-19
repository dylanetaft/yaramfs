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

  any=
  for name in $(list_hooks); do
    path="${YARAMFS_CFG_CONFIG_DIR}/${name}"
    # Files only (skip dirs like hooks/shared on the guest).
    [ -f "${path}" ] || continue
    any=1
    echo "=> ${name} ${phase}" >&2
    set -- "${phase}"
    . "${path}" || die ${LINENO} "hook ${name} ${phase} failed"
  done

  if [ -z "${any}" ]; then
    die ${LINENO} "no hooks found in ${YARAMFS_CFG_CONFIG_DIR}"
  fi
}
