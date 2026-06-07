# 3DS Write Gate — Design

Companion to [`plan.md`](./plan.md). Verifies configy's **write path** on Nintendo 3DS
once `configyFsWritable` is flipped to `true` for `-d:ds3`. Mirrors the
hardware-verified [Vita write gate](../vita-writable/verification-gate.md); the one
material difference is the **device-root `mkdir` crux** (see plan.md). 3DS hardware is
available, so the crux is settled by a real-device run rather than guessed: the gate
builds with **stock `std/os.createDir`** and only ships a `-d:ds3` contingency if that
fails on hardware.

---

## What must be proven (the write surface)

Flipping the flag activates (on 3DS) four things currently gated off; each round-trips:

1. **`ensureConfigDir`** — creates `sdmc:/config/<vendor>/<app>/[<dep>/]` and is
   idempotent. Built **first with stock `std/os.createDir`** (which mkdir's/stats the
   bare `sdmc:/` device root — the crux); the **hardware run decides** whether stock
   works or the contingency (below) is needed.
2. **`writeConfigJson`** (uncompressed, `MagicRaw` 0x00) — write → read back → equal.
3. **`writeConfigJson(compress = true)`** — `supersnappy.compress` + the `MagicSnappy`
   (0x01) read branch on-device.
4. **`writeConfigBytes`** raw round-trip; **`deleteConfig`** → `configFileExists` false.

A leaf `writeFile` to `sdmc:/` is already proven (the read smoke's marker), so the
genuinely new behavior is **nested dir creation** and **delete** (`removeFile` →
newlib `unlink` → sdmc devoptab) — both unproven on hardware (linking is fine; the
**runtime** behavior on Horizon FS is what the hardware run settles).

---

## Contingency (only if hardware shows stock `createDir` fails): a ds3 `createDirTree`

Default path is **stock `std/os.createDir`** (what Phase 2 tests on hardware). Open
this contingency only if that run shows the device-root `mkdir`/`stat` is fatal.

**Integration — do NOT add a second `ensureConfigDir` proc.** Both existing overloads
(`fs.nim:13`, `:27`) already contain `when configyFsWritable: createDir(result)`, which
flips on for ds3. Adding a `when defined(ds3): proc ensureConfigDir*` would **redefine**
them (compile error) — and leaving them as-is calls the root-hitting stock `createDir`.
Instead, route that one call site through a helper:

```nim
proc createDirTree(dir: string) {.raises: [OSError, IOError].} =
  when defined(ds3):
    # Create only the real subdirs UNDER the device root - never mkdir/stat "sdmc:/".
    # Assumes a "device:/" prefix (e.g. "sdmc:/"); safe because validateComponent
    # (paths.nim) forbids ':' in app/dep/filename, so the only ':' is the device's.
    let afterPrefix = dir.find('/', start = dir.find(':') + 1) + 1  # past "sdmc:/"
    for i in afterPrefix ..< dir.len:
      if dir[i] == '/':
        let sub = dir[0 ..< i]                 # sdmc:/config, then .../<vendor>, ...
        if not dirExists(sub):
          discard existsOrCreateDir(sub)        # single-level; NOT recursive createDir
  else:
    createDir(dir)                              # desktop/Vita: unchanged

# then in BOTH ensureConfigDir overloads, inside `when configyFsWritable`:
#   try: createDirTree(result)
#   except CatchableError as e: raise newException(ConfigIOError, ...)
```

Notes:
- **Use `existsOrCreateDir(sub)`, never `createDir(sub)`.** `createDir("sdmc:/config")`
  re-runs `parentDirs(fromRoot=true)`, whose first element is `sdmc:/` -> it would touch
  the device root again, defeating the purpose. `existsOrCreateDir` (`osdirs.nim:399`)
  creates exactly one level and tolerates EEXIST.
- **What this buys (honest):** it avoids the device *root* mkdir/stat only. It still
  depends on sdmc dir-`stat` (`dirExists`, and `existsOrCreateDir`'s EEXIST branch) for
  the nested components — which the read gate did NOT prove (it only exercised
  *file*-`stat`, never `dirExists`). So dir-stat on `sdmc:` is validated by the hardware
  run regardless of which path ships; the contingency narrows the unknown from
  "device-root + nested" to "nested only."
- The `else` branch keeps desktop/Vita byte-for-byte identical to today.

---

## Artifacts to add (Phase 0 — no toolchain needed)

### 1. `verify/ds3/ds3_write_smoke.nim`

Mirror `verify/vita/vita_write_smoke.nim` (the corrected, `doAssert`-free version) but
use the 3DS console harness from `verify/ds3/ctru.nim` (gfx + console + `aptMainLoop`
waiting for **START**), as the read smoke does. The write checks are identical:

```nim
import std/[json, options, strutils]
import configy, ctru

const App = "wsmoke"
# ... gfxInitDefault(); consoleInit(GFX_TOP, nil)
# run(): same steps as vita_write_smoke - ensure_create/ensure_again, write/read json
#   (raw + compressed), write/read bytes, delete, deleted_gone, cleanup, isWritable.
#   Failed checks `raise newException(ValueError, ...)` (NOT doAssert: AssertionDefect
#   is a Defect, not a CatchableError, so the step template would not catch it and the
#   marker would never be written).
# echo the report to the console AND writeFile("sdmc:/configy_write_smoke_result.txt", report)
#   (raw writeFile - proven on sdmc:; independent of the API under test).
# aptMainLoop { if KEY_START: break }; gfxExit()
```

Built with **stock `createDir`** (no ds3 contingency yet) — it is the instrument that
tests the crux on hardware.

### 2. Build script

Parametrize `scripts/build_3ds.sh` to take an optional source + output base (no-arg =
read smoke, unchanged), and add `scripts/build_3ds_write.sh` mirroring how
`build_vita_write.sh` wraps `build_vita.sh`. **Preserve the read gate's two invariants
by name:** toolchain-absent -> `exit 0` (PASS-for-scope), and **never `cp` over the
tracked `nim.cfg`** (the `@if ds3:` block carries all switches). Same libdl/librt stub
idiom, `3dsxtool` packaging. `removeFile`->`unlink` is newly referenced vs the read
build — confirm it links (expect it resolves from newlib; no new flag).

### 3. `.gitignore`

Add `/ds3_write_smoke` and `/ds3_write_smoke.3dsx`.

---

## Phase 2 — Run it (Azahar smoke, then real 3DS as the decider)

### Azahar (logic smoke; does NOT settle the crux)
```sh
./scripts/build_3ds_write.sh
open -a Azahar ./ds3_write_smoke.3dsx
cat "$HOME/Library/Application Support/Azahar/sdmc/configy_write_smoke_result.txt"
```
Expect all PASS. **Caveat:** Azahar's SD is a host passthrough — `mkdir`/`stat`/`unlink`
on it behave like the host filesystem, NOT Horizon FS. An Azahar pass confirms the
*logic* (round-trip correctness) but does NOT prove on-device dir/delete semantics. It
is necessary, not sufficient — and specifically cannot answer the device-root crux.

### Real 3DS hardware (the decider + gold check)
Copy `ds3_write_smoke.3dsx` to the SD card, launch via the Homebrew Launcher, read PASS/
FAIL on-screen, then read `sdmc:/configy_write_smoke_result.txt` off the card. This is
the only run that exercises libctru's sdmc devoptab + Horizon FS for: the **device-root
`mkdir`/`stat`** (stock `createDir`), **nested `mkdir`**, and **`unlink`** (delete).

**Crux verdict, recorded in RESULTS:**
- **stock `createDir` PASS on hardware** -> keep stock; no ds3 contingency. Done.
- **stock `createDir` FAIL** (device-root mkdir/stat fatal) -> add the `createDirTree`
  contingency (above), rebuild, re-run on hardware to confirm.

### Opportunistic (nearly free)
Re-run the existing **read** smoke (`ds3_smoke.3dsx`) on the same hardware to retire the
read gate's outstanding Azahar-only status and establish the dir-stat baseline.

---

## Expected marker (all PASS)

```
ensure_create=PASS
ensure_again=PASS
write_json=PASS
read_json=PASS
write_json_z=PASS
read_json_z=PASS
write_bytes=PASS
read_bytes=PASS
delete=PASS
deleted_gone=PASS
cleanup=PASS
isWritable=true
```

---

## Acceptance criteria

- [ ] `configyFsWritable` true for `-d:ds3`; psp unchanged (false); Vita unchanged.
- [ ] `verify/ds3/ds3_write_smoke.nim` + build target exist; read smoke untouched;
      no `doAssert` (uses `check`/CatchableError); built with stock `createDir`.
- [ ] Build script preserves exit-0-when-toolchain-absent and never-`cp`-over-`nim.cfg`.
- [ ] Builds via `arm-none-eabi-gcc`, packages a `.3dsx`; the `unlink` (delete) path links.
- [ ] Azahar marker: all steps PASS, `isWritable=true` (logic smoke).
- [ ] **Real-hardware marker: all steps PASS** (committed gold check) — settling the
      device-root mkdir/stat, nested mkdir, and unlink on Horizon FS.
- [ ] Crux verdict recorded: stock `createDir` sufficed, OR the `createDirTree`
      contingency was added (via the helper, both overloads, `existsOrCreateDir`) and
      re-verified on hardware.
- [ ] `nim check -d:ds3`, desktop `nimble test`, all `--compileOnly` rows green; read
      contract unchanged.
- [ ] `configy.nimble` bumped `0.3.0` -> `0.4.0`; behavior change documented.

---

## Explicitly NOT part of this gate

- No psp write enablement; no Vita changes.
- No `configRoot`/path-layout change (would relocate files; breaks the read layout).
- No empty-dir removal in `deleteConfig` (file removal only, as on every target).
- No "hardware-verified" claim off Azahar alone.

---

## Reference file map

| artifact | source to mirror |
|----------|------------------|
| `createDirTree` helper (contingency, ds3 branch) | new — the crux fix; integrate at the existing `ensureConfigDir` call site |
| `verify/ds3/ds3_write_smoke.nim` | `verify/vita/vita_write_smoke.nim` (checks) + `verify/ds3/ds3_smoke.nim` (ctru console harness) |
| `scripts/build_3ds_write.sh` (+ parametrized `build_3ds.sh`) | `scripts/build_vita_write.sh` / parametrized `build_vita.sh` |
| run / read-back | `../3ds-support/RESULTS.md` (Azahar) + `../vita-writable/RESULTS.md` (hardware) |
