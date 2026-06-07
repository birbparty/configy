# Vita Verification Gate — Results

**Status: ✅ VERIFIED (compile + link + `vita-elf-create` + `.vpk` + Vita3K runtime)**
— configy's read path compiles, **links**, packages on a real VitaSDK toolchain,
**and runs correctly in the Vita3K emulator** (both absent- and planted-file cases).
Real-hardware `-Wl,-q` relocation correctness remains the one item Vita3K cannot
prove (it loads at the link base); see "Hardware caveat".

- **Date:** 2026-06-06
- **Machine:** macOS (Apple Silicon), Nim 2.2.10
- **Toolchain:** VitaSDK at `/usr/local/vitasdk`; `arm-vita-eabi-gcc` 15.2.0;
  `vita-elf-create` / `vita-make-fself` / `vita-mksfoex` / `vita-pack-vpk`
- **Emulator:** Vita3K v0.2.1 (4036-40ce476b), Vulkan/MoltenVK, firmware installed
- **Branch:** `feat/vita-verification-gate`

This mirrors the [3DS effort](../3ds-support/RESULTS.md). Both the strongest
non-hardware signal (link + a successful `vita-elf-create` + a well-formed `.vpk`)
**and** the Vita3K runtime read exercise are **green**.

## Vita3K runtime corroboration (both cases PASS)

Booted the packaged `.vpk` in Vita3K (`Vita3K -r CFGY00001`); the headless exerciser
wrote `ux0:data/configy_smoke_result.txt`, read back from Vita3K's host ux0 dir
(`~/Library/Application Support/Vita3K/Vita3K/fs/ux0/`).

**Absent-file case** (no probe planted):
```
resolved_path=ux0:data/config/smoketest/smoke/probe.json
exists_ok=true     exists=false
read_ok=true       read_isNone=true
```
→ `configFileExists` returns false without raising; `readConfigJson` returns
`none()` without raising. Exactly the contract inputty/consumers depend on.

**Planted-file case** (host-planted `\x00{"hello":"vita","n":7}`):
```
exists=true
read_isNone=false
read_parsed={"hello":"vita","n":7}
```
→ file found via `std/os` (newlib → `sceIo`); `MagicRaw` byte stripped; JSON parsed
correctly. Confirms the full read path (`fileExists` → `readFile` → magic framing →
`parseJson`) works on Vita, and that `std/os` reaches `ux0:` with no shim.

The Vita3K log confirmed `vita_smoke` (eboot.bin) loaded, linked, and ran
(`load_app_impl: Title: configy vita smoke / Serial: CFGY00001`). Note: Vita3K's
`-r` auto-boot is flaky (some launches drop to the Qt GUI launcher instead of
booting); just retry until the log shows `load_app_impl`.

## Hardware caveat (the one residual)

Vita3K loads the module at its **link base**, so the `-Wl,-q` relocation/data-abort
failure mode that only manifests at a **non-link base** is invisible here — a Vita3K
pass is weaker than the 3DS Azahar pass on exactly this axis. The successful
`vita-elf-create` is the strongest relocation signal obtainable without a real Vita;
true load-at-non-link-base correctness still needs hardware (tracked in configy-uzq).

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

## Not yet done (hardware only)

Only the real-hardware run remains — to retire the `-Wl,-q`-at-non-link-base risk
that Vita3K structurally cannot exercise (see "Hardware caveat"). Everything testable
in the emulator passes. To reproduce the Vita3K run:

```sh
./scripts/build_vita.sh                                   # produces vita_smoke.vpk
VBIN=/Applications/Vita3K.app/Contents/MacOS/Vita3K
unzip -o vita_smoke.vpk -d "<Vita3K ux0>/app/CFGY00001"  # or install via the GUI
"$VBIN" -r CFGY00001 --log-level 1                        # retry if it opens the GUI
cat "<Vita3K ux0>/data/configy_smoke_result.txt"
```

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
