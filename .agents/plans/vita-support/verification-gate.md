# Vita Verification Gate — Design

Companion to [`plan.md`](./plan.md). Concrete design for proving configy compiles,
links, and runs its read path on a real Sony PS Vita toolchain (VitaSDK,
`--os:linux` + newlib, `arm-vita-eabi-gcc`), not just on the host `nim check`.

Everything here mirrors a **proven, working Nim-on-Vita build**:
`~/git/raylib-nim-multiplatform`. configy's gate is **much simpler** than that one
— configy has no raylib / SDL2 / vitaGL dependency, so it needs only libc + a few
`Sce*` stubs for file I/O. Where this doc says "mirror X," copy the pattern from
that repo and **strip every graphics lib**.

> Adapted from the 3DS gate ([`../3ds-support/verification-gate.md`](../3ds-support/verification-gate.md)).
> The Vita-specific newlib-`ux0:` question (the 3DS gate's analog of the libctru
> devoptab) is **resolved statically as YES** — see §"File I/O reaches ux0:" — so
> the runtime tier corroborates rather than discovers. The real residual risk is
> `-Wl,-q` relocation correctness (§"Residual risk").

---

## The two-tier model

| Tier | What it checks | Needs SDK? | Where it runs |
|------|----------------|-----------|---------------|
| **A** | Nim semantic analysis / codegen for `-d:vita` | No | Any machine, CI |
| **B** | Real C compile + link + `vita-elf-create` + runtime read-path corroboration | Yes (VitaSDK + Vita3K / hardware) | A machine with VitaSDK |

Tier A is what configy has today (host `nim check -d:vita`, plus the existing
`--compileOnly` CI matrix row). Necessary but **not sufficient** — it runs against
the host libc and proves nothing about linking on `arm-vita-eabi-gcc` + newlib.
Tier B is the new work.

Guiding principle (same as 3DS): **a missing toolchain is a PASS for scope, not a
failure.** The Tier B script detects absent VitaSDK and exits cleanly (exit 0), so
it is safe to invoke anywhere.

> **CI honesty caveat:** "PASS when toolchain absent" means the Tier B CI job is
> decorative until a runner actually has VitaSDK — a permanently-green Tier B job
> verifies nothing. The real signal is a human running Tier B once on a VitaSDK
> machine.

---

## File I/O reaches `ux0:` — resolved (the 3DS-devoptab analog)

On 3DS the read path worked because libctru auto-inits the `sdmc:` devoptab. **Vita
needs no devoptab** — that is a devkitPro concept with no Vita equivalent. VitaSDK's
newlib hardcodes the mapping in its C library syscall layer, which the installed
SDK confirms statically:

- `arm-vita-eabi/lib/libc.a` references `sceIoOpen`, `sceIoRead`, `sceIoGetstat`,
  `sceIoGetstatByFd`, `sceIoMkdir`, `sceIoClose`, `sceIoWrite`, `sceIoRemove`
  (verify with `arm-vita-eabi-nm libc.a | grep sceIo`). newlib's
  `_open_r`/`_stat_r`/`_read_r` are backed by these, and its path layer handles
  `:`-prefixed device paths like `ux0:`.
- There is **no `libScePosix`** — the mapping lives in `libc.a` itself. (The only
  "posix" lib in the sysroot is `libpcre2-posix`, unrelated.) Never reference
  `-lScePosix`.

So configy's read path — `configFileExists` → `fileExists` → C `stat`, and
`readConfigJson` → `loadBytes` → `readFile` → C `open`/`read` — links and reaches
`ux0:` **with no `sceIo*` shim**.

The reference build does its Vita file I/O with raw `sceIo*` (`src/debug_vita.nim`,
`src/vita_diag.nim`) as a deliberate zero-dependency-logging choice during graphics
bring-up — **not** because newlib I/O is unavailable. It even logs to
`ux0:data/...`, the exact prefix form `configRoot()` emits, so the path style is
already proven on hardware.

**Consequence for this gate:** the Tier B runtime step *corroborates* the read path;
it does not decide whether file I/O is possible. A `sceIo*` read shim in
`store`/`fs` is a **contingency only**, kept in the back pocket for the unlikely
case the runtime contradicts this static evidence — not a planned outcome.

---

## Residual risk: `-Wl,-q` relocation correctness (the genuine unknown)

The one Vita-specific item the gate cannot fully retire without hardware:

- `-Wl,-q` (`--emit-relocs`) is **mandatory**: `vita-elf-create` needs the retained
  relocations to emit SCE relocations into the `.velf`. Without them, `movw`/`movt`
  absolute addresses keep link-time values and data-abort when the module loads at
  a non-link base — what real hardware does.
- **Vita3K loads at the link base and hides this bug.** A Vita3K runtime pass is
  therefore weaker than the 3DS Azahar pass.
- **Strongest non-hardware signal: a successful `vita-elf-create`.** It consumes
  the relocations; if `-Wl,-q` were missing or wrong, it fails or emits a broken
  module. Foreground this in RESULTS. Hardware is the only gold check for the
  load-at-non-link-base path.

---

## The real Vita target (settled, not Standalone) — and where the flags MUST live

From `raylib-nim-multiplatform/config.nims` (vita branch) — the verified flag set:

```
--cpu:arm
--os:linux          # NOT standalone — VitaSDK newlib provides libc/file-I/O stubs
--mm:arc
--threads:off
-d:useMalloc
-d:nimAllocPagesViaMalloc
-d:noSignalHandler
--opt:size
```

Plus `-d:vita` and configy's mandatory `-d:configyVendor=<org>`.

**Critical wiring fact (same trap as 3DS):** if the toolchain paths live in a cfg
but `--cpu:arm --os:linux` are not set, the `arm.linux.gcc.*` block is **inert**
and `nim c -d:vita` silently builds a **host binary that proves nothing.** configy
has no root `config.nims`, so these switches must be added — they go in the
`@if vita:` block below.

**Do NOT add `-march`/`-mfpu`/`-mfloat-abi` flags.** Unlike the 3DS block (which
needs explicit `-march=armv6k -mtune=mpcore`), `arm-vita-eabi-gcc` already defaults
to `-march=armv7-a+simd -mfpu=neon -mfloat-abi=hard` (confirm with
`arm-vita-eabi-gcc -Q --help=target`). Copying the 3DS arch flags would target the
wrong CPU.

---

## Artifacts to add (Phase 1 — authorable with no toolchain)

### 1. `@if vita:` block in the **existing committed `nim.cfg`** (NOT a copied-over cfg)

Add alongside the existing `@if ds3:` / `@if psp:` blocks. Carries **both** the
target switches **and** the VitaSDK toolchain. Note how much is stripped vs the
reference `nim_vita.cfg` — no `-lraylib`, `-lSDL2`, `-lvitaGL`, `-lvitashark`,
`-lSceShaccCg*`, `-lmathneon`, `-lstdc++`, and none of the graphics `Sce*` stubs.

```
# Sony PS Vita (VitaSDK, os:linux + newlib). Graphics-free: configy needs only
# libc + a few Sce* stubs for file I/O — NOT the raylib/SDL2/vitaGL soup the
# reference build links. Target switches MUST be set here or `nim c -d:vita`
# silently builds a host binary (the arm.linux.gcc.* block is inert until an
# arm/linux target is selected). Toolchain paths assume the VitaSDK default at
# /usr/local/vitasdk.
@if vita:
  --cc:gcc
  --cpu:arm
  --os:linux
  --threads:off
  --define:useMalloc
  --define:nimAllocPagesViaMalloc
  --define:noSignalHandler
  --opt:size

  # Do NOT add -march/-mfpu: arm-vita-eabi-gcc defaults to
  # armv7-a+simd / neon / hard-float. (The 3DS block's armv6k/mpcore flags are
  # for a different CPU — do not copy them here.)

  arm.linux.gcc.path      = "/usr/local/vitasdk/bin"
  arm.linux.gcc.exe       = "arm-vita-eabi-gcc"
  arm.linux.gcc.linkerexe = "arm-vita-eabi-gcc"

  --passC:"-I/usr/local/vitasdk/arm-vita-eabi/include"

  # -Wl,-q (--emit-relocs) is MANDATORY on Vita: vita-elf-create needs the
  # retained relocations to emit SCE relocations into the .velf. Without it,
  # movw/movt absolute addresses keep their link-time values and data-abort when
  # the module loads at a non-link base on real hardware. (Vita3K loads at the
  # link base and HIDES this bug — see the residual-risk note above.)
  --passL:"-Wl,-q"
  --passL:"-L/usr/local/vitasdk/arm-vita-eabi/lib"

  # LINK ORDER MATTERS. GNU ld is single-pass left-to-right: it is libc's
  # _open_r/_stat_r that reference sceIoOpen/sceIoGetstat (which live in
  # SceIofilemgr_stub), so -lc/-lm MUST come BEFORE the Sce* stubs. Wrapping in
  # --start-group/--end-group is the robust alternative if order proves fiddly.
  --passL:"-lc -lm"
  # Minimal Sce stub set, KNOWN-INCOMPLETE from static evidence: libc.a's syscall
  # layer references sceKernelExitProcess/sceKernelGetProcessId (→ SceProcessmgr /
  # SceLibKernel) in addition to the SceIo* calls. Start here and APPEND whatever
  # the linker reports as unresolved.
  --passL:"-lSceIofilemgr_stub -lSceLibKernel_stub -lSceProcessmgr_stub"

  # Nim injects -ldl AND -lrt for os:linux targets. Vita ships a REAL libdl.a
  # (arm-vita-eabi/lib/libdl.a) so -ldl resolves natively — but it has NO librt,
  # and configy pulls in -lrt via std/os -> times (same as 3DS). An empty librt.a
  # stub on the link path (-L.) satisfies the flag; scripts/build_vita.sh creates
  # it in the build CWD. (A libdl.a stub is unnecessary; the real one is used.)
  --passL:"-L."
@end
```

Notes:
- `--mm:arc` is already set unconditionally at the top of `nim.cfg`; not repeated.
- The `Sce*` stub list is a **known-incomplete starting point** — treat unresolved
  symbols at link time as the source of truth and append what GCC reports.
- `/usr/local/vitasdk` is the VitaSDK default; mark it as the one spot a user edits
  for a non-default install.

> **Do NOT** reintroduce a `cp nim_vita.cfg nim.cfg` step. The reference build does
> this because its `nim.cfg` is transient; configy's `nim.cfg` is **tracked** —
> copying over it and `rm`-ing it on cleanup would delete a committed file.

### 2. Exerciser program — outside `tests/`, e.g. `verify/vita/vita_smoke.nim`

Place it **outside `tests/`** (as with 3DS): `tests/config.nims` injects
`-d:configyVendor=testvendor` for everything under `tests/`, which would fight the
vendor value the gate pins and desync the `ux0:` path. Pin one vendor value
(this doc uses `smoketest`) and use it consistently in the build command **and**
the planted-file path.

The program exercises the **read path only** (writes short-circuit at runtime once
`configyFsWritable = false` for vita) and emits a **machine-readable marker**:

```nim
import configy
# Under -d:vita configyFsWritable is false, so do NOT call configy's write/ensure
# APIs (writeConfigJson raises ConfigUnsupportedError; createDir is compiled out).
# Exercise only the read path:
let existsAbsent = configFileExists("smoke", "probe.json")   # expect false pre-plant
let gotAbsent    = readConfigJson("smoke", "probe.json")     # expect none(), must NOT raise

# Write a machine-readable marker. newlib reaches ux0:, so a plain writeFile to
# ux0:data/configy_smoke_result.txt works:
writeFile("ux0:data/configy_smoke_result.txt",
  "absent_exists=" & $existsAbsent & "\n" &
  "absent_isNone=" & $gotAbsent.isNone & "\n" &
  "resolved_path=" & configFile("smoke", "probe.json") & "\n")
```

For the planted-file case, re-run with a valid configy file planted on Vita3K's
`ux0` and additionally record whether `readConfigJson` parsed it.

> **Optional belt-and-suspenders:** a minimal raw `sceIo*` marker FFI (mirroring
> `raylib-nim-multiplatform/src/debug_vita.nim`, header `psp2/io/fcntl.h`) would
> guarantee the marker lands even in the unlikely event newlib I/O surprises us.
> It is **not required** — `writeFile` reaches `ux0:` — but it is a cheap way to
> make the marker independent of the very API under test. Use it only if you want
> that independence; do not treat it as load-bearing.

### 3. `scripts/build_vita.sh` (guarded build/link/package — no cp over nim.cfg)

Mirror the **structure** of `raylib-nim-multiplatform/scripts/build_vita.sh`, but
**without** the `cp …→nim.cfg` step (the `@if vita:` block makes it unnecessary)
and without any raylib/asset staging:

- Set `VITASDK` and `PATH` (`export PATH=$VITASDK/bin:$PATH`).
- **Guard:** if `arm-vita-eabi-gcc` (or `vita-elf-create` / `vita-pack-vpk`) is
  absent, print a clear "toolchain not installed" message and **exit 0** (PASS for
  scope — same intentional improvement over the reference's `exit 1` as the 3DS
  script).
- Create the empty **librt** stub: `arm-vita-eabi-ar rcs librt.a` (configy pulls in
  `-lrt` via `std/os → times`; Vita has no librt). A libdl stub is **not** needed —
  Vita ships a real `libdl.a`. Clean up on exit via `trap` (remove only `librt.a` +
  intermediates — **never `nim.cfg`**).
- Compile with an explicit `--out:` and thread that exact path into
  `vita-elf-create` (mirror how `build_3ds.sh` threads `$OUT_ELF` — the reference's
  literal `src/<module>` input path does **not** apply when you set `--out:`):
  ```sh
  OUT_ELF="$REPO_ROOT/vita_smoke"
  nim c -d:vita -d:release -d:configyVendor=smoketest \
    --path:src --path:verify/vita --out:"$OUT_ELF" verify/vita/vita_smoke.nim
  file "$OUT_ELF"        # sanity: must report ARM, not host
  ```
- **Package the `.vpk`** (required — Vita3K and hardware both run a `.vpk`):
  ```sh
  vita-elf-create  "$OUT_ELF"               vita_smoke.velf
  vita-make-fself  vita_smoke.velf          eboot.bin
  vita-mksfoex -s TITLE_ID=CFGY00001 "configy vita smoke" param.sfo
  vita-pack-vpk -s param.sfo -b eboot.bin   vita_smoke.vpk
  ```
  `vita-pack-vpk` places `param.sfo` into `sce_sys/` and `eboot.bin` at the VPK
  root itself — no manual staging dir is needed (that is what the reference's
  `zip -r` approach did instead; this 4-tool pipeline is the chosen, cleaner path,
  not a mirror of the reference's packaging). `TITLE_ID` is 4 letters + 5 digits;
  `CFGY00001` is fine for a smoke build.

### 4. Prereqs doc / README note — `verify/vita/README.md`

Mirror the reference toolchain prereqs:

```sh
# VitaSDK (installs arm-vita-eabi toolchain + vita-* tools)
git clone https://github.com/vitasdk/vdpm && cd vdpm && ./bootstrap-vitasdk.sh
export VITASDK=/usr/local/vitasdk
export PATH=$VITASDK/bin:$PATH

# Emulator (macOS)
brew install vita3k        # or download from https://vita3k.org
```

State plainly: the user installs the SDK; the script does not. Document **where
Vita3K's `ux0` lives on the host** for marker readback (this differs from Azahar's
path — confirm for your Vita3K version; do not assume the 3DS Azahar path) and the
Vita3K-hides-the-`-Wl,-q`-bug caveat.

---

## Phase 2 — Run it (requires VitaSDK + Vita3K / hardware)

1. **Link + `.velf` check (strongest signal without hardware).** Run
   `scripts/build_vita.sh` on a machine with VitaSDK.
   - PASS criterion: Nim transpiles, `arm-vita-eabi-gcc` compiles, and the link
     **succeeds** (no unresolved `fileExists`/`readFile`, no missing `-lrt`, all
     `Sce*` stubs resolved — record the real set), producing an ARM ELF.
   - `vita-elf-create` **succeeds** (this exercises `-Wl,-q`), and the `.vpk` is
     produced.
   - `file <out>` reports ARM, not host.
2. **Runtime read-path corroboration (Vita3K).**
   - **Vita3K caveat (critical):** Vita3K loads at the link base and **hides** the
     `-Wl,-q` relocation/data-abort bug. A Vita3K pass confirms read-path *logic*,
     not relocation correctness, and is **weaker than the 3DS Azahar pass.** Do not
     present a Vita3K-only run as "verified like 3DS."
   - **Absent-file run:** launch with no probe planted; read the marker back from
     Vita3K's host `ux0` dir. Assert `absent_exists=false`, `absent_isNone=true`.
   - **Planted-file run:** plant a valid configy file (magic byte `0x00` + JSON) at
     `<ux0>/data/config/smoketest/smoke/probe.json` (vendor segment MUST equal the
     compiled-in `configyVendor`). Relaunch; assert found + parsed.
3. **Hardware run (if available)** — the only way to retire the `-Wl,-q` risk. If no
   hardware, say so plainly in RESULTS.
4. **Add the capabilities comment** — a Vita read-path-verified-on-VitaSDK-`<date>`
   line in `capabilities.nim` (an **add**, not a split — vita has no existing
   comment line there), keeping `configyFsWritable = false`.
5. **Write [`RESULTS.md`](./RESULTS.md)** foregrounding the link + `vita-elf-create`
   outcome and the honest runtime tier (Vita3K vs hardware).

---

## Acceptance criteria

- [ ] `vita` added to `configyFsWritable`'s read-only set (`= false` under `-d:vita`),
      with a new vita comment line.
- [ ] An `@if vita:` block exists in the committed `nim.cfg` setting `--cpu:arm
      --os:linux` + `-Wl,-q` + VitaSDK toolchain; **correct link order** (`-lc -lm`
      before `Sce*` stubs, or `--start-group`); **no** raylib/SDL/vitaGL libs; **no**
      `-march`/`-mfpu` flags; no `cp`/`rm` touches `nim.cfg`.
- [ ] `scripts/build_vita.sh` exits cleanly (PASS) when VitaSDK is absent.
- [ ] With VitaSDK present, the `-d:vita` exerciser **compiles and links** via
      `arm-vita-eabi-gcc` (librt stub in place), **`vita-elf-create` succeeds**, and
      a `.vpk` is produced; `file` confirms an ARM binary (not host).
- [ ] Runtime marker shows: absent → `none()`/false and no raise; planted → found +
      parsed. RESULTS states the achieved tier (Vita3K vs hardware) honestly and
      foregrounds the `-Wl,-q`/`vita-elf-create` result.
- [ ] `capabilities.nim` gains a Vita read-verified (+date) comment; writes deferred.
- [ ] Tier A (`nim check --path:src -d:vita`) still passes — no regression.
- [ ] Existing CI vita matrix row untouched (but its comment updated to reflect the
      arm/linux upgrade); `nim.cfg` not deleted or clobbered.

---

## Explicitly NOT part of this gate

- **No write/persistence testing via the configy API.** With `configyFsWritable =
  false` on vita, `writeConfigJson`/`ensureConfigDir` short-circuit (the former at
  runtime, the latter compiled out). Enabling/verifying configy writes on Vita is
  the deferred follow-up — low-cost, since newlib also backs `write`/`remove` with
  `sceIo*`.
- **No `--os:Standalone`.** The real target is os:linux+newlib.
- **No raylib/SDL2/vitaGL.** configy is graphics-free; strip all of it.
- **No `sceIo*` read shim.** Unneeded — newlib reaches `ux0:`. Contingency only.
- **No PSP changes.** PSP's `nim.cfg` example stays flagged-but-unverified.

---

## Reference file map (copy from here)

| configy artifact | Source to mirror |
|------------------|------------------|
| `@if vita:` block in `nim.cfg` | `~/git/raylib-nim-multiplatform/config.nims` (vita switches) + `nim_vita.cfg` (toolchain paths, `-Wl,-q`, **link order**); **drop all raylib/SDL2/vitaGL libs and all `-march`/`-mfpu` flags** |
| `verify/vita/vita_smoke.nim` | configy's own `verify/ds3/ds3_smoke.nim` (structure); optional `sceIo*` marker FFI from `~/git/raylib-nim-multiplatform/src/debug_vita.nim` |
| `scripts/build_vita.sh` (sans `cp nim.cfg`, sans assets) | `~/git/raylib-nim-multiplatform/scripts/build_vita.sh` (packaging) + configy `scripts/build_3ds.sh` (`$OUT_ELF` threading, exit-0 guard, stub idiom) |
| Vita3K launch | `~/git/raylib-nim-multiplatform/scripts/run_vita.sh` |
| prereqs / verify model | `~/git/raylib-nim-multiplatform/.agents/plans/multiplatform/08-toolchain-prereqs.md` + configy's `verify/ds3/README.md` |
| librt stub idiom | configy `scripts/build_3ds.sh` |
