# Dreamcast Smoke Tests — Flycast Verification Steps

Two gates: a **read-path** smoke and a **write-path** smoke. Both broadcast their
result on KOS serial; capture it from the host via Flycast's serial pseudo-terminal.

- **Read-path (`dreamcast_smoke`)**: PASSES on Flycast (2026-06-19).
- **Write-path (`dreamcast_write_smoke`)**: HANGS at `write_json_z` — blocked by
  **configy-cbj** (SH-4 VMU heap corruption). See the bottom of this file.

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

Note: this exercises the ABSENT-file path (`vmufs_read` returns <0, no buffer is
allocated). Reading an EXISTING VMU file returns correct bytes but triggers the
configy-cbj heap corruption — so the read path is proven safe only for absent
files until cbj is fixed.

## 2. Write-path gate (`dreamcast_write_smoke`) — BLOCKED (configy-cbj)

Requires `configyFsWritable=true` for dreamcast (`capabilities.nim` line 41).
With the flag flipped and built as above, this gate **hangs at `write_json_z`**:

```
== configy Dreamcast write-path gate ==
vmu_present=true
ensure_create=PASS
ensure_again=PASS
write_json=PASS
read_json=PASS
<HANG at write_json_z — no further output>
```

Do NOT flip `configy-6b6` until **configy-cbj** is resolved.

When `configyFsWritable=false` (current default), the write steps instead report
`FAIL:writeConfigJson: target is read-only` — expected.

## VMU slot

Both tests use slot **a1** (port 0, unit 1). In Flycast: Settings → VMU → add a
VMU to Port A1 before running.

## configy-cbj — SH-4 VMU heap corruption (the write-path blocker)

A VMU **read of an existing file** followed by an allocation-heavy op (Snappy
`compress` or `parseJson`) reliably hangs the next `malloc`. Diagnosis:

- Four consecutive writes (no reads) PASS; `write → read(existing) → write` hangs.
- The hang point moves across binaries but is deterministic within one binary →
  **layout-sensitive heap corruption**.
- NOT fixable by build flags: persists at GCC `-O0`, Nim `--opt:none`, `--checks:on`.
- NOT a configy logic bug: `vmufs_read` malloc/`c_free` balanced; `vmu_pkg_parse`
  is memory-safe; Nim `VmuPkg` matches KOS `vmu_pkg_t` exactly (importc).
- Likely root: the `--cpu:arm` proxy codegen for SH-4 + Nim ARC + `-d:useMalloc`
  (shared KOS malloc heap), or a KOS allocator quirk — a platform-level risk
  already flagged in `nim.cfg`.

## Wiring

```
dreamcast_smoke.nim        ← configy-h86 (PASS, closed)
dreamcast_write_smoke.nim  ← configy-4xb (blocked by configy-cbj → gates configy-6b6)
```
