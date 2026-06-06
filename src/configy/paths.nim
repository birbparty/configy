import std/os
import configy/capabilities
import configy/errors

proc validateComponent*(s: string) {.raises: [ConfigPathError].} =
  ## Validates a single path component (app, dep, or filename).
  ## Raises ConfigPathError if s is empty, contains '/', '\', ':', or is exactly "..".
  ## Note: embedded ".." substrings (e.g. "my..backup.json") are allowed —
  ## with '/' and '\' already blocked, they cannot form traversal sequences.
  if s.len == 0:
    raise newException(ConfigPathError, "path component must not be empty")
  if s == "..":
    raise newException(ConfigPathError, "path component must not be \"..\"")
  for c in s:
    case c
    of '/', '\\':
      raise newException(ConfigPathError,
        "path component must not contain path separators: " & s)
    of ':':
      raise newException(ConfigPathError,
        "path component must not contain ':' (NTFS ADS / device prefix risk): " & s)
    else:
      discard

proc configRoot*(): string {.raises: [ConfigPathError].} =
  ## The platform config prefix up to and including the vendor namespace,
  ## with a trailing separator. Values:
  ##   Desktop (Linux/macOS/Windows): $XDG_CONFIG_HOME/<vendor>/  (fallback: ~/.config/<vendor>/)
  ##   3DS:  sdmc:/config/<vendor>/
  ##   PSP:  ms0:/PSP/config/<vendor>/
  ##   Vita: ux0:data/config/<vendor>/
  ##   WASM: config/<vendor>/  (localStorage key prefix)
  ## On desktop, $XDG_CONFIG_HOME is used only when set, non-empty, and absolute.
  ## Raises ConfigPathError if HOME/USERPROFILE is unset and XDG_CONFIG_HOME is unusable.
  when defined(ds3):
    result = "sdmc:/config/" & VendorNamespace & "/"
  elif defined(psp):
    result = "ms0:/PSP/config/" & VendorNamespace & "/"
  elif defined(vita):
    result = "ux0:data/config/" & VendorNamespace & "/"
  elif defined(emscripten):
    result = "config/" & VendorNamespace & "/"
  else:
    # Desktop: Linux, macOS, Windows — XDG-literal everywhere.
    # Windows uses ~/.config/ instead of %APPDATA% intentionally (XDG-literal choice).
    let xdgConfigHome = getEnv("XDG_CONFIG_HOME")
    if xdgConfigHome.len > 0 and isAbsolute(xdgConfigHome):
      result = xdgConfigHome / VendorNamespace & $DirSep
    else:
      let home = getHomeDir()
      if home.len == 0:
        raise newException(ConfigPathError,
          "home directory is not set (HOME / USERPROFILE unset)")
      result = home / ".config" / VendorNamespace & $DirSep

proc configDir*(app: string): string {.raises: [ConfigPathError].} =
  ## Dep-less form: returns the config directory for app only, without creating it.
  ## Trailing separator is included.
  ## NOTE: configDir(app, x) treats x as a *dep* (directory), while
  ## configFile(app, x) treats x as a *filename*. A two-arg call to each function
  ## has the same types but different meanings for the second argument.
  validateComponent(app)
  when configyUsesOsPath:
    result = configRoot() & app & $DirSep
  else:
    result = configRoot() & app & "/"

proc configDir*(app, dep: string): string {.raises: [ConfigPathError].} =
  ## Full form: returns the config directory for app+dep without creating it.
  ## Trailing separator is included. Raises ConfigPathError on invalid components.
  validateComponent(app)
  validateComponent(dep)
  when configyUsesOsPath:
    # Use DirSep so Windows paths use backslashes consistently.
    # Avoid / operator: x / "" drops empty components (no trailing sep).
    result = configRoot() & app & $DirSep & dep & $DirSep
  else:
    result = configRoot() & app & "/" & dep & "/"

proc configFile*(app, filename: string): string {.raises: [ConfigPathError].} =
  ## Dep-less form: file lives directly under the app directory.
  ## Raises ConfigPathError on invalid app or filename.
  ## NOTE: the second positional arg is the *filename*, not a dep. A v0.1.x call
  ## configFile("app", "dep", "file.json") that loses the dep arg silently compiles
  ## to configFile("app", "dep") → a *file* at .../app/dep rather than an error.
  validateComponent(filename)
  result = configDir(app) & filename

proc configFile*(app, dep, filename: string): string {.raises: [ConfigPathError].} =
  ## Full form: configDir(app, dep) joined with a validated filename.
  ## Raises ConfigPathError on invalid app, dep, or filename.
  validateComponent(filename)
  result = configDir(app, dep) & filename
