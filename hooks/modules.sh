#!/bin/sh
. hooks/shared/head.sh
. hooks/shared/install.sh

prepare() {
  modules_prepare_defaults
  BUILD_DIR=${YARAMFS_CFG_PREP_BUILD_DIR}

  roots=$(mktemp)

  # Roots: explicit list if set (empty = none); else currently loaded.
  if eval "[ -n \"\${YARAMFS_CFG_MODULES+x}\" ]"; then
    for m in ${YARAMFS_CFG_MODULES}; do
      printf '%s\n' "${m}"
    done > "${roots}"
  else
    lsmod | awk 'NR > 1 { print $1 }' > "${roots}"
  fi

  # shellcheck disable=SC2046
  set -- $(cat "${roots}")
  rm -f "${roots}"

  ensure_modules "$@"
}

boot() {
  [ -f /etc/yaramfs-modules ] || return 0
  while read -r m || [ -n "${m}" ]; do
    [ -n "${m}" ] || continue
    modprobe "${m}" || die ${LINENO} "modprobe ${m} failed"
  done < /etc/yaramfs-modules
}

prepare_or_boot "$@"
