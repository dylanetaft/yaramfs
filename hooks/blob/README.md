# Hook static blobs

Host/repo-only assets packed into the initramfs at **prepare** time.

## Layout

```text
hooks/blob/<prepare-hook-basename>/…
```

- Directory name matches the **prepare** hook that installs the files (e.g. `udev`, `prepare-multipath-udev`), not the boot hook and not `NN-…` config symlink names.
- Paths under that directory are **initramfs-root-relative** (`etc/multipath/bindings` → image `/etc/multipath/bindings`).
- Modes are preserved (`cp -a` per file); set `chmod` on the blob files in git as needed (e.g. bindings `0600`, `kpartx_id` `0755`).
- Nothing here is auto-copied by `base`. Each prepare hook calls `install_blob_tree <basename>` from `hooks/shared/head.sh`, which copies each file into `BUILD_DIR` (no file list in the hook). File-by-file so `build/lib` → `usr/lib` is not replaced by a real `lib/` directory.

## Guests

Blobs are not shipped under guest `/hooks/`. Boot hooks assume prepare already placed the files at their final image paths.

## Current trees

| Prepare hook | Blob dir | Notes |
|--------------|----------|--------|
| `prepare-multipath-udev` | `hooks/blob/prepare-multipath-udev/` | multipath-tools `BINDINGS_FILE_HEADER` → `/etc/multipath/bindings` (LP#2120444) |
| `udev` | `hooks/blob/udev/` | `11-dm-yaramfs.rules` (db_persist), multipath-tools kpartx rules + `kpartx_id` |

Host udev rules stay on the host-only `UDEV_RULES_COPYLIST` in `udev.sh` (DM/block/multipath when present). Repo rules are only under `hooks/blob/udev/`.
