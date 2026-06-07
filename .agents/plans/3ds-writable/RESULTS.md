# 3DS Write Gate — Results

**Status: ✅ VERIFIED ON REAL 3DS HARDWARE** (with the `-d:ds3` `createDirTree` shim).
`configyFsWritable=true` for ds3; the full write round-trip passes on a physical 3DS.
The crux was decided on hardware: stock `std/os.createDir` FAILS (EINVAL on the bare
`sdmc:/` device root); the `createDirTree` shim that skips the root is required and
confirmed working. Azahar masked the failure entirely (host passthrough) — only the
device settled it.

- **Date:** 2026-06-07
- **Toolchain:** devkitARM release 66, `arm-none-eabi-gcc` 15.1.0; `3dsxtool`
- **Emulator:** Azahar (Citra fork)
- **Branch:** `feat/3ds-writable` (stacked on `feat/vita-writable`)

## Build (Phase 1) — ✅

`scripts/build_3ds_write.sh`: Nim compiled `-d:ds3` with the write surface (`createDir`,
`removeFile`→`unlink`) now linked; `arm-none-eabi-gcc` linked a static ARM ELF with no
unresolved symbols (the delete path resolves from newlib); `3dsxtool` packaged
`ds3_write_smoke.3dsx`.

## Azahar logic smoke (Phase 2a) — ✅ all PASS

```
ensure_create=PASS   ensure_again=PASS
write_json=PASS      read_json=PASS
write_json_z=PASS    read_json_z=PASS
write_bytes=PASS     read_bytes=PASS
delete=PASS          deleted_gone=PASS
cleanup=PASS         isWritable=true
```
Confirms round-trip *logic* (create/write/read/compress/delete) under stock `createDir`.
**Caveat:** Azahar's SD is host passthrough — `mkdir`/`stat` on the bare `sdmc:/` root
behave like the host FS, NOT libctru's sdmc devoptab + Horizon FS. This does NOT settle
the crux.

## Real 3DS hardware (Phase 2b, the decider) — stock `createDir` FAILED → shim shipped

Ran on a physical 3DS (3 times). **Stock `std/os.createDir` FAILS** — the crux fired
exactly as predicted:
```
ensure_create=FAIL:ensureConfigDir failed for sdmc:/config/smoketest/wsmoke/: Invalid argument
Additional info: sdmc:/
```
libctru's sdmc devoptab rejects `mkdir`/`stat` on the bare `sdmc:/` device root with
**EINVAL (not EEXIST)**, so `createDir`'s first op raises and the whole write surface
fails. This is precisely why Azahar (host passthrough → `mkdir("sdmc:/")` hits an
existing host dir → EEXIST → tolerated) passed while hardware failed. **Azahar masked
the crux completely; only the device settled it** — vindicating the decision to commit
to a hardware run.

**Resolution: shipped the `-d:ds3` `createDirTree` contingency** (`fs.nim`) — creates
only the real subdirs under the device root (`sdmc:/config`, …/`<vendor>`, …/`<app>`)
via single-level `existsOrCreateDir`, never touching bare `sdmc:/`. Routed in via the
existing `ensureConfigDir` call sites (both overloads). Rebuilt; Azahar sanity of the
shim is all-PASS (it doesn't regress the logic). The new `.3dsx` is staged on the card.

## Real 3DS hardware — shim re-run (Phase 2b') — ✅ all PASS

Re-ran `ds3_write_smoke.3dsx` (with the `createDirTree` shim) on the physical 3DS.
Marker read back from the card:
```
ensure_create=PASS   ensure_again=PASS
write_json=PASS      read_json=PASS
write_json_z=PASS    read_json_z=PASS
write_bytes=PASS     read_bytes=PASS
delete=PASS          deleted_gone=PASS
cleanup=PASS         isWritable=true
```
→ on real hardware, the shim creates the nested `sdmc:/config/smoketest/wsmoke/` tree
(nested `mkdir` + dir-`stat` on Horizon FS — never the bare root), the full read/write
round-trip works (raw + compressed), `deleteConfig` removes the file, and
`configFileExists` is false afterward. No crash dump. **3DS writes are verified on real
hardware.** (`deleteConfig` removes files only — the empty `wsmoke/` dir remains, as
designed.)

**Crux verdict (final):** stock `std/os.createDir` fails on the bare `sdmc:/` root
(EINVAL); the `-d:ds3` `createDirTree` shim (skip the device root, single-level
`existsOrCreateDir` per real subdir) is required and confirmed working on hardware.

---

(Original capture template below — fill remaining fields after the hardware run.)

Mirrors [`../vita-writable/RESULTS.md`](../vita-writable/RESULTS.md).

> **Going in:** the 3DS read path is Azahar-verified (not yet hardware), a leaf
> `writeFile` to `sdmc:/` already works (the read smoke's marker), and `supersnappy`
> compiles for ds3. The unproven, harder-than-Vita part is **directory creation under
> `sdmc:/`**: stock `std/os.createDir` mkdir's/stats the bare `sdmc:/` device root first
> (confirmed via `parentDirs`), which can't be settled statically (libctru ships
> compiled) and which Azahar's host-passthrough SD masks. **With hardware available this
> is a one-run experiment:** build with stock `createDir`, run on a real 3DS. If the
> device-root op is tolerated -> keep stock (no 3DS special case). If fatal -> ship the
> `createDirTree` contingency. Note dir-`stat` on `sdmc:` is itself new (the read gate
> only proved *file*-stat), so the hardware run validates it either way.

When executed, record:

- **Date / toolchain / emulator / hardware** — devkitARM + `arm-none-eabi-gcc` version;
  libctru version; `3dsxtool`; Azahar version; the 3DS model/CFW used.
- **Flip** — `configyFsWritable` true for ds3; psp confirmed still false; Vita unchanged.
- **Build** — links via `arm-none-eabi-gcc`; `.3dsx` packaged; `removeFile`->`unlink`
  (newly referenced vs the read build) links cleanly.
- **THE CRUX — record the hardware verdict:** with **stock `createDir`**, did the
  write-smoke create the nested `sdmc:/config/smoketest/wsmoke/` tree on a real 3DS
  (i.e. is `mkdir`/`stat` on the bare `sdmc:/` root tolerated by libctru's sdmc
  devoptab)?
  - **PASS** -> keep stock `createDir`; no ds3 special case shipped.
  - **FAIL** -> added the `createDirTree` contingency (helper at the existing call site;
    `existsOrCreateDir` per real subdir; both overloads), rebuilt, re-ran on hardware.
  Record which, with the actual error if it failed.
- **Azahar marker** — paste it; expect all PASS, `isWritable=true`. Logic smoke only —
  does NOT exercise Horizon FS dir/delete semantics.
- **Real-hardware marker** — paste it (the gold check). Expect all PASS.
- **Read smoke on hardware (opportunistic)** — re-ran `ds3_smoke.3dsx` on the device to
  retire the read gate's Azahar-only status; record the outcome.
- **Regression** — `nim check -d:ds3`, desktop `nimble test`, all `--compileOnly` rows
  green; read contract unchanged; psp/wasm writes still raise `ConfigUnsupportedError`.
- **Version / docs** — `configy.nimble` bumped `0.3.0` -> `0.4.0`; behavior change noted.

## Known limitations to record (pre-existing, cross-platform — name, don't fix here)

- **Non-atomic writes.** `storeBytes`->`writeFile` is not atomic; a power-loss mid-write
  leaves a truncated file, and the next `readConfigJson` raises `ConfigParseError` (not
  `none()`). More reachable on a handheld users power off abruptly — a corrupt config is
  not self-healing. (Out of scope.)
- **No concurrent-writer safety** — single-process homebrew; acceptable, just don't
  claim otherwise.
- **Test-artifact idempotency** — the write-smoke deletes its own `z.json`/`b.bin` so a
  stale file can't mask a re-run; the `wsmoke/` dir + marker remain (clean the card
  manually if desired).

## Reproduce (once artifacts exist)

```sh
./scripts/build_3ds_write.sh
open -a Azahar ./ds3_write_smoke.3dsx
cat "$HOME/Library/Application Support/Azahar/sdmc/configy_write_smoke_result.txt"
# Hardware (the decider): copy ds3_write_smoke.3dsx to the SD, run via Homebrew
# Launcher, read sdmc:/configy_write_smoke_result.txt off the card.
```
