# 3DS Verification Gate — Design

Companion to [`plan.md`](./plan.md). This is the concrete design for **Finding 1
(build the gate)**: prove configy compiles, links, and runs its read path on a
real Nintendo 3DS toolchain (devkitARM, os:linux + newlib, libctru), not just on
the host `nim check`.

Everything here mirrors a **proven, working Nim-on-3DS build**:
`~/git/raylib-nim-multiplatform`. configy's gate is *simpler* than that one —
configy has no raylib dependency, so it needs only libctru (for the `sdmc:`
devoptab) + the standard libdl stub. Where this doc says "mirror X," copy the
pattern from that repo and strip the raylib parts.

> **Review note (applied):** Two earlier-draft bugs were caught in review and are
> fixed below — (1) the target switches were dropped from every concrete
> artifact, which would have silently built a *host* binary; (2) the
> `cp …→nim.cfg` + cleanup idiom would have clobbered/deleted configy's
> **tracked** `nim.cfg`. Both are resolved by putting everything in an
> `@if ds3:` block in the committed `nim.cfg` (see below) instead of copying a
> separate cfg over it.

---

## The two-tier model

Lifted from `raylib-nim-multiplatform/.agents/plans/multiplatform/09-verify.md`.

| Tier | What it checks | Needs SDK? | Where it runs |
|------|----------------|-----------|---------------|
| **A** | Nim semantic analysis / codegen for `-d:ds3` | No | Any machine, CI |
| **B** | Real C compile + link + runtime read-path behavior | Yes (devkitARM + libctru + Azahar) | A machine with devkitPro |

Tier A is what configy has today (`nim check -d:ds3` passes). It is necessary but
**not sufficient** — it runs against the host libc and proves nothing about
linking on `arm-none-eabi-gcc` + newlib. Tier B is the new work.

The guiding principle from `09-verify.md`: **a missing toolchain is a PASS for
the agent's scope, not a failure.** The Tier B script must detect absent
devkitARM and exit cleanly with a message, so it is safe to invoke anywhere.

> **CI honesty caveat:** "PASS when toolchain absent" means the Tier B CI job is
> **decorative until a runner actually has devkitARM** — a permanently-green
> Tier B job verifies nothing. The *real* verification signal is a human running
> Tier B once on a devkitPro machine and then flipping the `capabilities.nim`
> comment (Phase 2 step 3). Do not mistake a green CI job for that signal.

---

## The real 3DS target (settled, not Standalone) — and where the flags MUST live

From `raylib-nim-multiplatform/config.nims` (ds3 branch) — the verified flag set:

```
--cpu:arm
--os:linux          # NOT standalone — devkitARM newlib provides libc/file-I/O stubs
--mm:arc
--threads:off
-d:useMalloc
-d:nimAllocPagesViaMalloc
-d:noSignalHandler
--opt:size
```

Plus `-d:ds3` (configy's existing console define) and configy's mandatory
`-d:configyVendor=<org>`.

**Critical wiring fact:** in the reference these switches live in `config.nims`,
and `nim_3ds.cfg` carries *only* toolchain paths + `passC`/`passL`. If you put
the toolchain paths in a cfg but forget `--cpu:arm --os:linux`, the
`arm.linux.gcc.*` block is **inert** (it only fires for an arm/linux target),
`-specs=3dsx.specs` is fed to the host gcc, and `nim c -d:ds3` builds a
**macOS/host binary that proves nothing**. configy has no root `config.nims`
(only `tests/config.nims`, which just sets the vendor define + path), so the
switches have nowhere to live unless we add them. **They must be set, or the gate
is a no-op.**

Why os:linux works once it *is* set: under `--os:linux`, devkitARM's newlib
supplies `fileExists`/`readFile` C stubs and libctru supplies the `sdmc:`
devoptab, so configy's read calls **link**. The only snag is that Nim injects
`-ldl` for os:linux targets and the 3DS has no libdl — solved by the empty
`libdl.a` stub. This is exactly boxy's documented idiom.

---

## Artifacts to add (Phase 1 — authorable with no toolchain)

### 1. `@if ds3:` block in the **existing committed `nim.cfg`** (NOT a copied-over cfg)

configy's `nim.cfg` is tracked and load-bearing (`--mm:arc`, the `@if psp:`
pointer-type workaround, and the cross-compile examples Phase 0 fixes). It
already uses the `@if … @end` idiom. Add a `ds3` block carrying **both** the
target switches **and** the toolchain paths/libs — this homes the switches
(fixes the host-binary bug) and avoids any `cp`/`rm` over a tracked file:

```
@if ds3:
  # Target: ARMv6K via devkitARM, os:linux + newlib (NOT standalone).
  --cpu:arm
  --os:linux
  --threads:off
  --define:useMalloc
  --define:nimAllocPagesViaMalloc
  --define:noSignalHandler
  --opt:size

  # devkitARM toolchain (default devkitPro install location; edit if yours differs)
  arm.linux.gcc.path      = "/opt/devkitpro/devkitARM/bin"
  arm.linux.gcc.exe       = "arm-none-eabi-gcc"
  arm.linux.gcc.linkerexe = "arm-none-eabi-gcc"

  # 3DS arch flags (from devkitPro's build system)
  --passC:"-specs=3dsx.specs"
  --passC:"-march=armv6k -mtune=mpcore -mfloat-abi=hard -mtp=soft"
  --passC:"-I/opt/devkitpro/libctru/include"

  # Linker — repeat arch flags so GCC picks the armv6k/fpu multilib + 3dsx_crt0.o
  --passL:"-specs=3dsx.specs -march=armv6k -mfloat-abi=hard"
  --passL:"-L/opt/devkitpro/libctru/lib -lctru"
  --passL:"-lm"
  # Nim injects -ldl for os:linux; 3DS has none — empty libdl.a stub in CWD
  --passL:"-L."
@end
```

Notes:
- `--mm:arc` is already set unconditionally at the top of `nim.cfg`, so it is not
  repeated here.
- No raylib `-I`/`-L` — configy needs only libctru for the devoptab.
- The `/opt/devkitpro` paths are the devkitPro default; mark them as the one spot
  a user edits for a non-default install (mirrors the reference's `### EDIT ###`).
- This block is keyed on `-d:ds3`, exactly like the reference keys on
  `defined(ds3)` — desktop/other targets are unaffected.

> **Do NOT** reintroduce a `cp nim_3ds.cfg nim.cfg` step. configy's `nim.cfg` is
> tracked; copying over it and `rm`-ing it on cleanup would delete a committed
> file (and discard the Phase 0 example fix).

### 2. Exerciser program — outside `tests/`, e.g. `verify/ds3/ds3_smoke.nim`

Place it **outside `tests/`**: `tests/config.nims` injects
`-d:configyVendor=testvendor` for everything under `tests/`, which would fight
the vendor value the gate pins and desync the `sdmc:` path. Pin one vendor value
(this doc uses `smoketest`) and use it consistently in the build command **and**
the planted-file path.

The program must do real 3DS runtime init and emit a **machine-readable result**,
not just print to a console a human has to watch:

```nim
import configy
# 3DS runtime init. With a .3dsx + default libctru, sdmcInit() is called by
# libctru's __appInit, so sdmc:/ resolves without an explicit call — CONFIRM this
# for your libctru version; if not auto-inited, call the sdmc devoptab setup here.
# gfx/console init is still needed if you also want on-screen output.

# Under -d:ds3 configyFsWritable is false, so do NOT call configy's write/ensure
# APIs (they short-circuit). Exercise only the read path:
let existsAbsent = configFileExists("smoke", "probe.json")   # expect false pre-plant
let gotAbsent    = readConfigJson("smoke", "probe.json")     # expect none(), must NOT raise

# Write a machine-readable marker with a RAW write (bypasses configy's read-only
# guard — this is test-harness I/O, not the configy API):
writeFile("sdmc:/configy_smoke_result.txt",
  "absent_exists=" & $existsAbsent & "\n" &
  "absent_isNone=" & $gotAbsent.isNone & "\n")
# (Re-run / second build with a planted probe.json asserts the present-file case.)
```

For the planted-file case, the program additionally records whether
`readConfigJson` parsed the planted file and `configFileExists` returned true,
appending to the same marker file.

### 3. `scripts/build_3ds.sh` (guarded build/link — no cp over nim.cfg)

Mirror the *structure* of `raylib-nim-multiplatform/scripts/build_3ds.sh`, but
**without** the `cp …→nim.cfg` step (the `@if ds3:` block makes it unnecessary):

- Set `DEVKITPRO`/`DEVKITARM` and PATH.
- **Guard:** if `arm-none-eabi-gcc` (or `3dsxtool`) is absent, print a clear
  "toolchain not installed" message and exit cleanly (PASS for scope).
  > The reference guard `exit 1`s before invoking Nim and counts that as
  > pass-for-scope. We deliberately exit **0** instead — cleaner CI semantics.
  > This is an intentional improvement, not a mirror; don't "fix" it back to 1.
- Create the empty libdl stub: `arm-none-eabi-ar rcs libdl.a` (clean up on exit).
- `nim c -d:ds3 -d:configyVendor=smoketest --path:src verify/ds3/ds3_smoke.nim`
  (cpu/os/opt now come from the `@if ds3:` block; `--path:src` lets the exerciser
  `import configy`).
- **Package the `.3dsx`** with `3dsxtool` (+ an smdh). This is **required**, not
  optional — Azahar runs a `.3dsx`, so Phase 2's runtime check cannot happen
  without it.
- `trap` cleanup removes only `libdl.a` and build intermediates — **never
  `nim.cfg`**.

### 4. Prereqs doc / README note

Mirror `08-toolchain-prereqs.md`:

```sh
dkp-pacman -S 3ds-dev        # installs devkitARM + libctru into /opt/devkitpro
export DEVKITPRO=/opt/devkitpro
export PATH=$PATH:$DEVKITPRO/tools/bin:$DEVKITPRO/devkitARM/bin
```

State plainly that the user installs the SDK; the script does not. `3dsxtool` (in
`$DEVKITPRO/tools/bin`) is required for the runtime tier.

---

## Phase 2 — Run it (requires devkitARM + Azahar)

1. **Link check.** Run `scripts/build_3ds.sh` on a machine with devkitARM.
   - PASS criterion: Nim transpiles, `arm-none-eabi-gcc` compiles, and the link
     **succeeds** (no unresolved `fileExists`/`readFile`, no missing `-ldl`),
     producing a `.3dsx`.
   - Sanity-check it really built ARM, not host: `file verify/ds3/ds3_smoke`
     should report ARM, and the `.3dsx` should exist.
2. **Runtime read-path check in Azahar** (mirror `run_3ds.sh` → `open -a Azahar`):
   - **Where the SD card lives on the host:** Azahar's virtual SD root is a host
     directory (default macOS: `~/Library/Application Support/Azahar/sdmc/`).
     Confirm the exact path for your Azahar version before planting/reading.
   - **Absent-file run:** launch with no probe planted; the exerciser writes
     `sdmc:/configy_smoke_result.txt`. Read it back host-side at
     `…/Azahar/sdmc/configy_smoke_result.txt` and assert
     `absent_exists=false`, `absent_isNone=true` (i.e. `readConfigJson` returned
     `none()` and did not raise).
   - **Planted-file run:** host-side, write a valid configy file (magic byte +
     JSON) to `…/Azahar/sdmc/config/smoketest/smoke/probe.json` (vendor segment
     MUST equal the compiled-in `configyVendor=smoketest`). Relaunch; assert the
     marker shows the file was found and parsed.
   - **Observability is explicit:** verification is via the marker file read
     host-side. If you skip the marker mechanism, this step becomes a **manual**
     human check (watch an on-screen console) — label it as such; do not present
     a human-watched run as automated.
3. **Flip the comment (split, don't replace).** `capabilities.nim:12` currently
   covers **both** 3DS and PSP: *"3DS and PSP default false until the SDK FS is
   verified."* PSP is NOT verified by this work. Split it:
   - 3DS line → *"3DS verified on devkitARM os:linux+newlib as of <date>."*
   - PSP line → keep *"PSP default false until the SDK FS is verified."*

   Leave `configyFsWritable = false` (write verification + enabling persistence
   is Finding 2, deferred).

---

## Acceptance criteria

- [ ] An `@if ds3:` block exists in the committed `nim.cfg` setting `--cpu:arm
      --os:linux` (+ the rest); no `cp`/`rm` touches `nim.cfg`.
- [ ] `scripts/build_3ds.sh` exits cleanly (PASS) when devkitARM is absent.
- [ ] With devkitARM present, the `-d:ds3` exerciser **compiles and links** via
      `arm-none-eabi-gcc` (libdl stub in place) and produces a `.3dsx`;
      `file` confirms an ARM binary (not host).
- [ ] In Azahar, the marker file shows: absent → `none()`/false and no raise;
      planted → found + parsed. (Or, if no marker: a documented manual check.)
- [ ] `capabilities.nim:12` comment **split** — 3DS marked verified (+date), PSP
      unchanged.
- [ ] Tier A (`nim check -d:ds3`) still passes — no regression.
- [ ] None of the contract invariants in `plan.md` changed; `nim.cfg` is not
      deleted or clobbered.

---

## Explicitly NOT part of this gate

- **No write/persistence testing via the configy API.** `configyFsWritable =
  false` on ds3, so `writeConfigJson`/`ensureConfigDir` short-circuit before any
  FS write. The marker file uses a raw `writeFile`, not configy's write API. The
  gate verifies the read path only. Enabling/verifying configy writes is Finding
  2 (deferred).
- **No `--os:Standalone`.** The real target is os:linux+newlib. Do not add a
  Standalone variant.
- **No PSP/Vita gate** and no flipping their capabilities comment — out of scope
  for this 3DS request (though the same `@if`-block template would extend later).

---

## Reference file map (copy from here)

| configy artifact | Source to mirror |
|------------------|------------------|
| `@if ds3:` block in `nim.cfg` | `~/git/raylib-nim-multiplatform/config.nims` (ds3 switches) + `nim_3ds.cfg` (toolchain paths/libs), merged; drop raylib `-I`/`-L` |
| `scripts/build_3ds.sh` (sans `cp nim.cfg`) | `~/git/raylib-nim-multiplatform/scripts/build_3ds.sh` |
| Azahar launch | `~/git/raylib-nim-multiplatform/scripts/run_3ds.sh` |
| prereqs / verify model | `~/git/raylib-nim-multiplatform/.agents/plans/multiplatform/08-toolchain-prereqs.md`, `09-verify.md` |
| libdl stub idiom | boxy `scripts/build_3ds.sh` |

> Note on `--opt`: the reference's `config.nims` sets `--opt:size` while its
> `build_3ds.sh` passes `-d:release --opt:none`. This is inconsistent in the
> source and does not affect the *link* outcome; this gate standardizes on
> `--opt:size` in the `@if ds3:` block.
