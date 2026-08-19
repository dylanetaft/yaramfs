#!/bin/sh
. hooks/shared/head.sh

prepare() {
  default_value YARAMFS_CFG_OUT_CPIO "out/initramfs.cpio.gz" ${LINENO}

  BUILD_DIR=${YARAMFS_CFG_PREP_BUILD_DIR}
  OUT=${YARAMFS_CFG_OUT_CPIO}

  if [ ! -x "${BUILD_DIR}/init" ]; then
    die ${LINENO} "missing executable ${BUILD_DIR}/init (base prepare must run first)"
  fi

  mkdir -p "$(dirname "${OUT}")"
  (
    cd "${BUILD_DIR}" || exit 1
    find . -print0 | cpio --null -o -H newc | gzip -9
  ) > "${OUT}"

  echo "wrote ${OUT}" >&2
}

boot() { :; }

prepare_or_boot "$@"
