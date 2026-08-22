#!/bin/sh
. hooks/shared/head.sh

prepare() {
  default_value YARAMFS_CFG_PREPARE_OUT_CPIO "out/initramfs.cpio.gz" ${LINENO}
  # Prefer pigz (parallel) when on PATH; else gzip. Override with YARAMFS_CFG_PREPARE_GZIP.
  default_value YARAMFS_CFG_PREPARE_GZIP "$(command -v pigz || command -v gzip)" ${LINENO}

  BUILD_DIR=${YARAMFS_CFG_PREPARE_BUILD_DIR}
  OUT=${YARAMFS_CFG_PREPARE_OUT_CPIO}
  GZIP=${YARAMFS_CFG_PREPARE_GZIP}

  if [ ! -x "${BUILD_DIR}/init" ]; then
    die ${LINENO} "missing executable ${BUILD_DIR}/init (base prepare must run first)"
  fi
  if [ ! -x "${GZIP}" ]; then
    die ${LINENO} "compressor not executable: ${GZIP}"
  fi

  mkdir -p "$(dirname "${OUT}")"
  (
    cd "${BUILD_DIR}" || exit 1
    find . -print0 | cpio --null -o -H newc | "${GZIP}" -9
  ) > "${OUT}"

  echo "wrote ${OUT} (via ${GZIP})" >&2
}

boot() { :; }

prepare_or_boot "$@"
