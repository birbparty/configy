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
  -p 0 -l setup --silent)

SETUP_NIMCFG=$(bd create "Create nim.cfg with --mm:arc" \
  -d "Create nim.cfg at repo root containing: --mm:arc. Add comments with cross-compile invocation examples for -d:ds3/-d:psp/-d:vita/-d:emscripten." \
  -p 0 -l setup --silent)
bd dep add $SETUP_NIMCFG $SETUP_NIMBLE

# CRITICAL: tests/config.nims must exist before any test task — without it every
# nim compile fails at the static vendor guard in capabilities.nim.
SETUP_TESTCFG=$(bd create "Create tests/config.nims with -d:configyVendor=testvendor" \
  -d "Create tests/config.nims: switch(\"define\", \"configyVendor=testvendor\"). This is a prerequisite for all test tasks — without it every compile fails at the static{.error.} guard in capabilities.nim." \
  -p 0 -l setup --silent)
bd dep add $SETUP_TESTCFG $SETUP_NIMBLE

SETUP_TESTAMENT=$(bd create "Wire testament test runner and create tests/ scaffold" \
  -d "Ensure 'nimble test' invokes testament. Create tests/ directory with empty placeholder. Confirm 'nimble test' exits cleanly on an empty suite before any impl task begins." \
  -p 0 -l setup --silent)
bd dep add $SETUP_TESTAMENT $SETUP_TESTCFG
bd dep add $SETUP_TESTAMENT $SETUP_NIMCFG

# ========================================
# Phase 2: Core Modules
# ========================================
# NOTE: capabilities.nim and errors.nim have no deps on each other — build in parallel.

IMPL_CAPS=$(bd create "Implement capabilities.nim compile-time consts" \
  -d "src/configy/capabilities.nim. Consts: configyHasRealFs (not emscripten), configyFsWritable (false for emscripten/ds3/psp; true for desktop/windows/vita), configyUsesOsPath (false for ds3/psp/vita/emscripten), configyHasSnappy (always true). configyVendor strdefine with static guard raising {.error.} when empty. VendorNamespace* = configyVendor. No logic, consts only." \
  -p 0 -l core --silent)
bd dep add $IMPL_CAPS $SETUP_NIMCFG

IMPL_ERRORS=$(bd create "Implement errors.nim ConfigError hierarchy" \
  -d "src/configy/errors.nim. Five types: ConfigError* (base, CatchableError), ConfigPathError* (bad component/traversal), ConfigIOError* (FS op failed), ConfigParseError* (malformed data: bad magic, corrupt Snappy, bad JSON, empty payload), ConfigUnsupportedError* (write on read-only target, WASM v1 ops). No logic, type definitions only." \
  -p 0 -l core --silent)
bd dep add $IMPL_ERRORS $SETUP_NIMCFG

# paths.nim depends on BOTH capabilities and errors.
IMPL_PATHS=$(bd create "Implement paths.nim cross-platform path resolution" \
  -d "src/configy/paths.nim. Exports: validateComponent* — raises ConfigPathError on: empty string, contains '/' or '\\', s==\"..\" (exact segment only; embedded '..' like 'my..backup.json' is ALLOWED), ':' anywhere (NTFS ADS / Windows portability). configRoot* — console branches use raw when defined(ds3)/elif defined(psp)/elif defined(vita) for per-device prefix (sanctioned exception to capabilities centralization; plain string concat only, never std/os). configDir* — calls configRoot() then validates app/dep via validateComponent; uses configyUsesOsPath for join strategy. configFile* — configDir + validateComponent on filename. Console/WASM: plain concat. Desktop/Windows: std/os / operator." \
  -p 0 -l core --silent)
bd dep add $IMPL_PATHS $IMPL_CAPS
bd dep add $IMPL_PATHS $IMPL_ERRORS

IMPL_FS=$(bd create "Implement fs.nim write-capability gating and dir creation" \
  -d "src/configy/fs.nim. isWritable*(): returns configyFsWritable directly — v1 is a compile-time const, no runtime probe. ensureConfigDir*(app, dep): resolve configDir(app, dep); if isWritable() then createDir (raises ConfigIOError on failure); returns resolved path regardless. BEST-EFFORT: non-throwing on read-only targets. No-op returning key prefix on WASM. Does NOT own ensureConfigFile — that lives in store.nim." \
  -p 0 -l core --silent)
bd dep add $IMPL_FS $IMPL_PATHS

# wasm.nim imports only errors + capabilities — no store dep. Implement in parallel with store.
IMPL_WASM=$(bd create "Implement wasm.nim v1 localStorage stubs (emscripten only)" \
  -d "src/configy/wasm.nim. All four procs under 'when defined(emscripten)': setItem(key, value: string) raises ConfigUnsupportedError, getItem(key: string): Option[string] returns none(), removeItem(key: string): bool returns false, hasItem(key: string): bool returns false (used by configFileExists WASM routing). NOTE: architecture.md shows removeItem returning bool (not raising) — follow that signature. Do NOT declare setItemBase64/getItemBase64 — those are v2 scope only." \
  -p 0 -l core --silent)
bd dep add $IMPL_WASM $IMPL_CAPS
bd dep add $IMPL_WASM $IMPL_ERRORS

IMPL_STORE=$(bd create "Implement store.nim: byte core, JSON, binary, typed, file mgmt" \
  -d "src/configy/store.nim. Internal: MagicRaw='\\x00', MagicSnappy='\\x01', storeBytes, loadBytes (raises ConfigParseError on: 0-byte file, 1-byte file with empty payload, unknown magic, corrupt Snappy payload), notFound. Public: ensureConfigFile* (lives HERE not fs.nim — calls ensureConfigDir then joins filename), writeConfigJson*, readConfigJson*, writeConfigBytes*, readConfigBytes*, writeConfig*[T] (compile-time guard: when not compiles(%data): {.error.}), readConfig*[T] (wraps JsonKindError/ValueError as ConfigParseError), deleteConfig*, configFileExists*. WASM routing: write paths → wasm.setItem (raises v1); configFileExists → wasm.hasItem (false v1); read paths → wasm.getItem (none() v1). writeConfigBytes/readConfigBytes on WASM v1 also route through plain setItem/getItem." \
  -p 0 -l core --silent)
bd dep add $IMPL_STORE $IMPL_FS
bd dep add $IMPL_STORE $IMPL_WASM

IMPL_UMBRELLA=$(bd create "Implement src/configy.nim umbrella re-export module" \
  -d "src/configy.nim. import+export: capabilities, errors, paths, fs, store. when defined(emscripten): import+export wasm. Run 'nim c -d:configyVendor=testvendor src/configy.nim' to verify clean compile on desktop before closing." \
  -p 0 -l core --silent)
bd dep add $IMPL_UMBRELLA $IMPL_STORE

# ========================================
# Phase 3: Supersnappy Console Verification Spike
# ========================================

SPIKE_SNAPPY=$(bd create "Verify supersnappy compiles under devkitARM, PSPDEV, VitaSDK" \
  -d "Spike: attempt to compile a minimal supersnappy usage against each console toolchain (devkitARM for 3DS, PSPDEV for PSP, VitaSDK for Vita). Document outcome. If any target fails, a follow-up task must add 'when configyFsWritable: import supersnappy' guard to store.nim and open a separate bead to track it. Close with written findings." \
  -p 2 -l analysis --silent)
bd dep add $SPIKE_SNAPPY $IMPL_STORE

# ========================================
# Phase 4: Testing
# ========================================

TEST_ERRORS=$(bd create "Write tests/test_errors.nim error hierarchy tests" \
  -d "tests/test_errors.nim. Verify: all five types catchable as ConfigError base, correct type raised per failure mode (bad component → ConfigPathError, write-on-RO → ConfigUnsupportedError, corrupt/empty file → ConfigParseError, FS failure → ConfigIOError, WASM write → ConfigUnsupportedError). Use doAssertRaises." \
  -p 1 -l testing --silent)
bd dep add $TEST_ERRORS $SETUP_TESTAMENT
bd dep add $TEST_ERRORS $IMPL_UMBRELLA

TEST_PATHS=$(bd create "Write tests/test_paths.nim path resolution and validation tests" \
  -d "tests/test_paths.nim. validateComponent boundary cases — must raise ConfigPathError: empty string, '/', '\\', exact '..', ':' anywhere in string. Must NOT raise: 'my..backup.json' (embedded '..' is allowed — only bare \"..\" is rejected), 'settings.json'. configRoot/configDir/configFile string output assertions for desktop (Linux/macOS via getHomeDir). WASM path is a key prefix (no leading slash). Separate test proc per platform where applicable." \
  -p 0 -l testing --silent)
bd dep add $TEST_PATHS $SETUP_TESTAMENT
bd dep add $TEST_PATHS $IMPL_UMBRELLA

TEST_STORE=$(bd create "Write tests/test_store.nim storage round-trip and error tests" \
  -d "tests/test_store.nim. Cover: JSON round-trip (raw + compressed), binary round-trip (raw + compressed), typed generic round-trip, missing file → none(), 0-byte file → ConfigParseError, 1-byte file (magic only, empty payload) → ConfigParseError, unknown magic byte → ConfigParseError, corrupt Snappy payload → ConfigParseError, to(T) conversion failure → ConfigParseError, write on read-only target → ConfigUnsupportedError, cross-format read mismatch (writeConfigBytes file read via readConfigJson → ConfigParseError), Snappy round-trip correctness on tiny input, deleteConfig returns true on present file / false on absent." \
  -p 0 -l testing --silent)
bd dep add $TEST_STORE $SETUP_TESTAMENT
bd dep add $TEST_STORE $IMPL_UMBRELLA

# ========================================
# Phase 5: WASM v2 Implementation
# ========================================
# Lower priority — v1 core must be complete and verified first.

IMPL_WASM_V2_INTEROP=$(bd create "Implement wasm.nim v2: setItem/getItem/removeItem via Emscripten JS interop" \
  -d "src/configy/wasm.nim. Replace v1 stubs with real EM_JS/{.emit.} implementations under 'when defined(emscripten)'. setItem(key, value) → JS localStorage.setItem(key, value). getItem(key) → JS localStorage.getItem(key) → Option[string] (none if null). removeItem(key) → JS localStorage.removeItem(key), return true. Flip configyFsWritable to true for emscripten in capabilities.nim (guarded: when defined(emscripten): true). Full read/write/delete lifecycle must work end-to-end." \
  -p 2 -l impl --silent)
bd dep add $IMPL_WASM_V2_INTEROP $IMPL_UMBRELLA

IMPL_WASM_V2_BASE64=$(bd create "Implement wasm.nim v2: setItemBase64/getItemBase64 for binary/compression path" \
  -d "src/configy/wasm.nim. Add setItemBase64(key, rawBytes: string) — base64-encodes rawBytes before localStorage.setItem (localStorage is UTF-16; raw Snappy output and magic bytes cannot survive setItem/getItem intact). Add getItemBase64(key): Option[string] — localStorage.getItem then base64-decode to raw bytes. Update store.nim to route writeConfigBytes/readConfigBytes through setItemBase64/getItemBase64 when defined(emscripten). The self-describing magic-byte format must be preserved end-to-end." \
  -p 2 -l impl --silent)
bd dep add $IMPL_WASM_V2_BASE64 $IMPL_WASM_V2_INTEROP

IMPL_WASM_V2_CAPS=$(bd create "Update capabilities.nim: flip configyFsWritable=true for emscripten in v2" \
  -d "src/configy/capabilities.nim. After WASM v2 interop is confirmed working: change configyFsWritable branch for emscripten from false to true. This unblocks isWritable() on WASM targets. Verify that existing tests still pass after the change and that writeConfigJson/writeConfigBytes no longer raise ConfigUnsupportedError on emscripten." \
  -p 2 -l impl --silent)
bd dep add $IMPL_WASM_V2_CAPS $IMPL_WASM_V2_BASE64

TEST_WASM_V2=$(bd create "Write tests/test_wasm_v2.nim localStorage round-trip tests" \
  -d "tests/test_wasm_v2.nim. Tests only compile/run under -d:emscripten. Cover: JSON round-trip via setItem/getItem, binary round-trip via setItemBase64/getItemBase64, configFileExists returns true after write, deleteConfig removes item (hasItem returns false after), readConfigJson after deleteConfig returns none(), Snappy-compressed JSON via WASM v2." \
  -p 2 -l testing --silent)
bd dep add $TEST_WASM_V2 $SETUP_TESTAMENT
bd dep add $TEST_WASM_V2 $IMPL_WASM_V2_CAPS

# ========================================
# Phase 6: Documentation & CI
# ========================================

DOCS_README=$(bd create "Write README.md: quick start, path scheme, platform matrix" \
  -d "Repo-level README.md. Include: quick start (typed generic, JsonNode, binary examples), path scheme table (all 6 platforms with resolved paths), platform support matrix (resolve/create/read/write per platform), -d:configyVendor install note, links to planning docs in /Users/punk1290/.agents/plans/configy/." \
  -p 2 -l docs --silent)
bd dep add $DOCS_README $IMPL_UMBRELLA

CI_SETUP=$(bd create "Set up CI: desktop tests + console/WASM cross-compile checks" \
  -d "Create .github/workflows/ci.yml. Job 1: desktop tests — 'nimble test' on Linux + Windows runners (tests/config.nims supplies the vendor define; real execution). Job 2: cross-compile smoke — 'nim c --compileOnly -d:configyVendor=testvendor -d:<target> src/configy.nim' for each of ds3/psp/vita/emscripten (verifies compile-time gates, no execution). Pin nim version in both jobs. Trigger on push and PR." \
  -p 1 -l deploy --silent)
bd dep add $CI_SETUP $TEST_STORE
bd dep add $CI_SETUP $TEST_PATHS
bd dep add $CI_SETUP $TEST_ERRORS

echo ""
echo "Bead graph created! View with:"
echo "  bd ready              # List unblocked tasks"
echo "  bd graph              # Show dependency graph"
echo "  bd list               # List all beads"
