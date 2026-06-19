# Make Dreamcast Writable (configy)

## Metadata

| Field | Value |
|-------|-------|
| Requested by | User (Dreamcast VMU persistence feature) |
| Date | 2026-06-19 |
| Priority | **P0** |
| Target repo | `~/git/configy` (`github.com/birbparty/configy`) |
| KOS path | `~/git/workspace/KallistiOS/` |
| Status | **IN PROGRESS** — Layer 0 analysis complete; Layer 1 implementation pending |
| Companion docs | [`seam-map.md`](./seam-map.md) — exact gaps · [`kos-api.md`](./kos-api.md) — VMU KOS API catalog |

---

## Bottom line (read first)

Dreamcast config persistence uses the **VMU (Visual Memory Unit)** — a 128KB EEPROM device with a
proprietary block filesystem. Unlike Vita (std/os works) or 3DS (std/os with a device-root shim),
the VMU is **NOT accessible via standard POSIX file I/O**. KallistiOS provides:

- `vmufs_file_write` / `vmufs_file_read` / `vmufs_file_delete` — direct block-level VMU access
- `/vmu/a1/` mount point via `fs_vmu` (KOS's VFS layer) — allows `open()`/`write()`, but with
  flat layout (no subdirectories, ≤12-char uppercase filename, 512B block multiples)
- `vmu_pkg_build` / `vmu_pkg_parse` — wraps data into VMS format (DC memory card file format)

**The VMU is fundamentally different from every other platform configy supports:**
1. **Flat filesystem** — no subdirectory support at all. `/vmu/a1/FILENAME` only.
2. **12-char uppercase filename limit** — `configRoot()/vendor/app/file.json` cannot map 1:1.
3. **Block-granular storage** — files are in 512B blocks; waste is real.
4. **Maple bus slot lookup** — must probe at runtime whether a VMU is inserted at slot a1.

This requires a dedicated `vmu.nim` with KOS FFI bindings, a path→filename hashing strategy,
and new `when defined(dreamcast):` arms throughout the existing layer.

---

## Architecture

```
configy public API (store.nim / fs.nim / paths.nim)
         │
         ├── when defined(dreamcast): → vmu.nim  ← NEW
         │       ├── KOS FFI: vmufs.h / fs_vmu.h / vmu_pkg.h
         │       ├── maple_enum_type → slot a1 probe
         │       ├── path→12-char-hash mapping
         │       └── vmu_pkg_build / vmu_pkg_parse wrapping
         │
         └── else: existing POSIX path (unchanged)
```

---

## Layer 1: What must change in existing files

See [`seam-map.md`](./seam-map.md) for the exact arms. Summary:

| File | What changes |
|------|-------------|
| `capabilities.nim` | Add `defined(dreamcast)` to `configyUsesOsPath` false-set; add `elif defined(dreamcast): false` to `configyFsWritable` (initially false, flipped after Flycast verification) |
| `paths.nim` | Add `elif defined(dreamcast):` arm to `configRoot()` returning `/vmu/a1/<vendor>/` |
| `fs.nim` | Add dreamcast no-op arm to `createDirTree`; add runtime VMU probe to `isWritable()` |
| `store.nim` | Add `when defined(dreamcast):` arms routing write/read/delete through `vmu.nim` |

## Layer 2: New file

`src/configy/vmu.nim` — all KOS FFI, maple probe, hash, packaging.

---

## Current broken behavior (without any dreamcast arms)

| Code | Symptom | Root cause |
|------|---------|------------|
| `capabilities.nim:34-37` `configyFsWritable=true` | Dreamcast thinks writes are safe | Falls through `else: true` |
| `capabilities.nim:5` `configyUsesOsPath=true` | Uses `$DirSep` and POSIX ops | Missing from false-set |
| `paths.nim:44-54` `configRoot()` else branch | `getHomeDir()` → `""` → `ConfigPathError` | No dreamcast arm |
| `fs.nim:36` `createDirTree` else → `createDir` | Tries to mkdir `/vmu/a1/...` subdirs | VMU is flat, no dirs |
| `store.nim` write APIs | `writeFile("/vmu/a1/...")` with no VMU init | Needs vmufs / vmu_pkg |

---

## Decisions (pending hardware verification)

| Question | Decision |
|----------|----------|
| `configyFsWritable` initial value | **false** (flip to true only after Flycast round-trip passes) |
| Path mapping strategy | **Hash**: `<vendor>/<app>/<dep?>/<filename>` → ≤12-char uppercase hash; parity: same logical path always yields same hash (write-name == read-name) |
| VMU slot | **Port A, Slot 1** (`/vmu/a1/`) — constant; Maple `a1` is the standard save slot |
| Packaging | **VMS format via vmu_pkg_build/vmu_pkg_parse** — DC memory manager shows VMS files with icon/description |
| Evidence standard | **Flycast emulator round-trip** (write → read back → equal) before flipping `configyFsWritable` to true |

---

## Task graph (Layer 1 → Layer 2 → verification → flip)

```
configy-50l [ANALYSIS, this task]
configy-fnb [ANALYSIS, KOS API catalog]
    │
    ▼
configy-o1g: Pin host tests before dreamcast arm
configy-as0: capabilities.nim arms
configy-c45: paths.nim dreamcast configRoot()
configy-g07: nim.cfg KOS toolchain block
configy-9a8: NEW vmu.nim KOS FFI
    │
    ▼
configy-70t: vmu.nim path→12-char hash
configy-t93: vmu.nim runtime VMU presence probe
configy-pw6: fs.nim dreamcast isWritable + flat ensureConfigDir
configy-2n9: store.nim VMU routing
    │
    ▼
configy-7ty: Host unit tests for hash parity
configy-t4j: Host tests for Layer-1 arms
configy-tv0: verify/dreamcast smoke tests
configy-uhl: build scripts
    │
    ▼
configy-h86: Run smoke on Flycast (read path)
configy-4xb: Run write smoke on Flycast
    │
    ▼
configy-6b6: Flip configyFsWritable true (LAST, gated on Flycast)
configy-nw2: v0.5.0 version bump
```
