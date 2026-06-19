# Dreamcast Smoke Tests — Flycast Verification Steps

Two gates: a **read-path** smoke and a **write-path** smoke. Both broadcast their
result on KOS serial; capture it from the host via the emulator's serial PTY.

- **Read-path (`dreamcast_smoke`)**: PASSES on Flycast + redream.
- **Write-path (`dreamcast_write_smoke`)**: PASSES on Flycast + redream — all 13
  steps, `isWritable=true`, `RESULT=PASS`. EMULATOR-ONLY (no real hardware yet).
  Enabling it required the **configy-cbj** fix (see the bottom of this file).

## Prerequisites

- Docker running with the `einsteinx2/dcdev-kos-toolchain:gcc-9` image
  (complete KOS + sh-elf-gcc 9 + `makeip`/`cdi4dc`/`scramble`/`mkisofs`)
- `nim` in PATH on the host (generates C; the Docker container compiles + links)
- [Flycast](https://github.com/flyinghead/flycast) installed

The native KOS toolchain at `~/dreamcast-toolchain/dc/` is GCC pass-1 only
(no newlib/libkallisti); it cannot link. Use the Docker build below.

## Build (bootable CDI + ELF)

`scripts/build_dreamcast_cdi.sh` runs the full pipeline: `nim --compileOnly` on
the host → `sh-elf-gcc` compile+link in Docker → raw binary → `scramble` →
`makeip` (IP.BIN) → `mkisofs` (ISO) → `cdi4dc` (CDI).

```bash
./scripts/build_dreamcast_cdi.sh verify/dreamcast/dreamcast_smoke.nim
# → dreamcast_smoke.elf  and  dreamcast_smoke.cdi
```

Optional env knobs (debugging the SH-4 codegen, configy-cbj): `DC_OPT=-O0`
(GCC opt), `DC_RELEASE=--checks:on` (Nim debug/checks), `DC_NIMFLAGS=--opt:none`.

## Running + capturing serial

Flycast has no file picker; pass the image on the command line. KOS serial is
captured via a pseudo-terminal — set `Debug.SerialConsoleEnabled = yes` AND
`Debug.SerialPTY = yes` in `~/Library/Application Support/Flycast/data/emu.cfg`
(macOS). On launch Flycast logs `Pseudoterminal is at /dev/ttysNNN`; read it:

```bash
/Applications/Flycast.app/Contents/MacOS/flycast dreamcast_smoke.elf &  # or the .cdi
# Grab the PTY path Flycast prints, then in another shell:
cat /dev/ttysNNN
```

The smokes **broadcast their report on a loop** (with `flushFile(stdout)`): a
one-shot echo+exit is uncatchable because KOS runs `main()` to completion in
milliseconds — before any host reader can attach — then exits, and newlib's
stdout is block-buffered on the non-TTY SCIF. The loop lets a reader attach at
any time and capture a complete `RESULT=` line.

## 1. Read-path gate (`dreamcast_smoke`) — PASSES

Verifies `configFileExists` / `readConfigJson` do not raise on a VMU with no
`probe.json`. Observed PASS output:

```
== configy Dreamcast read-path gate ==
vmu_present=true
vmu_free_blocks=200
configyFsWritable=false
resolved_path=/vmu/a1/smoketest/dcsmk/probe.json
exists_ok=true
exists=false
read_ok=true
read_isNone=true   ← probe.json absent → none()
RESULT=PASS
```

PASS criteria: `exists_ok=true`, `read_ok=true`, `read_isNone=true`.
(`configyFsWritable` now reports `true`; the snippet above predates that flip.)

## 2. Write-path gate (`dreamcast_write_smoke`) — PASSES

Requires `configyFsWritable=true` for dreamcast (now the default — configy-6b6).
Built as above and run on Flycast + redream, all steps PASS:

```
== configy Dreamcast write-path gate ==
vmu_present=true
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
RESULT=PASS
```

EMULATOR-ONLY: verified on Flycast + redream, not yet on real Dreamcast hardware.

## VMU slot

Both tests use slot **a1** (port 0, unit 1). In Flycast: Settings → VMU → add a
VMU to Port A1 before running.

## configy-cbj — SH-4 VMU heap corruption (RESOLVED)

Symptom: a VMU **read of an existing file** followed by an allocation-heavy op
(Snappy `compress` / `parseJson`) hung the next `malloc`; the write round-trip
hung at `write_json_z`.

How it was isolated (all on emulator, serial-captured):
- `write→read(existing)→write` hangs; hang point moves across binaries but is
  deterministic within one → **layout-sensitive heap corruption**.
- Reproduces on **both** Flycast and redream → not an emulator artifact.
- Not compression, not the double-read, not the C→Nim `copyMem` alignment.
- A **pure-C** control (same KOS VMU FFI, no Nim) is CLEAN → not a KOS bug.
- A **minimal Nim** control (generic C `malloc`/`free` + Nim allocs) is CLEAN →
  not generic FFI interleaving. The bug needs the real VMU FFI **and** the Nim
  runtime together.

Root cause: with `-d:useMalloc`, Nim's ARC allocations and KOS's VMU/maple-DMA
buffers (the `malloc`'d target of a maple DMA read in `vmufs_read`) share ONE
newlib heap; the VMU read path corrupts adjacent Nim heap chunks.

Fix: drop `-d:useMalloc` for the dreamcast target in `nim.cfg` (keep
`nimAllocPagesViaMalloc`), giving Nim its own page allocator separate from KOS's
C/DMA-buffer heap. Validated against layout-luck: passes on Flycast + redream,
`--opt:size` and `--opt:none`, and with injected arena-perturbing allocations;
re-enabling `-d:useMalloc` deterministically reproduces the hang. 3DS/Vita keep
`-d:useMalloc` (real filesystems, no maple DMA).

## Wiring

```
dreamcast_smoke.nim        ← configy-h86 (PASS, closed)
dreamcast_write_smoke.nim  ← configy-4xb (PASS) → unblocked configy-6b6 (flag flipped)
                             after configy-cbj fix (drop -d:useMalloc)
```
