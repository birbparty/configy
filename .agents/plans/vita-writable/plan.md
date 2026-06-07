# Make Vita Writable (configy)

## Metadata

| Field | Value |
|-------|-------|
| Requested by | User ("come up with a plan to make vita writable") |
| Date | 2026-06-06 |
| Priority | **Low — non-blocking** (no known Vita persistence consumer today) |
| Target repo | `~/git/configy` (`github.com/birbparty/configy`) |
| Builds on | [`../vita-support/`](../vita-support/) — the read-path gate, ✅ verified on real hardware |
| Companion docs | [`verification-gate.md`](./verification-gate.md) — write-gate design · [`RESULTS.md`](./RESULTS.md) — **outcome (✅ Vita3K + real hardware, all-PASS)** |
| Status | **VERIFIED ON HARDWARE 2026-06-06** (`feat/vita-writable`): `configyFsWritable=true` for vita; write round-trip (create/write/read/compress/delete) all PASS in Vita3K **and on a physical PS Vita**; crux confirmed on-device. v0.3.0. See [`RESULTS.md`](./RESULTS.md). |

---

## Bottom line (read first)

The Vita read path is fully verified (compile → link → `vita-elf-create` → `.vpk` →
Vita3K → **real hardware**, both absent and planted cases). This plan flips Vita from
read-only to writable — i.e. makes `configyFsWritable = true` for `-d:vita` — and
verifies the write surface (`ensureConfigDir`/`createDir`, `writeConfigJson`/`Bytes`,
`deleteConfig`) to the **same evidence standard the read path was held to**
(round-trip on real hardware, not just a comment flip).

This is much smaller than the read gate because the hard parts are already proven:
the toolchain, `-Wl,-q` relocations, and — crucially — that **`std/os` file I/O
reaches `ux0:` on hardware**. We even have incidental proof a *write* works:
`vita_smoke`'s marker was written with `writeFile("ux0:data/...")` and landed on the
physical card. VitaSDK newlib backs `mkdir`/`write`/`remove` with `sceIo*`
(`sceIoMkdir`/`sceIoWrite`/`sceIoRemove` are all referenced in `libc.a`), and
`ux0:data/` is the canonical writable homebrew directory.

**The one genuinely unverified operation is directory creation** —
`std/os.createDir` walking a `ux0:`-prefixed path. That is the crux (§"The crux").

---

## Decisions (locked)

| Question | Decision |
|----------|----------|
| Default writable, or opt-in flag? | **Writable by default** for `-d:vita` (like desktop). `ux0:data/` is unambiguously writable and there is no consumer to surprise. No new compile flag. |
| Evidence standard | **Round-trip on real hardware** (write → read back → equal; create dir; delete). A comment flip alone is not acceptable — mirror the read gate's rigor. |
| Scope of the flip | **Vita only.** Do NOT touch `ds3`/`psp` — their write paths are unverified and stay `false`. |
| `createDir` approach | **Try `std/os.createDir` first** (analysis says it should work — see the crux). Only if hardware shows it fails, add a `-d:vita` `sceIoMkdir`-based shim — a contingency, not the default plan. |
| Versioning | **Minor bump** (`0.2.0` → `0.3.0`): this changes observable behavior on Vita (writes/deletes now succeed instead of raising `ConfigUnsupportedError`; `ensureConfigDir` now creates). |

---

## Current state (verified during planning)

The write surface is already fully implemented and merely *gated off* on Vita:

- `capabilities.nim:30-33` —
  `configyFsWritable = ... elif defined(ds3) or defined(psp) or defined(vita): false`.
  Vita is in the read-only set; flipping = removing `or defined(vita)`.
- `fs.nim:6-11` — `isWritable()` returns `configyFsWritable` (no runtime probe).
- `fs.nim:18-44` — `ensureConfigDir` guards `createDir` with **compile-time**
  `when configyFsWritable`. On Vita today `createDir` is compiled OUT (the proc
  returns the path without creating). Flipping compiles it IN.
- `store.nim` — `writeConfigJson`/`writeConfigBytes`/`deleteConfig` guard at
  **runtime** with `if not isWritable(): raise ConfigUnsupportedError`. Flipping
  makes them proceed.
- `store.nim:60-62` — `ensureConfigFile` = `ensureConfigDir(app[, dep]) & filename`,
  and the write APIs call `ensureConfigFile`. **So every write auto-creates its
  directory via `createDir`** — the crux below is exercised by every write, not just
  explicit `ensureConfigDir` calls.

So the flip is one line in `capabilities.nim`; the *work* is verifying the
now-compiled-in `createDir` + the now-active write/delete APIs actually function on
Vita.

---

## The crux: `std/os.createDir` over a `ux0:`-prefixed path

`writeConfigJson(app, "f.json", …)` resolves to
`ux0:data/config/<vendor>/<app>/f.json` and calls
`createDir("ux0:data/config/<vendor>/<app>/")`. What Nim's `createDir` does
(`lib/std/private/osdirs.nim`):

1. `omitNext = isAbsolute(dir)`. On the posix (os:linux) target `isAbsolute` means
   "starts with `/`"; `ux0:data/…` does **not**, so `omitNext = false`. (Confirmed:
   `ospaths2.nim` posix branch is `path[0] == '/'`.)
2. It iterates `parentDirs(dir, fromRoot=true)` **root→leaf**, calling
   `existsOrCreateDir(p)` per prefix. `:` is not a separator and there is no `/`
   between `ux0:` and `data`, so the first component is **`ux0:data/`** (trailing
   slash from `configDir`) — it never `mkdir`s a bare `ux0:` device root. Root→leaf
   order means each parent exists before its child. Subsequent: `…/config`,
   `…/<vendor>`, `…/<app>`.
3. `existsOrCreateDir` → `rawCreateDir` → posix `mkdir(p, 0o777)`. On `EEXIST` it
   treats the dir as already-present (then `dirExists` confirms); on any **other**
   errno it `raiseOSError`. (`mkdir` first runs `__realpath`, then `sceIoMkdir`.)

**Static analysis resolves most of this in our favor** (disassembly of the installed
VitaSDK `libc.a`, corroborated by the headers):

- `mkdir → _mkdir_r → sceIoMkdir`; on error `_mkdir_r` calls
  `__vita_sce_errno_to_errno`, which (for this call form) returns the **low byte** of
  the SCE error (`sceErr & 0xFF`) with no lookup table. The Sce errno family is
  `0x8001_00XX` where `XX` is the POSIX errno (the header example `0x80010018` =
  `EMFILE` 24 confirms the convention). So `SCE_ERROR_ERRNO_EEXIST` (`0x80010011`) →
  `0x11` = **17** = `EEXIST` (`sys/errno.h:41`) — exactly what `rawCreateDir`'s posix
  branch tolerates. **newlib does not mistranslate the code.**
- `_unlink_r` (backing `removeFile`/`deleteConfig`) and `_open_r`/`_stat_r` (read
  path, already hardware-proven) route through the **same** `__realpath` +
  errno-translate layer, so `createDir`/delete inherit path-prefix handling already
  proven to work on `ux0:` on hardware. **No new path-prefix risk.**

**The one piece NOT statically provable** lives in the kernel `iofilemgr` module, not
`libc.a`: that `sceIoMkdir` actually *returns* `0x80010011` when the directory already
exists. (`SCE_ERROR_ERRNO_EEXIST` isn't even in the SDK headers — it's conventional.)
`ux0:data/` (and often `…/config/`, `…/<vendor>/`) always exist, so `mkdir` is called
on them on **every** write and relies on that code → `EEXIST`. So:

- **Static check (done at plan time):** the newlib EEXIST translation is confirmed;
  no `mkdir`-of-bare-`ux0:`, no path-prefix risk. This **narrows but does not
  eliminate** the unknown — it does not replace the hardware run.
- **Definitive check (Phase 2, hardware):** `ensureConfigDir` is called twice; the
  already-exists prefixes are mkdir'd on the first call too, and `ensure_again`
  additionally exercises the exists path for the leaf. A clean PASS confirms
  `sceIoMkdir` emits the conventional code.

**Fallback (contingency only):** if hardware shows `createDir` raising on an
already-exists component, add a `-d:vita` `ensureConfigDir` branch in `fs.nim` that
walks the tree and, **before each `sceIoMkdir`, does a `dirExists(p)` pre-check —
skipping/ignoring the mkdir when the dir already exists**. (Do NOT instead "treat the
Sce already-exists code as success": that relies on the *same* unconfirmed return
code `std/os.createDir` relies on, so it would fail identically. The `dirExists`
guard is what actually de-risks it — `stat`/`dirExists` on `ux0:` is already proven by
the read gate.) File it as its own issue; do not expand scope silently.

---

## Behavior change / contract impact

This is a deliberate, observable change on Vita (hence the minor version bump):

| API | Vita today (read-only) | After flip (writable) |
|-----|------------------------|-----------------------|
| `isWritable()` | `false` | `true` |
| `ensureConfigDir(app[, dep])` | returns path, **does not create** | returns path, **creates the tree** (may raise `ConfigIOError`) |
| `writeConfigJson` / `writeConfigBytes` | raises `ConfigUnsupportedError` | writes the file |
| `deleteConfig` | raises `ConfigUnsupportedError` | removes the file |
| read APIs (`readConfigJson`, `configFileExists`, …) | unchanged | unchanged |

**Invariants to preserve** (the existing contract, do not break):
1. Read APIs still never raise on an absent file (`none()` / `false`).
2. The four error types stay exported and stable; writes still raise
   `ConfigUnsupportedError` on the *other* read-only targets (ds3/psp/wasm).
3. `isWritable()` remains the single source of truth consumers branch on — now it
   reports `true` for Vita, which is the whole point.

---

## Out of scope (do NOT do)

- **Do not** flip `ds3` or `psp` — unverified; they stay `false`.
- **Do not** change the read path or its already-verified gate.
- **Do not** add directory *removal* / empty-dir cleanup semantics to `deleteConfig`
  (it removes the file only, same as every other target) — out of scope.
- **Do not** ship the flip without the hardware round-trip (no comment-only "done").

---

## Phased task breakdown

### Phase 0 — Flip + author the write-smoke (no toolchain needed) ✅ DONE
- [x] `capabilities.nim`: removed `or defined(vita)` from the read-only `elif`
      (→ `elif defined(ds3) or defined(psp): false`); rewrote the Vita comment
      (writable; Vita3K-verified; hardware pending).
- [x] Added `verify/vita/vita_write_smoke.nim` (read smoke untouched); uses `check`
      (CatchableError) not `doAssert`; marker via writeFile + raw sceIo.
- [x] Parametrized `scripts/build_vita.sh` (optional src + TITLE_ID) + added thin
      `scripts/build_vita_write.sh` (`CFGW00001`). `.gitignore` updated.
- [x] `nim check -d:vita` clean; desktop `nimble test` green; `--compileOnly` for
      ds3/psp/vita/wasm all green (ds3/psp still read-only).

### Phase 1 — Build/link (VitaSDK) ✅ DONE
- [x] Built the write-smoke: static ARM ELF, `vita-elf-create` passed, `.vpk`
      produced, zero unresolved symbols (`sceIoRemove` resolved from existing stub).

### Phase 2 — Run the write round-trip ✅ Vita3K DONE; ⏳ hardware staged
- [x] Vita3K: all steps PASS, `isWritable=true`; crux resolved positively (no shim).
- [x] Real hardware (gold check): installed `CFGW00001` via VitaShell, ran it — all
      steps PASS on the device; crux confirmed on-device; no coredump.

### Phase 3 — Land it ✅ DONE
- [x] Shim not needed — crux resolved positively in Vita3K and confirmed on hardware.
- [x] Bumped `configy.nimble` `0.2.0` → `0.3.0`; updated README platform-table Vita note.
- [x] Wrote [`RESULTS.md`](./RESULTS.md).
- [x] Hardware run passed; updated `capabilities.nim`/RESULTS/plan wording to
      "hardware-verified".

---

## Suggested bd issues (create at execution time)

1. `feat: make configy writable on Vita (flip configyFsWritable, verify write round-trip)` — type=feature, p3
2. `test: add verify/vita write-smoke (ensureConfigDir/write/read-back/delete) + build script` — type=task, p3 (blocks #1's verification)
3. `chore: confirm std/os.createDir works over ux0: on Vita hardware (EEXIST mapping)` — type=task, p3 — **the crux**
4. `feat: sceIoMkdir-based ensureConfigDir shim under -d:vita` — type=feature, p4 — **CONTINGENCY ONLY** (open if #3 finds createDir fails)
5. `chore: bump configy 0.2.0 -> 0.3.0 and document Vita-writable behavior change` — type=chore, p3

---

## References

- **The read-path gate this builds on:** [`../vita-support/`](../vita-support/)
  (`plan.md`, `verification-gate.md`, `RESULTS.md` — read verified on real hardware).
- configy write-surface code: `capabilities.nim:30-33` (the flag),
  `fs.nim:6-44` (`isWritable`/`ensureConfigDir`/compile-time `createDir` gate),
  `store.nim:60-62` (`ensureConfigFile`→`ensureConfigDir`), `store.nim:72-107,152-188`
  (write APIs, runtime gate), `store.nim` `deleteConfig`.
- Nim `createDir` semantics: `lib/std/private/osdirs.nim` (`createDir` →
  `parentDirs(fromRoot)` → `existsOrCreateDir` → `rawCreateDir` → posix `mkdir`,
  `EEXIST`-tolerant).
- Incidental write proof: `vita_smoke`'s marker (`writeFile("ux0:data/...")`) landed
  on real hardware — see `../vita-support/RESULTS.md`.
- VitaSDK newlib backs `mkdir`/`write`/`remove` with `sceIo*`:
  `arm-vita-eabi-nm /usr/local/vitasdk/arm-vita-eabi/lib/libc.a | grep -E 'sceIoMkdir|sceIoWrite|sceIoRemove'`.
