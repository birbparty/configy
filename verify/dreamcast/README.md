# Dreamcast Smoke Tests — Flycast Verification Steps

Two gates: a **read-path** smoke and a **write-path** smoke. Both output to
stdout (KOS serial → Flycast serial terminal). Check the serial terminal for
PASS/FAIL lines.

## Prerequisites

- KOS toolchain installed (`sh-elf-gcc`, `KOS_BASE`, `KOS_CC_BASE`)
- [Flycast](https://github.com/flyinghead/flycast) built with serial support
- A GD-ROM image tool (e.g. `mkdcdisc`) if booting from CDI (optional for
  Flycast, which can load ELF directly via `flycast -elf dreamcast_smoke.elf`)

## 1. Read-path gate (`dreamcast_smoke.elf`)

Verifies that `configFileExists` and `readConfigJson` do not raise on a Dreamcast
with no (or an empty) VMU at slot a1.

```bash
# Build
./scripts/build_dreamcast.sh

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
# Flip configyFsWritable for dreamcast in src/configy/capabilities.nim:
#   elif defined(dreamcast):  true  # flipped after Flycast round-trip (configy-6b6)

# Build
./scripts/build_dreamcast_write.sh

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
