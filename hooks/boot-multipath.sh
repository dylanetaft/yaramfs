#!/bin/sh
. hooks/shared/head.sh

# One-shot multipath map setup before boot-root resolves/mounts root.
# Requires prepare-multipath (binary + modules in the image). No multipathd.
# Config order: after modules and boot-iscsi (paths present), before boot-root.
# boot-root still prefers /dev/mapper/* when resolving UUID=/LABEL=.

prepare() { :; }

boot() {
  if ! command -v multipath >/dev/null 2>&1; then
    echo "yaramfs: multipath binary missing (enable prepare-multipath)" >&2
    die ${LINENO} "multipath not found"
  fi

  mkdir -p /etc/multipath /run/multipath /var/lib/multipath 2>/dev/null || true
  echo "yaramfs: multipath -v2" >&2
  multipath -v2 || die ${LINENO} "multipath failed"
}

prepare_or_boot "$@"
