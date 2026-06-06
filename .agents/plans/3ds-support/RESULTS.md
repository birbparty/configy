# 3DS Verification Gate — Results

**Status: ✅ VERIFIED** — configy's read path compiles, links, and runs correctly
on a real Nintendo 3DS toolchain.

- **Date:** 2026-06-06
- **Machine:** macOS (Apple M4 Max), Nim 2.2.10
- **Toolchain:** devkitARM release 66, gcc 15.1.0; libctru; 3dsxtool
- **Emulator:** Azahar (Citra fork)
- **Branch:** `feat/3ds-verification-gate`

This closes **Finding 1** of [`plan.md`](./plan.md): configy was previously only
host-`nim check`-verified; it is now verified compile→link→run on the real
devkitARM `--os:linux` + newlib + libctru target.

## What was executed

1. **Tier A (host `nim check`)** — `nim check --path:src -d:ds3
   -d:configyVendor=test src/configy.nim` → clean (warnings only).
2. **Tier B compile + link** — `scripts/build_3ds.sh`:
   - Nim transpiled all of configy + supersnappy to C.
   - `arm-none-eabi-gcc` compiled and **linked** to a static ARM ELF:
     `ELF 32-bit LSB executable, ARM, EABI5, statically linked` — confirmed ARM,
     not a host binary.
   - Packaged `ds3_smoke.3dsx` with `3dsxtool`.
3. **Tier B runtime (Azahar)** — launched the `.3dsx`; exerciser wrote
   `sdmc:/configy_smoke_result.txt`, read back from Azahar's host SD passthrough
   dir (`~/Library/Application Support/Azahar/sdmc/`):

   **Absent-file case:**
   ```
   resolved_path=sdmc:/config/smoketest/smoke/probe.json
   exists_ok=true     exists=false
   read_ok=true       read_isNone=true
   ```
   → `configFileExists` returns false without raising; `readConfigJson` returns
   `none()` without raising. (This is exactly the contract inputty depends on.)

   **Planted-file case** (host-planted `\x00{"hello":"3ds","n":42}`):
   ```
   exists=true
   read_isNone=false
   read_parsed={"hello":"3ds","n":42}
   ```
   → file found; magic byte stripped; JSON parsed correctly.

## New findings surfaced during execution (fixed)

1. **configy needs an `librt.a` stub in addition to `libdl.a`.** Nim injects both
   `-ldl` *and* `-lrt` for `--os:linux` targets; the 3DS (newlib) has neither.
   configy pulls in `-lrt` because it imports `std/os` (→ `times`). The reference
   raylib build only needed the libdl stub. `scripts/build_3ds.sh` now creates
   both empty stub archives; documented in the `@if ds3:` block of `nim.cfg`.

2. **The Tier A `nim check` command must pass `--path:src`.** Running
   `nim check src/configy.nim` *without* `--path:src` makes Nim mis-resolve the
   submodule imports (the `src/configy.nim` file vs the `src/configy/` dir
   collide), so only the multi-arg `configDir/configFile/ensureConfigDir`
   overloads are seen and the check fails spuriously. With `--path:src` (as in
   the build script and the test config) it passes. The plan's original Tier A
   command was missing this flag.

3. **libctru auto-inits the `sdmc:` devoptab for a `.3dsx`** — no explicit
   `sdmcInit()` was needed; `sdmc:/` paths resolved out of the box. (This
   confirms the "verify whether auto-init happens" open question in
   [`verification-gate.md`](./verification-gate.md).)

4. **Azahar's SD card is an immediate host passthrough** — the marker file
   appeared in the host `sdmc/` dir within ~1s of the app running, so the
   read-back assertion does not require a clean emulator shutdown.

## Regression check

`nimble test` (desktop) → all 4 suites PASS after the `@if ds3:` block and the
`capabilities.nim` comment change. No contract invariant changed;
`configyFsWritable` remains `false` for ds3 (writes still out of scope — Finding 2).

## Artifacts added

- `nim.cfg` — `@if ds3:` block (target switches + devkitARM toolchain); 3DS
  cross-compile example corrected `--os:standalone` → `--os:linux`.
- `verify/ds3/ds3_smoke.nim` — read-path exerciser.
- `verify/ds3/ctru.nim` — minimal libctru FFI (console + apt loop + input).
- `verify/ds3/README.md` — how to build/run/assert.
- `scripts/build_3ds.sh` — guarded build/link/package (PASS-for-scope when
  toolchain absent).
- `src/configy/capabilities.nim` — comment split: 3DS marked verified, PSP
  unchanged.

## Reproduce

```sh
./scripts/build_3ds.sh
open -a Azahar ./ds3_smoke.3dsx
cat "$HOME/Library/Application Support/Azahar/sdmc/configy_smoke_result.txt"
```

## Out of scope (unchanged)

3DS *writes* / persistence (Finding 2, deferred); `--os:Standalone` support;
PSP/Vita verification (their `nim.cfg` examples still show `--os:standalone` and
are likely wrong, but were not validated here).
