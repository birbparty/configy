# XDG-Style Config Paths Plan

## Goal

Replace configy's current hidden-dot-vendor path scheme with XDG Base Directory
Specification-compliant paths. All desktop targets (Linux, macOS, Windows) should
use `$XDG_CONFIG_HOME/<vendor>/<app>/<dep>/<file>`, with console targets mirroring
the same `config/<vendor>/<app>/<dep>/` shape on their device prefixes.

---

## Decisions (locked)

| Question | Decision |
|----------|----------|
| Vendor namespace | **Keep; fold into path** — vendor preserved as a subdirectory, not dropped |
| macOS / Windows convention | **XDG-literal everywhere** — `~/.config/` on all desktop OSes, including macOS and Windows |
| TOML format | **Non-goal** — `config.toml` in the prompt illustrates path shape only; no TOML serializer |
| `dep` parameter | **Make optional** — `configDir(app)` and `configDir(app, dep)` both valid; enables `~/.config/<vendor>/<app>/config.toml` |

---

## Open Sub-Question: Vendor Fold-In Format

Two options for how vendor appears in the path. Recommendation follows; this decision
should be confirmed before implementation starts.

### Option A — Subdirectory (recommended)

```
~/.config/<vendor>/<app>/<dep>/<file>
```

Example: `~/.config/acme/mytool/cache/settings.json`

Pros: Namespace hierarchy is readable; mirrors how large organizations use XDG in practice
(e.g., `~/.config/google/chrome/`). Clean ownership: `<vendor>/` owns its whole subtree.

Cons: Two directories before the file, not one.

### Option B — Dash-concatenated

```
~/.config/<vendor>-<app>/<dep>/<file>
```

Example: `~/.config/acme-mytool/cache/settings.json`

Pros: Single directory at the XDG root, matching the "one directory per program" letter of
the spec. Familiar pattern for CLI tools.

Cons: `<vendor>` and `<app>` become visually ambiguous at a glance. (`validateComponent`
does NOT ban hyphens — `"my-app"` is explicitly allowed — so this is purely a readability
concern, not a validation constraint.)

**This plan assumes Option A.** Change the per-platform table below if Option B is chosen;
no other sections need to change.

---

## New Path Scheme (per platform)

### configRoot() — returns the vendor-scoped config base with trailing separator

| Platform | Old (current) | New |
|----------|---------------|-----|
| Linux | `~/.<vendor>/config/` | `$XDG_CONFIG_HOME/<vendor>/` → fallback `~/.config/<vendor>/` |
| macOS | `~/.<vendor>/config/` | Same as Linux (XDG-literal everywhere) |
| Windows | `%APPDATA%\<vendor>\config\` | `~\.config\<vendor>\` (uses `getHomeDir()`, not `%APPDATA%`) |
| Nintendo 3DS | `sdmc:/<vendor>/config/` | `sdmc:/config/<vendor>/` |
| PSP | `ms0:/PSP/<vendor>/config/` | `ms0:/PSP/config/<vendor>/` |
| PS Vita | `ux0:data/<vendor>/config/` | `ux0:data/config/<vendor>/` |
| WASM | `<vendor>/config/` (localStorage prefix) | `config/<vendor>/` (mirrors desktop shape) |

### configDir(app, dep?) — full directory path

`dep` is now optional. When omitted, the directory is `configRoot() + <app> + sep`.
When provided, the directory is `configRoot() + <app> + sep + <dep> + sep`.

| Platform | With dep | Without dep |
|----------|----------|-------------|
| Linux/macOS | `~/.config/acme/mytool/cache/` | `~/.config/acme/mytool/` |
| Windows | `C:\Users\Matt\.config\acme\mytool\cache\` | `C:\Users\Matt\.config\acme\mytool\` |
| 3DS | `sdmc:/config/acme/mytool/cache/` | `sdmc:/config/acme/mytool/` |
| PSP | `ms0:/PSP/config/acme/mytool/cache/` | `ms0:/PSP/config/acme/mytool/` |
| Vita | `ux0:data/config/acme/mytool/cache/` | `ux0:data/config/acme/mytool/` |
| WASM | `config/acme/mytool/cache/` | `config/acme/mytool/` |

**API note:** Use two distinct overloads for everything that takes `dep` — not a
single proc with a default `""` for a middle positional parameter. Nim compiles
`proc f(app: string, dep = "", filename: string)` but a positional two-arg call
`f("app", "file.json")` does NOT work: the second arg binds to `dep`, leaving
`filename` unfilled. Forcing callers to write `configFile("app", filename = "f")`
is poor ergonomics. Two overloads dispatch correctly and stay positional:

```nim
proc configDir*(app: string): string               # dep-less
proc configDir*(app, dep: string): string          # full
proc configFile*(app, filename: string): string    # dep-less
proc configFile*(app, dep, filename: string): string  # full
```

This pattern cascades to `fs.nim` and all ~9 public procs in `store.nim`.

### configFile variants

Both forms should work:
- `configFile(app, dep, filename)` — full three-level path
- `configFile(app, filename)` — two-level path (dep omitted)

Internally, `configFile` delegates to the appropriate `configDir` overload.

---

## XDG Spec Compliance

`$XDG_CONFIG_HOME` must be respected exactly per the spec. Three conditions must ALL hold
for the env var to be used; if any fail, fall back to `~/.config`:

1. The variable is **set**
2. The value is **non-empty**
3. The value is an **absolute path** (most implementations miss this check)

Nim implementation in `configRoot()` for the desktop branch:

```nim
let xdgConfigHome = getEnv("XDG_CONFIG_HOME")
if xdgConfigHome.len > 0 and isAbsolute(xdgConfigHome):
  result = xdgConfigHome / VendorNamespace & $DirSep
else:
  result = getHomeDir() / ".config" / VendorNamespace & $DirSep
```

This collapses the two formerly separate desktop branches (Linux/macOS shared `else`, and the
Windows branch) into one. Windows gets `~\.config\<vendor>\` via
`getHomeDir() / ".config" / VendorNamespace`.

**Note on Windows:** `~/.config/` is non-standard on Windows; the conventional location is
`%APPDATA%`. The decision to use XDG-literal everywhere is intentional (chosen by the owner)
and common in cross-platform CLI tools. Document this explicitly in the README.

---

## Migration Strategy

### Decision: explicit break, no migration helper (v0 → v1)

Rationale: configy has no published consumers yet (active development via ralph loop, no
release). A migration shim adds code complexity and tests for a transition that no one needs.

What to do instead:
1. Bump the Nimble version to signal the break (e.g., `0.1.0` → `0.2.0`)
2. Document the old and new paths in CHANGELOG or README
3. Callers who have data at old locations must move it manually — the old path is derivable
   from the old scheme for any given `(vendor, app, dep)` triple

**If a migration helper is needed later**, the pattern is:
- `migrateFromLegacy(app, dep)` — detect old path, copy files to new path, delete old dir
- Caller opts in; not automatic on startup

---

## Breaking Changes & Blast Radius

### Files that change

| File | What changes |
|------|-------------|
| `src/configy/paths.nim` | `configRoot()` rewritten; one desktop branch; `getHomeDir()` guard; dep-less overloads for `configDir`/`configFile`; console path segment order changes |
| `src/configy/fs.nim` | Dep-less overloads: `ensureConfigDir(app)`, `ensureConfigFile(app, filename)` |
| `src/configy/store.nim` | Dep-less overloads for all 9 public procs (see Phase 1b) |
| `src/configy/capabilities.nim` | Minor doc cleanup only (optional; `configyUsesOsPath` unchanged) |
| `tests/test_paths.nim` | Hidden-dot assertions replaced; XDG env-var tests with save/restore; dep-less overload tests |
| `tests/test_store.nim` | Dep-less round-trip tests (write then read without dep) |
| `README.md` | Path examples, per-platform table, Windows note, dep-less usage examples |

### Files that do NOT change

| File | Why safe |
|------|----------|
| `src/configy/errors.nim` | Error types unchanged |
| `src/configy/wasm.nim` | Stub; localStorage key prefix update only (documentation-level) |
| `configy.nimble` | Version bump only |

### Public API changes

`configDir` and `configFile` gain optional-dep overloads. Existing two-argument
`configDir(app, dep)` and three-argument `configFile(app, dep, filename)` calls remain
valid — this is additive. Callers recompile; those using `dep` get new paths transparently;
those who want dep-less paths can now use `configDir(app)` / `configFile(app, filename)`.

`fs.nim` and `store.nim` public procedures (`ensureConfigDir`, `writeConfigJson`, etc.)
must be updated to propagate the optional `dep` parameter through their call chains.

---

## Implementation Tasks

### Phase 1 — Core path rewrite

**Task 1.1: Rewrite `configRoot()` in `paths.nim`**

Replace the three desktop branches (Windows, else/Linux, else/macOS) with a single
XDG-aware desktop branch:

```nim
proc configRoot*(): string {.raises: [ConfigPathError].} =
  when defined(ds3):
    result = "sdmc:/config/" & VendorNamespace & "/"
  elif defined(psp):
    result = "ms0:/PSP/config/" & VendorNamespace & "/"
  elif defined(vita):
    result = "ux0:data/config/" & VendorNamespace & "/"
  elif defined(emscripten):
    result = "config/" & VendorNamespace & "/"
  else:
    # Desktop: Linux, macOS, Windows — XDG-literal everywhere
    let xdgConfigHome = getEnv("XDG_CONFIG_HOME")
    if xdgConfigHome.len > 0 and isAbsolute(xdgConfigHome):
      result = xdgConfigHome / VendorNamespace & $DirSep
    else:
      let home = getHomeDir()
      if home.len == 0:
        raise newException(ConfigPathError,
          "home directory is not set (HOME / USERPROFILE unset)")
      result = home / ".config" / VendorNamespace & $DirSep
```

**Note on `{.raises: [ConfigPathError].}`:** The old Windows branch raised on missing
`APPDATA`; the new implementation only raises on empty `getHomeDir()`. Keep the
annotation for API stability — downstream `{.raises.}` chains in `fs.nim`/`store.nim`
already expect it — but document the guard explicitly in the new docstring.

Update `configRoot()`'s docstring to reflect the new per-platform values:
```
##   Desktop (Linux/macOS/Windows): $XDG_CONFIG_HOME/<vendor>/  (fallback: ~/.config/<vendor>/)
##   3DS:  sdmc:/config/<vendor>/
##   PSP:  ms0:/PSP/config/<vendor>/
##   Vita: ux0:data/config/<vendor>/
##   WASM: config/<vendor>/  (localStorage key prefix)
```

**Task 1.2: Add dep-less overloads for `configDir()` and `configFile()`**

Use two explicit overloads — not a default `dep = ""`. The dep-less `configDir` has `dep`
as a trailing parameter so the default-value approach *would* work there, but for consistency
with `configFile` (where dep is middle-position and the default fails positionally) use
overloads throughout:

```nim
proc configDir*(app: string): string {.raises: [ConfigPathError].} =
  ## Dep-less form: returns config directory for app only.
  validateComponent(app)
  when configyUsesOsPath:
    result = configRoot() & app & $DirSep
  else:
    result = configRoot() & app & "/"

proc configDir*(app, dep: string): string {.raises: [ConfigPathError].} =
  ## Full form: preserves existing (app, dep) signature unchanged.
  validateComponent(app)
  validateComponent(dep)
  when configyUsesOsPath:
    result = configRoot() & app & $DirSep & dep & $DirSep
  else:
    result = configRoot() & app & "/" & dep & "/"

proc configFile*(app, filename: string): string {.raises: [ConfigPathError].} =
  ## Dep-less form: file lives directly under app directory.
  validateComponent(filename)
  result = configDir(app) & filename

proc configFile*(app, dep, filename: string): string {.raises: [ConfigPathError].} =
  ## Full form: preserves existing (app, dep, filename) signature unchanged.
  validateComponent(filename)
  result = configDir(app, dep) & filename
```

`configFile("myapp", "config.toml")` dispatches to the dep-less overload positionally —
no named arguments required. `configFile("myapp", "cache", "state.bin")` dispatches to
the full overload. Existing callers are unaffected.

**Cascade to `fs.nim` and `store.nim`:** Every public proc that currently takes `(app, dep, ...)`
needs a dep-less overload. See Phase 1b below.

### Phase 1b — Dep-less overloads for `fs.nim` and `store.nim`

The dep-less feature is unusable end-to-end unless the store procs also accept it.
Every proc that currently takes `(app, dep, ...)` needs a dep-less twin. Full list:

**`fs.nim`** (1 proc — `dep` is trailing, straightforward):
- `ensureConfigDir(app, dep)` → add `ensureConfigDir(app)`
- `ensureConfigFile(app, dep, filename)` → add `ensureConfigFile(app, filename)`

**`store.nim`** (9 procs — `dep` is middle, all need overloads):
- `configFileExists(app, dep, filename)` → add `configFileExists(app, filename)`
- `deleteConfig(app, dep, filename)` → add `deleteConfig(app, filename)`
- `writeConfigBytes(app, dep, filename, data, compress)` → add dep-less form
- `readConfigBytes(app, dep, filename)` → add dep-less form
- `writeConfigJson(app, dep, filename, data, compress, pretty)` → add dep-less form
- `readConfigJson(app, dep, filename)` → add dep-less form
- `writeConfig[T](app, dep, filename, data, compress, pretty)` → add dep-less form
- `readConfig[T](app, dep, filename)` → add dep-less form
- `ensureConfigFile` (if duplicated in store) → add dep-less form

Each dep-less overload simply delegates:
```nim
proc writeConfigJson*(app, filename: string; data: JsonNode;
                      compress = false; pretty = false) =
  writeConfigJson(app, "", filename, data, compress, pretty)
```
Wait — this won't work if the full overload also takes `(app, dep, filename, ...)` because
`""` would dispatch back. Instead delegate to `configFile(app, filename)` directly rather
than calling the dep form with an empty dep.

Concretely: dep-less `store.nim` overloads call `configFile(app, filename)` (the dep-less
path overload) for the file path, then proceed with the same body. Extract the path
resolution step so the body isn't duplicated.

### Phase 2 — Update `capabilities.nim`

**Task 2.1: Verify `configyUsesOsPath` needs no change**

`configyUsesOsPath` excludes console/WASM targets; Windows remains included (uses
`std/os`). This is still correct for the new scheme — no change needed.

**Task 2.2 (optional): Remove the now-dead VendorNamespace capability note**

`capabilities.nim` has no `%APPDATA%` reference — that lived entirely in the Windows
branch of `configRoot()` (paths.nim:43-46), which Task 1.1 removes. Check whether the
`VendorNamespace` docstring (capabilities.nim:27) needs updating to remove any
mention of `%APPDATA%`. If not present, Task 2.2 is a no-op.

### Phase 3 — Update tests in `test_paths.nim`

**Task 3.1: Update `configRoot starts with home dir hidden dir` test**

Old assertion: `contains(root, "." & VendorNamespace)` — remove hidden-dot check; assert
`.config` instead. **Critical:** this assertion is only valid when `XDG_CONFIG_HOME` is
unset/empty/relative. Save and restore the env var around every fallback test:

```nim
test "configRoot falls back to ~/.config when XDG_CONFIG_HOME is unset":
  let saved = getEnv("XDG_CONFIG_HOME")
  delEnv("XDG_CONFIG_HOME")
  let root = configRoot()
  check root.startsWith(getHomeDir() / ".config")
  check strutils.contains(root, VendorNamespace)
  if saved.len > 0: putEnv("XDG_CONFIG_HOME", saved)
```

**Task 3.2: Remove Windows `%APPDATA%` test (if one exists)**

Search `test_paths.nim` for any `APPDATA`-asserting tests; remove or replace with
XDG-path assertions.

**Task 3.3: Add XDG env-var override tests**

Every test that sets `XDG_CONFIG_HOME` must save the original value and restore it in
a teardown — otherwise tests clobber a pre-existing var on developer machines or CI
runners that export it (common on Linux desktops):

```nim
# Helper used by all XDG tests
proc withXdgConfigHome(value: string, body: proc()) =
  let saved = getEnv("XDG_CONFIG_HOME")
  if value.len > 0: putEnv("XDG_CONFIG_HOME", value)
  else: delEnv("XDG_CONFIG_HOME")
  try: body()
  finally:
    if saved.len > 0: putEnv("XDG_CONFIG_HOME", saved)
    else: delEnv("XDG_CONFIG_HOME")

test "configRoot respects XDG_CONFIG_HOME when set to absolute path":
  withXdgConfigHome("/tmp/xdg-test"):
    let root = configRoot()
    check root.startsWith("/tmp/xdg-test")
    check strutils.contains(root, VendorNamespace)

test "configRoot ignores XDG_CONFIG_HOME if not absolute":
  withXdgConfigHome("relative/path"):
    let root = configRoot()
    check root.startsWith(getHomeDir())

test "configRoot ignores empty XDG_CONFIG_HOME":
  withXdgConfigHome(""):
    let root = configRoot()
    check root.startsWith(getHomeDir())
```

**Task 3.4: Update `configDir produces expected structure` test**

Add check that path contains `.config` (save/restore env var here too via `withXdgConfigHome`):
```nim
check strutils.contains(dir, ".config")
```

**Task 3.5: Add tests for optional `dep` in `configDir` and `configFile`**

```nim
test "configDir without dep returns two-level path":
  let dir = configDir("myapp")
  check dir.endsWith("/")
  check strutils.contains(dir, "myapp")
  check not strutils.contains(dir, "mylib")  # no dep segment

test "configFile without dep includes filename directly under app":
  let path = configFile("myapp", "settings.json")   # positional, no named arg needed
  check path.endsWith("settings.json")
  check not strutils.contains(path, "/mylib/")  # no dep segment in path

test "configFile dep-less and full differ only in dep segment":
  let short = configFile("myapp", "config.toml")
  let full   = configFile("myapp", "cache", "config.toml")
  check full.len > short.len
  check strutils.contains(full, "cache")
  check not strutils.contains(short, "cache")
```

**Task 3.6: Add dep-less round-trip test in `test_store.nim`**

```nim
test "writeConfigJson / readConfigJson round-trip without dep":
  let app = "testapp-nodep"
  let filename = "nodep.json"
  let data = %* {"key": "value"}
  writeConfigJson(app, filename, data)
  let got = readConfigJson(app, filename)
  check got.isSome
  check got.get == data
  discard deleteConfig(app, filename)  # dep-less delete
```

This verifies the end-to-end dep-less path compiles, resolves, and round-trips through
the actual filesystem — not just the path string.

### Phase 4 — Update `wasm.nim`

**Task 4.1: Change the localStorage key prefix comment/constant**

Current stub uses `<vendor>/config/` prefix. Update to `config/<vendor>/` to mirror
the new desktop shape. Since WASM v1 is stubbed, this may be documentation-only.

### Phase 5 — Update README and docs

**Task 5.1: Update per-platform path table in README**

Replace the path examples with the new scheme. Add a Windows note explaining the
intentional choice of `~/.config/` over `%APPDATA%`.

**Task 5.2: Add XDG env-var override documentation**

Document that `$XDG_CONFIG_HOME` is respected on all desktop targets when set to a
non-empty absolute path, per the XDG Base Directory Specification.

**Task 5.3: Add migration note**

One paragraph: old path scheme, new path scheme, how to move existing data manually.

### Phase 6 — Bump version

**Task 6.1: Update `configy.nimble`**

Increment version from current to next minor (breaking change). Add a line to the
description noting XDG compliance.

---

## Non-Goals

- **TOML serialization**: the `config.toml` filename in the goal statement illustrates
  path shape only. The library remains format-agnostic (caller chooses filenames).
- **XDG_DATA_HOME / XDG_CACHE_HOME / XDG_STATE_HOME**: out of scope. configy is a
  config library; only `XDG_CONFIG_HOME` is relevant. Other base dirs can be addressed
  in a future feature.
- **Automatic data migration**: no read-old/write-new migration shim. Callers move data
  manually if needed; the old paths are derivable from the documented old scheme.
- **Removing `dep` entirely**: `dep` becomes optional, not removed. The existing
  `(app, dep)` signature remains valid; only the zero-dep form is new.
- **WASM full implementation**: WASM v2 localStorage lifecycle is a separate feature.
  This plan updates the key prefix only.

---

## Acceptance Criteria

- [ ] `configRoot()` on Linux returns a path starting with `$XDG_CONFIG_HOME/<vendor>/`
      when `$XDG_CONFIG_HOME` is a set, non-empty, absolute path
- [ ] `configRoot()` on Linux falls back to `~/.config/<vendor>/` when `$XDG_CONFIG_HOME`
      is unset, empty, or a relative path
- [ ] `configRoot()` on macOS returns the same form as Linux (XDG-literal, no `~/Library`)
- [ ] `configRoot()` on Windows returns `~\.config\<vendor>\` (home-dir-based, not `%APPDATA%`)
- [ ] Console paths (`sdmc:/`, `ms0:/PSP/`, `ux0:data/`) start with `config/<vendor>/` after
      the device prefix, not `<vendor>/config/`
- [ ] All existing `test_paths.nim` tests pass after updates
- [ ] New XDG env-var override tests (3 cases) pass, with save/restore hygiene
- [ ] `configRoot()` raises `ConfigPathError` when `HOME`/`USERPROFILE` is unset and
      `XDG_CONFIG_HOME` is not usable (guards against silent `/.config/` path)
- [ ] `configDir("myapp")` returns `~/.config/<vendor>/myapp/` (no dep segment)
- [ ] `configFile("myapp", "config.toml")` — positional, no named arg — returns
      `~/.config/<vendor>/myapp/config.toml`
- [ ] `configDir("myapp", "mylib")` still works (no regression)
- [ ] `configFile("myapp", "cache", "state.bin")` still works (no regression)
- [ ] `writeConfigJson(app, filename, data)` / `readConfigJson(app, filename)` round-trips
      and the on-disk path contains no dep segment
- [ ] All dep-less store procs (`writeConfigJson`, `readConfigJson`, `writeConfig[T]`,
      `readConfig[T]`, `deleteConfig`, `configFileExists`, etc.) compile and function
- [ ] Console paths (`sdmc:/`, `ms0:/PSP/`, `ux0:data/`) start with `config/<vendor>/` after
      the device prefix (verified by cross-compile `nim check` in CI)
- [ ] `nim check` succeeds on all supported platforms (or cross-compile checks in CI)
- [ ] README path examples match the new scheme, including dep-less examples
