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

Cons: `<vendor>` and `<app>` become visually ambiguous at a glance; `VendorNamespace`
validation currently bans `-` in some contexts (check `validateComponent`).

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

**API note:** Nim does not support true optional positional args; use a default value
(e.g., `dep = ""`). When `dep` is empty, skip the dep segment. `validateComponent`
must be updated to permit empty only when called in optional context — or call it
conditionally. Implementation choice: add an `allowEmpty = false` parameter to
`validateComponent`, or check before calling.

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
| `src/configy/paths.nim` | `configRoot()` rewritten; one desktop branch instead of three; console path segment order changes |
| `src/configy/capabilities.nim` | Windows branch in `configyUsesOsPath` simplification (optional cleanup); `VendorNamespace` validation may need to allow `-` if Option B chosen |
| `tests/test_paths.nim` | Tests asserting `"." & VendorNamespace` in root path must change; `%APPDATA%` / Windows branch tests change; new XDG env-var override test needed |
| `README.md` | Path examples, table of per-platform locations, Windows note |

### Files that do NOT change

| File | Why safe |
|------|----------|
| `src/configy/errors.nim` | Error types unchanged |
| `src/configy/fs.nim` | Calls `configDir()` — update signatures to accept optional dep |
| `src/configy/store.nim` | Calls `fs.nim` — update signatures to accept optional dep |
| `src/configy/wasm.nim` | Stub; update localStorage key prefix only |
| `configy.nimble` | Bump version number only |

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
      result = getHomeDir() / ".config" / VendorNamespace & $DirSep
```

Update the docstring in `configRoot()` to reflect new values.

**Task 1.2: Make `dep` optional in `configDir()` and `configFile()`**

Add optional-dep overloads. Nim's approach: use a default value of `""` and skip the
dep segment when empty. `validateComponent` must not be called when dep is empty:

```nim
proc configDir*(app: string, dep = ""): string {.raises: [ConfigPathError].} =
  validateComponent(app)
  let root = configRoot()
  if dep.len == 0:
    when configyUsesOsPath:
      result = root & app & $DirSep
    else:
      result = root & app & "/"
  else:
    validateComponent(dep)
    when configyUsesOsPath:
      result = root & app & $DirSep & dep & $DirSep
    else:
      result = root & app & "/" & dep & "/"

proc configFile*(app: string, dep = "", filename: string): string {.raises: [ConfigPathError].} =
  validateComponent(filename)
  result = configDir(app, dep) & filename
```

Note: Nim requires named-argument call or positional ordering for optional middle
parameters. Verify with a two-argument call `configFile("app", filename = "f.json")`
compiles cleanly — if not, split into two distinct procs instead:

```nim
proc configFile*(app, filename: string): string  # dep-less overload
proc configFile*(app, dep, filename: string): string  # full overload
```

Two separate procs avoids named-argument ambiguity and is easier to document.

### Phase 2 — Update `capabilities.nim`

**Task 2.1: Remove the Windows-specific `%APPDATA%` path from consideration**

`configyUsesOsPath` currently excludes only console/WASM targets; Windows is included
(uses `std/os`). This remains correct for the new scheme — no change needed.

**Task 2.2 (optional): Remove the now-dead Windows-only `%APPDATA%` fallback check**

Since the Windows branch is removed from `configRoot()`, the `%APPDATA%` documentation
in `capabilities.nim` can be cleaned up if it references the old scheme.

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
  let path = configFile("myapp", "settings.json")
  check path.endsWith("settings.json")
  check not strutils.contains(path, "/mylib/")  # no dep segment in path
```

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
- [ ] `configDir("myapp")` returns `~/.config/<vendor>/myapp/` (no dep segment)
- [ ] `configFile("myapp", filename = "config.toml")` returns
      `~/.config/<vendor>/myapp/config.toml`
- [ ] `configDir("myapp", "mylib")` still works (no regression)
- [ ] `fs.nim` and `store.nim` public procs accept optional dep
- [ ] `nim check` succeeds on all supported platforms (or cross-compile checks in CI)
- [ ] README path examples match the new scheme, including dep-less examples
