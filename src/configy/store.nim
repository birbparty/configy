import std/[os, json, options, strutils]
import supersnappy
import configy/errors
import configy/paths
import configy/fs
# Re-export the types consumers need to use the return values of this module's procs.
# Without these, `import configy` consumers cannot call .isSome/.get on Option results
# or use %* / JsonNode for writeConfigJson arguments.
export options, json
when defined(emscripten):
  import configy/wasm
when defined(dreamcast):
  import configy/vmu  # writeVmuFile/readVmuFile/existsVmuFile/deleteVmuFile

# ── Internal byte-level core ──────────────────────────────────────────────────

const MagicRaw    = '\x00'
const MagicSnappy = '\x01'

proc storeBytes(path: string; data: string; compress: bool) =
  let payload =
    try:
      if compress: MagicSnappy & supersnappy.compress(data)
      else:        MagicRaw    & data
    except CatchableError as e:
      raise newException(ConfigIOError, "compression failed for " & path & ": " & e.msg)
  when defined(dreamcast):
    writeVmuFile(path, payload)  # VMS-wraps payload; raises ConfigIOError on failure
  else:
    try:
      writeFile(path, payload)
    except CatchableError as e:
      raise newException(ConfigIOError, "write failed for " & path & ": " & e.msg)

proc loadBytes(path: string): string =
  let raw =
    when defined(dreamcast):
      readVmuFile(path)  # VMS-unwraps; raises ConfigIOError on absent/error, ConfigParseError on bad CRC
    else:
      try: readFile(path)
      except CatchableError as e:
        raise newException(ConfigIOError, "read failed for " & path & ": " & e.msg)
  if raw.len == 0:
    raise newException(ConfigParseError, "empty file (missing magic byte): " & path)
  case raw[0]
  of MagicRaw:
    if raw.len == 1:
      raise newException(ConfigParseError, "empty payload after magic byte: " & path)
    result = raw[1..^1]
  of MagicSnappy:
    if raw.len == 1:
      raise newException(ConfigParseError, "empty Snappy payload: " & path)
    try:
      result = supersnappy.uncompress(raw[1..^1])
    except CatchableError as e:
      raise newException(ConfigParseError, "corrupt Snappy payload in " & path & ": " & e.msg)
  else:
    raise newException(ConfigParseError,
      "unknown magic byte 0x" & raw[0].ord.toHex(2) & " — not a configy file: " & path)

proc notFound(path: string): bool =
  when defined(dreamcast):
    not existsVmuFile(path)  # returns false on absent VMU or absent file → notFound = true
  else:
    not fileExists(path)

# ── Public API ────────────────────────────────────────────────────────────────

proc ensureConfigFile*(app, filename: string): string
    {.raises: [ConfigPathError, ConfigIOError].} =
  ## Dep-less form: ensureConfigDir(app) + filename. Returns a writable file path.
  validateComponent(filename)
  result = ensureConfigDir(app) & filename

proc ensureConfigFile*(app, dep, filename: string): string
    {.raises: [ConfigPathError, ConfigIOError].} =
  ## Full form: ensureConfigDir(app, dep) + filename. Returns a writable file path.
  validateComponent(filename)
  result = ensureConfigDir(app, dep) & filename

# ── JSON helpers ──────────────────────────────────────────────────────────────

proc writeConfigJson*(app, filename: string; data: JsonNode;
                      pretty = false; compress = false)
    {.raises: [ConfigPathError, ConfigUnsupportedError, ConfigIOError].} =
  ## Dep-less form: serialize data → compress → magic byte → write.
  ## Raises ConfigUnsupportedError if not isWritable().
  when defined(emscripten):
    let key = configFile(app, filename)
    let serialized = if pretty: json.pretty(data) else: $data
    wasm.setItem(key, serialized)
  else:
    if not isWritable():
      raise newException(ConfigUnsupportedError,
        "writeConfigJson: target is read-only")
    let path = ensureConfigFile(app, filename)
    let serialized = if pretty: json.pretty(data) else: $data
    storeBytes(path, serialized, compress)

proc writeConfigJson*(app, dep, filename: string; data: JsonNode;
                      pretty = false; compress = false)
    {.raises: [ConfigPathError, ConfigUnsupportedError, ConfigIOError].} =
  ## Full form: serialize data → compress → magic byte → write.
  ## Raises ConfigUnsupportedError if not isWritable().
  ## On WASM v1: delegates to wasm.setItem which raises ConfigUnsupportedError.
  when defined(emscripten):
    let key = configFile(app, dep, filename)
    # TODO(wasm-v2): add magic-byte framing and compress support for localStorage.
    let serialized = if pretty: json.pretty(data) else: $data
    wasm.setItem(key, serialized)
  else:
    if not isWritable():
      raise newException(ConfigUnsupportedError,
        "writeConfigJson: target is read-only")
    let path = ensureConfigFile(app, dep, filename)
    let serialized = if pretty: json.pretty(data) else: $data
    storeBytes(path, serialized, compress)

proc readConfigJson*(app, filename: string): Option[JsonNode]
    {.raises: [ConfigPathError, ConfigParseError, ConfigIOError].} =
  ## Dep-less form: none() if file absent. Checks magic, decompresses, parses JSON.
  when defined(emscripten):
    let key = configFile(app, filename)
    let val = wasm.getItem(key)
    if val.isNone: return none(JsonNode)
    try:
      return some(parseJson(val.get))
    except CatchableError as e:
      raise newException(ConfigParseError, "JSON parse error: " & e.msg)
  else:
    let path = configFile(app, filename)
    if notFound(path): return none(JsonNode)
    let payload = loadBytes(path)
    try:
      return some(parseJson(payload))
    except CatchableError as e:
      raise newException(ConfigParseError, "JSON parse error in " & path & ": " & e.msg)

proc readConfigJson*(app, dep, filename: string): Option[JsonNode]
    {.raises: [ConfigPathError, ConfigParseError, ConfigIOError].} =
  ## Full form: none() if file absent. Checks magic, decompresses, parses JSON.
  ## On WASM v1: delegates to wasm.getItem which returns none().
  when defined(emscripten):
    let key = configFile(app, dep, filename)
    # TODO(wasm-v2): strip magic-byte framing and decompress from localStorage value.
    let val = wasm.getItem(key)
    if val.isNone: return none(JsonNode)
    try:
      return some(parseJson(val.get))
    except CatchableError as e:
      raise newException(ConfigParseError, "JSON parse error: " & e.msg)
  else:
    let path = configFile(app, dep, filename)
    if notFound(path): return none(JsonNode)
    let payload = loadBytes(path)
    try:
      return some(parseJson(payload))
    except CatchableError as e:
      raise newException(ConfigParseError, "JSON parse error in " & path & ": " & e.msg)

# ── Binary helpers ────────────────────────────────────────────────────────────

proc writeConfigBytes*(app, filename: string; data: string; compress = false)
    {.raises: [ConfigPathError, ConfigUnsupportedError, ConfigIOError, ConfigParseError].} =
  ## Dep-less form: write raw bytes with magic byte prefix.
  ## Empty data raises ConfigParseError — use deleteConfig to remove a file.
  if data.len == 0:
    raise newException(ConfigParseError,
      "writeConfigBytes: empty payload not supported — use deleteConfig to remove a file")
  when defined(emscripten):
    let key = configFile(app, filename)
    wasm.setItem(key, data)
  else:
    if not isWritable():
      raise newException(ConfigUnsupportedError,
        "writeConfigBytes: target is read-only")
    let path = ensureConfigFile(app, filename)
    storeBytes(path, data, compress)

proc writeConfigBytes*(app, dep, filename: string; data: string; compress = false)
    {.raises: [ConfigPathError, ConfigUnsupportedError, ConfigIOError, ConfigParseError].} =
  ## Full form: write raw bytes with magic byte prefix.
  ## Empty data raises ConfigParseError — use deleteConfig to remove a file.
  ## Raises ConfigUnsupportedError if not isWritable().
  ## On WASM v1: delegates to wasm.setItem which raises ConfigUnsupportedError.
  if data.len == 0:
    raise newException(ConfigParseError,
      "writeConfigBytes: empty payload not supported — use deleteConfig to remove a file")
  when defined(emscripten):
    let key = configFile(app, dep, filename)
    # TODO(wasm-v2): use setItemBase64 and add magic-byte framing.
    wasm.setItem(key, data)
  else:
    if not isWritable():
      raise newException(ConfigUnsupportedError,
        "writeConfigBytes: target is read-only")
    let path = ensureConfigFile(app, dep, filename)
    storeBytes(path, data, compress)

proc readConfigBytes*(app, filename: string): Option[string]
    {.raises: [ConfigPathError, ConfigParseError, ConfigIOError].} =
  ## Dep-less form: none() if absent. Checks magic, decompresses, returns raw bytes.
  when defined(emscripten):
    let key = configFile(app, filename)
    return wasm.getItem(key)
  else:
    let path = configFile(app, filename)
    if notFound(path): return none(string)
    return some(loadBytes(path))

proc readConfigBytes*(app, dep, filename: string): Option[string]
    {.raises: [ConfigPathError, ConfigParseError, ConfigIOError].} =
  ## Full form: none() if absent. Checks magic, decompresses, returns raw bytes.
  ## On WASM v1: delegates to wasm.getItem which returns none().
  when defined(emscripten):
    let key = configFile(app, dep, filename)
    # TODO(wasm-v2): use getItemBase64 and strip magic-byte framing.
    return wasm.getItem(key)
  else:
    let path = configFile(app, dep, filename)
    if notFound(path): return none(string)
    return some(loadBytes(path))

# ── Typed generic helpers ─────────────────────────────────────────────────────

proc writeConfig*[T](app, filename: string; data: T;
                     pretty = false; compress = false)
    {.raises: [ConfigPathError, ConfigUnsupportedError, ConfigIOError].} =
  ## Dep-less form: %data -> writeConfigJson.
  ## NOTE: writeConfig("app", "x", "y") binds here when "y" is a string, with
  ## T=string ("x"=filename, "y"=data). For dep+filename, use the 3-string
  ## writeConfigJson overload or pass a non-string data type.
  when not compiles(%data):
    {.error: "configy.writeConfig: T has no `%` proc — import its JSON module".}
  writeConfigJson(app, filename, %data, pretty = pretty, compress = compress)

proc writeConfig*[T](app, dep, filename: string; data: T;
                     pretty = false; compress = false)
    {.raises: [ConfigPathError, ConfigUnsupportedError, ConfigIOError].} =
  ## Full form: %data -> writeConfigJson. Compile-time guard if T has no % proc.
  when not compiles(%data):
    {.error: "configy.writeConfig: T has no `%` proc — import its JSON module".}
  writeConfigJson(app, dep, filename, %data, pretty = pretty, compress = compress)

proc readConfig*[T](app, filename: string): Option[T]
    {.raises: [ConfigPathError, ConfigParseError, ConfigIOError].} =
  ## Dep-less form: readConfigJson -> .to(T). none() if absent.
  when not compiles(block:
    var j: JsonNode
    j.to(T)):
    {.error: "configy.readConfig: T has no `to(T)` conversion — import its JSON module".}
  let j = readConfigJson(app, filename)
  if j.isNone: return none(T)
  try:
    return some(j.get.to(T))
  except CatchableError as e:
    raise newException(ConfigParseError,
      "type conversion failed for " & filename & ": " & e.msg)

proc readConfig*[T](app, dep, filename: string): Option[T]
    {.raises: [ConfigPathError, ConfigParseError, ConfigIOError].} =
  ## Full form: readConfigJson -> .to(T). none() if absent. ConfigParseError if to(T) fails.
  when not compiles(block:
    var j: JsonNode
    j.to(T)):
    {.error: "configy.readConfig: T has no `to(T)` conversion — import its JSON module".}
  let j = readConfigJson(app, dep, filename)
  if j.isNone: return none(T)
  try:
    return some(j.get.to(T))
  except CatchableError as e:
    raise newException(ConfigParseError,
      "type conversion failed for " & filename & ": " & e.msg)

# ── File management ───────────────────────────────────────────────────────────

proc deleteConfig*(app, filename: string): bool
    {.raises: [ConfigPathError, ConfigUnsupportedError, ConfigIOError].} =
  ## Dep-less form: delete the file. true if removed, false if absent.
  when defined(emscripten):
    raise newException(ConfigUnsupportedError,
      "deleteConfig: localStorage delete not supported in WASM v1")
  else:
    if not isWritable():
      raise newException(ConfigUnsupportedError,
        "deleteConfig: target is read-only")
    let path = configFile(app, filename)
    when defined(dreamcast):
      return deleteVmuFile(path)  # true=deleted, false=not found, raises on VMU error
    else:
      if notFound(path): return false
      try:
        removeFile(path)
        return true
      except CatchableError as e:
        raise newException(ConfigIOError,
          "deleteConfig failed for " & path & ": " & e.msg)

proc deleteConfig*(app, dep, filename: string): bool
    {.raises: [ConfigPathError, ConfigUnsupportedError, ConfigIOError].} =
  ## Full form: delete the file. true if removed, false if absent.
  ## Raises ConfigUnsupportedError on a read-only target.
  when defined(emscripten):
    # TODO(wasm-v2): implement removeItem via localStorage JS interop.
    raise newException(ConfigUnsupportedError,
      "deleteConfig: localStorage delete not supported in WASM v1")
  else:
    if not isWritable():
      raise newException(ConfigUnsupportedError,
        "deleteConfig: target is read-only")
    let path = configFile(app, dep, filename)
    when defined(dreamcast):
      return deleteVmuFile(path)  # true=deleted, false=not found, raises on VMU error
    else:
      if notFound(path): return false
      try:
        removeFile(path)
        return true
      except CatchableError as e:
        raise newException(ConfigIOError,
          "deleteConfig failed for " & path & ": " & e.msg)

proc configFileExists*(app, filename: string): bool
    {.raises: [ConfigPathError].} =
  ## Dep-less form: true if the file exists. Safe on read-only targets.
  when defined(emscripten):
    let key = configFile(app, filename)
    return wasm.hasItem(key)
  elif defined(dreamcast):
    let path = configFile(app, filename)
    return existsVmuFile(path)
  else:
    let path = configFile(app, filename)
    return fileExists(path)

proc configFileExists*(app, dep, filename: string): bool
    {.raises: [ConfigPathError].} =
  ## Full form: true if the file exists. Safe on read-only targets.
  when defined(emscripten):
    let key = configFile(app, dep, filename)
    return wasm.hasItem(key)
  elif defined(dreamcast):
    let path = configFile(app, dep, filename)
    return existsVmuFile(path)
  else:
    let path = configFile(app, dep, filename)
    return fileExists(path)
