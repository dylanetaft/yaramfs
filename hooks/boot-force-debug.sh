#!/bin/sh
. hooks/shared/head.sh

# Opt-in recovery shell: fails boot so guest /init opens a child recovery shell
# (PID 1 stays /init; exit the shell to retry switch_root).
# Enable by linking into config/ (e.g. 85-boot-force-debug.sh) and/or setting
# YARAMFS_CFG_BOOT_FORCE_DEBUG non-empty when the symlink is always present.
# Unset FORCE_DEBUG with symlink present → no-op (safe default in tree configs).

prepare() { :; }

boot() {
  [ -n "${YARAMFS_CFG_BOOT_FORCE_DEBUG}" ] || return 0
  die ${LINENO} "boot-force-debug: forced failure (recovery shell)"
}

prepare_or_boot "$@"
