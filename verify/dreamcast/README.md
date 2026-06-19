# Dreamcast Smoke Tests — Flycast Verification Steps

Two gates: a **read-path** smoke and a **write-path** smoke. Both output to
stdout (KOS serial → Flycast serial terminal). Check the serial terminal for
PASS/FAIL lines.

## Prerequisites

- Docker running with the `haydenkow/nu_dckos` image (complete KOS + sh-elf-gcc 4.7.3)
- `nim` in PATH on the host (generates C; the Docker container compiles + links)
- [Flycast](https://github.com/flyinghead/flycast) installed (can load ELF directly)

**Note:** The native KOS toolchain at `~/dreamcast-toolchain/dc/` is GCC pass-1 only
(no newlib/libkallisti). Use `scripts/build_dreamcast_docker.sh` for actual builds.

## 1. Read-path gate (`dreamcast_smoke.elf`)

Verifies that `configFileExists` and `readConfigJson` do not raise on a Dreamcast
with no (or an empty) VMU at slot a1.

```bash
# Build (two-phase: nim→C on host, sh-elf-gcc+KOS link in Docker)
./scripts/build_dreamcast_docker.sh verify/dreamcast/dreamcast_smoke.nim

# Run in Flycast (direct ELF boot)
flycast -elf dreamcast_smoke.elf

# Expected serial output (key lines):
# vmu_present=true (or false if no VMU in slot a1)
# exists_ok=true
# read_ok=true
# read_isNone=true   ← probe.json absent → none()
```

PASS criteria:
- `exists_ok=true` (no exception from `configFileExists`)
- `read_ok=true` (no exception from `readConfigJson`)
- `read_isNone=true` (absent file returns none, not an exception)

## 2. Write-path gate (`dreamcast_write_smoke.elf`)

Verifies the full VMU write round-trip. Requires `configyFsWritable=true` for
dreamcast (tracked in `configy-6b6` — flip `capabilities.nim` line 41 from
`false` to `true` before this gate).

```bash
# Flip configyFsWritable for dreamcast in src/configy/capabilities.nim line 41:
#   elif defined(dreamcast):  true  # TEMP: Flycast write-path smoke (configy-4xb)
# (Revert to false after the smoke passes — the permanent flip is configy-6b6)

# Build (Docker-based; nim on host, sh-elf-gcc+KOS link in Docker)
./scripts/build_dreamcast_docker.sh verify/dreamcast/dreamcast_write_smoke.nim

# Run in Flycast with a VMU inserted at slot a1
flycast -elf dreamcast_write_smoke.elf
```

Expected serial output (all steps PASS):

```
== configy Dreamcast write-path gate ==
vmu_present=true
vmu_free_blocks=<N>
configyFsWritable=true
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

When `configyFsWritable=false` (default before configy-6b6), write steps report
`FAIL:writeConfigJson: target is read-only` — this is expected.

## VMU slot

Both tests use slot **a1** (port 0, unit 1) — the standard Dreamcast save VMU
slot. In Flycast: Settings → VMU → add a VMU to Port A1 before running.

## Wiring

```
dreamcast_smoke.nim      ← configy-h86 (run on Flycast)
dreamcast_write_smoke.nim ← configy-4xb (run on Flycast, gates configy-6b6)
```

After all write steps PASS on Flycast, flip `configyFsWritable=true` for
dreamcast in `capabilities.nim` and close `configy-6b6`.
