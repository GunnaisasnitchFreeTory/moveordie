# Quarantine Archive

This folder is a **reversible quarantine** for files that are not part of the active Rojo game source pipeline.

## Why these were moved

- Active runtime source is mapped from `src/` via `default.project.json`.
- Root-level legacy variants (`temp_*`, `_temp_*`, `fixed_*`, one-off spinwheel variants, and old patch/upload helpers) are not used by the mapped runtime tree.
- Files were moved here instead of deleted to keep rollback simple.

## Moved sets

- `root_legacy/temp_*`
- `root_legacy/_temp_*`
- `root_legacy/fixed_*`
- `root_legacy/spinwheel_final.lua`
- `root_legacy/spinwheel_modified.lua`
- `root_legacy/fix_*.py`
- `root_legacy/upload_*.py`

## Verification run

- `rojo --version` -> available
- `rojo build -o _quarantine_unused/verify_after_cleanup.rbxlx` -> success

## Left untouched (needs intentional decision)

- `agent-tools/`, `tools/`, `docs/`
- Root helper extraction files: `_extract_source.ps1`, `_find_lines.ps1`, `_get_range.ps1`, `_read_sources.ps1`, `_spin_client.luau`
- Root `_t_*.luau` snapshots (likely legacy, but intentionally left for a later explicit pass)
