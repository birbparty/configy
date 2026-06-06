# Nintendo 3DS Support Plan (configy)

## Metadata

| Field | Value |
|-------|-------|
| Requested by | inputty 3DS port (`~/git/inputty`, `github.com/birbparty/inputty`) |
| Request | `.agents/requests/3ds-support/README.md` |
| Date | 2026-06-06 |
| Priority | **Low — NON-BLOCKING** (see Bottom line) |
| Target repo | `~/git/configy` (`github.com/birbparty/configy`) |
| Companion docs | [`verification-gate.md`](./verification-gate.md) — gate design · [`RESULTS.md`](./RESULTS.md) — **verification outcome (✅ done)** |
| Status | **Finding 1 VERIFIED 2026-06-06** on devkitARM + Azahar — see [`RESULTS.md`](./RESULTS.md) |

---

## Bottom line (read first)

**Nothing in this plan gates any inputty or clckr 3DS milestone.** inputty's
libctru HID input backend (`-d:ds3 -d:useCtru`) imports only inputty's pure
`types` module; its configy wrapper is desktop-only and not in the barrel, and
inputty hard-sets `inputtyCanPersist = false` under `-d:ds3`. A `-d:ds3` clckr
build never touches configy.

This plan exists to close two real-but-non-urgent findings the inputty team
surfaced while auditing the 3DS path, plus one discrepancy found in configy's
own build config during planning. Treat the whole thing as coordination +
hardening, not a feature epic. None of it is on a consumer's critical path.

---

## Decisions (locked)

| Question | Decision |
|----------|----------|
| Finding 1 — verification approach | **Build the verification gate** (devkitARM os:linux+newlib compile/link + Azahar sdmc: read exercise), then flip the `capabilities.nim` "until verified" comment. Detail in [`verification-gate.md`](./verification-gate.md). |
| Finding 2 — flip `configyFsWritable` for ds3 | **Future, not now.** sdmc: is writable, but no consumer needs 3DS persistence today. Record rationale; take no code action. |
| `nim.cfg` 3DS example uses `--os:standalone` | **Correct it** to the real `--os:linux` + newlib target. This is *in scope* — it steers users away from Standalone, the opposite of "do not support Standalone." |
| `--os:Standalone` *support* | **Out of scope.** No real 3DS build uses Standalone; do not spend effort making configy compile under it. |
| Reference toolchain | **`~/git/raylib-nim-multiplatform`** — a proven Nim-on-3DS build. Mirror its `config.nims` ds3 block, `nim_3ds.cfg`, and `scripts/build_3ds.sh` libdl-stub idiom. |

---

## Current state (verified during planning)

configy already has genuine, sound 3DS awareness at the Nim level:

- `capabilities.nim:5` — `configyUsesOsPath = false` under `-d:ds3` (paths use
  plain string concat, not `std/os` operators).
- `capabilities.nim:14-17` — `configyFsWritable = false` for ds3 (conservative).
- `paths.nim:35-36` — `configRoot()` returns `sdmc:/config/<vendor>/` for ds3.
- `fs.nim:20,35` — `createDir` is `when configyFsWritable`-guarded, so it is
  compiled out on ds3.
- `errors.nim` — all four error types the contract names exist and are exported:
  `ConfigPathError`, `ConfigIOError`, `ConfigParseError`, `ConfigUnsupportedError`
  (plus base `ConfigError`). ✔ confirmed.

A host `nim check -d:ds3` passes. **That is the entire body of evidence today** —
it proves the ds3 `when`-branches type-check on the dev machine's libc. It proves
nothing about compiling *and linking* on real devkitARM. Closing that gap is
Finding 1.

### Read path is reachable on ds3 (and not behind the writable guard)

`readConfigJson` → `notFound` → `fileExists` (`store.nim:54,121,143`) and
`loadBytes` → `readFile` (`store.nim:32`) are compiled in and callable under
`-d:ds3` — they are *not* gated by `isWritable()`. They should link under
os:linux+newlib (devkitARM supplies file-I/O stubs; libctru supplies the
`sdmc:` devoptab), but this has never been exercised end-to-end. The gate must
exercise the read path specifically.

---

## Discrepancies found during planning

Two mismatches between the request and the current tree. Both are minor; record
so a future reader isn't confused.

1. **Stale path reference.** The request cites `paths.nim:34` returning
   `sdmc:/<vendor>/config/`. The current post-XDG code (`paths.nim:35-36`)
   returns `sdmc:/config/<vendor>/` — vendor now sits *after* `config/`. The
   request predates the XDG refactor (commit `12db50f`). Finding 2's substance
   (sdmc: is writable) is unaffected.

2. **`nim.cfg` recommends the wrong OS target.** configy's own `nim.cfg`
   cross-compile examples tell users:
   ```
   3DS: nim c -d:ds3 --cpu:arm --os:standalone ...
   ```
   The request asserts "no `--os:Standalone` usage anywhere in configy" — that
   is now false; configy's own docs recommend it. The proven 3DS build
   (`raylib-nim-multiplatform/config.nims`) uses `--cpu:arm --os:linux` for ds3.
   The example is actively misleading. → Fix it (see "nim.cfg correction" below).

   > **Scope guard:** `nim.cfg` puts PSP and Vita on `--os:standalone` too, and
   > the same `raylib-nim-multiplatform/config.nims` uses `--os:linux` for *all
   > three* consoles — so those examples are likely wrong as well. But this
   > request is 3DS-scoped and the request's hard evidence (boxy libdl stub,
   > os:linux+newlib) is 3DS-only. **Correct the 3DS line; leave PSP/Vita as-is
   > and add a one-line note** that they appear to share the same defect and
   > warrant separate verification. Do not silently "fix" targets you have not
   > verified.

---

## Finding 1 — Verify configy on a real devkitARM toolchain

**✅ DONE — verified 2026-06-06.** configy compiles, links, and runs its read
path on real devkitARM (os:linux+newlib+libctru) in Azahar. Outcome, commands,
and surfaced sub-findings (needs an `librt` stub too; Tier A needs `--path:src`;
libctru auto-inits sdmc) are in [`RESULTS.md`](./RESULTS.md). The
`capabilities.nim` comment has been split (3DS verified; PSP unchanged).

**Decision: build the gate.** Full design in [`verification-gate.md`](./verification-gate.md).

In short, mirror the two-tier model from `raylib-nim-multiplatform`:

- **Tier A (always runnable, no SDK):** `nim check -d:ds3` — configy already
  passes this. Keep as a CI regression gate.
- **Tier B (real toolchain):** an `@if ds3:` block in the committed `nim.cfg`
  supplies the target switches + toolchain flags, and a guarded build script
  creates the empty `libdl.a` stub, compiles a trivial `-d:ds3` configy program
  with `arm-none-eabi-gcc`, links against libctru, packages a `.3dsx`, and — in
  Azahar — exercises `readConfigJson` / `configFileExists` against an `sdmc:/`
  path. The script must **exit cleanly (PASS) when the toolchain is absent**, so
  it is safe to run on CI/dev machines without devkitARM. (No `cp` over
  `nim.cfg` — it is tracked.)

On success, **split** the `capabilities.nim:12` comment — it currently covers
*both* 3DS and PSP (*"3DS and PSP default false until the SDK FS is verified"*),
and this work verifies only 3DS. Change the 3DS half to *"3DS verified on
devkitARM os:linux+newlib as of <date>"* and **leave the PSP half unchanged**
(*"PSP default false until the SDK FS is verified"*). Do not blanket-replace the
line — that would falsely claim PSP is verified. The flip is a comment change
only — leave `configyFsWritable = false`; making it `true` is Finding 2, which
stays deferred.

---

## Finding 2 — sdmc: is writable (FYI / future, no action now)

The 3DS *does* have a writable filesystem: `sdmc:/` (the SD card), available
after the sdmc devoptab is set up in standard homebrew. So:

- configy's `configyFsWritable = false` for ds3 is **more conservative than the
  hardware**, justified only as "until the SDK FS is verified."
- inputty's parallel `inputtyCanPersist = false` is justified as "no standard
  writable path in devkitARM homebrew" — which is **inaccurate**; sdmc: is that
  path.

**No action in this plan.** No consumer needs 3DS persistence today (clckr
doesn't; inputty explicitly scoped it out). When/if 3DS binding persistence is
wanted, the path is: complete Finding 1's verification → flip `configyFsWritable`
to `true` for ds3 → have inputty relax `inputtyCanPersist` and align its
rationale. Recorded here so the two libraries can reconcile when it comes up; it
is a future feature, not part of this request.

---

## nim.cfg correction (in scope)

Edit `nim.cfg`'s cross-compile example block:

- **Change** the 3DS example from `--os:standalone` to the verified target:
  `--cpu:arm --os:linux --mm:arc --threads:off -d:useMalloc
  -d:nimAllocPagesViaMalloc -d:noSignalHandler` (proven in
  `raylib-nim-multiplatform/config.nims`). The toolchain paths/libs for an actual
  build live in an `@if ds3:` block added to this same `nim.cfg` — see
  [`verification-gate.md`](./verification-gate.md). (These switches **must** be
  set somewhere or the toolchain config is inert and the build silently targets
  the host.)
- **Add** a one-line note that PSP/Vita examples likely share the same
  `--os:standalone`-vs-`--os:linux` defect and need separate verification before
  being changed (out of scope here).

This change is small and independent of the toolchain being installed; it can
land before Tier B is ever run.

---

## Invariants to preserve (the contract inputty depends on)

These are a **"do not break" guard**, not tasks. inputty's *desktop* persistence
relies on configy's current read-only-target contract:

1. `isWritable()` / `configyFsWritable` stays a reliable compile-or-runtime
   signal — inputty's `saveBindings` no-ops when it's false.
2. `readConfigJson` returns `none()` for an absent file rather than raising
   (`store.nim:121,143`).
3. The four re-exported error types stay stable and exported: `ConfigPathError`,
   `ConfigUnsupportedError`, `ConfigIOError`, `ConfigParseError`.

Any work in this plan (especially a future Finding-2 `configyFsWritable` flip)
must keep all three intact. The Tier B gate is read-only and touches none of them.

---

## Out of scope (do NOT do)

- **Do not** make configy compile under `--os:Standalone`. No real 3DS build
  uses it; it would be effort spent on a target nobody ships. (Correcting the
  `nim.cfg` example *away* from Standalone is in scope and is the opposite of
  this.)
- **Do not** flip `configyFsWritable` to `true` for ds3 (that's Finding 2,
  deferred).
- **Do not** change the PSP/Vita `nim.cfg` examples — unverified for this request.
- **Do not** add 3DS persistence APIs or sdmc:-write logic.

---

## Phased task breakdown

### Phase 0 — nim.cfg correction (independent, no toolchain needed) ✅ DONE
- [x] Fix the 3DS cross-compile example comment in `nim.cfg` from
      `--os:standalone` to `--os:linux` + the verified flag set.
- [x] Add the PSP/Vita "likely same defect, unverified" note.
- [x] Confirm `nim check --path:src -d:ds3 -d:configyVendor=test src/configy.nim`
      still passes (Tier A regression). **NOTE:** `--path:src` is required — see
      [`RESULTS.md`](./RESULTS.md) finding #2.

### Phase 1 — Author the verification gate artifacts ✅ DONE
- [x] Add an `@if ds3:` block to the committed `nim.cfg` carrying the target
      switches (`--cpu:arm --os:linux …`) **and** the devkitARM toolchain
      paths/libs. (No `cp` over the tracked `nim.cfg`.)
- [x] Add a `-d:ds3` exerciser **outside `tests/`** (`verify/ds3/ds3_smoke.nim`
      + `verify/ds3/ctru.nim`) that hits the read path and writes a
      machine-readable marker. (Outside `tests/` to avoid `tests/config.nims`
      forcing `configyVendor=testvendor`.)
- [x] Add a guarded `scripts/build_3ds.sh` (libdl **+ librt** stubs; clean-exit
      PASS when devkitARM absent; packages a `.3dsx`; never touches `nim.cfg`).
- [x] Document toolchain prereqs (`verify/ds3/README.md`).

### Phase 2 — Run the gate on a real toolchain ✅ DONE (devkitARM + Azahar)
- [x] Built with `arm-none-eabi-gcc`; **links** to a static ARM ELF.
- [x] Ran in Azahar; `readConfigJson` → `none()` for absent, parses a planted
      file; `configFileExists` behaves. See [`RESULTS.md`](./RESULTS.md).
- [x] Split the `capabilities.nim:12` comment — 3DS marked verified (2026-06-06),
      PSP left as "until verified".

### Phase 3 — CI wiring (optional hardening) — NOT done (deferred, low priority)
- [ ] Wire the Tier A `nim check -d:ds3` into CI as a permanent regression gate.
- [ ] Wire the Tier B script into CI as a non-fatal job (PASS when toolchain
      absent), so it activates automatically on any runner that has devkitARM.
- [ ] **Caveat to document:** until a CI runner actually has devkitARM, the Tier
      B job is permanently green and verifies nothing. The real verification
      signal is the manual Phase 2 run + comment flip — a green Tier B job is not
      a substitute for it.

---

## Suggested bd issues (create at execution time, not now)

Listed for whoever picks this up; this plan does **not** create them.

1. `fix: nim.cfg 3DS cross-compile example uses --os:standalone (should be --os:linux)` — type=bug, p2
2. `feat: add devkitARM os:linux+newlib compile/link gate for -d:ds3 configy` — type=feature, p3
3. `chore: exercise configy ds3 read path in Azahar against sdmc:/ and flip capabilities comment` — type=task, p3 (deps on #2)
4. `chore: investigate whether PSP/Vita nim.cfg examples share the --os:standalone defect` — type=task, p4

---

## References

- inputty request: `~/git/inputty/.agents/plans/2026-06-06-3ds-libctru-hid-backend/`
- inputty configy wrapper (desktop-only): `~/git/inputty/src/inputty/config.nim`
- **Proven Nim-on-3DS build (template for the gate):**
  - `~/git/raylib-nim-multiplatform/config.nims` (ds3 block: cpu arm, **os linux**)
  - `~/git/raylib-nim-multiplatform/nim_3ds.cfg` (devkitARM paths, specs, libctru)
  - `~/git/raylib-nim-multiplatform/scripts/build_3ds.sh` (libdl stub idiom)
  - `~/git/raylib-nim-multiplatform/scripts/run_3ds.sh` (Azahar launch)
  - `~/git/raylib-nim-multiplatform/.agents/plans/multiplatform/08-toolchain-prereqs.md`, `09-verify.md`
- boxy `scripts/build_3ds.sh` — original os:linux+newlib+libdl-stub idiom.
- configy 3DS-relevant code: `capabilities.nim:5,12-17`, `paths.nim:35-36`,
  `fs.nim:20,35`, `store.nim:32,54,121,143`, `errors.nim`.
