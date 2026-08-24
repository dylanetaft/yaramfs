# Agent notes (yaramfs)

## Hook ordering — do not hard-code in docs

**Do not document fixed hook slot numbers or a canonical run order in `README.md` or `config/env/prepare_config.example.sh`.**

Those files describe hooks and `YARAMFS_CFG_*` only. Lexicographic order of numbered symlinks in `config/` is run order, but which `NN` values are used is subject to change. Ordering for real layouts will be documented later via **example config directory copies** for different use cases — not by baking slot lists into the README or the prepare config template.

### OK

- Relative constraints required for correctness (e.g. “before modules”, “after network is up”, “after iscsi, before boot-root”).
- The symlink naming pattern `config/NN-name.sh` → `hooks/…`, including `NN-prepare-*` for prepare-only hooks, **without** promising specific `NN` values in README or `prepare_config.example.sh`.
- `YARAMFS_CFG_*` name source of truth in code: `grep -R YARAMFS_CFG hooks/`.

### Not OK

- Stock slot tables or claims like “default order is 00, 05, … every 5”.
- Concrete paths such as `config/20-prepare-multipath.sh`, `config/65-boot-force-debug.sh`, or parenthetical slots like `(40)` / `(50)` in those two files.
- Implying the Hooks section of the README is a fixed execution sequence.
