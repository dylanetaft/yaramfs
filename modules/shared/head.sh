#!/bin/sh
die() { echo "$0:$1 $2" >&2; exit 1; }

: ${YARAMFS_CFG_PREP_BUILD_DIR:=build}


if [ "${1}" != "prepare" ] && [ "${1}" != "boot" ]; then
  die $LINENO" Hook must be called with prepare or boot"
fi

default_value() {
  var_name="$1"
  default_var_value="$2"
  caller_lineno="$3"


  eval "current_value=\${${var_name}}"

  if [ -z ${default_var_value} ]; then
    die ${caller_lineno} "default value for ${var_name} is empty"
  fi

  if [ -z ${current_value} ]; then
    eval "${var_name}=${default_var_value}"
  fi

}
