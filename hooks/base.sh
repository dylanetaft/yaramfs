#!/bin/sh
. hooks/shared/head.sh

prepare() {
  default_value YARAMFS_CFG_P_BUSYBOX_PATH "$(which busybox)" ${LINENO}
  default_value YARAMFS_CFG_P_PROOT "$(which proot)" ${LINENO}

  BUILD_DIR=${YARAMFS_CFG_PREP_BUILD_DIR}

  rm -rf "${BUILD_DIR}"
  mkdir "${BUILD_DIR}"
  mkdir "${BUILD_DIR}/sys"
  mkdir "${BUILD_DIR}/proc"
  mkdir "${BUILD_DIR}/dev"
  mkdir "${BUILD_DIR}/run"
  mkdir "${BUILD_DIR}/tmp"
  mkdir "${BUILD_DIR}/bin"
  mkdir "${BUILD_DIR}/sbin"
  # Merged-/usr layout (same idea as the host): libs land under usr/lib*,
  # ELF interpreter paths like /lib64/ld-linux-*.so stay valid via symlinks.
  mkdir -p "${BUILD_DIR}/usr/lib" "${BUILD_DIR}/usr/lib64"
  ln -s usr/lib "${BUILD_DIR}/lib"
  ln -s usr/lib64 "${BUILD_DIR}/lib64"
  mkdir -p "${BUILD_DIR}/mnt/root"
  mkdir "${BUILD_DIR}/etc"
  mkdir "${BUILD_DIR}/root"
  mkdir -p "${BUILD_DIR}/dev/pts"
  mkdir -p "${BUILD_DIR}/hooks"

  install -m 0755 -D "${YARAMFS_CFG_P_BUSYBOX_PATH}" "${BUILD_DIR}/bin/busybox"
  # Create applet symlinks (including bin/sh) inside the build root.
  LD_PRELOAD= "${YARAMFS_CFG_P_PROOT}" -r "${BUILD_DIR}" -w / /bin/busybox --install -s /bin \
    || die ${LINENO} "proot busybox --install failed"
  [ -x "${BUILD_DIR}/bin/sh" ] \
    || die ${LINENO} "bin/sh missing after busybox --install (init shebang needs it)"

  install -m 0755 hooks/shared/init "${BUILD_DIR}/init"

  # Shared runner used by guest /init (for_each_hook, etc.).
  mkdir -p "${BUILD_DIR}/hooks/shared"
  install -m 0644 hooks/shared/head.sh "${BUILD_DIR}/hooks/shared/head.sh"

  # Copy resolved hook files so guest for_each_hook can run them as processes.
  for name in $(list_hooks); do
    path="${YARAMFS_CFG_CONFIG_DIR}/${name}"
    prepare_only=$(echo "${name}" | grep -e '^[0-9]*-prepare');
    [ ! -n "${prepare_only}" ] || continue
    [ -f "${path}" ] || continue
    cp -L "${path}" "${BUILD_DIR}/hooks/${name}"
    chmod 0755 "${BUILD_DIR}/hooks/${name}"
  done
}

boot() {
  mount -t proc proc /proc
  mount -t sysfs sysfs /sys
  mount -t devtmpfs devtmpfs /dev
  mkdir -p /dev/pts
  mount -t devpts devpts /dev/pts 2>/dev/null || true
  mkdir -p /tmp
  mount -t tmpfs tmpfs /tmp 2>/dev/null || true
}

prepare_or_boot "$@"
