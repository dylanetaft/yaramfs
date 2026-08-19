#!/bin/sh

source modules/shared/head.sh

if [ "${1}" = "prepare" ]; then
  default_value YARAMFS_CFG_P_BUSYBOX_PATH "$(which busybox)" ${LINENO}
fi

prepare() {
  BUILD_DIR=${YARAMFS_CFG_PREP_BUILD_DIR}
  rm -rf ${BUILD_DIR}
  mkdir ${BUILD_DIR}
  mkdir ${BUILD_DIR}/sys
  mkdir ${BUILD_DIR}/proc
  mkdir ${BUILD_DIR}/dev
  mkdir ${BUILD_DIR}/run
  mkdir ${BUILD_DIR}/bin
  mkdir ${BUILD_DIR}/sbin
  mkdir ${BUILD_DIR}/lib
  mkdir ${BUILD_DIR}/lib64
  mkdir -p ${BUILD_DIR}/mnt/root
  mkdir ${BUILD_DIR}/etc
  mkdir ${BUILD_DIR}/root
  install -m 0755 -D ${YARAMFS_CFG_P_BUSYBOX_PATH} ${BUILD_DIR}/bin/busybox
  # Run busybox --install to create symlinks for all busybox applets
  LD_PRELOAD= proot -r ./build -w / /bin/busybox --install -s /bin
}

boot() {
  mount -t proc proc /proc
  mount -t sysfs sysfs /sys
  mount -t devtmpfs devtmpfs /dev
  mount -t devpts devpts /dev/pts
}

if [ "${1}" = "prepare" ]; then
  prepare
elif [ "${1}" = "boot" ]; then
  boot
fi
