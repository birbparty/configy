# Request: configy & Nintendo 3DS support

- **Requested by:** inputty 3DS port (`~/git/inputty`, `github.com/birbparty/inputty`)
- **Date:** 2026-06-06
- **Priority:** Low — **NON-BLOCKING.** See "Bottom line" first.
- **Target repo:** `~/git/configy` (`github.com/birbparty/configy`)

## Bottom line (read this first)

**The inputty 3DS input backend needs NOTHING from configy to ship.**

inputty is adding a libctru HID input backend (`-d:ds3 -d:useCtru`) so clckr can
take 3DS joypad input. That backend imports only inputty's pure `types` module.
inputty's configy wrapper (`src/inputty/config.nim`) is **desktop-only and not in
the barrel** (`src/inputty.nim`), so a `-d:ds3` clckr build never touches configy.
inputty also hard-sets `inputtyCanPersist = false` under `-d:ds3` — no binding
persistence is attempted on 3DS.

So **nothing here gates the 3DS input work or any inputty 3DS milestone.** This
document exists only to record two real-but-non-urgent findings for configy's
owners, surfaced while auditing the 3DS path. Treat it as coordination, not a
blocker.

## What I verified (so you don't have to re-derive it)

- configy already has genuine 3DS awareness:
  - `capabilities.nim`: `configyFsWritable = false` and `configyUsesOsPath = false`
    under `-d:ds3` (paths use plain string concat, not `std/os` operators).
  - `paths.nim:34`: `configRoot()` returns `sdmc:/<vendor>/config/` for ds3.
  - `fs.nim`: `createDir` is `when configyFsWritable`-guarded (compiled out on ds3).
- `nim check --path:src --path:<configy>/src -d:ds3 -d:configyVendor=test
  src/inputty/config.nim` → **exit 0**. configy's ds3 Nim-level branches are sound.
- The **real 3DS toolchain target is `--os:linux` + newlib**, NOT `--os:Standalone`.
  Confirmed: no `--os:Standalone` usage anywhere in birbparty / boxy /
  raylib-nim-multiplatform / inputty / configy. Real builds use
  `arm.linux.gcc` (devkitARM `arm-none-eabi-gcc`); boxy's `build_3ds.sh` even
  stubs `libdl.a` precisely because "Nim injects `-ldl` for `--os:linux` targets."
  Under os:linux+newlib, devkitARM supplies the file-I/O stubs and libctru
  supplies the `sdmc:` devoptab, so configy's `fileExists`/`readFile`/`writeFile`
  calls **link** — they are not a 3DS link blocker.

## Finding 1 — configy is unverified on a real devkitARM toolchain (verification ask, not a code change)

**Status:** non-blocking; configy already flags this itself
(`capabilities.nim:12`: *"Conservative: 3DS and PSP default false until the SDK FS
is verified."*).

The only evidence configy works on 3DS today is a **host `nim check`** (Nim
semantic analysis on the dev machine's libc). That proves the ds3 `when`-branches
compile; it proves nothing about compiling **and linking** on real devkitARM
(`arm-none-eabi-gcc` + newlib + libctru). This is the same host-vs-real-toolchain
gap inputty's own ctru backend plan calls out for its FFI.

Note the read path is reachable on ds3 and is **not** behind the `isWritable()`
runtime guard: `readConfigJson` → `notFound` → `fileExists` (`store.nim:54,100`)
and `loadBytes` → `readFile` (`store.nim:32`) are compiled in and callable on
`-d:ds3`. They should link under os:linux+newlib, but that has never been
exercised end-to-end.

**Ask (pick one, both small):**
- (a) Add a real-toolchain compile gate: build a trivial `-d:ds3` configy program
  with `arm.linux.gcc` (mirror `raylib-nim-multiplatform/nim_3ds.cfg`: `-specs=3dsx.specs`,
  `-march=armv6k …`, `-I/opt/devkitpro/libctru/include`, `-L…/libctru/lib -lctru -lm`,
  the `libdl.a` stub), exercise `readConfigJson`/`configFileExists` against an
  `sdmc:/` path in Azahar, and confirm it links and behaves; **or**
- (b) If you'd rather not own a devkitARM gate, just document that configy's 3DS FS
  is unverified and that the consuming app owns toolchain validation — and flip the
  `capabilities.nim:12` comment from "until verified" to a clear "verified on
  devkitARM os:linux+newlib as of <date>" once someone does (a).

**Explicitly out of scope — do NOT do this:** do not try to make configy compile
under `--os:Standalone`. inputty's `cross_compile_gate.sh` mentions a deferred
Phase-2 that aspires to `--os:Standalone` (and notes configy's `fileExists` blocks
it), but **no real 3DS build uses Standalone** — it's os:linux+newlib. Solving
Standalone would be effort spent on a target nobody ships.

## Finding 2 — sdmc: is writable; the `configyFsWritable=false` / `inputtyCanPersist=false` stance is more conservative than the hardware (FYI / future)

**Status:** FYI only. No consumer needs 3DS persistence today; clckr does not, and
inputty's input request explicitly scoped persistence out.

There is a latent disagreement between the two libraries' rationales:
- inputty (`capabilities.nim`): `inputtyCanPersist = false` on ds3, justified as
  *"no standard writable path in devkitARM homebrew."*
- configy already models `sdmc:/<vendor>/config/` (`paths.nim:34`) and sets
  `configyFsWritable = false` only *"until the SDK FS is verified."*

The 3DS **does** have a writable filesystem: `sdmc:/` (the SD card), available
after `romfsInit`/sdmc devoptab setup in standard homebrew. So configy's modeling
is closer to correct than inputty's "no writable path" claim. If 3DS binding
persistence is ever wanted, it is *feasible* — it would mean flipping
`configyFsWritable` to true for ds3 (after Finding 1's verification), and inputty
correspondingly relaxing `inputtyCanPersist`. That's a **future feature**, not
part of this request; recorded here so the two libraries can align the rationale
when/if it comes up.

## What inputty depends on from configy (the contract to keep stable)

Even though 3DS doesn't use it, inputty's desktop persistence relies on configy's
current read-only-target contract — please keep these invariants:
- `isWritable()` / `configyFsWritable` is a reliable compile-or-runtime signal;
  inputty's `saveBindings` no-ops when it's false (`inputty/config.nim:41`).
- `readConfigJson` returns `none()` for an absent file rather than raising.
- The error types inputty re-exports stay stable: `ConfigPathError`,
  `ConfigUnsupportedError`, `ConfigIOError`, `ConfigParseError`.

## References

- inputty 3DS input backend plan: `~/git/inputty/.agents/plans/2026-06-06-3ds-libctru-hid-backend/`
- inputty configy wrapper: `~/git/inputty/src/inputty/config.nim` (desktop-only)
- inputty cross-compile gate (Phase-2 Standalone caveat): `~/git/inputty/tests/cross_compile_gate.sh`
- Real 3DS toolchain reference: `~/git/raylib-nim-multiplatform/nim_3ds.cfg`,
  boxy `scripts/build_3ds.sh` (os:linux + newlib + libdl stub idiom).
- configy 3DS-relevant code: `capabilities.nim` (lines 5, 12-17), `paths.nim:34`,
  `fs.nim:21`, `store.nim:54,100,198`.
