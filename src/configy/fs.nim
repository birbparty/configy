import std/os
import configy/capabilities
import configy/errors
import configy/paths

proc isWritable*(): bool {.raises: [].} =
  ## Returns true if this platform can persist config data.
  ## v1: reflects the compile-time configyFsWritable const (no runtime probe).
  ## Note: isWritable() is a platform capability flag, not a per-call guarantee —
  ## ensureConfigDir can still raise ConfigIOError at runtime on writable platforms.
  configyFsWritable

proc ensureConfigDir*(app, dep: string): string {.raises: [ConfigPathError, ConfigIOError].} =
  ## Resolve configDir(app, dep) and create the directory (and parents) if missing.
  ## Returns the directory path.
  ## ConfigPathError is raised on invalid app/dep on ALL targets (before any FS access).
  ## On read-only targets (3DS, PSP, WASM), directory creation is skipped and the
  ## resolved path is returned as-is (best-effort, non-throwing for FS operations).
  ## ConfigIOError is raised only when creation is attempted and fails.
  result = configDir(app, dep)
  when configyFsWritable:
    try:
      createDir(result)
    except CatchableError as e:
      raise newException(ConfigIOError,
        "ensureConfigDir failed for " & result & ": " & e.msg)
