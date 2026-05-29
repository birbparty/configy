# Project Planning with Beads

## Agent Instructions

You are an expert software architect creating a comprehensive task breakdown. This task graph will be executed by AI agents working in parallel, coordinated through MCP Agent Mail with file reservations to prevent conflicts.

<quality_expectations>
Create a thorough, production-ready task graph. Include all necessary setup, implementation, testing, and documentation tasks. Go beyond the basics - consider edge cases, error handling, security considerations, and integration points. Each task should be specific enough for an agent to execute independently without ambiguity.
</quality_expectations>

## Project Information

### Links to Relevant Documentation
- `/Users/punk1290/.agents/plans/configy/README.md` — overview, path scheme, quick start, platform support summary
- `/Users/punk1290/.agents/plans/configy/architecture.md` — module breakdown, canonical type/proc signatures (authoritative on signature drift)
- `/Users/punk1290/.agents/plans/configy/api-design.md` — full public API surface, error model, platform guards, usage examples
- `/Users/punk1290/.agents/plans/configy/platform-matrix.md` — per-platform read/write/stub capability matrix, 3DS/PSP caveat, WASM v1/v2 plan

### Project Description
`configy` is a small, cross-platform configuration **path resolver** and **storage** library for Nim. It answers: *"Where do I put my config data on this platform, and how do I read/write it safely?"*

The library resolves a predictable, vendor-namespaced directory path across six platforms (Linux/macOS desktop, Windows, Nintendo 3DS, PSP, PS Vita, and WebAssembly/localStorage), creates it on first use where writable, and provides JSON read/write helpers with optional Snappy compression. It is **not** a config schema framework — it is plumbing.

Key design decisions baked in:
- The vendor/organization namespace is set at **compile time** via `-d:configyVendor=yourorg`. Build fails if unset. This lets all of an org's apps share a predictable config root without tying the library to any one owner.
- A config store keyed by `<app>/<dep>` lets many libraries coexist without collision. The consuming application supplies `<app>`; each library supplies `<dep>`.
- Every path is `<root>/<vendor>/config/<app>/<dep>/`, adapted per platform.
- "Can I compute the path" (always yes) and "can I write there" (varies per platform) are kept strictly separate.
- Console paths (3DS, PSP, Vita) use plain string concatenation — they are device-prefixed strings that `std/os` normalization would corrupt.
- WASM is fully stubbed in v1 (read → `none()`, write → `ConfigUnsupportedError`); v2 implements localStorage JS interop via `EM_JS`/`{.emit.}`.
- 3DS and PSP write capability is conservatively gated OFF in v1 (`configyFsWritable = false`) because SDK write support cannot be confirmed from planning docs alone.

### Technical Stack
- **Language:** Nim (ARC memory model)
- **Package manager:** Nimble (`configy.nimble`)
- **External dependency:** `supersnappy` (pure Nim, Snappy compression; compiles on all targets — pending verification on devkitARM/PSPDEV/VitaSDK)
- **Stdlib:** `std/os`, `std/json`, `std/options`
- **Testing:** `testament` test runner
- **Target platforms:**
  - Desktop: Linux / macOS
  - Windows
  - Nintendo 3DS (`-d:ds3`, devkitARM/libctru)
  - PSP (`-d:psp`, PSPDEV)
  - PS Vita (`-d:vita`, VitaSDK)
  - WebAssembly (`-d:emscripten`, Emscripten)

### Specific Requirements
- **Compile-time vendor namespace:** `-d:configyVendor=yourorg` required; `static: when len == 0: {.error.}` guard in `capabilities.nim`. Every compile — including all test runs — fails without this define. A `tests/config.nims` supplying `-d:configyVendor=testvendor` is a prerequisite for every test task.
- **Build config:** `nim.cfg` at repo root must set `--mm:arc`. Required before any compile task.
- **ARC-compatible:** plain value types and `seq`/`string` only; no cycles, no custom GC hooks; `JsonNode` is a `ref` managed by ARC but never stored in module-level state.
- **No global mutable state:** every proc takes all inputs as parameters; no hidden "current app" singleton.
- **Exceptions, not `Result`:** `ConfigError` hierarchy — `ConfigPathError`, `ConfigIOError`, `ConfigParseError`, `ConfigUnsupportedError`. Genuine queries use `bool`/`Option[T]`.
- **Centralized platform gating:** all `when defined(...)` checks centralized in `capabilities.nim` as named consts (`configyFsWritable`, `configyUsesOsPath`, `configyHasRealFs`, `configyHasSnappy`). The one sanctioned exception: per-console prefix selection inside `configRoot()` in `paths.nim` must use raw `when defined(ds3)/elif defined(psp)/...` because the consts model binary capability flags, not which device prefix to emit. Every other platform branch uses the named consts.
- **`isWritable()` v1 behavior:** returns `configyFsWritable` directly (the compile-time const). No runtime probe in v1.
- **`validateComponent` is exported (`*`)** — `architecture.md` (authoritative on drift) declares it with `*`. Rejection rules, uniform across all three components (app, dep, filename):
  - Empty string → reject
  - Contains `/` or `\` → reject (path separator injection)
  - Exactly equals `..` (i.e., `s == ".."`) → reject (path traversal). Substrings like `my..backup.json` are **allowed** — with `/` and `\` already blocked, embedded `..` cannot form `../` traversal in practice
  - Contains `:` anywhere → reject in **all three components** including filenames. Rationale: configy's cross-platform contract includes Windows; `:` in a filename produces an NTFS Alternate Data Stream (silent data-loss bug) or a drive-letter reinterpretation mid-path. Portable timestamps must use dashes (`2026-01-01T12-00.json`), not colons
- **`ensureConfigFile` lives in `store.nim`** (not `fs.nim`) — `architecture.md` is authoritative on this. Agents implementing `IMPL_FS` and `IMPL_STORE` must not both claim this proc.
- **Magic byte format:** every file begins with `\x00` (raw) or `\x01` (Snappy). Files are self-describing; mixed compressed/uncompressed in the same dir work correctly. A 0-byte file or unknown magic byte raises `ConfigParseError`. A 1-byte file (magic byte only, empty payload) is also malformed — parsing an empty payload must raise `ConfigParseError`. Writes are NOT atomic in v1.
- **Console path safety:** `sdmc:/`, `ms0:/PSP/`, `ux0:data/` are built via plain string concatenation only — never routed through `os.normalizedPath` or the `/` operator.
- **WASM v1 stubs:** `wasm.nim` declares exactly four procs (all under `when defined(emscripten)`): `setItem` (raises `ConfigUnsupportedError`), `getItem` (returns `none()`), `removeItem` (raises `ConfigUnsupportedError` — consistent with write; we do not support partial lifecycle), `hasItem` (returns `false` — used by `configFileExists` WASM routing). Do NOT declare `setItemBase64`/`getItemBase64` in v1; those are v2 only. In v1, `writeConfigBytes`/`readConfigBytes` on WASM route through plain `setItem`/`getItem`. `deleteConfig` on WASM v1 raises `ConfigUnsupportedError` (write and delete are both unsupported until the full localStorage lifecycle is implemented in v2).
- **WASM v2 scope:** v2 is in scope for this task graph. When WASM is supported it must support the full read/write/delete lifecycle. v2 work: implement `setItem`/`getItem`/`removeItem` via Emscripten JS interop (`EM_JS`/`{.emit.}`), add `setItemBase64`/`getItemBase64` for the binary/compression path (localStorage is UTF-16; raw Snappy output and magic bytes cannot survive `setItem`/`getItem` intact), flip `configyFsWritable` to `true` for `emscripten`. v2 beads should be included in the graph at lower priority than v1 core.
- **supersnappy console verification:** open item tracked as a dedicated spike task — must verify supersnappy compiles cleanly under devkitARM, PSPDEV, and VitaSDK before enabling console writes. Outcome may require adding a `when configyFsWritable: import supersnappy` guard to `store.nim`.
- **Path input validation:** `validateComponent(s)` rejects empty strings, `/`, `\`, `..`, and `:` to prevent path traversal and device-prefix corruption.
- **Test coverage:** path resolution per platform (desktop-runnable), `validateComponent` boundary cases — each of these must raise `ConfigPathError`: empty string, `/`, `\`, exact `..`, `:` in any position; and these must NOT raise: `my..backup.json` (embedded `..` is allowed), `settings.json` (normal filename). JSON + binary + typed-generic round-trip, compression/decompression, missing-file → `none()`, 0-byte file → `ConfigParseError`, 1-byte file (magic byte + empty payload) → `ConfigParseError`, unknown magic byte → `ConfigParseError`, corrupt Snappy payload → `ConfigParseError`, `to(T)` conversion failure → `ConfigParseError`, write-on-read-only target → `ConfigUnsupportedError`, cross-format read mismatch (bytes file read via `readConfigJson` → `ConfigParseError`), Snappy round-trip correctness on tiny input.

---

## Your Task

Analyze this project and create a comprehensive **Beads task graph** using the `bd` CLI. Beads provides dependency-aware, conflict-free task management for multi-agent execution.

---

<critical_constraint>
Your ONLY output is a bash shell script. Do NOT use `bd add` — the correct command to create a bead is `bd create`. Use `bd dep add` for dependencies. Do not implement anything yourself.
</critical_constraint>

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
# Generated: 2026-05-29

set -e

if [ ! -d ".beads" ]; then
    bd init
fi

echo "Creating project beads..."

# ========================================
# Phase 1: Project Setup & Infrastructure
# ========================================

SETUP_NIMBLE=$(bd create "Initialize configy.nimble with metadata and supersnappy dep" \
  -d "Create configy.nimble: name=configy, version, author, license (MIT), requires nim >= 2.0.0 and supersnappy. Add 'task test' calling testament. Set srcDir = \"src\"." \
  -p 0 --label setup --silent)

SETUP_NIMCFG=$(bd create "Create nim.cfg with --mm:arc" \
  -d "Create nim.cfg at repo root containing: --mm:arc. Add comments with cross-compile invocation examples for -d:ds3/-d:psp/-d:vita/-d:emscripten." \
  -p 0 --label setup --silent)
bd dep add $SETUP_NIMCFG $SETUP_NIMBLE

# CRITICAL: tests/config.nims must exist before any test task — without it every
# nim compile fails at the static vendor guard in capabilities.nim.
SETUP_TESTCFG=$(bd create "Create tests/config.nims with -d:configyVendor=testvendor" \
  -d "Create tests/config.nims: switch(\"define\", \"configyVendor=testvendor\"). This is a prerequisite for all test tasks — without it every compile fails at the static{.error.} guard in capabilities.nim." \
  -p 0 --label setup --silent)
bd dep add $SETUP_TESTCFG $SETUP_NIMBLE

SETUP_TESTAMENT=$(bd create "Wire testament test runner and create tests/ scaffold" \
  -d "Ensure 'nimble test' invokes testament. Create tests/ directory with empty placeholder. Confirm 'nimble test' exits cleanly on an empty suite before any impl task begins." \
  -p 0 --label setup --silent)
bd dep add $SETUP_TESTAMENT $SETUP_TESTCFG
bd dep add $SETUP_TESTAMENT $SETUP_NIMCFG

# ========================================
# Phase 2: Core Modules
# ========================================
# NOTE: capabilities.nim and errors.nim have no deps on each other — build in parallel.

IMPL_CAPS=$(bd create "Implement capabilities.nim compile-time consts" \
  -d "src/configy/capabilities.nim. Consts: configyHasRealFs, configyFsWritable (false for emscripten/ds3/psp; true otherwise), configyUsesOsPath (false for ds3/psp/vita/emscripten), configyHasSnappy, VendorNamespace. Static guard on empty configyVendor. No logic, consts only." \
  -p 0 --label core --silent)
bd dep add $IMPL_CAPS $SETUP_NIMCFG

IMPL_ERRORS=$(bd create "Implement errors.nim ConfigError hierarchy" \
  -d "src/configy/errors.nim. Types: ConfigError, ConfigPathError, ConfigIOError, ConfigParseError, ConfigUnsupportedError. No logic, type definitions only. No deps on capabilities." \
  -p 0 --label core --silent)
bd dep add $IMPL_ERRORS $SETUP_NIMCFG

# paths.nim depends on BOTH capabilities and errors.
IMPL_PATHS=$(bd create "Implement paths.nim cross-platform path resolution" \
  -d "src/configy/paths.nim. Exports: validateComponent* (security gate — raises ConfigPathError on: empty string, contains '/' or '\\', s==\"..\", contains ':'). NOTE: embedded '..' like 'my..backup.json' is ALLOWED — only the bare segment \"..\" is rejected. ':' is rejected everywhere including filenames (NTFS ADS / Windows portability). configRoot*, configDir*, configFile*. IMPORTANT: configRoot uses raw when defined(ds3)/elif defined(psp)/... for per-console prefix selection — sanctioned exception to the capabilities centralization rule. Console branches use plain string concat only, never std/os. Desktop/Windows use std/os / operator. configDir calls validateComponent on app and dep. configFile calls validateComponent on filename." \
  -p 0 --label core --silent)
bd dep add $IMPL_PATHS $IMPL_CAPS
bd dep add $IMPL_PATHS $IMPL_ERRORS

IMPL_FS=$(bd create "Implement fs.nim write-capability gating and dir creation" \
  -d "src/configy/fs.nim. Exports: isWritable* (v1: returns configyFsWritable directly, no runtime probe), ensureConfigDir*. ensureConfigDir is non-throwing on read-only targets: resolves path, creates dir only when isWritable(), raises ConfigIOError only if create is attempted and fails. No-op on WASM. Does NOT own ensureConfigFile — that lives in store.nim." \
  -p 0 --label core --silent)
bd dep add $IMPL_FS $IMPL_PATHS

# wasm.nim imports only errors + capabilities — no store dep. Implement in parallel with fs/store.
IMPL_WASM=$(bd create "Implement wasm.nim v1 localStorage stubs (emscripten only)" \
  -d "src/configy/wasm.nim. All procs under 'when defined(emscripten)': setItem(raises ConfigUnsupportedError), getItem(returns none()), removeItem(returns false), hasItem(returns false — used by configFileExists WASM routing). Do NOT add setItemBase64/getItemBase64 — those are v2 scope." \
  -p 0 --label core --silent)
bd dep add $IMPL_WASM $IMPL_CAPS
bd dep add $IMPL_WASM $IMPL_ERRORS

IMPL_STORE=$(bd create "Implement store.nim: byte core, JSON, binary, typed, file mgmt" \
  -d "src/configy/store.nim. Private: MagicRaw='\\x00', MagicSnappy='\\x01', storeBytes, loadBytes (raises ConfigParseError on 0-byte, 1-byte/empty-payload, unknown magic, corrupt Snappy), notFound. Public: ensureConfigFile*, writeConfigJson*, readConfigJson*, writeConfigBytes*, readConfigBytes*, writeConfig*[T], readConfig*[T], deleteConfig*, configFileExists*. ensureConfigFile lives HERE not fs.nim. WASM routing: write paths call wasm.setItem (raises in v1); configFileExists calls wasm.hasItem (false in v1); read paths call wasm.getItem (none() in v1). Compile-time generic guards on writeConfig/readConfig." \
  -p 0 --label core --silent)
bd dep add $IMPL_STORE $IMPL_FS
bd dep add $IMPL_STORE $IMPL_WASM

IMPL_UMBRELLA=$(bd create "Implement src/configy.nim umbrella re-export module" \
  -d "src/configy.nim. import+export: capabilities, errors, paths, fs, store. When defined(emscripten): import+export wasm. Run 'nim c -d:configyVendor=testvendor src/configy.nim' to verify clean compile on desktop." \
  -p 0 --label core --silent)
bd dep add $IMPL_UMBRELLA $IMPL_STORE

# ========================================
# Phase 3: Supersnappy Console Verification Spike
# ========================================

SPIKE_SNAPPY=$(bd create "Verify supersnappy compiles under devkitARM, PSPDEV, VitaSDK" \
  -d "Spike: compile a minimal supersnappy usage against each console toolchain. Document outcome. If any target fails to compile, a follow-up task must add 'when configyFsWritable: import supersnappy' guard to store.nim. Close with findings." \
  -p 2 --label analysis --silent)
bd dep add $SPIKE_SNAPPY $IMPL_STORE

# ========================================
# Phase 4: Testing
# ========================================

TEST_ERRORS=$(bd create "Write tests/test_errors.nim error hierarchy tests" \
  -d "tests/test_errors.nim. Verify: all five types catchable as ConfigError, correct type raised per failure mode (bad component → ConfigPathError, write-on-RO → ConfigUnsupportedError, corrupt file → ConfigParseError, FS failure → ConfigIOError)." \
  -p 1 --label testing --silent)
bd dep add $TEST_ERRORS $SETUP_TESTAMENT
bd dep add $TEST_ERRORS $IMPL_UMBRELLA

TEST_PATHS=$(bd create "Write tests/test_paths.nim path resolution and validation tests" \
  -d "tests/test_paths.nim. Cover: configRoot/configDir/configFile string output per platform (desktop-runnable assertions). validateComponent — must raise ConfigPathError: empty string, '/', '\\', exact '..', ':' anywhere. Must NOT raise: 'my..backup.json' (embedded '..' is allowed), 'settings.json' (normal name). WASM path is a key prefix, not an OS path." \
  -p 0 --label testing --silent)
bd dep add $TEST_PATHS $SETUP_TESTAMENT
bd dep add $TEST_PATHS $IMPL_UMBRELLA

TEST_STORE=$(bd create "Write tests/test_store.nim storage round-trip and error tests" \
  -d "tests/test_store.nim. Cover: JSON round-trip (raw + compressed), binary round-trip (raw + compressed), typed generic round-trip, missing file → none(), 0-byte file → ConfigParseError, 1-byte file (magic only, empty payload) → ConfigParseError, unknown magic byte → ConfigParseError, corrupt Snappy payload → ConfigParseError, to(T) conversion failure → ConfigParseError, write on read-only target → ConfigUnsupportedError, cross-format read mismatch (writeConfigBytes file read via readConfigJson → ConfigParseError), Snappy on tiny input round-trip correctness." \
  -p 0 --label testing --silent)
bd dep add $TEST_STORE $SETUP_TESTAMENT
bd dep add $TEST_STORE $IMPL_UMBRELLA

# ========================================
# Phase 5: Documentation & CI
# ========================================

DOCS_README=$(bd create "Write README.md: quick start, path scheme, platform matrix" \
  -d "Repo-level README.md. Include: quick start (typed generic, JsonNode, binary), path scheme table (all 6 platforms), platform support summary table, -d:configyVendor install note, links to planning docs." \
  -p 2 --label docs --silent)
bd dep add $DOCS_README $IMPL_UMBRELLA

CI_SETUP=$(bd create "Set up CI: desktop tests + console/WASM cross-compile checks" \
  -d "Create .github/workflows/ci.yml. Job 1: desktop tests — 'nimble test' on Linux + Windows (tests/config.nims supplies the vendor define; real execution). Job 2: cross-compile smoke — 'nim c --compileOnly -d:configyVendor=testvendor -d:<target> src/configy.nim' for each of ds3/psp/vita/emscripten (verifies compile-time gates, no execution). Pin nim version in both jobs." \
  -p 1 --label deploy --silent)
bd dep add $CI_SETUP $TEST_STORE
bd dep add $CI_SETUP $TEST_PATHS
bd dep add $CI_SETUP $TEST_ERRORS

echo ""
echo "Bead graph created! View with:"
echo "  bd ready              # List unblocked tasks"
```

---

## Bead Creation Guidelines

### Priority Levels
- `-p 0` = Critical (blocking other work)
- `-p 1` = High (important but not blocking)
- `-p 2` = Medium (standard work)
- `-p 3` = Low (nice to have)

### Labels (Phase Grouping)
Use `--label` to group beads by phase:
- `setup` - Project initialization and build config
- `core` - Core module implementation
- `analysis` - Spikes and verification tasks
- `testing` - Test coverage
- `docs` - Documentation
- `deploy` - CI/CD

### Dependency Rules
1. Never create cycles
2. Every bead should have a clear dependency chain back to setup tasks
3. Use `bd dep add CHILD PARENT` (child depends on parent completing first)
4. Parallel work should share a common ancestor, not depend on each other

### Task Granularity
- Each bead should be completable in **under 750 lines of code**
- Tasks should be atomic enough for one agent to complete without coordination
- If a task requires multiple file areas, consider splitting by file area

---

## File Reservation Planning

For each major work area, note the file patterns that will need exclusive reservation:

```bash
# capabilities:     src/configy/capabilities.nim
# errors:           src/configy/errors.nim
# paths:            src/configy/paths.nim
# fs:               src/configy/fs.nim
# store:            src/configy/store.nim  (also owns ensureConfigFile)
# wasm:             src/configy/wasm.nim
# umbrella:         src/configy.nim
# nimble:           configy.nimble
# build config:     nim.cfg
# test vendor def:  tests/config.nims     ← prerequisite for ALL test tasks
# tests/paths:      tests/test_paths.nim
# tests/store:      tests/test_store.nim
# tests/errors:     tests/test_errors.nim
```

This helps agents claim appropriate file surfaces when they start work.

---

## Context Documentation

Place any important context in `docs/` for agents to reference. The planning documents at `/Users/punk1290/.agents/plans/configy/` are the authoritative reference for:
- Module signatures (`architecture.md` wins on drift with `api-design.md`)
- Platform capability matrix (`platform-matrix.md`)
- The 3DS/PSP write caveat and supersnappy console verification item

---

## Verification Steps

After generating the script:

1. **Run it**: `chmod +x setup-beads.sh && ./setup-beads.sh`
2. **Check ready work**: `bd ready` should show initial setup tasks

---

## Completeness Checklist

Ensure your task graph includes:

- [ ] All setup and configuration tasks
- [ ] Core architecture and shared utilities
- [ ] Feature implementation tasks (broken into small units)
- [ ] Error handling and edge cases
- [ ] Unit and integration tests for each feature
- [ ] API documentation
- [ ] Security considerations (path-traversal prevention via `validateComponent` — no auth in scope for this library)
- [ ] Performance considerations where relevant
- [ ] CI/CD and deployment tasks
- [ ] Clear dependency chains with no cycles
