#!/bin/sh
. hooks/shared/head.sh

# OpenSSH client tools into the image (sftp + ssh transport; no server; no keys).
# sftp execs /usr/bin/ssh by default — keep those image paths.

prepare() {
  default_value YARAMFS_CFG_PREPARE_SSH "$(which ssh)" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_SFTP "$(which sftp)" ${LINENO}

  for _pair in \
    "${YARAMFS_CFG_PREPARE_SSH}:/usr/bin/ssh" \
    "${YARAMFS_CFG_PREPARE_SFTP}:/usr/bin/sftp"
  do
    _src=${_pair%%:*}
    _dest=${_pair#*:}
    if [ ! -x "${_src}" ]; then
      die ${LINENO} "openssh client tool not executable: ${_src}"
    fi
    install_binary "${_src}" "${_dest}"
  done
}

boot() { :; }

prepare_or_boot "$@"
