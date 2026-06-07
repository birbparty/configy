# Make Nintendo 3DS Writable (configy)

## Metadata

| Field | Value |
|-------|-------|
| Requested by | User ("which other platforms do not have write capabilities?" → plan 3DS) |
| Date | 2026-06-07 |
| Priority | **Low — non-blocking** (no known 3DS persistence consumer today) |
| Target repo | `~/git/configy` (`github.com/birbparty/configy`) |
| Builds on | [`../3ds-support/`](../3ds-support/) (read gate, Azahar-verified) · pattern from [`../vita-writable/`](../vita-writable/) (write gate, hardware-verified) |
| Companion docs | [`verification-gate.md`](./verification-gate.md) — write-gate design · [`RESULTS.md`](./RESULTS.md) — **outcome (✅ Azahar logic smoke; real-hardware decider pending)** |
| Status | **VERIFIED ON HARDWARE 2026-06-07** (`feat/3ds-writable`, stacked on `feat/vita-writable`): `configyFsWritable=true` for ds3; write round-trip all PASS on a physical 3DS. Crux decided on-device: stock `createDir` FAILS (EINVAL on bare `sdmc:/`) → shipped the `-d:ds3` `createDirTree` shim (skips the device root), confirmed working on hardware. v0.4.0. See [`RESULTS.md`](./RESULTS.md). |

---

## Bottom line (read first)

This makes configy writable on Nintendo 3DS — flip `configyFsWritable` to `true` for
`-d:ds3` and verify the write surface (`ensureConfigDir`/`createDir`,
`writeConfigJson`/`Bytes`, `deleteConfig`). It mirrors the just-completed
[Vita-writable effort](../vita-writable/) — **but 3DS is NOT a copy-paste of Vita**,
because of one path-shape difference that lands directly on the crux.

The 3DS read path is verified (compiles/links/runs on devkitARM + Azahar) and a leaf
`writeFile` to `sdmc:/` already works (the read smoke writes its marker there). What is
unproven — and **harder to prove than it was on Vita** — is **directory creation**,
specifically that `std/os.createDir` over a `sdmc:/`-prefixed path works on real 3DS
hardware. Two facts make this the central risk:

1. **`createDir` will `mkdir`/`stat` the bare `sdmc:/` device root first** (empirically
   confirmed — see "The crux"). On Vita the analogous path (`ux0:data/...`) had no
   slash after the colon, so the first component was a real subdir, never the device
   root. On 3DS (`sdmc:/config/...`) the device root is unavoidable with stock
   `createDir`.
2. **It can't be settled statically** — libctru ships compiled (no `sdmc_dev.c` in the
   devkitPro install to inspect, unlike VitaSDK's `libc.a` which we disassembled), so
   how its sdmc devoptab maps `mkdir`/`stat` on the root and on existing dirs is opaque.
   And **Azahar's SD is a host passthrough** that will almost certainly accept
   `mkdir("sdmc:/")`/`stat("sdmc:/")` regardless of how real Horizon FS behaves — so the
   emulator can't answer it either. (The 3DS read gate was Azahar-only; its reads also
   await a hardware run — cheap to retire opportunistically here, see Phase 2.)

**Hardware is available, which changes the approach.** Rather than pre-committing to a
bespoke code path, the crux becomes a **one-run on-device experiment**: build the
write-smoke with stock `std/os.createDir` and run it on a real 3DS. If the device-root
`mkdir`/`stat` is tolerated → keep the desktop/Vita code path, no 3DS special case
(simpler, one path). If it's fatal → ship a small `-d:ds3` `ensureConfigDir` that
creates only the real subdirectories under the device root (never touching bare
`sdmc:/`) — fully designed as a ready contingency in
[`verification-gate.md`](./verification-gate.md). See "The crux" + Decisions.

There is **no known 3DS persistence consumer**, so nothing here is on a critical path.

---

## Decisions (locked)

| Question | Decision |
|----------|----------|
| Default writable, or opt-in? | **Writable by default** for `-d:ds3` (like desktop/Vita). `sdmc:/` is writable; no consumer to surprise. No new compile flag. |
| Rely on stock `std/os.createDir`? | **Decide on hardware (test-first).** Build with stock `createDir` and run on a real 3DS. If the device-root `mkdir`/`stat` is tolerated → keep stock (no 3DS special case). If fatal → ship the `-d:ds3` `ensureConfigDir` contingency that creates only real subdirs under the root (never bare `sdmc:/`), integrated via a `createDirTree` helper at the existing call site (NOT a redefined proc — see verification-gate). Rationale: hardware turns a permanent unknown into a one-run test; don't ship a permanent ds3-only path to dodge a risk hardware can retire. Note the shim only avoids the device *root* — it still depends on sdmc dir-`stat`, which the read gate did NOT prove (it only proved file-`stat`). |
| Evidence standard | **Round-trip on real 3DS hardware — committed (hardware is available).** Azahar is run first as a logic smoke (necessary, not sufficient — its host-passthrough SD does not exercise Horizon FS dir semantics). The claim "verified" is earned only by the hardware run; do NOT claim hardware-verified off Azahar alone. |
| Scope of the flip | **3DS only.** Do NOT touch `psp` (no real-toolchain verification at all yet) or change Vita. |
| Versioning | **Minor bump** (`0.3.0` → `0.4.0`): observable behavior change on 3DS (writes/deletes succeed instead of raising; `ensureConfigDir` now creates). |

---

## Current state (verified during planning)

The write surface is implemented and merely gated off on 3DS (identical to how Vita
was before its flip):

- `capabilities.nim` — `configyFsWritable = ... elif defined(ds3) or defined(psp): false`.
  Flipping = removing `defined(ds3)` → `elif defined(psp): false`.
- `fs.nim` — `isWritable()` returns `configyFsWritable`; `ensureConfigDir` guards
  `createDir` with **compile-time** `when configyFsWritable` (compiled OUT on 3DS today).
- `store.nim` — `writeConfigJson`/`writeConfigBytes`/`deleteConfig` guard at **runtime**
  with `if not isWritable(): raise ConfigUnsupportedError`; the write APIs call
  `ensureConfigFile` → `ensureConfigDir` → `createDir`, so **every write auto-creates
  its directory** (the crux is hit by every write, not just explicit `ensureConfigDir`).
- `paths.nim:35-36` — `configRoot()` for ds3 = `"sdmc:/config/" & vendor & "/"`.
- Read gate: `verify/ds3/{ds3_smoke.nim,ctru.nim,README.md}`, `scripts/build_3ds.sh`,
  the `@if ds3:` block in `nim.cfg` — all in place and Azahar-verified.

A leaf `writeFile` to `sdmc:/` is already proven (the read smoke writes
`sdmc:/configy_smoke_result.txt`). What is new and unproven is **nested directory
creation under `sdmc:/`** and **delete** (`removeFile`/`sceIo`-equivalent → the sdmc
devoptab `unlink`).

---

## The crux: `std/os.createDir` over a `sdmc:/`-prefixed path

`writeConfigJson(app, "f.json", …)` resolves to `sdmc:/config/<vendor>/<app>/f.json`
and calls `createDir("sdmc:/config/<vendor>/<app>/")`. Empirically (Nim 2.2.10),
`parentDirs("sdmc:/config/smoketest/app/", fromRoot=true)` yields, in order:

```
sdmc:/
sdmc:/config/
sdmc:/config/smoketest/
sdmc:/config/smoketest/app/
```

`createDir` calls `existsOrCreateDir(p)` on each. `isAbsolute("sdmc:/…")` is **false**
on the os:linux target (it doesn't start with `/`), so `omitNext = false` and the
**first** call is `existsOrCreateDir("sdmc:/")` → `mkdir("sdmc:/", 0o777)`, and on
`EEXIST` → `dirExists("sdmc:/")` (`stat`). **Both operations target the bare `sdmc:`
device root.**

This is the same mechanism as Vita, but the path shape makes it bite here:

| | Vita (`ux0:data/config/…`) | 3DS (`sdmc:/config/…`) |
|---|---|---|
| First `parentDirs` element | `ux0:data/` (a real subdir) | **`sdmc:/` (the device root)** |
| First `mkdir` target | `ux0:data` (exists → EEXIST) | **bare `sdmc:/`** |
| Statically verifiable? | Yes — disassembled VitaSDK `libc.a` (`sceIoMkdir` err → low-byte → EEXIST) | **No** — libctru ships compiled; no `sdmc_dev.c` in the devkitPro install |
| Emulator masks it? | Vita3K passthrough — somewhat | **Azahar passthrough — almost certainly yes** for the device-root case |
| Hardware run done? | Yes (read + write) | Not yet (read gate was Azahar-only) — **this gate adds the hardware run** |

So the unknowns are: does libctru's sdmc devoptab map `mkdir`-on-existing (and the
root) to `EEXIST`, and does `stat("sdmc:/")` succeed? Static tools (no source,
host-passthrough emulator) can't retire them — **but a real 3DS can, in one run.**

**Decision (locked): test stock `createDir` on hardware; ship the contingency only if
it fails.**

- **Phase 2 runs the write-smoke (built with stock `createDir`) on a real 3DS.** That
  directly exercises `mkdir("sdmc:/")`/`stat("sdmc:/")` against Horizon FS — the only
  thing that can answer the crux.
- **If it succeeds** (libctru tolerates the root op → `EEXIST`/success): keep stock
  `createDir`, no 3DS special case. Parity with desktop/Vita; nothing to maintain.
- **If it fails:** ship the `-d:ds3` contingency `ensureConfigDir` (full design in
  [`verification-gate.md`](./verification-gate.md)) that:
  1. Takes the resolved dir (`sdmc:/config/<vendor>/<app>/`).
  2. Splits off the `device:/` prefix and **never mkdir/stats the bare root**.
  3. For each cumulative real subdir (`sdmc:/config`, `…/<vendor>`, `…/<app>`):
     guards with `dirExists` and creates one level via `existsOrCreateDir` (NOT
     recursive `createDir`, which would itself recurse back to `sdmc:/`).
  Integrate it by routing the existing `createDir(result)` call site (in *both*
  `ensureConfigDir` overloads) through a `createDirTree` helper that branches
  `when defined(ds3)` — do **not** add a second `ensureConfigDir` proc (that redefines
  the existing one).

**Honest scope of what the contingency buys:** it avoids the device *root* mkdir/stat
only. It still depends on sdmc dir-`stat` for the nested components — and the read gate
proved only *file*-`stat` (`fileExists`/`readFile`), never `dirExists`. So directory
stat on `sdmc:` is new on this gate regardless of which path ships; the hardware run is
what proves it.

> Note: do NOT "fix" this by changing `configRoot` to `sdmc:config/…` (no slash) —
> that would relocate where files live (a breaking change) and contradict the
> Azahar-verified read layout. Keep the path; fix the dir-creation.

---

## Behavior change / contract impact

Same shape as the Vita flip (hence the minor bump):

| API | 3DS today (read-only) | After flip (writable) |
|-----|------------------------|-----------------------|
| `isWritable()` | `false` | `true` |
| `ensureConfigDir` | returns path, does not create | returns path, **creates the tree** (stock `createDir`, or the ds3 contingency if hardware requires it; may raise `ConfigIOError`) |
| `writeConfigJson` / `writeConfigBytes` | raises `ConfigUnsupportedError` | writes the file |
| `deleteConfig` | raises `ConfigUnsupportedError` | removes the file |
| read APIs | unchanged | unchanged |

**Invariants to preserve:** read APIs still never raise on absent files; the four error
types stay exported; writes still raise `ConfigUnsupportedError` on the remaining
read-only targets (psp/wasm); `isWritable()` stays the single capability signal.

---

## Out of scope (do NOT do)

- **Do not** flip `psp` (no real-toolchain verification yet) or change Vita.
- **Do not** change `configRoot`/the on-disk path layout (breaking; Azahar-verified).
- **Do not** add empty-dir removal to `deleteConfig` (file removal only, as on every target).
- **Do not** claim "hardware-verified" off an Azahar-only run.

---

## Phased task breakdown

### Phase 0 — Flip + write-smoke with STOCK createDir (no toolchain needed) ✅ DONE
- [x] `capabilities.nim`: remove `defined(ds3)` from the read-only `elif`
      (→ `elif defined(psp): false`); update the 3DS comment to the writable posture
      (honest about Azahar-vs-hardware). Flipping compiles the existing
      `when configyFsWritable: createDir(result)` into ds3's `ensureConfigDir` — that
      stock path is what Phase 2 tests. Do NOT add a ds3 `ensureConfigDir` yet.
- [ ] Add `verify/ds3/ds3_write_smoke.nim` (read smoke untouched) — write round-trip
      exerciser mirroring `verify/vita/vita_write_smoke.nim` (uses `check` raising a
      `CatchableError`, NOT `doAssert`; reuses `ctru.nim` for console + START-to-exit;
      marker via raw `writeFile` to `sdmc:/`, not the API under test).
- [ ] Parametrize `scripts/build_3ds.sh` (optional src + out name; preserve the read
      gate's invariants — **exit 0 when toolchain absent**, and **never `cp` over the
      tracked `nim.cfg`**) + add `scripts/build_3ds_write.sh`; `.gitignore` the
      write-smoke artifacts.
- [ ] `nim check -d:ds3` clean; desktop `nimble test` green; `--compileOnly` for
      ds3/psp/vita/wasm all green (psp still read-only).

### Phase 1 — Build/link (devkitARM) ✅ DONE
- [x] Built the write-smoke: linked a static ARM ELF via `arm-none-eabi-gcc` 15.1.0,
      packaged `ds3_write_smoke.3dsx`; the delete path (`removeFile`→`unlink`) linked
      with no unresolved symbols.

### Phase 2 — Run the write round-trip (Azahar smoke ✅, real 3DS gold check ✅)
- [x] **Azahar:** ran, marker all PASS (`isWritable=true`) — logic smoke confirmed. Its
      passthrough SD does NOT exercise Horizon FS dir semantics — not the decider.
- [x] **Real 3DS hardware (the decider):** ran the `.3dsx` — **stock `createDir` FAILED**
      (EINVAL on bare `sdmc:/`). Crux settled on-device. Azahar had masked it.
- [ ] (Opportunistic, not done) Re-run the read smoke on hardware to retire its
      Azahar-only status — deferred; not blocking the write work.
- [x] Recorded the crux verdict in RESULTS: stock failed → shipped the Phase 3 shim.

### Phase 3 — Land it (+ contingency, which Phase 2 required) ✅ DONE
- [x] Stock `createDir` failed on hardware → added the `-d:ds3` `createDirTree` helper at
      the existing `ensureConfigDir` call sites (both overloads; `existsOrCreateDir` per
      real subdir, never bare `sdmc:/`), rebuilt, **re-ran on hardware: all PASS.**
- [x] Bumped `configy.nimble` `0.3.0` → `0.4.0`; updated README platform table (3DS Write).
- [x] Wrote [`RESULTS.md`](./RESULTS.md) — hardware-verified.

---

## Suggested bd issues (create at execution time)

1. `feat: make configy writable on 3DS (flip configyFsWritable; verify write round-trip on hardware)` — type=feature, p3
2. `test: add verify/ds3 write-smoke (stock createDir) + parametrized build script` — type=task, p3
3. `chore: run 3DS write gate on real hardware — decide stock createDir vs ds3 shim (the crux)` — type=task, p2 (the decider; blocks #1)
4. `feat: -d:ds3 ensureConfigDir via createDirTree helper (skip device root)` — type=feature, p3 — **CONTINGENCY ONLY**, open iff #3 shows stock createDir fails on hardware
5. `chore: bump configy 0.3.0 -> 0.4.0 and document 3DS-writable behavior change` — type=chore, p3

---

## References

- **The Vita-writable effort this mirrors:** [`../vita-writable/`](../vita-writable/)
  (plan, write-gate, RESULTS — hardware-verified). Same write surface, same exerciser
  shape; the difference is the device-root `mkdir` crux.
- **The 3DS read gate:** [`../3ds-support/`](../3ds-support/) (`RESULTS.md` — Azahar-only).
- configy write surface: `capabilities.nim` (flag), `fs.nim` (`isWritable`/`ensureConfigDir`),
  `store.nim` (`ensureConfigFile`, write APIs, `deleteConfig`), `paths.nim:35-36` (ds3 root).
- Crux evidence: `parentDirs("sdmc:/config/smoketest/app/", fromRoot=true)` → `sdmc:/`
  first (Nim `lib/std/private/ospaths2.nim`); `createDir`/`existsOrCreateDir`/`rawCreateDir`
  (`lib/std/private/osdirs.nim`). libctru sdmc devoptab is compiled (no source in
  `/opt/devkitpro` to inspect).
- 3DS toolchain: devkitARM + libctru + `3dsxtool`; Azahar SD passthrough at
  `~/Library/Application Support/Azahar/sdmc/`.
