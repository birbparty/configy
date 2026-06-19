# Dreamcast Seam Map — Exact Arms for Layer 1

Generated from analysis of `src/configy/{capabilities,paths,fs,store}.nim` on 2026-06-19.

---

## capabilities.nim

### Gap 1 — `configyUsesOsPath` (line 5)

```nim
# CURRENT:
configyUsesOsPath* = not (defined(ds3) or defined(psp) or defined(vita) or defined(emscripten))

# REQUIRED: add defined(dreamcast)
configyUsesOsPath* = not (defined(ds3) or defined(psp) or defined(vita) or defined(dreamcast) or defined(emscripten))
```

**Effect**: `configDir()` in paths.nim will use `"/"` instead of `$DirSep` for path
construction. More importantly, disables any code path gated on `when configyUsesOsPath`
that assumes POSIX path semantics (absolute paths, `getHomeDir`, XDG).

### Gap 2 — `configyFsWritable` (lines 34-37)

```nim
# CURRENT:
const configyFsWritable* =
  when defined(emscripten): false
  elif defined(psp):        false
  else:                     true           # ← dreamcast falls here: WRONG (initially)

# REQUIRED: add dreamcast arm (false initially, flipped after Flycast verification)
const configyFsWritable* =
  when defined(emscripten): false
  elif defined(psp):        false
  elif defined(dreamcast):  false          # ← gated until VMU round-trip verified
  else:                     true
```

**Effect with current code**: Dreamcast build thinks it's writable → `writeConfigJson`
does NOT raise `ConfigUnsupportedError` → calls `ensureConfigFile` → `ensureConfigDir`
→ `createDirTree` → `createDir("/vmu/a1/...")` — fails because VMU has no subdirs AND
VMU bindings aren't initialized.

**Note on `configyHasRealFs`** (line 2): `not defined(emscripten)` — dreamcast falls
through to `true`. This is CORRECT once VMU bindings are in place (KOS does provide a
real block FS via `fs_vmu`). No change needed here.

---

## paths.nim

### Gap 3 — `configRoot()` (lines 35-54)

```nim
# CURRENT: no dreamcast arm — falls through to else (desktop XDG/HOME)
#   getHomeDir() on KOS → "" (HOME not set) → ConfigPathError

# REQUIRED: add before the else branch
elif defined(dreamcast):
  result = "/vmu/a1/" & VendorNamespace & "/"
```

**Why `/vmu/a1/`**: KOS mounts the VMU at port A slot 1 under `/vmu/a1/`. This is the
standard save-game VMU slot on Dreamcast. Port enumeration: port A = 0, unit 1 = slot 1.

**VMU path scheme is LOGICAL, not physical**: `/vmu/a1/<vendor>/<app>/<filename>` cannot
be stored as-is on VMU (flat FS, 12-char limit). The `vmu.nim` layer hashes the logical
path to a ≤12-char uppercase filename. `configRoot()` returns the logical prefix; `vmu.nim`
maps it to the physical VMU filename.

**`configDir()` (lines 63-78)**: No change needed. Once `configyUsesOsPath = false` for
dreamcast, the `else` branch already uses `"/"` string concatenation, which is correct.

---

## fs.nim

### Gap 4 — `createDirTree()` (lines 23-36)

```nim
# CURRENT: ds3 shim, else createDir(dir) — createDir on VMU would fail (no dirs)

# REQUIRED: add dreamcast no-op before else
when defined(ds3):
  # ... existing ds3 shim ...
elif defined(dreamcast):
  discard  # VMU is a flat filesystem; no directories exist or can be created
else:
  createDir(dir)
```

**Why no-op**: `/vmu/a1/` is a flat VFS — `fs_vmu` exposes files only, no subdirectory
support. Calling `createDir` would either fail or reference a path that doesn't exist
in KOS's VFS. All VMU files are stored flat under the mount point with hashed names.

### Gap 5 — `isWritable()` at runtime (lines 6-11)

Current: returns `configyFsWritable` (compile-time const). With `configyFsWritable=false`
for dreamcast, `isWritable()` always returns false (correct for the initial gate).

**After the Flycast gate**, when `configyFsWritable` is flipped to true for dreamcast,
`isWritable()` will return true. At that point the plan (task `configy-pw6`) calls for
adding a **runtime VMU presence probe**: check that a VMU is actually inserted at slot a1
via `maple_enum_type(MAPLE_FUNC_MEMCARD, 0)` (see `kos-api.md`). This turns `isWritable()`
from a compile-time const return into a runtime check for dreamcast.

```nim
# Target state for isWritable() after flip (task configy-pw6):
proc isWritable*(): bool {.raises: [].} =
  when defined(dreamcast):
    vmu.isPresent()  # runtime maple probe via vmu.nim
  else:
    configyFsWritable
```

---

## store.nim

### Gap 6 — write/read/delete routing (throughout)

store.nim writes use `writeFile(path, payload)` and reads use `readFile(path)`. For
dreamcast, these must route through `vmu.nim` which calls `vmufs_file_write/read/delete`
and handles VMS packaging.

The store.nim routing is a **Layer 2** concern (blocked on `vmu.nim` existing first).
The pattern is:

```nim
# Example target for writeConfigJson (dep-less):
when defined(dreamcast):
  let logicalPath = configFile(app, filename)
  vmu.writeVmuFile(logicalPath, payload)  # routes through vmufs_file_write + vmu_pkg_build
else:
  writeFile(path, payload)
```

The `logicalPath` → physical VMU filename hash is owned by `vmu.nim` (task `configy-70t`).
`store.nim` passes the logical path and lets `vmu.nim` own the hash mapping — hash parity
(write-name == read-name) is verified by host unit tests (task `configy-7ty`).

---

## Summary: exact arms Layer 1 must add

| Task | File | Line(s) | Change |
|------|------|---------|--------|
| `configy-as0` | `capabilities.nim` | 5 | Add `or defined(dreamcast)` to `configyUsesOsPath` false-set |
| `configy-as0` | `capabilities.nim` | 34-37 | Add `elif defined(dreamcast): false` to `configyFsWritable` |
| `configy-c45` | `paths.nim` | ~41 | Add `elif defined(dreamcast): result = "/vmu/a1/" & VendorNamespace & "/"` before else |
| `configy-pw6` | `fs.nim` | ~23-36 | Add `elif defined(dreamcast): discard` to `createDirTree` |
| `configy-pw6` | `fs.nim` | 6-11 | After flip: add dreamcast `vmu.isPresent()` arm to `isWritable()` |
| `configy-2n9` | `store.nim` | ~18-36 | Add `when defined(dreamcast):` arms to `storeBytes`/`loadBytes` routing through vmu.nim |

**Ordering constraint**: `vmu.nim` (`configy-9a8`) must exist before `store.nim` routing
(`configy-2n9`) can be implemented. The `capabilities.nim`, `paths.nim`, and `fs.nim` arms
(`configy-as0`, `configy-c45`, `configy-pw6` no-op part) can be implemented in any order
after the host test baseline is pinned (`configy-o1g`).
