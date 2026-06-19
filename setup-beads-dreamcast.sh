#!/usr/bin/env bash
# Project: configy
# Change: Dreamcast config paths + real VMU persistence (-d:dreamcast)
# Generated: 2026-06-18
#
# Two-layer change:
#   Layer 1 (host-checkable, independently mergeable): register the dreamcast
#     platform across capabilities.nim/paths.nim, closing the silent fallthrough
#     to the desktop POSIX/XDG arm. Ships with configyFsWritable=false for
#     dreamcast — no KOS toolchain required.
#   Layer 2 (real VMU persistence): self-owned KOS FFI (vmu.nim), VMS packaging,
#     hash filename collapse, runtime isWritable() probe, store.nim routing,
#     Flycast smoke, then the configyFsWritable=true flip + version bump.
#
# Seam discipline (single-file collisions chained, never siblings):
#   capabilities.nim : CAPS_USESOS (first) -> FLIP_WRITABLE (last)
#   vmu.nim (NEW)    : FFI -> HASH -> ICON -> PKG_WRAP -> FREEBLOCKS -> PROBE
#   paths.nim        : PATHS_ROOT only
#   fs.nim           : FS_DREAMCAST only
#   store.nim        : STORE_DREAMCAST only
#   nim.cfg          : NIMCFG_DREAMCAST only

set -euo pipefail

if [ ! -d ".beads" ]; then
    bd init
fi

echo "Creating Dreamcast VMU task graph..."

# ============================================================
# Phase 1: Analysis & Preparation
# ============================================================

ANALYZE_CAPS=$(bd create "Analyze configy platform predicates for the dreamcast gaps" \
  -d "Audit src/configy/capabilities.nim, paths.nim, fs.nim, store.nim and document every hard-coded platform list dreamcast is missing from. CRITICAL finding to confirm: configyFsWritable (capabilities.nim:34-37) is 'when emscripten:false elif psp:false else:true' — with NO dreamcast arm, a dreamcast build falls through to 'else: true' (wrongly writable) AND configyUsesOsPath (:5) / configRoot() else-branch fall through to desktop POSIX/XDG (getHomeDir/XDG -> ConfigPathError on a HOME-less console). Output: the exact set of arms Layer 1 must add and the seam map." \
  -p 0 -l analysis -t task --silent)

ANALYZE_KOS=$(bd create "Catalog KOS VMU API surface against KallistiOS headers" \
  -d "Against ~/git/workspace/KallistiOS/kernel/arch/dreamcast/include/dc/ record exact signatures and types for: dc/vmufs.h (vmufs_file_write/read/delete, vmufs_free_blocks; blk_cnt is a RUNTIME field, never hard-code 200), dc/fs_vmu.h (/vmu/<port><unit>/ mount e.g. /vmu/a1/, 512B block multiples, no subdirs), dc/vmu_pkg.h (vmu_pkg_t fields; int vmu_pkg_build(vmu_pkg_t*, uint8_t**, int*); int vmu_pkg_parse(uint8_t*, size_t, vmu_pkg_t*) returns 0/-1 on bad CRC; 32x32 4bpp icon, icon_pal[16], 512B/frame). Note the maple_device_t* slot-lookup path (maple_enum_type) for port A slot 1. Feeds vmu.nim + nim.cfg + errors check." \
  -p 0 -l analysis -t task --silent)

CHAR_TESTS=$(bd create "Pin current configRoot/isWritable/caps behavior in host tests before the dreamcast arm" \
  -d "Add characterization assertions (extend tests/test_paths.nim + a caps test) that pin current behavior on existing targets BEFORE the dreamcast arm lands: desktop configRoot XDG/HOME resolution, configyUsesOsPath/configyHasRealFs/configyFsWritable values per existing -d:ds3/-d:vita/-d:psp/-d:emscripten. These are the guardrail the additive dreamcast arms must not perturb. Host-only (tests/config.nims supplies -d:configyVendor=testvendor)." \
  -p 0 -l prep -t task --silent)
bd dep add $CHAR_TESTS $ANALYZE_CAPS

BASELINE_ISSUE=$(bd create "Pre-existing nim check baseline failure (dep-less overloads) — not dreamcast" \
  -d "Standalone tracking bug: 'nim check -d:configyVendor=birbparty src/configy.nim' on pinned Nim 2.2.10 fails with PRE-EXISTING dep-less-overload errors at fs.nim:44, store.nim:62/120/etc, unrelated to Dreamcast. The dreamcast gate is 'no NEW nim check errors vs this baseline', NOT absolutely green. Capture the exact baseline error set here so the regression gate can diff against it." \
  -p 3 -l analysis -t bug --silent)
bd dep add $BASELINE_ISSUE $ANALYZE_CAPS

# ============================================================
# Phase 2: Layer 1 — register the platform (host-checkable)
# ============================================================

CAPS_USESOS=$(bd create "capabilities.nim: add dreamcast arms (usesOsPath + fsWritable=false) + provenance comment" \
  -d "FIRST and only Layer-1 edit to capabilities.nim. (1) Add 'or defined(dreamcast)' to configyUsesOsPath (:5) so dreamcast uses plain-string concat, not std/os DirSep. (2) Add 'elif defined(dreamcast): false' to configyFsWritable (:34-37) — read-only until Layer 2 lands; this is REQUIRED because the bare 'else: true' default would otherwise make dreamcast wrongly writable. (3) Leave configyHasRealFs (:2) true, no edit. (4) Add a '# Dreamcast:' provenance comment block mirroring the ds3/vita/psp notes, but do NOT use 'verified on real hardware' wording (emulator-only bar — see RESULTS task). The configyFsWritable=true FLIP is a SEPARATE later task (FLIP_WRITABLE) — do not flip here." \
  -p 0 -l impl -t feature --silent)
bd dep add $CAPS_USESOS $CHAR_TESTS

PATHS_ROOT=$(bd create "paths.nim: add elif defined(dreamcast) to configRoot() returning /vmu/a1/<vendor>/" \
  -d "Only edit to paths.nim. Add 'elif defined(dreamcast):' to configRoot() (:35-54) BEFORE the desktop else, returning exactly '/vmu/a1/' & VendorNamespace & '/' (e.g. /vmu/a1/birbparty/). Must never call getHomeDir()/getEnv(XDG_CONFIG_HOME) (empty HOME on Dreamcast -> ConfigPathError). configRoot() is built directly and NOT passed through validateComponent, so the leading '/' and 'a1' are safe. Update the doc-comment table (:25-34) to list the Dreamcast root. configDir/configFile already select string-concat via configyUsesOsPath — verify, do not re-edit." \
  -p 0 -l impl -t feature --silent)
bd dep add $PATHS_ROOT $CHAR_TESTS

L1_TESTS=$(bd create "Host tests for the Layer-1 dreamcast arms (configRoot, caps consts)" \
  -d "Add host-checkable tests under -d:dreamcast (note: dreamcast is not a nim.cfg build-config, so -d:dreamcast on host only proves the arms parse/type-check against host std/os): assert configRoot() == '/vmu/a1/' & VendorNamespace & '/', that it never raises ConfigPathError for missing HOME, configyUsesOsPath==false, configyHasRealFs==true, configyFsWritable==false (still, pre-flip). Extend tests/test_paths.nim style with a 'when defined(dreamcast)' block." \
  -p 1 -l testing -t task --silent)
bd dep add $L1_TESTS $CAPS_USESOS
bd dep add $L1_TESTS $PATHS_ROOT

L1_REGRESSION=$(bd create "Existing-platform regression gate (compileOnly matrix + desktop nimble test)" \
  -d "Concrete additive-only gate, mirroring the ds3/vita verification gates: run the per-platform 'nim c --compileOnly' matrix for desktop/ds3/vita/psp/emscripten and desktop 'nimble test'; confirm NO new nim check errors vs the BASELINE_ISSUE set, and that psp/wasm writes still raise ConfigUnsupportedError and ds3/vita behavior is unchanged. Layer 1 is shippable when this passes — no dependency on any Layer-2/FFI/smoke task." \
  -p 1 -l testing -t task --silent)
bd dep add $L1_REGRESSION $CAPS_USESOS
bd dep add $L1_REGRESSION $PATHS_ROOT

# ============================================================
# Phase 3: Layer 2 — vmu.nim KOS FFI (serialized single-file chain)
# ============================================================

VMU_FFI=$(bd create "NEW src/configy/vmu.nim: self-owned KOS FFI bindings + a1 slot constant + null-safe Maple lookup" \
  -d "Create src/configy/vmu.nim with {.importc, header: \"dc/vmufs.h\"/\"dc/fs_vmu.h\"/\"dc/vmu_pkg.h\".} bindings for vmufs_file_write/read/delete, vmufs_free_blocks, vmu_pkg_build/parse, and the maple_device_t* slot lookup. Define ONE shared slot constant (port A, unit 1 -> 'a1') used by BOTH the probe and the read/write path — they must never diverge. Maple-init precondition: configy must NOT init Maple (host app brings up KOS/maple_init); the slot lookup must be NULL-SAFE (maple_enum_type/lookup returns null -> caller gets 'absent', never a crash). MUST NOT import inputty. Document the ordering contract. First edit to vmu.nim; subsequent vmu.nim tasks are chained to avoid seam collisions." \
  -p 0 -l impl -t feature --silent)
bd dep add $VMU_FFI $ANALYZE_KOS

VMU_HASH=$(bd create "vmu.nim: deterministic path -> <=12-char uppercase filename hash (FROZEN contract)" \
  -d "Add the deterministic collapse of the full logical path '<vendor>/<app>/<dep>/<file>' to an uppercase, <=12-char VMU filename (no subdirs on VMU). Pin the exact algorithm (hash, truncation rule, uppercasing) and comment it as a FROZEN FORMAT CONTRACT — changing it orphans every previously-written VMU file on a ~100KB device. Define the collision response EXPLICITLY (two distinct logical paths -> same name: error vs overwrite) — a 12-char uppercase namespace is small enough this must be a decision. Same function is reused verbatim by the read path (parity). Chained on vmu.nim." \
  -p 0 -l impl -t feature --silent)
bd dep add $VMU_HASH $VMU_FFI

VMU_HASH_TESTS=$(bd create "Host unit tests for the path->filename hash incl. write-name==read-name parity" \
  -d "New host test file (no KOS toolchain): assert the hash is deterministic, output is uppercase and <=12 chars, and the defined collision response holds. CRITICAL: assert write-name(path) == read-name(path) for the same logical path — the read path (readConfigJson/configFileExists) must derive the identical VMU filename as the write path, or write-then-read silently fails. Runs on the host independent of KOS." \
  -p 1 -l testing -t task --silent)
bd dep add $VMU_HASH_TESTS $VMU_HASH

VMU_ICON=$(bd create "vmu.nim: committed default 32x32 4bpp VMU icon const (minimal valid glyph)" \
  -d "Define a single committed static const byte array: a valid 32x32 4bpp paletted icon (512B/frame) with icon_pal[16] for vmu_pkg_build, so written files appear in the BIOS file manager. A trivial recognizable placeholder glyph suffices — rich icon/LiveArea presentation is OUT OF SCOPE. Do not block the FFI on art. Chained on vmu.nim." \
  -p 2 -l impl -t task --silent)
bd dep add $VMU_ICON $VMU_HASH

VMU_PKG_WRAP=$(bd create "vmu.nim: VMS packaging wrap/unwrap (vmu_pkg_build on write, vmu_pkg_parse on read)" \
  -d "Wrap payloads in the VMS package format on write via vmu_pkg_build (valid header + the committed 32x32 4bpp icon) and unwrap on read via vmu_pkg_parse (returns -1 on bad CRC -> map to ConfigParseError). Round-trip: vmu_pkg_parse must recover exactly what vmu_pkg_build wrote. Chained on vmu.nim (needs VMU_ICON)." \
  -p 1 -l impl -t feature --silent)
bd dep add $VMU_PKG_WRAP $VMU_ICON

VMU_FREEBLOCKS=$(bd create "vmu.nim: free-block budgeting via vmufs_free_blocks + honest out-of-space" \
  -d "Query vmufs_free_blocks for the REAL budget at call time (never hard-code 200 blocks / 100KB). Enforce 512B-multiple sizing. When a write would exceed free blocks, report out-of-space honestly so store.nim can raise ConfigIOError — no partial write that looks like success. Chained on vmu.nim." \
  -p 1 -l impl -t feature --silent)
bd dep add $VMU_FREEBLOCKS $VMU_PKG_WRAP

VMU_PROBE=$(bd create "vmu.nim: runtime presence probe (VMU at a1 present + free blocks), null-safe" \
  -d "Implement the runtime probe used by fs.isWritable(): returns true only if the VMU at the shared a1 slot is present (via Maple) AND has free blocks (vmufs_free_blocks). MUST be null-safe — Maple not up / no VMU / full -> false, never a crash. Uses the SAME a1 slot constant as the write path. This is the runtime truth that reconciles with the compile-time configyFsWritable const. Chained on vmu.nim (last vmu.nim edit)." \
  -p 0 -l impl -t feature --silent)
bd dep add $VMU_PROBE $VMU_FREEBLOCKS

# ============================================================
# Phase 4: Layer 2 — errors confirmation + fs.nim + store.nim routing
# ============================================================

ERRORS_CHECK=$(bd create "errors.nim: confirm error taxonomy covers VMU failure modes" \
  -d "Confirm ConfigIOError (absent device / full / oversize), ConfigParseError (bad CRC on vmu_pkg_parse read), ConfigUnsupportedError (read-only / not writable), ConfigPathError cover all VMU failure modes. Add a NEW error type ONLY if a genuinely new mode exists (default: no edit — reuse the existing taxonomy). Document the mapping for the store.nim routing task." \
  -p 2 -l impl -t task --silent)
bd dep add $ERRORS_CHECK $ANALYZE_KOS

FS_DREAMCAST=$(bd create "fs.nim: dreamcast runtime isWritable() probe + flat-VMU ensureConfigDir/createDirTree" \
  -d "Only edit to fs.nim. isWritable() (:6-11): add a dreamcast arm that returns the runtime vmu probe result instead of the compile-time const, staying {.raises: [].} and non-throwing; must not regress const behavior on other platforms. createDirTree/ensureConfigDir (:13-65): add dreamcast behavior — the VMU is FLAT (no dir tree to create), so ensureConfigDir is a non-throwing best-effort no-op / presence check, NOT a createDir. Routes through vmu.nim's probe." \
  -p 0 -l impl -t feature --silent)
bd dep add $FS_DREAMCAST $VMU_PROBE

STORE_DREAMCAST=$(bd create "store.nim: dreamcast write/read/delete VMU routing with hash parity + raise-before-touch" \
  -d "Only edit to store.nim byte-core (storeBytes/loadBytes/notFound, :18-54) and the write entry points. Add a dreamcast path that routes through vmu.nim instead of std/os writeFile/readFile/fileExists/removeFile: VMS-wrap on write, parse on read, delete via vmufs_file_delete. BOTH write AND read/exists MUST apply the IDENTICAL path->VMU-filename hash (read/write parity) — keep the magic-byte (MagicRaw/MagicSnappy) framing INSIDE the VMS payload. Write entry points must consult runtime isWritable() and raise ConfigUnsupportedError BEFORE any FS/FFI touch when not writable (reconciles the 'when configyFsWritable' const-gate vs the runtime probe — they can never half-attempt a write). Preserve the empty-payload ConfigParseError contract (:156-158)." \
  -p 0 -l impl -t feature --silent)
bd dep add $STORE_DREAMCAST $FS_DREAMCAST
bd dep add $STORE_DREAMCAST $ERRORS_CHECK

# ============================================================
# Phase 5: Toolchain, build scripts, verify smokes, Flycast
# ============================================================

NIMCFG_DREAMCAST=$(bd create "nim.cfg: @if dreamcast KOS sh-elf toolchain block + host-vs-SH4 warning" \
  -d "Add an '@if dreamcast:' block mirroring '@if ds3:'/'@if psp:' (--cc:gcc, KOS sh-elf --cpu/--os, --threads:off, -d:useMalloc, -d:nimAllocPagesViaMalloc, -d:noSignalHandler, --opt:size, KOS sh-elf gcc path/exe/linkerexe, KOS includes/libs). Derive the SH-4/KOS link idioms ($KOS_BASE, kos-cc, romdisk, kos-ports) from ~/git/topdown/.agents/plans/dreamcast-support/01-toolchain-and-nim-sh4.md — do NOT assume the devkitARM/VitaSDK librt-stub idiom transfers. Include the warning comment: MUST set toolchain switches or '-d:dreamcast' silently builds a host binary. Only edit to nim.cfg." \
  -p 1 -l impl -t feature --silent)
bd dep add $NIMCFG_DREAMCAST $ANALYZE_KOS

BUILD_SCRIPTS=$(bd create "scripts/build_dreamcast.sh + build_dreamcast_write.sh + .gitignore entries" \
  -d "Mirror scripts/build_3ds*.sh / build_vita*.sh, carrying their load-bearing invariants: (a) absent toolchain (no sh-elf-gcc / no \$KOS_BASE) is a PASS-for-scope 'exit 0' so host CI stays green; (b) NEVER cp over the tracked nim.cfg — pass KOS paths on the 'nim c' line. build_dreamcast_write.sh is the thin write wrapper (mirrors build_vita_write.sh). Fold in .gitignore entries: /dreamcast_smoke, /dreamcast_write_smoke, and .elf/.cdi/.bin Dreamcast build intermediates, mirroring the ds3/vita .gitignore blocks." \
  -p 1 -l impl -t task --silent)
bd dep add $BUILD_SCRIPTS $NIMCFG_DREAMCAST

VERIFY_SMOKE=$(bd create "verify/dreamcast/dreamcast_smoke.nim + dreamcast_write_smoke.nim" \
  -d "Mirror verify/ds3/ and verify/vita/. dreamcast_write_smoke.nim exercises the full write round-trip — ensureConfigDir -> writeConfigJson (raw + supersnappy-compressed) -> writeConfigBytes -> read-back round-trip -> deleteConfig — against an fs_vmu-mounted VMU at a1, then writes a machine-readable PASS/FAIL marker to the VMU (or a host-readable sink) for host-side assertion. Use 'check'+CatchableError (NOT doAssert) so a failed step is reported, mirroring vita_write_smoke.nim. Include a README for Flycast steps." \
  -p 1 -l testing -t task --silent)
bd dep add $VERIFY_SMOKE $STORE_DREAMCAST
bd dep add $VERIFY_SMOKE $BUILD_SCRIPTS

FLYCAST_SMOKE=$(bd create "Run dreamcast_write_smoke round-trip on Flycast (the verification bar)" \
  -d "Build with build_dreamcast_write.sh and run dreamcast_write_smoke on the Flycast emulator with VMU emulation. Capture the marker and assert all steps PASS (ensure_create/ensure_again/write_json/read_json/write_json_z/read_json_z/write_bytes/read_bytes/delete/deleted_gone/cleanup, isWritable=true). This Flycast PASS is the LOCKED (risk-noted) bar that gates the configyFsWritable=true flip — NOT real hardware." \
  -p 0 -l testing -t task --silent)
bd dep add $FLYCAST_SMOKE $VERIFY_SMOKE

# ============================================================
# Phase 6: Flip + version bump + docs (gated on Flycast PASS)
# ============================================================

FLIP_WRITABLE=$(bd create "capabilities.nim: flip dreamcast configyFsWritable false->true (LAST edit, gated on Flycast)" \
  -d "Change the dreamcast arm of configyFsWritable from false to true. This MUST be the LAST edit to capabilities.nim and depends on FLYCAST_SMOKE PASS — never run parallel to the Layer-1 CAPS_USESOS edit. Update the Dreamcast provenance comment to record EMULATOR-verified status; do NOT use 'verified on real hardware' wording (that stays barred until the hardware re-verify follow-up closes)." \
  -p 0 -l impl -t feature --silent)
bd dep add $FLIP_WRITABLE $FLYCAST_SMOKE
bd dep add $FLIP_WRITABLE $CAPS_USESOS

NIMBLE_BUMP=$(bd create "configy.nimble: version bump to v0.5.0 once Dreamcast writes land" \
  -d "Bump version in configy.nimble (0.4.0 -> 0.5.0) once the configyFsWritable=true flip lands. Gated on FLIP_WRITABLE." \
  -p 2 -l docs -t chore --silent)
bd dep add $NIMBLE_BUMP $FLIP_WRITABLE

RESULTS_DOC=$(bd create ".agents/plans/dreamcast-writable/RESULTS.md (EMULATOR-ONLY banner)" \
  -d "Write the verification writeup mirroring .agents/plans/3ds-writable/RESULTS.md and vita-writable/RESULTS.md — BUT lead with an explicit 'EMULATOR-ONLY — NOT hardware-verified' banner (the OPPOSITE of the ds3/vita 'VERIFIED ON REAL HARDWARE' lead). Document the Flycast round-trip results, record emulator-only as a KNOWN RISK (Flycast may mask the same class of bug the 3DS sdmc:/ EINVAL did on real hardware), and link the open hardware re-verify follow-up. Gated on FLYCAST_SMOKE." \
  -p 1 -l docs -t task --silent)
bd dep add $RESULTS_DOC $FLYCAST_SMOKE

HW_REVERIFY=$(bd create "FOLLOW-UP: re-verify Dreamcast VMU write round-trip on physical hardware" \
  -d "Open follow-up: build dreamcast_write_smoke and run on a PHYSICAL Dreamcast + real VMU. Acceptance: every dreamcast_write_smoke marker (ensure_create..cleanup, isWritable=true) PASSes on hardware. Until this closes, NO 'hardware-verified' claim may appear anywhere (capabilities.nim provenance comment, RESULTS.md, README). Tracks the accepted risk of the emulator-only verification bar." \
  -p 2 -l testing -t task --silent)
bd dep add $HW_REVERIFY $FLIP_WRITABLE

echo ""
echo "Dreamcast VMU task graph created."
echo "Layer 1 (host-checkable, independently mergeable):"
echo "  $ANALYZE_CAPS $CHAR_TESTS $CAPS_USESOS $PATHS_ROOT $L1_TESTS $L1_REGRESSION"
echo "Layer 2 (VMU persistence):"
echo "  $ANALYZE_KOS $VMU_FFI $VMU_HASH $VMU_HASH_TESTS $VMU_ICON $VMU_PKG_WRAP $VMU_FREEBLOCKS $VMU_PROBE"
echo "  $ERRORS_CHECK $FS_DREAMCAST $STORE_DREAMCAST"
echo "  $NIMCFG_DREAMCAST $BUILD_SCRIPTS $VERIFY_SMOKE $FLYCAST_SMOKE"
echo "Flip + docs: $FLIP_WRITABLE $NIMBLE_BUMP $RESULTS_DOC $HW_REVERIFY"
echo "Baseline bug: $BASELINE_ISSUE"
echo ""
echo "Run 'bd ready' to see initial analysis tasks."
