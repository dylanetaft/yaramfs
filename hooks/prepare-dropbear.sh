#!/bin/sh
. hooks/shared/head.sh

# Dropbear tools into the image (no boot daemon; no host keys).

prepare() {
  default_value YARAMFS_CFG_PREPARE_DROPBEAR "$(which dropbear)" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_DBCLIENT "$(which dbclient)" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_DROPBEARKEY "$(which dropbearkey)" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_DROPBEARCONVERT "$(which dropbearconvert)" ${LINENO}

  for _pair in \
    "${YARAMFS_CFG_PREPARE_DROPBEAR}:/bin/dropbear" \
    "${YARAMFS_CFG_PREPARE_DBCLIENT}:/bin/dbclient" \
    "${YARAMFS_CFG_PREPARE_DROPBEARKEY}:/bin/dropbearkey" \
    "${YARAMFS_CFG_PREPARE_DROPBEARCONVERT}:/bin/dropbearconvert"
  do
    _src=${_pair%%:*}
    _dest=${_pair#*:}
    if [ ! -x "${_src}" ]; then
      die ${LINENO} "dropbear tool not executable: ${_src}"
    fi
    install_binary "${_src}" "${_dest}"
  done
}

boot() { :; }

prepare_or_boot "$@"
