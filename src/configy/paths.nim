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
  ## The platform config prefix up to and including the vendor namespace +
  ## "config" segment, with a trailing separator. Values:
  ##   Desktop : ~/.<vendor>/config/
  ##   Windows : %APPDATA%\<vendor>\config\
  ##   3DS     : sdmc:/<vendor>/config/
  ##   PSP     : ms0:/PSP/<vendor>/config/
  ##   Vita    : ux0:data/<vendor>/config/
  ##   WASM    : <vendor>/config/  (localStorage key prefix)
  when defined(ds3):
    result = "sdmc:/" & VendorNamespace & "/config/"
  elif defined(psp):
    result = "ms0:/PSP/" & VendorNamespace & "/config/"
  elif defined(vita):
    result = "ux0:data/" & VendorNamespace & "/config/"
  elif defined(emscripten):
    result = VendorNamespace & "/config/"
  elif defined(windows):
    let appData = getEnv("APPDATA")
    if appData.len == 0:
      raise newException(ConfigPathError, "APPDATA environment variable is not set")
    result = appData / VendorNamespace / "config" / ""
  else:
    result = getHomeDir() / "." & VendorNamespace / "config" / ""

proc configDir*(app, dep: string): string {.raises: [ConfigPathError].} =
  ## Pure resolver: returns the config directory for app+dep WITHOUT creating it.
  ## Trailing separator is included. Raises ConfigPathError on invalid components.
  validateComponent(app)
  validateComponent(dep)
  when configyUsesOsPath:
    result = configRoot() / app / dep / ""
  else:
    result = configRoot() & app & "/" & dep & "/"

proc configFile*(app, dep, filename: string): string {.raises: [ConfigPathError].} =
  ## configDir(app, dep) joined with a validated filename.
  ## Raises ConfigPathError on invalid app, dep, or filename.
  validateComponent(filename)
  result = configDir(app, dep) & filename
