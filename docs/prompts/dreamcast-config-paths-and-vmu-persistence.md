# Big Change Planning with Beads

## Agent Instructions

You are an expert software architect creating a comprehensive task breakdown for a change to an existing codebase. This task graph will be executed by AI agents working in parallel, coordinated through MCP Agent Mail with file reservations to prevent conflicts.

<quality_expectations>
Create a thorough, production-ready task graph. Include all necessary analysis, preparation, implementation, testing, and documentation tasks. Go beyond the basics — consider edge cases, error handling, security considerations, backwards compatibility, and integration points. Each task should be specific enough for an agent to execute independently without ambiguity.
</quality_expectations>

<critical_constraint>
You must NOT implement any of the changes yourself. Your ONLY output is a bash shell script containing `bd create` and `bd dep add` commands. Do NOT use `bd add` — the correct command is `bd create`. Do not write code. Do not create files other than the shell script. Do not modify existing files. Read and analyze the codebase, then produce the script.
</critical_constraint>

## Change Information

### Change Type
NEW_FEATURE — registering Sega Dreamcast (`-d:dreamcast`) as a first-class configy platform **and** building a real VMU (Visual Memory Unit) persistence backend. This is a new-platform port plus a genuinely new storage backend (KOS `vmufs`/`fs_vmu`/`vmu_pkg` FFI), not a path-prefix tweak like the 3DS/Vita ports.

### Description
Register Sega Dreamcast (`-d:dreamcast`, KallistiOS / `sh-elf-gcc` / SH-4) as a first-class configy platform and implement **real, working VMU persistence** — i.e. `configyFsWritable` reaches `true` on Dreamcast.

This proceeds in two layers that should both land:

**Layer 1 — register the platform + close the silent-fallthrough bug (foundation).**
configy currently has explicit per-platform branches for desktop, 3DS (`-d:ds3`), Vita (`-d:vita`), PSP (`-d:psp`), and WASM (`emscripten`) in `capabilities.nim`, `paths.nim`, and `fs.nim`. **`dreamcast` is in none of them.** Because the predicates are written as `not (defined(ds3) or defined(psp) or defined(vita) or defined(emscripten))`, a Dreamcast build silently falls through to the **desktop POSIX/XDG arm** — wrong on a console with no HOME and no general writable filesystem. Foundation work:
- `src/configy/capabilities.nim`: add `or defined(dreamcast)` to **`configyUsesOsPath`** (`:5`) so Dreamcast uses plain-string path concat, not `std/os` `DirSep`. Leave **`configyHasRealFs`** (`:2`) `true` (the VMU is a real, non-localStorage store; it has zero internal consumers, so it cannot implicitly gate POSIX behavior).
- `src/configy/paths.nim`: add a `dreamcast` branch to **`configRoot()`** (`:35-54`) **before** the desktop `else`, returning a VMU-nominal root so it never calls `getHomeDir()`/`getEnv("XDG_CONFIG_HOME")` (both meaningless on Dreamcast → empty HOME → `ConfigPathError`). The KOS `fs_vmu` VFS mounts each card at `/vmu/<port><unit>/` (e.g. `/vmu/a1/` for port A, slot 1). `configRoot()` is built directly and is NOT passed through `validateComponent`, so the leading `/` and the `a1` are safe.

**Layer 2 — real VMU persistence (the actual ask: writable Dreamcast).** Build a genuine VMU-backed store so `configyFsWritable` becomes `true` on Dreamcast and the standard write round-trip (`ensureConfigDir` → `writeConfigJson` raw+compressed → `writeConfigBytes` → `deleteConfig`) works. The Dreamcast storage reality drives the whole design:
- **No general-purpose writable FS.** Unlike the 3DS `sdmc:` or Vita `ux0:` (thin `std/os`-over-newlib path-prefix changes), the VMU is **not** reachable through `std/os` `writeFile`/`createDir`. It needs a dedicated FFI path to KOS: low-level `vmufs` (`dc/vmufs.h`: `vmufs_file_write`/`vmufs_file_read`/`vmufs_file_delete`, plus a free-block query) and/or the `fs_vmu` VFS layer (`dc/fs_vmu.h`), with BIOS-visible files wrapped in the **VMS package format** (`dc/vmu_pkg.h`: `vmu_pkg_build`/`vmu_pkg_parse`, header + mandatory 32×32 4bpp icon).
- **Flat namespace, ≤12-char uppercase filenames, no subdirectories.** configy's `<vendor>/<app>/<dep>/<file>` hierarchy does **not** map onto the VMU. **Decision (locked): use a deterministic hash-based collapse** — hash the full logical path to an uppercase, ≤12-char VMU filename. Collision-resistant and uniform (accepting opacity in the BIOS file manager). This breaks the directory model the other platforms share, so it needs a dedicated `dreamcast` write/read path rather than reusing `createDirTree`.
- **Block budget.** A standard VMU has ~200 user blocks × 512 B ≈ 100 KB usable, but this is hardware lore — query `vmufs_free_blocks` (`dc/vmufs.h`) for the real budget; never hard-code 200. Files must be multiples of 512 B. configy + supersnappy compression should fit small binding files; the write path must report out-of-space honestly (`ConfigIOError`).
- **Device presence is runtime, not compile-time.** **Decision (locked): `isWritable()` becomes a runtime probe on Dreamcast** — it checks VMU presence (via the Maple bus) and free blocks at call time, rather than reflecting the compile-time `configyFsWritable` const. This changes the `fs.nim:6-11` contract for this one platform: `isWritable()` is `{.raises: [].}` and must stay non-throwing. The target VMU may be absent or full; writes must fail gracefully.
- **Maple coupling.** VMU access needs a `maple_device_t*` for the slot — the same Maple bus the sibling inputty Dreamcast controller backend uses. **Keep configy's VMU FFI self-owned — do NOT import inputty.** Just note the shared subsystem.

**Layer 2 design contracts (resolve these in the task graph — they are the gaps an implementer would otherwise guess at):**
- **Slot policy: `a1` only.** `configRoot()` is pinned to `/vmu/a1/`, so Layer 2 must probe **and** write **port A slot 1 only**, via a single shared slot constant used by both the runtime probe and the write/read path (never let them diverge — diverging slots means reads hit a different card than writes). Multi-slot / first-present-VMU scanning is **out of scope** (consistent with the request's "Multi-VMU / slot selection UX" exclusion). If `a1` is absent, the device is "not writable" — do not silently fall back to another slot.
- **Maple-init precondition.** configy assumes the host app has already brought up KOS/Maple (`KOS_INIT_FLAGS` / `maple_init`); configy's FFI must **not** init Maple itself. The runtime probe must be **null-safe**: if `maple_enum_type`/slot lookup returns null (Maple not up, or no VMU), `isWritable()` returns `false` rather than crashing. Document this ordering contract.
- **Runtime-probe ↔ write-gate reconciliation (correctness-critical).** `configyFsWritable` is a compile-time `const` consumed by `when configyFsWritable:` at `fs.nim:45,60` and by the `store.nim` write entry points. Flipping it `true` for dreamcast compiles the write path *in* — but the locked runtime `isWritable()` probe can still return `false` (VMU absent/full). The store write entry points on dreamcast **must consult the runtime probe and raise before any FS/FFI touch** when not writable (the documented "raise before any FS touch" contract), so the const-gate and the runtime probe can never disagree into a half-attempted write.
- **Hash contract (frozen + collision response).** Pin the exact path→filename algorithm (hash of the full logical `<vendor>/<app>/<dep>/<file>`, truncation rule, uppercasing) and **comment it as a frozen format contract** — changing it orphans every previously-written VMU file (filename no longer derivable) on a ~100 KB device. Define the **collision response explicitly** (two distinct logical paths → same ≤12-char name): error vs. overwrite — a 12-char uppercase namespace is small enough that this must be a decision, not left implicit.
- **Read/write hash parity (first-class task + test).** The read path (`readConfigJson`/`configFileExists`, the `loadBytes`/`fileExists` core) must route through the **identical** hash + `vmu_pkg_parse`, or a write-then-read round-trip silently fails (write hashes the name; read looks for the literal hierarchical path). A host unit test must assert `write-name(path) == read-name(path)` for the same logical path, independent of any KOS toolchain.

**Verification (locked decision):** the bar for flipping `configyFsWritable=true` is a **Flycast emulator** round-trip (`dreamcast_write_smoke`), NOT real hardware. ⚠️ This deviates from the 3DS/Vita "verified on real hardware" bar and from the request's own warning (the 3DS `sdmc:/` EINVAL bug only surfaced on real hardware; Azahar masked it). This is an accepted, documented risk for this change — the plan must surface emulator-only verification as a known limitation in `RESULTS.md`, and leave a follow-up task to re-verify on physical hardware before any "hardware-verified" claim is made.

### Links to Relevant Documentation
- **Motivating request:** `~/.agents/projects/configy/requests/2026-06-18-dreamcast-config-paths-and-vmu-persistence.md`
- **Motivating plan (topdown Dreamcast port):** `~/git/topdown/.agents/plans/dreamcast-support/` (esp. `01-toolchain-and-nim-sh4.md` for the KOS `--cpu`/`--os` Nim profile)
- **Sibling request (shared Maple bus):** `~/.agents/projects/inputty/requests/2026-06-18-dreamcast-maple-controller-backend.md`
- **Prior console writable work to mirror (layout, scripts, smoke, RESULTS.md):** `.agents/plans/3ds-writable/RESULTS.md`, `.agents/plans/vita-writable/RESULTS.md`, and the committed `ds3_write_smoke`/`vita_write_smoke` binaries + `verify/ds3/`, `verify/vita/`, `scripts/build_3ds*.sh`, `scripts/build_vita*.sh`.
- **KOS VMU API (verified present at `~/git/workspace/KallistiOS/kernel/arch/dreamcast/include/dc/`):**
  - `dc/vmufs.h` — low-level FAT/block VMU FS: `vmufs_file_write`, `vmufs_file_read`, `vmufs_file_delete`, free-block query (`vmufs_free_blocks`); `blk_cnt` is a runtime field, do not hard-code 200. Docs: https://cadcdev.sourceforge.net/docs/kos-current/vmufs_8h.html
  - `dc/fs_vmu.h` — VFS layer; mounts each card at `/vmu/<port><unit>/` (e.g. `/vmu/a1/` = port A slot 1). VMUs have no subdirectories. Files must be multiples of 512 B and carry a header to appear in the BIOS menu. Docs: https://kos-docs.dreamcast.wiki/fs__vmu_8h.html and https://kos-docs.dreamcast.wiki/group__vmu.html
  - `dc/vmu_pkg.h` — VMS package: `int vmu_pkg_build(vmu_pkg_t *src, uint8_t **dst, int *dst_size)`, `int vmu_pkg_parse(uint8_t *data, size_t data_size, vmu_pkg_t *pkg)` (returns 0 / -1 on bad CRC). Icon must be 32×32, 4bpp paletted, ≤16 colors (≤15 with transparency), 512 B/frame. Docs: https://kos-docs.dreamcast.wiki/group__vmu__package.html and example https://kos-docs.dreamcast.wiki/vmu_2vmu__pkg_2vmu_8c.html
- **VMU filename limit (12 chars) reference:** https://sega.fandom.com/wiki/VMU
- **Emulator (verification target):** Flycast — VMU emulation. Treat emulator PASS as the agreed (but risk-noted) bar for this change.

### Affected Areas
- **`src/configy/capabilities.nim`** — `configyUsesOsPath` (`:5`, add `or defined(dreamcast)`); `configyFsWritable` (`:34-37`, add a `dreamcast` arm — `false` until Layer 2 lands, then `true`); `configyHasRealFs` (`:2`, leave `true`, no edit). Add a `# Dreamcast:` provenance comment block mirroring the existing 3DS/Vita/PSP notes.
- **`src/configy/paths.nim`** — `configRoot()` (`:35-54`): add `elif defined(dreamcast)` branch returning the `/vmu/a1/`-rooted nominal path before the desktop `else`. Update the doc comment table (`:25-34`) to list the Dreamcast root. `configDir`/`configFile` already pick string-concat via `configyUsesOsPath` — verify, don't re-edit.
- **`src/configy/fs.nim`** — `isWritable()` (`:6-11`): add the Dreamcast runtime-probe path (stays `{.raises: [].}`). `createDirTree` (`:13-36`) / `ensureConfigDir` (`:38-65`): add the `dreamcast` no-op-or-VMU-aware behavior (VMU is flat — there is no dir tree to create; `ensureConfigDir` should be a non-throwing best-effort no-op or a presence check).
- **`src/configy/store.nim`** — the byte-level core (`storeBytes`/`loadBytes`, `:18-50`+) currently calls `writeFile`/`readFile`/`fileExists`. Add a `dreamcast` write/read/delete path that routes through the new VMU module (VMS-wrap on write, parse on read) instead of `std/os` file I/O. **Both** the write **and** read/exists paths must apply the same path→VMU-filename hash collapse (see read/write parity contract above). Write entry points must consult the runtime `isWritable()` probe and raise *before any FS/FFI touch* when not writable (preserve the `ConfigUnsupportedError` / `ConfigParseError`-for-empty contract at `store.nim:156-158`).
- **`src/configy/vmu.nim` (NEW)** — self-owned KOS FFI module: `{.importc, header: "dc/vmufs.h" / "dc/fs_vmu.h" / "dc/vmu_pkg.h".}` bindings, the `vmu_pkg_t` wrap/unwrap, the deterministic path→`≤12-char uppercase` hash (frozen contract), free-block budgeting (via `vmufs_free_blocks`), null-safe Maple-slot (`a1`) device lookup, and the runtime presence probe. Must NOT import inputty.
- **Default VMU icon (committed asset, sub-task of `vmu.nim`)** — `vmu_pkg_build` needs a valid 32×32 4bpp paletted icon (512 B/frame, `icon_pal[16]`) for the file to appear in the BIOS menu. Define a single committed static `const` byte array with a minimal recognizable glyph (a placeholder is fine — rich icon/LiveArea presentation is out of scope). Don't block the FFI task on art: a trivial valid icon suffices.
- **`src/configy/errors.nim`** — confirm `ConfigIOError`/`ConfigUnsupportedError`/`ConfigParseError`/`ConfigPathError` cover the VMU failure modes (absent device, full, bad CRC on read, oversize). Add an error only if a genuinely new mode exists.
- **`nim.cfg`** — add an `@if dreamcast:` toolchain block mirroring the `@if ds3:` / `@if psp:` blocks (`--cc:gcc`, KOS `sh-elf` `--cpu`/`--os`, `-d:useMalloc`, etc.) per `topdown/.agents/plans/dreamcast-support/01-toolchain-and-nim-sh4.md`. Include the "MUST set toolchain switches or `-d:dreamcast` silently builds a host binary" warning comment.
- **`scripts/build_dreamcast.sh`, `scripts/build_dreamcast_write.sh` (NEW)** — mirror `build_3ds*.sh`/`build_vita*.sh`, **carrying their load-bearing invariants**: (a) absent toolchain (no `sh-elf-gcc`/`$KOS_BASE`) is a **PASS-for-scope `exit 0`** so host CI without the KOS toolchain stays green; (b) the script passes KOS paths on the `nim c` line and **never `cp`s over the tracked `nim.cfg`**. KOS link idioms differ from the devkitARM/VitaSDK librt-stub pattern (`$KOS_BASE`, `kos-cc`, romdisk, `kos-ports`) — derive these from the topdown toolchain plan, don't assume the Vita stub idiom transfers.
- **`.gitignore`** — add the new smoke artifacts (`/dreamcast_smoke`, `/dreamcast_write_smoke`, and any `.elf`/`.cdi`/`.bin` Dreamcast build intermediates), mirroring the ds3/vita `.gitignore` entries (folded into the build-script task).
- **`verify/dreamcast/dreamcast_smoke.nim`, `verify/dreamcast/dreamcast_write_smoke.nim` (NEW)** — mirror `verify/ds3/`, `verify/vita/`.
- **`tests/`** — Layer-1 host-checkable assertions under `-d:dreamcast` (configRoot value, isWritable, caps consts) + Layer-2 unit tests for the path→filename hash (determinism, ≤12 chars, uppercase, collision behavior) that run on the host without KOS.
- **`.agents/plans/dreamcast-writable/RESULTS.md` (NEW)** — verification writeup mirroring `3ds-writable`/`vita-writable`, explicitly flagging the emulator-only bar as a known risk + the hardware re-verify follow-up.
- **`configy.nimble`** — version bump (e.g. v0.5.0) once Dreamcast writes land.

### Success Criteria

**Layer 1 (host-checkable; no KOS toolchain required):**
- New `when defined(dreamcast)` arms add **no new** `nim check` errors vs the maintainer's clean baseline on a pinned Nim (2.2.10 validated 2026-06-18). NOTE: a bare `nim check -d:configyVendor=birbparty src/configy.nim` currently fails with **pre-existing** dep-less-overload errors (`fs.nim:44`, `store.nim:62/120/…`) unrelated to Dreamcast — file these as a separate configy issue; the gate is "no NEW errors", not "absolutely green".
- `configRoot()` under `-d:dreamcast` returns **exactly** `"/vmu/a1/" & VendorNamespace & "/"` (e.g. `/vmu/a1/birbparty/`), never calls `getHomeDir`/XDG, never raises `ConfigPathError` for missing HOME.
- `configyUsesOsPath` is **false** and `configyHasRealFs` is **true** on `dreamcast`.
- All existing targets (desktop/ds3/vita/psp/emscripten) compile and behave unchanged — purely additive. **Enforced by a concrete regression gate** (not a vague claim): run the existing per-platform `--compileOnly` matrix + desktop `nimble test`, and confirm psp/wasm writes still raise `ConfigUnsupportedError`, mirroring the ds3/vita verification gates.
- **Layer 1 is independently mergeable:** with `configyFsWritable=false` for dreamcast it is fully host-checkable and shippable without the KOS toolchain. No Layer-1 task may depend on any Layer-2/FFI/smoke task; the only L1→L2 hinge is the `configyFsWritable=true` flip + `.nimble` bump.

**Layer 2 (real VMU persistence):**
- `configyFsWritable` is **true** on Dreamcast and `isWritable()` is a **runtime probe** (VMU presence + free blocks via Maple/`vmufs`), staying `{.raises: [].}` and non-throwing.
- The full write round-trip works against an `fs_vmu`-mounted VMU: `ensureConfigDir` → `writeConfigJson` (raw + supersnappy-compressed) → `writeConfigBytes` → read-back round-trip → `deleteConfig`, verified by `dreamcast_write_smoke` on **Flycast**.
- VMU files are VMS-packaged (BIOS-visible: valid header + 32×32 4bpp icon) and `vmu_pkg_parse` round-trips what `vmu_pkg_build` wrote (CRC ok).
- Logical paths collapse deterministically to **uppercase ≤12-char** VMU filenames; the hash is collision-resistant, has a defined collision response, and is unit-tested on the host — including a `write-name(path) == read-name(path)` parity assertion so write and read agree without a KOS toolchain.
- Out-of-space and absent-device are reported honestly (`ConfigIOError` / `isWritable()==false`) — no partial write that looks like success; free budget queried via `vmufs_free_blocks` (never a hard-coded 200/100 KB).
- VMU FFI is self-owned (no `import inputty`).
- `RESULTS.md` documents the Flycast verification **and** explicitly records emulator-only as a known risk with a hardware-re-verify follow-up task open.
- `nim c` against the KOS `--cpu`/`--os` profile links cleanly (this is where a `std/os` call that won't compile under SH-4/newlib would surface — the only check that actually exercises the SH-4 seam).

### Constraints
- **Verification bar is Flycast emulator only** for this change (locked user decision) — explicitly *not* real hardware. This contradicts the 3DS/Vita precedent and the request's own "emulator PASS is not a hardware PASS" warning (3DS `sdmc:/` EINVAL only showed on hardware; Azahar masked it). The plan MUST treat this as an accepted, documented risk:
  - `RESULTS.md` leads with an explicit **"EMULATOR-ONLY — NOT hardware-verified"** banner (the *opposite* of the ds3/vita RESULTS, which lead with "VERIFIED ON REAL HARDWARE").
  - The `capabilities.nim` dreamcast provenance comment must **NOT** use "verified on real hardware" wording (unlike the ds3/vita comments) until hardware verification closes.
  - A concrete **follow-up bead** to re-verify on a physical Dreamcast + VMU, with real acceptance: which `dreamcast_write_smoke` markers must PASS, and that no "hardware-verified" claim may appear anywhere until it closes.
- **Sequencing (file-seam collisions):** `capabilities.nim`, `store.nim`, and `fs.nim` are each touched by more than one task — these must be **chained via `bd dep add`, never siblings**. In particular the `configyFsWritable=true` flip in `capabilities.nim` must be the **last** edit to that file and **depend on `dreamcast_write_smoke` PASS**; it must not run parallel to the Layer-1 `configyUsesOsPath` edit.
- **`isWritable()` is a runtime probe on Dreamcast** (locked) — it must remain `{.raises: [].}` and non-throwing, and must not regress the compile-time-const behavior on any other platform.
- **Hash-based filename collapse** (locked) — deterministic, uppercase, ≤12 chars; accept BIOS-menu opacity in exchange for collision resistance.
- **Self-owned VMU FFI** — configy must NOT import inputty, even though both touch the Maple bus.
- **Additive** — no changes to existing desktop/3DS/Vita/PSP/WASM branches beyond adding the `dreamcast` arm next to them; all existing smoke tests stay green.
- **Convention: keep platform logic in `capabilities.nim` + `paths.nim` where possible.** Layer 2 legitimately needs `dreamcast` branches in `fs.nim`, `store.nim`, and the new `vmu.nim` (the VMU is not a `std/os` target), but avoid scattering raw `defined(dreamcast)` beyond these seams.
- **Host `nim check` is necessary but not sufficient** — `dreamcast` is not a build-config define in `nim.cfg`/`config.nims`, so a host `nim check -d:dreamcast` only proves the new arms parse/type-check against host `std/os`; it does NOT exercise the SH-4/KOS/newlib seam. Don't let the host check stand in for the KOS-profile compile.
- **Out of scope:** VMU icon/LiveArea-style presentation beyond the minimal VMS header+icon needed to write at all; BIOS file-manager metadata beyond that; multi-VMU / slot-selection UX; SD/GDEMU/DreamShell alternative storage backends.

---

## Your Task

Analyze this codebase change and create a comprehensive **Beads task graph** using the `bd` CLI. Beads provides dependency-aware, conflict-free task management for multi-agent execution.

Before creating the task graph, you MUST first analyze the affected areas of the codebase:

1. Check `docs/specs/` and `docs/adr/` for existing architectural decisions
2. Examine the directory/module structure of the affected areas listed above
3. Identify key interfaces, APIs, and integration points that must be preserved
4. Note existing test patterns and coverage in the affected areas
5. Assess risk areas where changes could break existing functionality

Use your analysis to make each bead specific — reference actual file paths, module names, and patterns you observed.

Then generate a shell script that creates the complete task graph.

**IMPORTANT: Your ONLY deliverable is a bash shell script with `bd create` commands. Not an implementation plan. Not a design document. Not a code review. A runnable `.sh` script.**

---

## Output Format

Generate a shell script that creates the full task graph. The script should:

1. **Initialize Beads** (if not already initialized)
2. **Create all beads** with appropriate priorities
3. **Establish dependencies** between beads
4. **Add labels** for phase grouping

### Example Output

```bash
#!/bin/bash
# Project: configy
# Change: Dreamcast config paths + real VMU persistence (-d:dreamcast)
# Generated: 2026-06-18

set -e

# Initialize beads if needed
if [ ! -d ".beads" ]; then
    bd init
fi

echo "Creating change beads..."

# ========================================
# Phase 1: Analysis & Preparation
# ========================================

ANALYZE_CAPS=$(bd create "Analyze configy platform predicates (capabilities.nim, paths.nim, fs.nim, store.nim) and document every hard-coded platform list dreamcast is missing from" -p 0 --label analysis --silent)

ANALYZE_KOS=$(bd create "Catalog KOS VMU API surface (dc/vmufs.h, dc/fs_vmu.h, dc/vmu_pkg.h) against ~/git/workspace/KallistiOS — exact signatures, /vmu/a1 mount, 512B blocks, vmu_pkg_t fields" -p 0 --label analysis --silent)

CHAR_TESTS=$(bd create "Add characterization/host tests pinning current configRoot/isWritable behavior on existing targets before adding the dreamcast arm" -p 0 --label prep --silent)
bd dep add $CHAR_TESTS $ANALYZE_CAPS

# ========================================
# Phase 2: Layer 1 — register platform
# ========================================

CAPS_USESOS=$(bd create "Add 'or defined(dreamcast)' to configyUsesOsPath (capabilities.nim:5); leave configyHasRealFs true; add dreamcast provenance comment" -p 0 --label impl --silent)
bd dep add $CAPS_USESOS $CHAR_TESTS

PATHS_ROOT=$(bd create "Add elif defined(dreamcast) to configRoot() (paths.nim:35-54) returning exactly '/vmu/a1/' & VendorNamespace & '/' before desktop else; update doc table" -p 0 --label impl --silent)
bd dep add $PATHS_ROOT $CAPS_USESOS

# ... etc (Layer 2: vmu.nim FFI, VMS wrap, hash collapse, runtime isWritable,
#     store.nim VMU path, nim.cfg @if dreamcast, build scripts, smoke, RESULTS.md)
```

---

## Bead Creation Guidelines

### Priority Levels
- `-p 0` = Critical (blocking other work, or high-risk changes needing early validation)
- `-p 1` = High (important implementation work)
- `-p 2` = Medium (standard work)
- `-p 3` = Low (cleanup, nice-to-haves)

### Labels (Phase Grouping)
Use `--label` to group beads by phase:
- `analysis` - Understanding current state
- `prep` - Preparation work (characterization tests, feature flags, scaffolding)
- `impl` - Core implementation
- `testing` - Test coverage
- `migration` - Data/code migration
- `docs` - Documentation updates
- `cleanup` - Post-rollout cleanup

### Dependency Rules
1. Never create cycles
2. Analysis tasks should complete before implementation begins
3. Characterization tests should exist before changing code
4. Use `bd dep add CHILD PARENT` (child depends on parent completing first)
5. Parallel work should share a common ancestor, not depend on each other

### Task Granularity
- Each bead should be completable in **under 750 lines of code changed**
- Tasks should be atomic enough for one agent to complete without coordination
- If a task requires multiple file areas, consider splitting by file area

---

## Change-Specific Considerations

### For New Features
- Start with analysis of similar existing features (here: the 3DS and Vita writable ports are the direct precedent — same scripts/verify/RESULTS.md layout)
- The VMU backend is genuinely new (FFI, VMS packaging, hash collapse) — sequence FFI bindings → packaging → store routing → smoke
- Plan for emulator (Flycast) verification AND an explicit hardware-re-verify follow-up task
- Include documentation and changelog/version-bump updates

### For Migrations
- N/A for stored data (greenfield platform), but the path→VMU-filename hash is a one-way mapping — document it so a future format change has a migration story

### For Performance Changes
- VMU is tiny (~100 KB) and slow flash — verify supersnappy-compressed binding files fit the real `vmufs_free_blocks` budget; report out-of-space honestly

---

## File Reservation Planning

```bash
# CAUTION: shared single-file seams — keep edits minimal and coordinate
# capabilities.nim  : 3 consts, additive arms only (high read-fanout)
# paths.nim         : configRoot() only
# fs.nim            : isWritable() + ensureConfigDir/createDirTree dreamcast arm
# store.nim         : byte-level write/read/delete VMU routing
# vmu.nim (NEW)     : self-owned; no inputty import
# nim.cfg           : @if dreamcast block only (mirror @if ds3)
```

---

## Verification Steps

After generating the script:

1. **Run it**: `chmod +x setup-beads.sh && ./setup-beads.sh`
2. **Check ready work**: `bd ready` should show initial analysis/prep tasks

---

## Completeness Checklist

Ensure your task graph includes:

- [ ] Analysis of current platform predicates + KOS VMU API surface
- [ ] Characterization/host tests for existing behavior before the dreamcast arm
- [ ] Layer 1: `configyUsesOsPath` + `configRoot()` dreamcast arms (compile-clean, honest caps)
- [ ] Layer 2: new `src/configy/vmu.nim` KOS FFI (vmufs/fs_vmu/vmu_pkg), self-owned
- [ ] VMS packaging (vmu_pkg_build/parse) with a built-in 32×32 4bpp icon
- [ ] Deterministic path→uppercase-≤12-char hash collapse (frozen contract + defined collision response, host-unit-tested)
- [ ] Read/write hash **parity** task + `write-name == read-name` host test
- [ ] Slot policy pinned to `a1` via one shared constant (probe and write agree); multi-slot out of scope
- [ ] Maple-init precondition documented; runtime probe is **null-safe** (no crash when Maple down / VMU absent)
- [ ] Runtime `isWritable()` probe (Maple presence + `vmufs_free_blocks`), `{.raises: [].}`
- [ ] Write entry points consult the runtime probe and **raise before any FS/FFI touch** (reconcile `when configyFsWritable` const-gate vs runtime probe)
- [ ] `store.nim` VMU write/read/delete routing + read-only contract preserved
- [ ] Default committed 32×32 4bpp VMU icon asset (minimal valid glyph)
- [ ] Existing-platform regression gate (per-platform `--compileOnly` matrix + desktop `nimble test`; psp/wasm still raise `ConfigUnsupportedError`)
- [ ] Layer 1 subgraph independently mergeable (no L1 bead depends on L2/FFI/smoke)
- [ ] File-seam tasks chained (capabilities/store/fs), `configyFsWritable=true` flip is last + depends on smoke PASS
- [ ] Build scripts: exit-0-when-toolchain-absent + never `cp` over `nim.cfg` + KOS link/romdisk idiom
- [ ] `.gitignore` entries for `dreamcast_smoke`/`dreamcast_write_smoke` + build intermediates
- [ ] `nim.cfg` `@if dreamcast` KOS toolchain block + host-vs-SH4 warning
- [ ] `scripts/build_dreamcast*.sh`, `verify/dreamcast/*smoke*.nim`
- [ ] Out-of-space / absent-device honest failure (`ConfigIOError`)
- [ ] `dreamcast_write_smoke` round-trip on Flycast
- [ ] `.agents/plans/dreamcast-writable/RESULTS.md` documenting Flycast bar + emulator-only RISK
- [ ] Follow-up task: re-verify on real Dreamcast hardware before any "hardware-verified" claim
- [ ] Separate issue filed for the pre-existing dep-less-overload `nim check` baseline failure
- [ ] `configyFsWritable=true` flip + `configy.nimble` version bump, gated on smoke PASS
- [ ] Clear dependency chains with no cycles
```
