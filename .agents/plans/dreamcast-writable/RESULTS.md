# Dreamcast Write Gate — Results

**Status: ⚠️ EMULATOR-ONLY — NOT hardware-verified.** `configyFsWritable` is flipped
to `true` for `-d:dreamcast`; the full VMU write→read round-trip passes on **two
independent emulators (Flycast and redream)**. It has **not** been run on a real
Dreamcast. This is the deliberate opposite of the 3DS/Vita gates, which led with
"VERIFIED ON REAL HARDWARE." Treat the flip as emulator-validated only.

- **Date:** 2026-06-19
- **Machine:** macOS (Apple Silicon), Nim 2.2.10
- **Toolchain:** `einsteinx2/dcdev-kos-toolchain:gcc-9` (KallistiOS + sh-elf-gcc 9), Docker
- **Emulators:** Flycast (serial via `Debug.SerialPTY`), redream v1.5.0 (`--serial`)
- **Branch:** `feat/dreamcast-cdi-and-vmu-heap-bug`

## Build — ✅

`scripts/build_dreamcast_cdi.sh verify/dreamcast/dreamcast_write_smoke.nim`:
two-phase (host `nim --compileOnly` → Docker `sh-elf-gcc` compile+link) → raw binary
→ `scramble` → `makeip` → `mkisofs` → `cdi4dc`, emitting a bootable `.cdi` (and `.elf`).
Built with `configyFsWritable=true` (write surface compiled in).

## Emulator runtime — ✅ all steps PASS (Flycast AND redream)

Serial marker captured from both emulators:
```
== configy Dreamcast write-path gate ==
vmu_present=true
ensure_create=PASS
ensure_again=PASS
write_json=PASS
read_json=PASS
write_json_z=PASS          <-- compressed (MagicSnappy 0x01) write
read_json_z=PASS
write_bytes=PASS
read_bytes=PASS
delete=PASS
deleted_gone=PASS
cleanup=PASS
isWritable=true
RESULT=PASS
```

## THE CRUX — configy-cbj (VMU heap corruption), RESOLVED

Enabling writes was blocked by a layout-sensitive heap corruption: a VMU **read of an
existing file** followed by an allocation-heavy op (Snappy `compress` / `parseJson`)
hung the next `malloc`; the round-trip hung at `write_json_z`.

Isolation (emulator, serial-captured):
- Reproduces on **both Flycast and redream** → not an emulator artifact.
- Not compression, not the `readConfigJson` double-read, not the C→Nim `copyMem` alignment.
- A **pure-C** control (same KOS VMU FFI, no Nim runtime) is CLEAN → **not a KOS bug**.
- A **minimal Nim** control (generic C `malloc`/`free` + Nim allocations) is CLEAN →
  not generic FFI interleaving. The bug needs the real VMU FFI **and** the Nim runtime.

Root cause: with `-d:useMalloc`, Nim's ARC allocations and KOS's VMU/maple-DMA buffers
(the `malloc`'d target of the maple DMA read inside `vmufs_read`) share ONE newlib
heap; the VMU read path corrupts adjacent Nim heap chunks.

Fix: **drop `-d:useMalloc` for the dreamcast target** in `nim.cfg` (keep
`nimAllocPagesViaMalloc`), giving Nim its own page allocator separate from KOS's
C/DMA-buffer heap.

Anti-layout-luck validation (two earlier candidate "fixes" were layout-luck false
positives, so the fix was held to explicit gates):
- Passes on **Flycast + redream**.
- Passes at **`--opt:size` and `--opt:none`**.
- Passes with **injected arena-perturbing allocations** before the round-trip.
- **Re-enabling `-d:useMalloc` deterministically reproduces the hang** (fix removal
  reintroduces the bug → the fix, not luck, is what resolves it).

## Regression — ✅

- Read-path gate (`dreamcast_smoke`, configy-h86) still PASSES (`exists_ok`/`read_ok`/
  `read_isNone`, `RESULT=PASS`).
- Host `nimble test`: 6/6 PASS.
- 3DS `nim c --compileOnly -d:ds3` still compiles (the nim.cfg change is scoped to the
  `@if dreamcast:` block; 3DS/Vita keep `-d:useMalloc` and are unaffected).

## Known risk — record explicitly

**Emulator-only is a real risk.** Flycast/redream may mask a class of bug that real
Dreamcast hardware exposes — exactly as Azahar's host-passthrough SD masked the 3DS
`sdmc:/` `EINVAL`-on-`mkdir` that only reproduced on real hardware (see
`.agents/plans/3ds-writable/RESULTS.md`). The configy-cbj root cause (maple-DMA buffer
adjacency in the heap) is precisely the kind of thing whose exact behavior can differ
on real silicon (cache coherency, DMA timing/granularity). **Open follow-up: re-verify
the write round-trip on a physical Dreamcast before claiming hardware support.**

## Known limitations (pre-existing, cross-platform — name, don't fix here)

- **Non-atomic writes.** `storeBytes` is not atomic; a crash/power-loss mid-write can
  leave a truncated VMU file, and the next read raises `ConfigParseError` (bad CRC /
  magic), not `none()`. Pre-existing and cross-platform; more reachable on a console
  users power off abruptly.
- **No concurrent-writer safety.** Single-process homebrew; acceptable, just not claimed.
- **Conservative VMU-full check.** `writeVmuFile` does not credit blocks freed by an
  overwrite; a re-save on a near-full card can false-positive "VMU full." Safe (writes
  are rejected, not corrupted); acceptable given configy's small files.

## Reproduce

```sh
./scripts/build_dreamcast_cdi.sh verify/dreamcast/dreamcast_write_smoke.nim
# Flycast (set Debug.SerialConsoleEnabled=yes, Debug.SerialPTY=yes in emu.cfg):
/Applications/Flycast.app/Contents/MacOS/flycast dreamcast_write_smoke.elf &
#   then read the /dev/ttysNNN it logs ("Pseudoterminal is at ...")
# redream:
#   point --serial=<a pty> at dreamcast_write_smoke.cdi and read the other end
```
