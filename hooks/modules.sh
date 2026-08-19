#!/bin/sh
. hooks/shared/head.sh
. hooks/shared/install.sh

prepare() {
  default_value YARAMFS_CFG_KERNEL_VERSION "$(uname -r)" ${LINENO}
  default_value YARAMFS_CFG_MODULES_DIR "/lib/modules/${YARAMFS_CFG_KERNEL_VERSION}" ${LINENO}
  # unset → GPU defaults; "" → no blacklist; set → that list only.
  default_if_unset YARAMFS_CFG_MODULES_BLACKLIST \
    "nvidia nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nouveau amdgpu radeon i915 xe" \
    ${LINENO}
  default_value YARAMFS_CFG_P_BUSYBOX_PATH "$(which busybox)" ${LINENO}

  roots=$(mktemp)

  # Roots: explicit list if set (empty = none); else currently loaded.
  if eval "[ -n \"\${YARAMFS_CFG_MODULES+x}\" ]"; then
    for m in ${YARAMFS_CFG_MODULES}; do
      printf '%s\n' "${m}"
    done > "${roots}"
  else
    lsmod | awk 'NR > 1 { print $1 }' > "${roots}"
  fi

  # Extra roots from earlier hooks (e.g. iscsi); same shell — no export needed.
  for m in ${YARAMFS_CFG_MODULES_ADDL}; do
    printf '%s\n' "${m}"
  done >> "${roots}"

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
