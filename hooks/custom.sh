#!/bin/sh
. hooks/shared/head.sh

# Optional payload from config/env/custom → image hooks/env/custom.
# Boot runs custom.sh when present (hard fail on non-zero).

prepare() {
  default_if_unset YARAMFS_CFG_PREPARE_CUSTOM_DIR \
    "${YARAMFS_CFG_CONFIG_DIR}/env/custom" ${LINENO}

  _src=${YARAMFS_CFG_PREPARE_CUSTOM_DIR}
  [ -d "${_src}" ] || return 0

  BUILD_DIR=${YARAMFS_CFG_PREPARE_BUILD_DIR}
  _dest="${BUILD_DIR}/hooks/env/custom"
  mkdir -p "${_dest}" || die ${LINENO} "mkdir ${_dest} failed"
  cp -a "${_src}/." "${_dest}/" || die ${LINENO} "copy ${_src} -> ${_dest} failed"

  if [ -f "${_dest}/custom.sh" ]; then
    chmod 0755 "${_dest}/custom.sh" || die ${LINENO} "chmod custom.sh failed"
  fi
}

boot() {
  _script="${YARAMFS_CFG_CONFIG_DIR}/env/custom/custom.sh"
  [ -f "${_script}" ] || return 0
  if [ ! -x "${_script}" ]; then
    die ${LINENO} "custom.sh not executable: ${_script}"
  fi
  sh "${_script}" || die ${LINENO} "custom.sh failed"
}

prepare_or_boot "$@"
