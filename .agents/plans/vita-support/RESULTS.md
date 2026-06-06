# Vita Verification Gate — Results

**Status: ✅ VERIFIED (compile + link + `vita-elf-create` + `.vpk`)** — configy's
read path compiles, **links**, and packages on a real VitaSDK toolchain. Runtime
corroboration in Vita3K/hardware is **not yet run** (see "Not yet done").

- **Date:** 2026-06-06
- **Machine:** macOS (Apple Silicon), Nim 2.2.10
- **Toolchain:** VitaSDK at `/usr/local/vitasdk`; `arm-vita-eabi-gcc` 15.2.0;
  `vita-elf-create` / `vita-make-fself` / `vita-mksfoex` / `vita-pack-vpk`
- **Branch:** `feat/vita-verification-gate`

This mirrors the [3DS effort](../3ds-support/RESULTS.md). The strongest signal
achievable without a real Vita — link + a successful `vita-elf-create` (the genuine
`-Wl,-q` test) + a well-formed `.vpk` — is **green**.

> **Pre-settled (held up):** VitaSDK's newlib `libc.a` backs `open`/`read`/`stat`
> with `sceIo*`, so configy's `std/os` read path reaches `ux0:` with **no shim**.
> The link succeeded with zero unresolved `sceIo*`/`fileExists`/`readFile` symbols,
> confirming this statically-derived expectation. No `sceIo*` read shim was needed.

## What was executed

1. **Tier A (host `nim check`)** — `nim check --path:src -d:vita
   -d:configyVendor=test src/configy.nim` → clean (warnings only: `os` imported and
   not used, since `createDir` compiles out under `configyFsWritable=false`).
2. **Tier B compile + link** — `scripts/build_vita.sh`:
   - Nim transpiled all of configy + supersnappy to C.
   - `arm-vita-eabi-gcc` 15.2.0 compiled and **linked** to a static ARM ELF:
     `ELF 32-bit LSB executable, ARM, EABI5 version 1 (SYSV), statically linked` —
     confirmed ARM, not a host binary.
   - **`vita-elf-create` succeeded** — the real test that `-Wl,-q` retained the
     relocations needed to emit SCE relocations into the `.velf`.
   - `vita-make-fself` → `vita-mksfoex` (`TITLE_ID=CFGY00001`) → `vita-pack-vpk`
     produced `vita_smoke.vpk` (`sce_sys/param.sfo` + `eboot.bin`).
3. **Tier B runtime (Vita3K/hardware)** — **not run** (see below).

## Findings confirmed during execution

1. **Link order as designed works.** `-lc -lm` before the `Sce*` stubs resolved
   newlib's `_open_r`/`_stat_r` → `sceIoOpen`/`sceIoGetstat` (in `SceIofilemgr_stub`)
   with no `--start-group` needed.
2. **`Sce*` stub set was sufficient as listed.** `-lSceIofilemgr_stub
   -lSceLibKernel_stub -lSceProcessmgr_stub` linked with no further unresolved
   symbols — the linker did **not** report additional stubs. (The list was flagged
   "known-incomplete"; in practice these three sufficed for the read-path exerciser.)
3. **Only the `librt` stub was needed.** Vita ships a real `libdl.a`, so `-ldl`
   resolved natively; the empty `librt.a` stub satisfied `-lrt` (pulled in via
   `std/os → times`). This matches the 3DS RESULTS finding, adjusted for Vita.
4. **No `-march`/`-mfpu` flags needed.** `arm-vita-eabi-gcc`'s defaults
   (`armv7-a+simd`/neon/hard-float) produced a valid ARM ELF; the 3DS armv6k flags
   were correctly omitted.
5. **No graphics libs.** Stripping the reference's raylib/SDL2/vitaGL link soup was
   correct — configy linked with only libc + the three `Sce*` stubs.

## Not yet done (runtime tier)

The Vita3K runtime read-path corroboration was not executed in this session
(Vita3K is a GUI emulator requiring firmware + manual `.vpk` install/run; not
reliably automatable headless here). To complete it:

```sh
./scripts/build_vita.sh                 # produces vita_smoke.vpk
# install vita_smoke.vpk in Vita3K, run it, then:
cat "<Vita3K ux0>/data/configy_smoke_result.txt"
```

⚠️ **Honesty caveat:** even once run, Vita3K loads at the link base and **hides**
`-Wl,-q` relocation bugs — a Vita3K pass is weaker than the 3DS Azahar pass.
Hardware is the only gold check for the load-at-non-link-base path. The successful
`vita-elf-create` here is the strongest relocation signal obtainable without
hardware.

## Regression check

- `nimble test` (desktop) → all 4 suites PASS (`test_errors`, `test_paths`,
  `test_placeholder`, `test_store`).
- `nim c --compileOnly` for `-d:ds3`, `-d:psp`, `-d:vita`, `-d:emscripten` → all OK
  (CI `platform-define-check` equivalent).
- No contract invariant changed. `configyFsWritable` is now `false` for vita
  (conservative posture); read APIs unchanged.

## Artifacts added / changed

- `nim.cfg` — `@if vita:` block (target switches + VitaSDK toolchain + `-Wl,-q` +
  correct link order + librt-stub note + no arch flags); Vita cross-compile example
  corrected `--os:standalone` → `--os:linux`.
- `src/configy/capabilities.nim` — `vita` added to the `configyFsWritable`
  read-only set; Vita verified comment added.
- `verify/vita/vita_smoke.nim` — read-path exerciser (headless; `writeFile` +
  belt-and-suspenders raw `sceIo*` marker).
- `verify/vita/README.md` — how to build/run/assert.
- `scripts/build_vita.sh` — guarded build/link/`vita-elf-create`/package
  (PASS-for-scope, exit 0, when toolchain absent).
- `.github/workflows/ci.yml` — comment updated (vita row now exercises arm/linux
  codegen via `@if vita:`).
- `.gitignore` — Vita build artifacts.

## Reproduce

```sh
./scripts/build_vita.sh
file vita_smoke                          # ARM, not host
unzip -l vita_smoke.vpk                  # sce_sys/param.sfo + eboot.bin
```

## Out of scope (unchanged)

Vita *writes* / persistence (deferred — low-cost, since newlib backs writes via
`sceIo*` and `ux0:data/` is writable); `--os:Standalone` support; PSP verification
(its `nim.cfg` example still shows `--os:standalone`, likely wrong, not validated
here).
