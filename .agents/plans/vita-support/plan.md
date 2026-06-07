# Sony PS Vita Support Plan (configy)

## Metadata

| Field | Value |
|-------|-------|
| Requested by | User ("add support for sony vita like we did with nintendo 3ds") |
| Date | 2026-06-06 |
| Priority | **Low — NON-BLOCKING** (no known Vita consumer today) |
| Target repo | `~/git/configy` (`github.com/birbparty/configy`) |
| Companion docs | [`verification-gate.md`](./verification-gate.md) — gate design · [`RESULTS.md`](./RESULTS.md) — **verification outcome (✅ link + vita-elf-create + .vpk + Vita3K runtime; hardware pending)** |
| Status | **VERIFIED 2026-06-06** on VitaSDK (`arm-vita-eabi-gcc` 15.2.0) + Vita3K v0.2.1: compiles, links, `vita-elf-create` passes, `.vpk` runs and reads `ux0:` correctly (both absent + planted cases). See [`RESULTS.md`](./RESULTS.md). Only real-hardware `-Wl,-q` corroboration remains. |
| Reference build | `~/git/raylib-nim-multiplatform` — proven Nim-on-Vita build (VitaSDK + raylib-5.5-vita + vitaGL) |

> **Note on this revision:** an initial draft framed "does `std/os` file I/O reach
> `ux0:` on Vita?" as the central unknown. Two independent Opus reviews inspected
> the installed VitaSDK (`/usr/local/vitasdk`) and showed it is **already answered
> YES** — VitaSDK's newlib `libc.a` syscall layer backs `open`/`read`/`stat` (and
> `write`/`remove`) directly with `sceIo*`. This plan is revised accordingly: the
> read path is expected to work as written, and the **real** residual risk is the
> `-Wl,-q` relocation correctness that only manifests on hardware (§"Residual risk").

---

## Bottom line (read first)

This mirrors the [3DS support effort](../3ds-support/): configy already has genuine,
Nim-level Vita *awareness* (path branch, `configyUsesOsPath`, a CI compile-only
check), but it has **never been compiled, linked, or run on a real VitaSDK
toolchain.** The host `nim check -d:vita` is the entire body of evidence today,
and it proves nothing about linking on `arm-vita-eabi-gcc` + newlib.

This plan closes that gap the same way the 3DS plan did — a two-tier verification
gate. Unlike the 3DS effort, the file-I/O reachability question is **already
settled**: VitaSDK's newlib routes standard C file I/O to `sceIo*` in its syscall
layer, so configy's `std/os`-based read path reaches `ux0:` with **no shim** (see
§"File I/O reaches ux0:"). What this gate must actually establish, in order of
risk:

1. **It links.** configy + supersnappy must compile and link with
   `arm-vita-eabi-gcc` + newlib (correct stubs, correct link order). This is the
   bulk of the work and the strongest signal achievable without a Vita.
2. **`vita-elf-create` succeeds.** This is the real test of the mandatory `-Wl,-q`
   flag — it needs the retained relocations to emit SCE relocations into the
   `.velf`. A successful `.velf`/`.vpk` is the best non-hardware evidence the
   relocation handling is correct.
3. **It runs (corroboration).** A Vita3K read exercise confirms logic, but Vita3K
   loads at the link base and so **hides** `-Wl,-q` relocation bugs — it is weaker
   than the 3DS Azahar pass. Hardware is the only gold check.

There is **no known Vita consumer** today, so nothing here is on anyone's critical
path. Treat it as hardening + de-risking, not a feature epic.

---

## Decisions (locked)

| Question | Decision |
|----------|----------|
| Verification approach | **Mirror the 3DS gate** — Tier A (`nim check -d:vita`, no SDK) + Tier B (real `arm-vita-eabi-gcc` compile/link, `.vpk` package, runtime read exercise). Detail in [`verification-gate.md`](./verification-gate.md). |
| Reference toolchain | **`~/git/raylib-nim-multiplatform`** (`nim_vita.cfg`, `config.nims` vita block, `scripts/build_vita.sh`). Mirror its toolchain + librt-stub idiom; **strip all raylib / SDL2 / vitaGL libs** — configy needs only libc + a few `Sce*` stubs. |
| `configyFsWritable` for vita | **Flip to `false`** (read-only-until-verified-on-hardware), to match 3DS/PSP's conservative posture and give correct runtime read-only semantics. This is a *posture* decision, not a scoping mechanism — it does **not** compile the write surface out (see §"The writable decision"). Verifying/enabling Vita *writes* is the deferred follow-up. |
| `--os` target | **`--os:linux`** (NOT `--os:standalone`), matching the reference `config.nims` vita block and the 3DS resolution. Correct the misleading `nim.cfg` example. |
| `--os:standalone` *support* | **Out of scope.** No real Vita homebrew build uses it. |
| Runtime check substitute | **Vita3K emulator** for read-path *corroboration* only — **with an explicit caveat** that Vita3K loads at the link base and so *hides* the `-Wl,-q` relocation bug. The real `-Wl,-q` signal is a successful `vita-elf-create`. Hardware is the only gold check. |

---

## Current state (verified during planning)

configy already has partial, sound Vita awareness at the Nim level:

- `capabilities.nim:5` — `configyUsesOsPath = false` under `-d:vita` (vita is
  already in the `defined(...)` set), so paths use plain string concat. ✔
- `paths.nim:39-40` — `configRoot()` returns `ux0:data/config/<vendor>/` for vita. ✔
- `.github/workflows/ci.yml` — the `platform-define-check` matrix **already has a
  `vita` row** (`--compileOnly -d:vita`). ✔ Do **not** re-add it. (But note its
  semantics change once the `@if vita:` block lands — see §"CI consequence".)
- `errors.nim` — the four contract error types exist and are exported. ✔

**Two gaps / discrepancies vs the 3DS treatment:**

1. **`capabilities.nim:14-21` does NOT mention vita at all** in the
   `configyFsWritable` block (`elif defined(ds3) or defined(psp): false`). vita
   therefore falls through to `else: true` — i.e. **configy currently treats Vita
   as a writable filesystem**, unlike the conservative 3DS/PSP default. The fix is
   to **add** `vita` to the `elif` and **add** a vita comment line (there is no
   existing combined comment to "split," unlike the 3DS case). See §"The writable
   decision".
2. **`nim.cfg` has no `@if vita:` block** and its cross-compile example still
   shows `--os:standalone` (already flagged in-file as "LIKELY wrong").

A host `nim check --path:src -d:vita -d:configyVendor=test src/configy.nim` is
expected to pass (mirror the 3DS Tier A; `--path:src` is **required** — see the
3DS RESULTS finding #2). **That is the entire body of evidence today.**

### File I/O reaches `ux0:` — confirmed (not an open question)

configy's read path is `configFileExists` → `fileExists` and `readConfigJson` →
`loadBytes` → `readFile` (`store.nim`), i.e. C `stat`/`open`/`read` via `std/os` /
`std/syncio`. These are compiled in and reachable under `-d:vita` (they are **not**
behind the writable guard).

On 3DS these linked and ran because libctru auto-inits the `sdmc:` devoptab. **Vita
needs no devoptab at all** — that is a devkitPro/3DS concept. VitaSDK's newlib
hardcodes the mapping in its syscall layer:

- `arm-vita-eabi/lib/libc.a` references `sceIoOpen`, `sceIoRead`, `sceIoGetstat`,
  `sceIoGetstatByFd`, `sceIoMkdir`, `sceIoClose`, `sceIoWrite`, `sceIoRemove`
  (confirmed via `arm-vita-eabi-nm`). Its `_open_r`/`_stat_r`/`_read_r` syscall
  stubs are backed by these `sceIo*` calls, and its path layer understands `:`
  device prefixes (e.g. `ux0:`).
- There is **no `libScePosix`** — the mapping is in `libc.a` (newlib) itself. The
  only "posix" lib in the sysroot is `libpcre2-posix` (unrelated). Do not link or
  reference `-lScePosix`.

So configy's read path links and reaches `ux0:` **without any `sceIo*` shim**. The
reference build's use of raw `sceIo*` (`src/debug_vita.nim`, `src/vita_diag.nim`)
is its deliberate zero-dependency-logging choice during graphics bring-up, **not**
evidence that newlib I/O is unavailable. Corroboration: those files log to
`ux0:data/...`, the exact prefix form `configRoot()` emits, so the path style is
already proven on hardware.

The Tier B runtime step therefore *corroborates* the read path rather than
*discovering* whether it works. The only scenario in which a `sceIo*` shim becomes
necessary is a surprise contradicting this static evidence — treat it as a
contingency, not a planned outcome.

---

## Residual risk: `-Wl,-q` relocation correctness (the real unknown)

The one genuinely Vita-specific risk the gate **cannot** fully retire without
hardware is relocation correctness:

- `-Wl,-q` (`--emit-relocs`) is **mandatory** on Vita: `vita-elf-create` needs the
  retained relocations to emit SCE relocations into the `.velf`. Without them,
  `movw`/`movt` absolute addresses keep their link-time values and data-abort when
  the module loads at a non-link base — which is what real hardware does.
- **Vita3K loads at the link base and hides this bug.** So a Vita3K runtime pass is
  *weaker* than the 3DS Azahar pass and must not be reported as "verified like 3DS."
- The strongest non-hardware signal is a **successful `vita-elf-create`** (it
  consumes the relocations) and a clean `.vpk`. Foreground that in RESULTS; mark
  hardware relocation correctness as unverified unless a real Vita is used.

---

## The writable decision (Finding-2 analog) — corrected rationale

On Vita, `configyFsWritable` currently resolves to `true` (vita is absent from the
read-only set). **Decision (locked): add `vita` to the read-only set**, so
`configyFsWritable = false` under `-d:vita`.

**What this actually does (precise, corrected from the draft):**

- `fs.nim` `ensureConfigDir` guards `createDir` with a **compile-time**
  `when configyFsWritable` — so `createDir` *does* compile out. ✔
- `store.nim` write APIs (`writeConfigJson` / `writeConfigBytes` / `deleteConfig`)
  guard at **runtime** with `if not isWritable(): raise ConfigUnsupportedError`.
  Their underlying `writeFile` / `removeFile` / `storeBytes` therefore **stay
  compiled and linked** regardless of the flag — they just always raise at runtime.

So flipping the flag does **not** "compile the write surface out" (the draft's and
even the 3DS docs' framing was imprecise). It removes only `createDir` from the
link surface and gives correct *runtime* read-only semantics.

**Why flip it anyway:**

- Consistency with 3DS/PSP's conservative "false until verified on hardware" posture.
- Correct runtime semantics: Vita writes are unverified on hardware, so the safe
  default is to refuse them, not silently attempt them.
- No known Vita consumer relies on `configyFsWritable = true` today.

**Note on the deferred write follow-up:** because newlib also backs `write`/`remove`
with `sceIo*` (verified), Vita writes will very likely *link and run* — so enabling
them later is low-cost and could fold into the same hardware run that retires the
`-Wl,-q` risk. `ux0:data/` is unambiguously the writable homebrew data directory.
The flip to `false` is a deliberately conservative posture, not a statement that
writes are hard.

---

## nim.cfg work (in scope)

1. **Add an `@if vita:` block** carrying **both** the target switches
   (`--cpu:arm --os:linux …`) **and** the VitaSDK toolchain paths/libs. As with
   3DS, the switches MUST live somewhere or the toolchain config is inert and
   `nim c -d:vita` silently builds a host binary. Full block in
   [`verification-gate.md`](./verification-gate.md). Key points the reviews
   surfaced:
   - **Strip every raylib / SDL2 / vitaGL lib** from the reference's `nim_vita.cfg`
     — configy needs only libc + a few `Sce*` stubs + the mandatory `-Wl,-q`.
   - **Link order matters:** `-lc`/`-lm` must come **before** the `Sce*` stubs (it
     is libc's `_open_r`/`_stat_r` that reference `sceIoOpen`/`sceIoGetstat` in
     `SceIofilemgr_stub`), or wrap them in `-Wl,--start-group … --end-group`.
   - **Do NOT add `-march`/`-mfpu` arch flags** like the 3DS block does:
     `arm-vita-eabi-gcc` already defaults to `-march=armv7-a+simd -mfpu=neon
     -mfloat-abi=hard`. Adding the 3DS's armv6k/mpcore flags would be wrong.
   - **librt stub only** (see below): Vita ships a real `libdl.a`; only `librt` is
     absent.
2. **Correct the cross-compile example** for Vita from `--os:standalone` to
   `--os:linux` (mirror the 3DS example fix; the reference `config.nims` uses
   `--os:linux` for Vita). PSP can stay flagged-but-unverified as it is.

This is small and independent of any toolchain being installed; it can land before
Tier B is ever run. (Do **not** reintroduce a `cp nim_vita.cfg nim.cfg` step —
configy's `nim.cfg` is tracked, exactly as for 3DS.)

### CI consequence (note, no new matrix row)

The existing `platform-define-check` `vita` row uses `--compileOnly`. Once the
`@if vita:` block adds `--cpu:arm --os:linux`, that row changes from a *host-libc*
codegen check to an *arm/linux* codegen check — exactly the upgrade `ci.yml`
already documents for `ds3`. `--compileOnly` means the absent VitaSDK toolchain is
never invoked, so the row stays green. **Update the `ci.yml` comment** that
currently says PSP/Vita/WASM use "only the platform define," so it doesn't go
stale. Do not add a new row.

---

## Invariants to preserve (the contract)

A "do not break" guard, not tasks — identical to the 3DS plan:

1. `configyFsWritable` stays a reliable compile-time signal (flipping vita
   `true → false` *strengthens* the signal, not breaks it).
2. `readConfigJson` returns `none()` for an absent file rather than raising.
3. The four re-exported error types stay stable and exported: `ConfigPathError`,
   `ConfigUnsupportedError`, `ConfigIOError`, `ConfigParseError`.

---

## Out of scope (do NOT do)

- **Do not** make configy compile under `--os:Standalone`. No real Vita build uses
  it. (Correcting the example *away* from Standalone is in scope.)
- **Do not** flip `configyFsWritable` to `true` for vita (that's the deferred
  write-verification follow-up). This plan flips it to `false`.
- **Do not** add the raylib / SDL2 / vitaGL link soup from the reference — configy
  is graphics-free.
- **Do not** add `-march`/`-mfpu` arch flags — the Vita gcc defaults are correct.
- **Do not** claim "verified like 3DS" off a Vita3K-only run — Vita3K hides the
  `-Wl,-q` relocation bug. State the achieved tier honestly in RESULTS.

---

## Phased task breakdown

### Phase 0 — nim.cfg + capabilities (independent, no toolchain needed) ✅ DONE
- [x] **Add** `vita` to the `configyFsWritable` read-only set in `capabilities.nim`
      (`elif defined(ds3) or defined(psp) or defined(vita): false`) and **add** a
      vita comment line (there is no existing combined comment to split). Mirror
      the 3DS/PSP "false until verified on hardware" wording.
- [x] Add an `@if vita:` block to the committed `nim.cfg` (target switches +
      VitaSDK toolchain + `-Wl,-q`; correct link order; no raylib/SDL/vitaGL; no
      arch flags). See verification-gate.
- [x] Correct the Vita cross-compile example comment `--os:standalone` →
      `--os:linux`.
- [x] Update the `ci.yml` comment to reflect that the vita row now exercises
      arm/linux codegen (see §"CI consequence").
- [x] Confirm `nim check --path:src -d:vita -d:configyVendor=test src/configy.nim`
      still passes (Tier A regression). `--path:src` is required.

### Phase 1 — Author the verification gate artifacts (no toolchain needed) ✅ DONE
- [x] Add a `-d:vita` exerciser **outside `tests/`** (`verify/vita/vita_smoke.nim`)
      that hits the read path and writes a machine-readable marker. (Uses
      `writeFile` + a belt-and-suspenders raw `sceIo*` marker.)
- [x] Add a guarded `scripts/build_vita.sh` mirroring `scripts/build_3ds.sh`:
      **librt stub** (Vita ships a real `libdl.a`); clean-exit PASS (exit 0) when
      VitaSDK absent; threads the `--out:` ELF path into `vita-elf-create`; runs
      `vita-elf-create → vita-make-fself → vita-mksfoex → vita-pack-vpk`; never
      touches `nim.cfg`.
- [x] Document toolchain prereqs (`verify/vita/README.md`).

### Phase 2 — Run the gate on a real toolchain (VitaSDK) ✅ compile/link DONE; ⏳ runtime pending
- [x] Built with `arm-vita-eabi-gcc` 15.2.0; **links** to a static ARM ELF; the
      3-stub `Sce*` set sufficed (linker reported no more); `vita-elf-create`
      **succeeded** and packaged `vita_smoke.vpk`. `file` confirms ARM. See RESULTS.
- [x] Ran in Vita3K v0.2.1 and read the marker back — **both cases PASS**: absent →
      `none()`/false (no raise); planted `\x00{"hello":"vita","n":7}` → found +
      parsed. Confirms `std/os` reaches `ux0:` with no shim. See RESULTS.
- [ ] (If a real Vita is available) run on hardware to retire the `-Wl,-q` risk —
      the one thing Vita3K (loads at link base) cannot prove.
- [x] **Added** a Vita read-path-verified comment line in `capabilities.nim`.
      `configyFsWritable` left `false`.
- [x] Wrote [`RESULTS.md`](./RESULTS.md) with the honest tier achieved (compile/link
      + `vita-elf-create` green; runtime pending).

### Phase 3 — CI wiring (optional hardening; deferred, low priority)
- [ ] Tier A `nim check -d:vita` as a permanent regression gate (the compile-only
      matrix row covers codegen; a `nim check` step adds semantic analysis).
- [ ] Tier B `scripts/build_vita.sh` as a non-fatal CI job (PASS when VitaSDK
      absent), activating automatically on any runner that gains VitaSDK.
- [ ] **Caveat to document:** until a CI runner actually has VitaSDK, the Tier B
      job is permanently green and verifies nothing. The real signal is the manual
      Phase 2 run + comment update.

---

## Suggested bd issues (create at execution time, not now)

1. `fix: nim.cfg Vita cross-compile example uses --os:standalone (should be --os:linux)` — type=bug, p2
2. `chore: flip configyFsWritable to false for vita (conservative, matches 3DS/PSP)` — type=task, p2
3. `feat: add VitaSDK os:linux+newlib compile/link + .vpk gate for -d:vita configy` — type=feature, p3
4. `chore: run Vita gate (link + vita-elf-create + Vita3K corroboration) and add capabilities comment` — type=task, p3 (deps on #3)
5. `feat: route configy reads through sceIo* under -d:vita` — type=feature, p4 — **CONTINGENCY ONLY**; VitaSDK newlib evidence says this won't be needed (libc.a backs file I/O with sceIo). Open only if Phase 2 surprises.

---

## References

- **Proven Nim-on-Vita build (template for the gate):**
  - `~/git/raylib-nim-multiplatform/config.nims` (vita block: cpu arm, **os linux**, mm arc)
  - `~/git/raylib-nim-multiplatform/nim_vita.cfg` (VitaSDK paths, `-Wl,-q`, stub/lib list + link order — strip raylib/SDL/vitaGL)
  - `~/git/raylib-nim-multiplatform/scripts/build_vita.sh` (`.vpk` pipeline + stub idiom)
  - `~/git/raylib-nim-multiplatform/scripts/run_vita.sh` (Vita3K launch)
  - `~/git/raylib-nim-multiplatform/src/debug_vita.nim` (raw `sceIo*` file I/O — the reference's zero-dep logging choice, not a constraint on configy)
  - `~/git/raylib-nim-multiplatform/.agents/plans/multiplatform/08-toolchain-prereqs.md`
- **The 3DS effort this mirrors:** `.agents/plans/3ds-support/{plan,verification-gate,RESULTS}.md`
- configy Vita-relevant code: `capabilities.nim:5,14-21`, `paths.nim:39-40`,
  `store.nim`/`fs.nim` (read/write path + gating), `.github/workflows/ci.yml` (vita matrix row).
- VitaSDK newlib evidence: `arm-vita-eabi-nm /usr/local/vitasdk/arm-vita-eabi/lib/libc.a | grep sceIo`.
- VitaSDK: <https://vitasdk.org> · Vita3K: <https://vita3k.org> (`brew install vita3k`)
