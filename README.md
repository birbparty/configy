# configy

A small, cross-platform configuration path resolver and storage library for Nim.

`configy` answers one question for any Nim application or library:

> *"Where do I put my config data on this platform, and how do I read/write it safely?"*

It resolves a predictable, vendor-namespaced directory per platform, creates it on first
use, and provides thin storage helpers for JSON, raw binary, and typed generics — with
optional Snappy compression on all three. It is plumbing, not policy.

---

## The path scheme

Every path is `<root>/<vendor>/config/<app>/<dep>/`, adapted per platform:

| Platform              | Resolved config directory                                         |
|-----------------------|-------------------------------------------------------------------|
| Desktop (Linux/macOS) | `~/.<vendor>/config/<app>/<dep>/`                                 |
| Windows               | `%APPDATA%\<vendor>\config\<app>\<dep>\`                          |
| Nintendo 3DS          | `sdmc:/<vendor>/config/<app>/<dep>/`                              |
| PSP                   | `ms0:/PSP/<vendor>/config/<app>/<dep>/`                           |
| PS Vita               | `ux0:data/<vendor>/config/<app>/<dep>/`                           |
| WebAssembly           | localStorage key prefix `<vendor>/config/<app>/<dep>/` (stubbed)  |

- `<vendor>` — your organization/project namespace, set at compile time (required).
- `<app>` — the consuming application name, supplied at call time.
- `<dep>` — the library or feature name, supplied at call time.

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
import configy
import std/options

# ── Typed generic (most ergonomic) ───────────────────────────────────────────
type Settings = object
  volume: float
  fullscreen: bool

if isWritable():
  writeConfig("myapp", "mylib", "settings.json",
              Settings(volume: 0.8, fullscreen: true), compress = true)

let s = readConfig[Settings]("myapp", "mylib", "settings.json")
# Desktop -> ~/.myorg/config/myapp/mylib/settings.json (compact JSON, Snappy-compressed)

# ── JsonNode (flexible, schema-free) ─────────────────────────────────────────
if isWritable():
  # pretty=true for human-editable files; default is compact
  writeConfigJson("myapp", "mylib", "raw.json", %*{"x": 1})

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
let dir  = configDir("myapp", "mylib")
let path = configFile("myapp", "mylib", "settings.json")

# Creating helpers (fs.nim / store.nim) — create the dir where writable, no-op where not.
# Never raise on a read-only target:
let made = ensureConfigDir("myapp", "mylib")
let file = ensureConfigFile("myapp", "mylib", "settings.json")
```

---

## Platform support

| Platform     | Resolve path | Create dir | Read | Write | Compress | Notes                               |
|--------------|:------------:|:----------:|:----:|:-----:|:--------:|-------------------------------------|
| Desktop      | yes          | yes        | yes  | yes   | yes      | Full support                        |
| Windows      | yes          | yes        | yes  | yes   | yes      | `%APPDATA%` root                    |
| PS Vita      | yes          | yes        | yes  | yes   | yes      | `ux0:data` is writable              |
| Nintendo 3DS | yes          | yes*       | yes  | yes*  | yes*     | *Write-capability gated; verify SDK |
| PSP          | yes          | yes*       | yes  | yes*  | yes*     | *Write-capability gated; verify SDK |
| WebAssembly  | yes          | n/a        | stub | stub  | stub†    | localStorage; v2 impl               |

† v2 routes binary/compression through base64-encoded localStorage values.

Path resolution is always available — computing a path is pure string work. Writing is a
separate capability gated by `isWritable()`.

---

## Error handling

```
ConfigError           ← catch this for any configy failure
  ConfigPathError     ← bad app/dep/filename, or %APPDATA% unset on Windows
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
