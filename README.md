# yaramfs - Yet Another initramfs

## What is it
An initramfs generator and boot script that is based on ordered execution of simple shell scripts and busybox.

## Why
While testing iscsi support in dracut, I noticed support was limited to the network-legacy module for nic configuration.   Additionally I wanted to add dropbear SSH support.  Dracut is a great general purpose initramfs generator.  For bespoke purposes, it can be a bit complex with modules, dependencies, etc.
Say for example, you want to boot off iscsi, then actually call out to a SAN, and refresh a snapshot before mounting rootfs.  It's easier to do that with ordered scripts.

## How it works
- `config/` holds numbered symlinks into `hooks/`. Lexicographic order is run order. Concrete layouts for different use cases will be documented later as example config directory copies (slot numbers are not fixed).
- `./prepare.sh` runs each hook's **prepare** phase (build the image tree, then cpio).
- Guest `/init` runs each hook's **boot** phase, then `switch_root` if root was mounted and hooks succeeded. Before `switch_root`, `/init` runs busybox `killall5` (TERM, then KILL) so initramfs daemons outside PID 1's session (e.g. udevd) do not survive into the real root; kernel threads and the init session are skipped. `/run` is still moved so the udev db can persist. On hook failure (or missing root), it opens a **child** recovery shell (PID 1 stays `/init`); exiting the shell retries `switch_root`.
- Names matching `NN-prepare-*` are prepare-only (copied into the image is skipped for boot).
- Hooks may `export_cfg VAR` so the parent runner picks up variables for later hooks (e.g. `YARAMFS_CFG_PREPARE_MODULES_ADDL`).
- Shared helpers live in `hooks/shared/head.sh`. Defaults: `YARAMFS_CFG_PREPARE_BUILD_DIR=build`, `YARAMFS_CFG_CONFIG_DIR=config`.

## Configuration
All `YARAMFS_CFG_*` parameters (prepare and boot) are documented in:

**[`config/env/prepare_config.example.sh`](config/env/prepare_config.example.sh)**

Copy and edit:

```sh
cp config/env/prepare_config.example.sh config/env/prepare_config.sh
```

`prepare_config.sh` is loaded at prepare (base). `YARAMFS_CFG_BOOT_*` set there are written into `boot_config.sh` by prepare-cpio and baked into the image. CLI env already set wins over the file. Name source of truth in code: `grep -R YARAMFS_CFG hooks/`.

## Build
```sh
./prepare.sh
```
Optional env overrides (examples):
```sh
YARAMFS_CFG_PREPARE_MODULES="foo bar" ./prepare.sh
YARAMFS_CFG_PREPARE_KERNEL=/path/to/Image YARAMFS_CFG_PREPARE_QEMU_APPEND="console=ttyAMA0 rdinit=/init root=UUID=..." ./prepare.sh
```
Minimally required host tools: busybox, proot, lddtree, cpio, gzip/pigz, kmod (modprobe)

## Hooks
Catalog by hook name (not a fixed run sequence). Relative constraints are noted where needed. Parameters: see [`config/env/prepare_config.example.sh`](config/env/prepare_config.example.sh).

### base
##### Phases
  - Prepare
     - Creates initramfs directories in build, installs busybox in image path
     - Installs guest `/init` and copies non-prepare-only hooks into the image
  - Boot
    - Mounts needed directories — proc, sysfs, devtmpfs, `/run` tmpfs (moved to newroot on switch_root), `/tmp` tmpfs
    - Loads baked `hooks/env/boot_config.sh` (`YARAMFS_CFG_BOOT_*` from prepare-cpio) and `export_cfg` so later boot hooks inherit them (no preserve/restore; file is the source of truth)

### prepare-network
##### Phases
  - Prepare
     - Collects network modules from lsmod, always adds 8021q, appends to YARAMFS_CFG_PREPARE_MODULES_ADDL
  - Boot
     - No-op (drivers are loaded by modules hook)

### prepare-input
##### Phases
  - Prepare
     - Collects input modules, appends to YARAMFS_CFG_PREPARE_MODULES_ADDL
  - Boot
     - No-op

### prepare-iscsi
##### Requires
Host open-iscsi package installed (iscsistart, iscsiadm)
##### Phases
  - Prepare
     - Appends iscsi kernel modules to YARAMFS_CFG_PREPARE_MODULES_ADDL
     - install_binary iscsistart (+ shared libs) into the image
     - Copies `/etc/iscsi/iscsid.conf` when readable
  - Boot
     - No-op (session is boot-iscsi)

### prepare-dropbear
##### Requires
Host dropbear package installed (`dropbear`, `dbclient`, `dropbearkey`, `dropbearconvert`)
##### Phases
  - Prepare
     - `install_binary` each tool (+ shared libs) into `/bin` in the image
     - Does not copy host keys or start a server (binaries only)
  - Boot
     - No-op (prepare-only in config naming)

### modules
##### Requires (prepare)
Host **kmod** `modprobe` (`sys-apps/kmod`). Busybox modprobe is not used for resolution (no usable `-d` / other-kver support). Busybox is still used for `depmod -b` in the build tree.
##### Phases
  - Prepare
     - Resolves each name against `YARAMFS_CFG_PREPARE_MODULES_DIR` (target kver), not necessarily the running kernel:
       1. kmod `modprobe -d ROOT -S KVER -D -q` (ROOT = parent of `lib/modules/KVER`)
       2. safety: `find` `NAME.ko*` under `MODULES_DIR` (leaf only — list soft deps in `YARAMFS_CFG_PREPARE_MODULES*` if needed)
     - Copies .ko into build, runs busybox `depmod -b`; writes boot list to `etc/yaramfs-modules`
  - Boot
     - modprobe each name in `/etc/yaramfs-modules` (warn and continue on failure)

### boot-provisioned-config
Optional override of the baked boot env from a file on a local filesystem (e.g. USB). Needs drivers already loaded (modules); place before network/iscsi if those hooks should see the provisioned env.
##### Phases
  - Prepare
     - No-op
  - Boot
     - If UUID set: wait for busybox `blkid` UUID match, mount ro, copy PATH over `hooks/env/boot_config.sh`, umount
     - Unset all `YARAMFS_CFG_BOOT_*`, `yaramfs_load_env boot`, `export_cfg` (provisioned file is authoritative)
     - Needs block/fs drivers already loaded (modules hook); add fs modules via prepare if needed
     - Fails hard when configured but device/file missing

### boot-netroot-network
Bring up NIC(s) for netroot using **MAC id** as the config key (lowercase hex, no colons: `aa:bb:cc:dd:ee:ff` → `aabbccddeeff`). iBFT and static CFG share the same apply path (match iface by MAC → up → optional VLAN → address).
##### Phases
  - Prepare
     - No-op
  - Boot
     - Collect macids from iBFT (if present) and from any already-set `YARAMFS_CFG_BOOT_NETROOT_<macid>_*`
     - For each macid: optional iBFT fill (firmware strings pass `yaramfs_is_eval_safe`) → find netdev by MAC → configure
     - Requires NIC drivers (and `iscsi_ibft` if using iBFT) already loaded (modules hook)

### boot-iscsi
##### Phases
  - Prepare
     - No-op
  - Boot
     - If all four manual fields set: `timeout … iscsistart -i … -t … -g … -a …` [`-p …`]
     - Else if none set: `timeout … iscsistart -b` (iBFT)
     - Must run after network is up

### custom
Optional escape hatch: copy a host payload directory into the image and optionally run a boot script. Place the config symlink wherever the payload should run relative to other boot hooks.
##### Phases
  - Prepare
     - Copies `CUSTOM_DIR/.` → `build/hooks/env/custom/`
     - If `custom.sh` is present in the payload, chmod 0755 on the image copy
  - Boot
     - If `/hooks/env/custom/custom.sh` exists: run it (`sh`); non-zero or non-executable fails boot
     - Missing script = no-op
     - Script inherits `YARAMFS_CFG_*` and may `export_cfg` for later hooks

### boot-root
##### Phases
  - Prepare
     - No-op (uses busybox `blkid` already in the image)
  - Boot
     - Parse cmdline (`root=`, `rootfstype=`, `rootflags=`, `rootdelay=`, `init=`)
     - Wait up to rootdelay for the device, mount on NEWROOT_MNT
     - `root=/dev/…` — use that block node as-is
     - `root=UUID=…` / `LABEL=…` — busybox `blkid`; prefer `/dev/mapper/*` (multipath maps), else first other match
     - export_cfg YARAMFS_CFG_BOOT_NEWROOT and YARAMFS_CFG_BOOT_INIT for PID 1
  - After hooks: `/init` runs `killall5` (TERM then KILL), moves proc/sys/dev/run, and `exec switch_root` when newroot is ready.

### multipath (opt-in pair)
No **multipathd**, no **udevd**. Host needs multipath-tools (`multipath` + `kpartx`). Enable both (relative order matters: prepare before modules; boot after iscsi, before boot-root):

```sh
ln -sf ../hooks/prepare-multipath.sh config/NN-prepare-multipath.sh   # before modules
ln -sf ../hooks/boot-multipath.sh    config/NN-boot-multipath.sh      # after iscsi, before boot-root
```

##### prepare-multipath (prepare-only)
  - Prepare
     - Appends multipath modules to `YARAMFS_CFG_PREPARE_MODULES_ADDL`
     - Installs `multipath` and `kpartx` (libdevmapper via `install_binary`; no multipathd)
     - Packs host multipath plugins (`libchecktur.so`, prioritizers, …) from `…/multipath/` at the same path in the image (required for path checkers; not ELF deps of the binary). Override dir: `YARAMFS_CFG_PREPARE_MULTIPATH_LIBDIR`
     - Empty `/etc/multipath` and `/var/lib/multipath` (clean room)
     - Optional: `YARAMFS_CFG_PREPARE_MULTIPATH_CONF=/path/to/multipath.conf` bakes `/etc/multipath.conf` (off by default; CLI applies blacklist/`find_multipaths` without multipathd)
  - Boot
     - Not installed in the guest (`NN-prepare-*`)

##### boot-multipath
  - Prepare
     - No-op
  - Boot
     - Requires `YARAMFS_CFG_BOOT_MULTIPATH_WWID` (space/comma-separated). Unset/empty → die.
     - Reads sysfs WWID (`/sys/block/sdX/device/wwid` or `…/nvmeXnY/wwid`); matches path disks only
     - Retries until a match appears or `YARAMFS_CFG_BOOT_MULTIPATH_SETTLE` seconds (default 30; iSCSI/NVMe settle)
     - Seeds `/etc/multipath/bindings` header if missing (multipath-tools LP#2120444: first run fails on empty/missing file)
     - `DM_DISABLE_UDEV=1`, then `multipath -v2` on each matched path
     - `kpartx -a -p -part` on multipath maps (partition nodes `…-partN`; set `YARAMFS_CFG_BOOT_MULTIPATH_KPARTX=0` to skip)
     - Seeds `/run/udev/data/bM:m` with `DM_UDEV_PRIMARY_SOURCE_FLAG=1` (sticky); `/run` is a tmpfs moved onto newroot so the db survives switch_root for real-root coldplug `/dev/disk/by-uuid`
     - Failure → die / recovery shell
  - Get a WWID from a path device: `cat /sys/block/sdX/device/wwid`
  - Do **not** mount root from a path partition (`/dev/sdb2`); use the multipath mapper (`…-part2` or `root=UUID=…`)

### Recovery shell
If boot hooks fail or nothing mounted a usable root, `/init` **stays PID 1** and runs an interactive shell as a **child** (not `exec` over init).

1. Fix whatever failed (modules, network, iSCSI, mount, …).
2. Mount the real root on **`/mnt/root`** (default), or write the mount path to **`/tmp/yaramfs_newroot`**.
3. Ensure **`/mnt/root/sbin/init`** exists (or write the init path to **`/tmp/yaramfs_init`**).
4. **`exit`** the shell — `/init` retries move-mount of proc/sys/dev/run and `switch_root`.

If root is still not ready, the banner and shell open again (no kernel panic from exiting the recovery shell). Env vars set inside the child shell are **not** visible to PID 1; use the mountpoint or marker files above.

If boot hooks all succeed, `/init` `switch_root`s when NEWROOT looks ready. If any hook failed, it opens recovery first (even if boot-root already mounted root); exit the shell to retry `switch_root`.

### boot-force-debug
Opt-in forced boot failure so guest `/init` opens the resumable recovery shell. A failed hook forces recovery before `switch_root` even if boot-root already mounted root. Place earlier only if you want to stop before root is mounted.
##### Phases
  - Prepare
     - No-op
  - Boot
     - If `YARAMFS_CFG_BOOT_FORCE_DEBUG` is non-empty: `die` (hook fails → recovery shell)
     - Unset/empty: no-op (safe when the config symlink is left in place)
     - Must be present in the provisioned/baked `boot_config.sh` as a `YARAMFS_CFG_BOOT_*` var (not only prepare_config)

### prepare-cpio
##### Phases
  - Prepare
     - Packs `build/` with cpio newc and compresses to OUT_CPIO
  - Boot
     - No-op (prepare-only in config naming)

### prepare-qemu
##### Phases
  - Prepare
     - If KERNEL set, exec qemu-system-aarch64 -nographic with kernel + initrd (+ optional NIC)
  - Boot
     - No-op (prepare-only)

## Adding a hook
1. Write `hooks/myhook.sh` with `prepare()` / `boot()` and end with `prepare_or_boot "$@"`.
2. Symlink from `config/NN-name.sh` (use `NN-prepare-…` if it should not run at boot in the guest).
3. Source `hooks/shared/head.sh`; use `die`, `default_value`, `export_cfg`, `install_binary` as needed.
4. Document new `YARAMFS_CFG_*` in `config/env/prepare_config.example.sh`.

## installkernel / kernel-install
yaramfs can act as the **initrd generator** for Gentoo `installkernel` and systemd `kernel-install`. It only builds `initrd` into the installer's staging area; it does **not** call `ukify` or choose the final boot path. installkernel (or a separate `ukify` plugin when `uki_generator=ukify`) installs the staged file as e.g. `/boot/initramfs-$ver.img` or wraps it in a UKI.

### Install
```sh
# tree (default path used by the example conf)
cp -a . /opt/yaramfs

# systemd kernel-install (USE=systemd on installkernel)
install -m755 /opt/yaramfs/scripts/installkernel/52-yaramfs.install /etc/kernel/install.d/52-yaramfs.install

# Gentoo traditional installkernel (preinst hooks)
install -m755 /opt/yaramfs/scripts/installkernel/52-yaramfs.install /etc/kernel/preinst.d/52-yaramfs.install

# select generator + UKI (drop-in). See scripts/installkernel/install.conf
mkdir -p /etc/kernel/install.conf.d
install -m644 /opt/yaramfs/scripts/installkernel/install.conf /etc/kernel/install.conf.d/yaramfs.conf
```
Requires installkernel with UKI/ukify support (e.g. USE flags `uki` `ukify` on Gentoo) so the ukify plugin is present. Adjust `yaramfs_root=` in the conf if the tree is not at `/opt/yaramfs`. Override at runtime with `YARAMFS_ROOT` if needed.

Note: `yaramfs_root` is read by the yaramfs plugin from conf/drop-ins; installkernel does not pass custom keys to plugins.

### What the plugin does
On `add` / preinst it runs:
```sh
YARAMFS_CFG_PREPARE_KERNEL_VERSION=$ver YARAMFS_CFG_PREPARE_OUT_CPIO=$STAGING/initrd $yaramfs_root/prepare.sh
```
`YARAMFS_CFG_PREPARE_KERNEL` is unset so the qemu hook is skipped. Staging is `${KERNEL_INSTALL_STAGING_AREA}` (systemd) or `${INSTALLKERNEL_STAGING_AREA}` (Gentoo). Writing the initrd under `/var/tmp/kernel-install.staging.*` is normal; installkernel (or ukify) promotes it to the final boot path afterward.

### Recovery chroot (rebuild initrd / UKI from live media)
If the installed system will not boot, mount its root from a live/recovery environment and chroot before running `kernel-install` or `prepare.sh`. Bare `installkernel` / `uname -r` often pick the **live** kernel, not the one on disk.

```sh
# Adjust devices and mountpoints. Example: root on /mnt/gentoo, ESP or /boot as needed.
mount /dev/ROOT  /mnt/gentoo
mount /dev/ESP   /mnt/gentoo/boot    # or /mnt/gentoo/efi — match your layout

mount -t proc  proc  /mnt/gentoo/proc
mount -t sysfs sys   /mnt/gentoo/sys
mount --rbind  /dev  /mnt/gentoo/dev
mount --make-rslave  /mnt/gentoo/dev 2>/dev/null || true
# UEFI vars if anything touches Secure Boot / efibootmgr:
# mount --rbind /sys/firmware/efi/efivars /mnt/gentoo/sys/firmware/efi/efivars

chroot /mnt/gentoo /bin/bash
source /etc/profile
```

Inside the chroot, use the **installed** kernel version and image (e.g. `gentoo-kernel-bin`), not the recovery kernel:

```sh
ls /lib/modules/
# gentoo-kernel-bin example:
KVER=7.1.8-gentoo-dist-bin          # your version under /lib/modules
IMG=/usr/lib/modules/${KVER}/vmlinuz
test -d "/lib/modules/${KVER}" && test -f "${IMG}"

# Argument order matters: add VERSION IMAGE (not IMAGE alone).
kernel-install -v add "${KVER}" "${IMG}"
# Or: emerge --config sys-kernel/gentoo-kernel-bin
```

**proc and proot:** prepare uses host `proot` for `busybox --install` inside the build tree. If `/proc` is missing in the chroot, proot fails with errors like `can't retrieve loader path proc/self/fd`. Fix mounts (`mount -t proc proc /mnt/gentoo/proc`) before chrooting; `ls /proc/self/fd` must work inside the chroot.

**Memory / ukify:** yaramfs only builds the staged initrd. With `uki_generator=ukify`, `60-ukify.install` then assembles a UKI and can use a lot of RAM (kernel + full initrd + stub). In a small recovery environment this often dies as `60-ukify.install terminated by signal kill` (OOM), even when the same machine succeeds after a normal boot. Check `dmesg | grep -i oom`, add swap if needed, and retry; or skip UKI for recovery (`layout=bls` / `grub` without `uki_generator=ukify`) and install separate `vmlinuz` + initrd, or run `ukify build` manually once RAM/swap is adequate.

**Initrd only** (bypass installkernel), still with an explicit kver:

```sh
YARAMFS_CFG_PREPARE_KERNEL_VERSION=${KVER} \
YARAMFS_CFG_PREPARE_MODULES_DIR=/lib/modules/${KVER} \
YARAMFS_CFG_PREPARE_OUT_CPIO=/boot/initramfs-${KVER}.img \
/opt/yaramfs/prepare.sh
```
