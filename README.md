# configy

A small, cross-platform configuration path resolver and storage library for Nim.

`configy` answers one question for any Nim application or library:

> *"Where do I put my config data on this platform, and how do I read/write it safely?"*

It resolves a predictable, vendor-namespaced directory per platform, creates it on first
use, and provides thin storage helpers for JSON, raw binary, and typed generics — with
optional Snappy compression on all three. It is plumbing, not policy.

---

## The path scheme

Paths follow the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/latest/)
on all desktop targets. `dep` is optional — omit it to put files directly under the app directory.

| Platform              | With dep                                                                    | Without dep                                                       |
|-----------------------|-----------------------------------------------------------------------------|-------------------------------------------------------------------|
| Desktop (Linux/macOS) | `~/.config/<vendor>/<app>/<dep>/`                                           | `~/.config/<vendor>/<app>/`                                       |
| Windows               | `~\.config\<vendor>\<app>\<dep>\`                                           | `~\.config\<vendor>\<app>\`                                       |
| Nintendo 3DS          | `sdmc:/config/<vendor>/<app>/<dep>/`                                        | `sdmc:/config/<vendor>/<app>/`                                    |
| PSP                   | `ms0:/PSP/config/<vendor>/<app>/<dep>/`                                     | `ms0:/PSP/config/<vendor>/<app>/`                                 |
| PS Vita               | `ux0:data/config/<vendor>/<app>/<dep>/`                                     | `ux0:data/config/<vendor>/<app>/`                                 |
| WebAssembly           | localStorage key prefix `config/<vendor>/<app>/<dep>/` (stubbed)            | `config/<vendor>/<app>/` (stubbed)                                |

- `<vendor>` — your organization/project namespace, set at compile time (required).
- `<app>` — the consuming application name, supplied at call time.
- `<dep>` — the library or feature name (optional), supplied at call time.

> **Overload note:** `configDir(app, x)` treats `x` as a **dep** (a sub-directory).
> `configFile(app, x)` treats `x` as a **filename** (the file itself). Both accept
> `(string, string)` but the second argument means different things. A three-arg call
> that accidentally loses an argument compiles silently to a different path — make sure
> you intend the dep-less form when using two positional arguments.
>
> **Name collision:** do not use the same name as both a dep-less filename and a dep
> (e.g. `configFile(app, "x")` and `configDir(app, "x")` under the same app). A
> filesystem cannot hold both a file and a directory named `x` — `ensureConfigDir`
> will raise `ConfigIOError` at runtime if you try.

### XDG env-var override (desktop)

On all desktop targets (Linux, macOS, Windows), `$XDG_CONFIG_HOME` is respected when it
is set, non-empty, and an **absolute path**. If any of those conditions fails, configy
falls back to `~/.config/`. This env-var resolution rule follows the XDG Base Directory
Specification. Note that configy nests files under `<vendor>/<app>/` (and optionally
`<dep>/`) within the XDG config root rather than the spec's conventional flat
`$XDG_CONFIG_HOME/<app>/` layout — the extra namespacing prevents vendor collisions.

### Windows note

configy uses `~/.config/` on Windows instead of the conventional `%APPDATA%`. This is an
intentional choice for cross-platform CLI tools that want a single, predictable path shape
on all desktops. If you need `%APPDATA%` behavior on Windows, set `XDG_CONFIG_HOME=%APPDATA%`
in your environment.

---

## Vendor namespace

The vendor namespace is **required** and set at compile time:

```sh
nim c -d:configyVendor=myorg myapp.nim
```

configy has no built-in default. The build fails with a clear error if
`-d:configyVendor` is not provided.

---

## Quick start

```nim
# Compile with: nim c -d:configyVendor=myorg myapp.nim
# (myorg is <vendor> from the path tables above — set at compile time)
import configy
import std/options

# ── Typed generic (most ergonomic) ───────────────────────────────────────────
type Settings = object
  volume: float
  fullscreen: bool

# With dep — file lives at ~/.config/myorg/myapp/mylib/settings.json
if isWritable():
  writeConfig("myapp", "mylib", "settings.json",
              Settings(volume: 0.8, fullscreen: true), compress = true)
let s = readConfig[Settings]("myapp", "mylib", "settings.json")

# Without dep — file lives at ~/.config/myorg/myapp/settings.json
if isWritable():
  writeConfig("myapp", "settings.json", Settings(volume: 0.8, fullscreen: true))
let s2 = readConfig[Settings]("myapp", "settings.json")

# ── JsonNode (flexible, schema-free) ─────────────────────────────────────────
if isWritable():
  # pretty=true for human-editable files; default is compact
  writeConfigJson("myapp", "mylib", "raw.json", %*{"x": 1})
  writeConfigJson("myapp", "config.json", %*{"x": 1})  # dep-less form

let j = readConfigJson("myapp", "mylib", "raw.json")  # auto-detects compression

# ── Binary (consumer owns serialization) ─────────────────────────────────────
if isWritable():
  writeConfigBytes("myapp", "mylib", "data.bin", myBytes, compress = true)

let b = readConfigBytes("myapp", "mylib", "data.bin")  # auto-detects compression
```

All read procs auto-detect compression via a magic byte — `\x00` = raw, `\x01` = Snappy
— so the reader never needs to know how a file was written. Mixed compressed/uncompressed
files in the same directory work correctly.

### Path helpers

```nim
# Pure resolvers (paths.nim) — compute a path, never touch disk.
# Safe on every target including read-only consoles and WASM:
let dir  = configDir("myapp", "mylib")   # ~/.config/myorg/myapp/mylib/
let dir2 = configDir("myapp")            # ~/.config/myorg/myapp/  (dep-less)
let path = configFile("myapp", "mylib", "settings.json")
let path2 = configFile("myapp", "settings.json")  # dep-less, positional

# Creating helpers (fs.nim / store.nim) — create the dir where writable, no-op where not.
# Never raise on a read-only target:
let made = ensureConfigDir("myapp", "mylib")
let made2 = ensureConfigDir("myapp")
let file = ensureConfigFile("myapp", "mylib", "settings.json")
let file2 = ensureConfigFile("myapp", "settings.json")
```

---

## Platform support

| Platform     | Resolve path | Create dir | Read | Write | Compress | Notes                                     |
|--------------|:------------:|:----------:|:----:|:-----:|:--------:|-------------------------------------------|
| Desktop      | yes          | yes        | yes  | yes   | yes      | Full support; XDG-compliant               |
| Windows      | yes          | yes        | yes  | yes   | yes      | `~/.config/` root (XDG-literal, not APPDATA) |
| PS Vita      | yes          | yes        | yes  | yes   | yes      | `ux0:data` writable; read hw-verified, writes Vita3K-verified (v0.3.0) |
| Nintendo 3DS | yes          | yes        | yes  | yes   | yes      | `sdmc:/` writable; writes hardware-verified (v0.4.0) |
| PSP          | yes          | yes*       | yes  | yes*  | yes*     | *Write-capability gated; verify SDK       |
| WebAssembly  | yes          | n/a        | stub | stub  | stub†    | localStorage; v2 impl                     |

† v2 routes binary/compression through base64-encoded localStorage values.

Path resolution is always available — computing a path is pure string work. Writing is a
separate capability gated by `isWritable()`.

---

## Error handling

```
ConfigError           ← catch this for any configy failure
  ConfigPathError     ← bad app/dep/filename, or HOME/USERPROFILE unset with no usable XDG_CONFIG_HOME
  ConfigIOError       ← filesystem operation failed (wraps OSError/IOError)
  ConfigParseError    ← file existed but was malformed (bad magic byte, corrupt
                         Snappy payload, invalid JSON, or failed to(T) conversion)
  ConfigUnsupportedError ← write on a read-only target (3DS/PSP v1, WASM v1)
```

Missing files on read return `none()`, not an exception.

---

## Design

- **Minimal pure-Nim dependencies.** One external dep: `supersnappy` (pure Nim, compiles
  on all targets†). Stdlib: `std/os`, `std/json`, `std/options`.
- **Self-describing files.** A magic byte prefix (`\x00` raw / `\x01` Snappy) makes every
  file self-describing — reads always auto-detect, no compile-time flags needed.
- **Pure vs. creating procs are clearly named.** `configDir`/`configFile` (pure, never
  touch disk); `ensureConfigDir`/`ensureConfigFile` (create where writable).
- **No global mutable state.** Every proc takes its inputs as parameters.
- **Compile-time platform gating.** All `when defined(...)` checks centralized in
  `src/configy/capabilities.nim`. Adding a new platform = one file change.
- **Compact by default.** `writeConfigJson` defaults to compact JSON (`pretty=false`),
  consistent with `std/json`. Pass `pretty=true` for human-editable files.
- **Exceptions, not `Result`.** A small `ConfigError` hierarchy wraps `std/os` and
  `std/json`. Genuine queries (`isWritable`, file-exists, reads) return `bool` or
  `Option[T]`.
- **ARC-compatible.** Plain value types; no cycles, no custom GC hooks.

† supersnappy compilation on devkitARM (3DS), PSPDEV, and VitaSDK should be verified
  against each toolchain before shipping to those targets.

---

## Migrating from v0.1.x

v0.2.0 changes path roots for all platforms. Existing config files stored under the old
scheme must be moved manually — configy does not auto-migrate. Old and new roots:

| Platform | Old root | New root |
|----------|----------|----------|
| Linux/macOS | `~/.<vendor>/config/` | `~/.config/<vendor>/` |
| Windows | `%APPDATA%\<vendor>\config\` | `~\.config\<vendor>\` |
| 3DS | `sdmc:/<vendor>/config/` | `sdmc:/config/<vendor>/` |
| PSP | `ms0:/PSP/<vendor>/config/` | `ms0:/PSP/config/<vendor>/` |
| Vita | `ux0:data/<vendor>/config/` | `ux0:data/config/<vendor>/` |
| WASM | `<vendor>/config/` | `config/<vendor>/` |

---

## Installation

Add to your `*.nimble` file:

```
requires "configy >= 0.1.0"
```

Or install directly:

```sh
nimble install configy
```

---

## Testing

```sh
nimble test
```

The test suite covers path resolution, all magic-byte error cases, JSON/binary/typed
round-trips with and without Snappy compression, and the full `ConfigError` hierarchy.
CI runs desktop tests on Linux, macOS, and Windows. It also runs platform-define
compile checks for 3DS, PSP, Vita, and WebAssembly — these verify that the
`when defined(...)` branches in the library compile cleanly on the host OS, but are
**not** full cross-compiles (actual cross-compilation requires devkitARM, PSPDEV,
VitaSDK, or Emscripten, which are not available in standard CI).
