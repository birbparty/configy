# Vita Write Gate — Results

**Status: ✅ VERIFIED IN VITA3K (hardware run staged, pending)** — `configyFsWritable`
flipped to `true` for `-d:vita`; the full write round-trip passes in Vita3K. The crux
(`std/os.createDir` over `ux0:`, incl. the already-exists path) resolved **positively**.
Real-hardware run is staged (vpk on the card) and pending the device.

- **Date:** 2026-06-06
- **Machine:** macOS (Apple Silicon), Nim 2.2.10
- **Toolchain:** VitaSDK `/usr/local/vitasdk`; `arm-vita-eabi-gcc` 15.2.0; `vita-*` tools
- **Emulator:** Vita3K v0.2.1
- **Branch:** `feat/vita-writable`

## Build (Phase 1) — ✅

`scripts/build_vita_write.sh` (→ `build_vita.sh verify/vita/vita_write_smoke.nim CFGW00001`):
Nim compiled `-d:vita` with `configyFsWritable=true` (write surface — `createDir`,
`writeFile`, `removeFile` — now compiled in); `arm-vita-eabi-gcc` linked a static ARM
ELF with **zero unresolved symbols** (confirms `removeFile`→`sceIoRemove`, newly
referenced vs the read build, resolves from the existing `SceIofilemgr_stub`);
`vita-elf-create` passed; `vita_write_smoke.vpk` produced.

## Vita3K runtime (Phase 2) — ✅ all steps PASS

`Vita3K -r CFGW00001`; marker read back from the host `ux0` dir:
```
ensure_create=PASS
ensure_again=PASS          <-- crux: createDir over ux0:, already-exists path
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
```

**Crux verdict (Vita3K): RESOLVED POSITIVELY.** `std/os.createDir` creates the nested
`ux0:data/config/smoketest/wsmoke/` tree and tolerates the already-exists path on the
second `ensureConfigDir` call — matching the static analysis (newlib maps
`sceIoMkdir`'s already-exists error → `EEXIST`, which `createDir` tolerates). No
`sceIoMkdir` shim needed.

## Real hardware (Phase 2 gold check) — ⏳ staged, pending

Vita3K's FS is host-passthrough and more forgiving than the device `sceIo`/exFAT stack
on exactly these edge cases (already-exists, nested create, delete), so hardware is the
gold check. `vita_write_smoke.vpk` has been copied to the card (`ux0:/`); to run:
install it via VitaShell, launch **configy vita_write_smoke** (`CFGW00001`), then read
back `ux0:/data/configy_write_smoke_result.txt` (expect the same all-PASS marker).
Tracked in configy-61d.

When executed, record:

- **Date / toolchain / emulator / hardware** — VitaSDK + `arm-vita-eabi-gcc` version;
  Vita3K version; whether a real Vita was used.
- **Flip** — `configyFsWritable` true for vita; ds3/psp confirmed still false.
- **Build** — links to ARM ELF; `vita-elf-create` passes; `.vpk` produced; whether
  any new `Sce*` stub was needed beyond the read build's set (expected: none).
- **THE CRUX — record the hardware outcome:** did `std/os.createDir` work over `ux0:`,
  including the already-exists `ensure_again` step? (Static analysis already confirms
  the newlib EEXIST translation — see [`plan.md`](./plan.md) "The crux"; what hardware
  settles is whether the kernel `sceIoMkdir` actually emits `0x80010011`/`EEXIST` on an
  already-existing directory.)
  - **Yes** (expected) → flip stands as-is; no shim.
  - **No** (mkdir/OS error on an existing prefix or on nested create) → add the
    `dirExists`-guarded `sceIoMkdir` `ensureConfigDir` shim under `-d:vita` (NOT a
    blind "treat the already-exists code as success" — that fails identically); record
    it.
- **Vita3K marker** — paste it; expect all steps PASS, `isWritable=true`.
- **Real-hardware marker** — paste it (gold check); expect all PASS incl.
  `ensure_again` and the compressed (`MagicSnappy`) round-trip.
- **Regression** — `nim check -d:vita`, desktop `nimble test`, all `--compileOnly`
  rows green; read-path contract unchanged; ds3/psp writes still raise
  `ConfigUnsupportedError`.
- **Version / docs** — `configy.nimble` bumped to `0.3.0`; behavior change noted.
- **Any new findings** (the read run surfaced the `-r` GUI-flakiness and the headless
  "opens-and-closes" shape — expect FS-edge findings here: already-exists, nested
  create, delete-then-exists).

## Known limitations to record (pre-existing, cross-platform — name, don't fix here)

- **Non-atomic writes.** `storeBytes` → `writeFile` (`store.nim:18-28`) is not atomic.
  A crash/power-loss mid-write leaves a truncated file, and the *next* `readConfigJson`
  then raises `ConfigParseError` (bad magic / corrupt Snappy), NOT `none()`. This is
  pre-existing and affects all targets, but enabling writes on a console users power
  off abruptly makes it more reachable. (A future write-temp-then-rename would fix it;
  out of scope here.)
- **No concurrent-writer safety.** Single-process homebrew, so acceptable — just don't
  claim safety the code doesn't provide.
- **Test-artifact idempotency.** The write-smoke deletes its own `z.json`/`b.bin` at
  the end (`cleanup` step) so a stale file from a prior run can't make a re-run's
  read-back pass on old data. The `wsmoke/` dir and marker remain; note manual card
  cleanup if desired. Re-runs are otherwise idempotent (the already-exists path is the
  point).

## Reproduce (once artifacts exist)

```sh
./scripts/build_vita_write.sh            # or: build_vita.sh <src> <titleid>
# Vita3K:
VBIN=/Applications/Vita3K.app/Contents/MacOS/Vita3K
unzip -o vita_write_smoke.vpk -d "<Vita3K ux0>/app/CFGW00001"
"$VBIN" -r CFGW00001 --log-level 1       # retry if it opens the GUI
cat "<Vita3K ux0>/data/configy_write_smoke_result.txt"
# Hardware: install the .vpk, run it, read ux0:/data/configy_write_smoke_result.txt off the card.
```
