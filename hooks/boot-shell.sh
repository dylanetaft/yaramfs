#!/bin/sh
. hooks/shared/head.sh

prepare() { :; }

boot() {
  echo "yaramfs: dropping to shell"
  exec setsid cttyhack sh
}

prepare_or_boot "$@"
