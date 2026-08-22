# yaramfs - Yet Another initramfs

## What is it
An initramfs generator and boot script that is based on ordered execution of simple shell scripts and busybox.

## Why
While testing iscsi support in dracut, I noticed support was limited to the network-legacy module for nic configuration.   Additionally I wanted to add dropbear SSH support.  Dracut is a great general purpose initramfs generator.  For bespoke purposes, it can be a bit complex with modules, dependencies, etc.
Say for example, you want to boot off iscsi, then actually call out to a SAN, and refresh a snapshot before mounting rootfs.  It's easier to do that with ordered scripts.

## How it works
- `config/` holds numbered symlinks into `hooks/`. Lexicographic order is run order.
- `./prepare.sh` runs each hook's **prepare** phase (build the image tree, then cpio).
- Guest `/init` runs each hook's **boot** phase, then `switch_root` if root was mounted.
- Names matching `NN-prepare-*` are prepare-only (copied into the image is skipped for boot).
- Hooks may `export_cfg VAR` so the parent runner picks up variables for later hooks (e.g. `YARAMFS_CFG_PREPARE_MODULES_ADDL`).
- Shared helpers live in `hooks/shared/head.sh`. Defaults: `YARAMFS_CFG_PREPARE_BUILD_DIR=build`, `YARAMFS_CFG_CONFIG_DIR=config`.

## Build
```sh
./prepare.sh
```
Optional env overrides (examples):
```sh
YARAMFS_CFG_PREPARE_MODULES="foo bar" ./prepare.sh
YARAMFS_CFG_PREPARE_KERNEL=/path/to/Image YARAMFS_CFG_PREPARE_QEMU_APPEND="console=ttyAMA0 rdinit=/init root=UUID=..." ./prepare.sh
```
Mininally required host tools: busybox, proot, lddtree, cpio, gzip/pigz 

## Hooks
Order below matches a typical `config/` layout (00 → 99).

### base
##### Parameters
 - YARAMFS_CFG_PREPARE_BUSYBOX_PATH
   - For prepare, specifies path to busybox
 - YARAMFS_CFG_PREPARE_PROOT
   - Specifies path to proot binary
##### Phases
  - Prepare
     - Creates initramfs directories in build, installs busybox in image path
     - Installs guest `/init` and copies non-prepare-only hooks into the image
  - Boot
    - Mounts needed directories - devtmpfs, proc, tmpfs, etc

### prepare-network
##### Parameters
 - YARAMFS_CFG_PREPARE_NETWORK_MODULES
   - Override which modules in prepare phase are inserted into image.  Disables autodetection.  If you want to append modules, use YARAMFS_CFG_PREPARE_MODULES_ADDL.
   - Unset = from lsmod, keep names whose modinfo path contains `/net/`.  Set empty = no NIC modules from this hook (8021q is still added).
##### Phases
  - Prepare
     - Collects network modules (or uses override), always adds 8021q, appends to YARAMFS_CFG_PREPARE_MODULES_ADDL
  - Boot
     - No-op (drivers are loaded by modules hook)

### prepare-input
##### Parameters
 - YARAMFS_CFG_PREPARE_INPUT_MODULES
   - Override input/hid modules for the image.  Disables autodetection.  Empty = none.
   - Unset = from lsmod, keep names whose modinfo path contains `/input/` or `/hid/`.
##### Phases
  - Prepare
     - Collects input modules, appends to YARAMFS_CFG_PREPARE_MODULES_ADDL
  - Boot
     - No-op

### prepare-iscsi
##### Requires
Host open-iscsi package installed (iscsistart, iscsiadm)
##### Parameters
 - YARAMFS_CFG_PREPARE_ISCSITART
   - Path to host iscsistart (default: `which iscsistart`)
##### Phases
  - Prepare
     - Appends iscsi kernel modules to YARAMFS_CFG_PREPARE_MODULES_ADDL
     - install_binary iscsistart (+ shared libs) into the image
     - Copies `/etc/iscsi/iscsid.conf` when readable
  - Boot
     - No-op (session is boot-iscsi)

### modules
##### Parameters
 - YARAMFS_CFG_PREPARE_MODULES
   - Explicit module names (space-separated) always considered for the image
 - YARAMFS_CFG_PREPARE_MODULES_ADDL
   - Extra names accumulated by earlier prepare hooks (export_cfg).  You can also set this yourself to append.
 - YARAMFS_CFG_PREPARE_KERNEL_VERSION
   - Kernel version for module tree (default: `uname -r`)
 - YARAMFS_CFG_PREPARE_MODULES_DIR
   - Host modules directory (default: `/lib/modules/$YARAMFS_CFG_PREPARE_KERNEL_VERSION`)
 - YARAMFS_CFG_PREPARE_BUSYBOX_PATH
   - busybox used for `modprobe -D` / `depmod` during prepare
##### Phases
  - Prepare
     - Resolves deps with busybox modprobe -D, copies .ko into build, runs depmod
     - Writes boot list to `etc/yaramfs-modules` in the image
  - Boot
     - modprobe each name in `/etc/yaramfs-modules` (warn and continue on failure)

### boot-network-ibft
##### Parameters
 - YARAMFS_CFG_BOOT_IBFT_DIR
   - iBFT sysfs root (default: `/sys/firmware/ibft`)
 - YARAMFS_CFG_BOOT_IBFT_\<N\>_MAC / _IP / _PREFIX / _NETMASK / _VLAN
   - Optional per-ethernet overrides (N = index from `ethernetN`).  Unset fields fall back to firmware sysfs values.
##### Phases
  - Prepare
     - No-op
  - Boot
     - For each iBFT ethernet*: match MAC, rename iface to ibftN, optional VLAN, assign address from iBFT
     - Requires iscsi_ibft (and NIC drivers) already loaded (modules hook)

### boot-iscsi
##### Parameters
 - YARAMFS_CFG_BOOT_ISCSI_TIMEOUT
   - Seconds before killing hung iscsistart -b (default: 60)
##### Phases
  - Prepare
     - No-op
  - Boot
     - `timeout … iscsistart -b` (login from iBFT).  Must run after network is up.

### root
##### Parameters
 - (mostly from kernel cmdline, not env)
   - root= — `/dev/…`, `UUID=…`, or `LABEL=…` (busybox findfs; no PARTUUID/PARTLABEL)
   - rootfstype=, rootflags= (default flags: ro), rootdelay= (seconds to wait, default 30), init=
 - YARAMFS_CFG_BOOT_NEWROOT_MNT
   - Mount point inside initramfs (default: `/mnt/root`)
 - YARAMFS_CFG_BOOT_ROOT / YARAMFS_CFG_BOOT_ROOTFSTYPE / YARAMFS_CFG_BOOT_ROOTFLAGS / YARAMFS_CFG_BOOT_ROOTDELAY / YARAMFS_CFG_BOOT_INIT
   - Filled from cmdline during boot; INIT defaults to `/sbin/init` if unset
##### Phases
  - Prepare
     - No-op (uses busybox findfs already in the image)
  - Boot
     - Parse cmdline, wait up to rootdelay for the device, mount on NEWROOT_MNT
     - export_cfg YARAMFS_CFG_BOOT_NEWROOT and YARAMFS_CFG_BOOT_INIT for PID 1
 - After hooks: `/init` moves proc/sys/dev/run and `exec switch_root`.  If nothing mounted root, drops to a rescue shell.

### prepare-cpio
##### Parameters
 - YARAMFS_CFG_PREPARE_OUT_CPIO
   - Output path (default: `out/initramfs.cpio.gz`)
 - YARAMFS_CFG_PREPARE_GZIP
   - Compressor (default: pigz if present, else gzip)
##### Phases
  - Prepare
     - Packs `build/` with cpio newc and compresses to OUT_CPIO
  - Boot
     - No-op (prepare-only in config naming)

### prepare-qemu
##### Parameters
 - YARAMFS_CFG_PREPARE_KERNEL
   - Kernel image path.  Unset = skip qemu (image-only prepare).
 - YARAMFS_CFG_PREPARE_OUT_CPIO
   - Initrd path (default: `out/initramfs.cpio.gz`; must exist from prepare-cpio)
 - YARAMFS_CFG_PREPARE_QEMU_MACHINE
   - Default: virt
 - YARAMFS_CFG_PREPARE_QEMU_CPU
   - Default: max
 - YARAMFS_CFG_PREPARE_QEMU_MEM
   - Default: 1024
 - YARAMFS_CFG_PREPARE_QEMU_APPEND
   - Kernel cmdline (default: `console=ttyAMA0 rdinit=/init panic=1`).  Add root=UUID=… etc. here for real root tests.
##### Phases
  - Prepare
     - If KERNEL set, exec qemu-system-aarch64 -nographic with kernel + initrd
  - Boot
     - No-op (prepare-only)

## Adding a hook
1. Write `hooks/myhook.sh` with `prepare()` / `boot()` and end with `prepare_or_boot "$@"`.
2. Symlink from `config/NN-name.sh` (use `NN-prepare-…` if it should not run at boot in the guest).
3. Source `hooks/shared/head.sh`; use `die`, `default_value`, `export_cfg`, `install_binary` as needed.

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
`YARAMFS_CFG_PREPARE_KERNEL` is unset so the qemu hook is skipped. Staging is `${KERNEL_INSTALL_STAGING_AREA}` (systemd) or `${INSTALLKERNEL_STAGING_AREA}` (Gentoo).
