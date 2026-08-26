#!/bin/sh
. hooks/shared/head.sh

prepare() {
  yaramfs_preserve_env
  yaramfs_load_env "prepare"
  yaramfs_restore_env
  default_value YARAMFS_CFG_PREPARE_BUSYBOX_PATH "$(which busybox)" ${LINENO}
  default_value YARAMFS_CFG_PREPARE_PROOT "$(which proot)" ${LINENO}

  BUILD_DIR=${YARAMFS_CFG_PREPARE_BUILD_DIR}

  rm -rf "${BUILD_DIR}"
  mkdir "${BUILD_DIR}"
  mkdir "${BUILD_DIR}/sys"
  mkdir "${BUILD_DIR}/proc"
  mkdir "${BUILD_DIR}/dev"
  mkdir "${BUILD_DIR}/run"
  mkdir "${BUILD_DIR}/tmp"
  # Merged-/usr layout (same idea as the host): real dirs under usr/{bin,sbin,lib*};
  # /bin /sbin /lib /lib64 are symlinks so both PATH (/bin:/sbin) and hardcoded
  # paths (/usr/bin/ssh, /lib64/ld-linux-*.so) resolve to the same files.
  mkdir -p \
    "${BUILD_DIR}/usr/bin" \
    "${BUILD_DIR}/usr/sbin" \
    "${BUILD_DIR}/usr/lib" \
    "${BUILD_DIR}/usr/lib64"
  ln -s usr/bin "${BUILD_DIR}/bin"
  ln -s usr/sbin "${BUILD_DIR}/sbin"
  ln -s usr/lib "${BUILD_DIR}/lib"
  ln -s usr/lib64 "${BUILD_DIR}/lib64"
  mkdir -p "${BUILD_DIR}/mnt/root"
  mkdir "${BUILD_DIR}/etc"
  mkdir "${BUILD_DIR}/root"
  mkdir -p "${BUILD_DIR}/dev/pts"
  mkdir -p "${BUILD_DIR}/hooks"

  # Minimal root identity (uid/gid 0) for getpwuid/getgrgid — e.g. OpenSSH sftp/ssh.
  install_blob_tree base

  install -m 0755 -D "${YARAMFS_CFG_PREPARE_BUSYBOX_PATH}" "${BUILD_DIR}/bin/busybox"
  # Create applet symlinks (including bin/sh) inside the build root.
  LD_PRELOAD= "${YARAMFS_CFG_PREPARE_PROOT}" -r "${BUILD_DIR}" -w / /bin/busybox --install -s /bin \
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

  # Publish all YARAMFS_CFG_* (config + defaults) for later prepare hooks / cpio.
  export_cfg
}

boot() {
  mount -t proc proc /proc
  mount -t sysfs sysfs /sys
  mount -t devtmpfs devtmpfs /dev
  mkdir -p /dev/pts
  mount -t devpts devpts /dev/pts 2>/dev/null || true
  # Separate tmpfs so /init can mount --move /run onto newroot before switch_root.
  # Plain dir on rootfs is not a mountpoint → move skipped → multipath udev db
  # seeds and other /run state die with the initramfs. mode=0755 matches systemd.
  mkdir -p /run
  if ! mountpoint -q /run 2>/dev/null; then
    mount -t tmpfs -o mode=0755,nodev,nosuid,strictatime tmpfs /run \
      || die ${LINENO} "mount tmpfs on /run failed"
  fi
  mkdir -p /tmp
  mount -t tmpfs tmpfs /tmp 2>/dev/null || true

  # After /tmp is final: load baked boot env (prepare-cpio → hooks/env/boot_config.sh)
  # and publish for later boot hooks. No preserve/restore — boot has no CLI env override path.
  yaramfs_load_env "boot"
  export_cfg
}

prepare_or_boot "$@"
