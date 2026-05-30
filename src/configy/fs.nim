import std/os
import configy/capabilities
import configy/errors
import configy/paths

proc isWritable*(): bool =
  ## Runtime answer to "can configy persist data on this target?"
  ## v1: returns the compile-time configyFsWritable const directly.
  configyFsWritable

proc ensureConfigDir*(app, dep: string): string =
  ## Resolve configDir(app, dep) and create the directory (and parents) if missing.
  ## Returns the directory path. BEST-EFFORT: non-throwing on read-only targets.
  ## On WASM returns the key prefix without touching any filesystem.
  ## Raises ConfigIOError if creation is attempted and fails.
  result = configDir(app, dep)
  when configyFsWritable:
    try:
      createDir(result)
    except OSError as e:
      raise newException(ConfigIOError,
        "ensureConfigDir failed for " & result & ": " & e.msg)
