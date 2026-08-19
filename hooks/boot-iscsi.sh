#!/bin/sh
. hooks/shared/head.sh

# iSCSI session from iBFT. Config order must be after modules (and boot-network-ibft).

prepare() { :; }

boot() {
  iscsistart -b || die ${LINENO} "iscsistart -b (iBFT connect) failed"
}

prepare_or_boot "$@"
