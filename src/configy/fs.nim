import std/os
import configy/capabilities
import configy/errors
import configy/paths

when defined(dreamcast):
  import configy/vmu  # vmuIsWritable() for runtime VMU probe

proc isWritable*(): bool {.raises: [].} =
  ## Returns true if this platform can persist config data.
  ## On Dreamcast: runtime VMU probe via vmuIsWritable() (present at a1 + free blocks).
  ## On all other platforms: reflects compile-time configyFsWritable const.
  ## Note: isWritable() is a best-effort indicator, not a per-call guarantee —
  ## ensureConfigDir can still raise ConfigIOError at runtime on writable platforms.
  when defined(dreamcast):
    vmuIsWritable()
  else:
    configyFsWritable

proc createDirTree(dir: string) =
  ## Create `dir` and any missing parents.
  ##
  ## On 3DS, std/os.createDir cannot be used directly: it walks parentDirs from the
  ## root, so for an `sdmc:/config/...` path its FIRST mkdir/stat targets the bare
  ## `sdmc:/` device root — which libctru's sdmc devoptab rejects with EINVAL (NOT
  ## EEXIST), so createDir raises and every write fails. (Confirmed on real 3DS
  ## hardware 2026-06-07; Azahar's host-passthrough SD masks it. See
  ## .agents/plans/3ds-writable/RESULTS.md.) So the ds3 branch creates only the real
  ## subdirs UNDER the device root, never touching the bare `device:/` prefix.
  ##
  ## On Dreamcast, the VMU is a flat filesystem with no directory support.
  ## ensureConfigDir returns the logical path as-is; createDirTree is a no-op.
  when defined(dreamcast):
    discard  # VMU is a flat FS — no dirs to create; path is used as a hash key only
  elif defined(ds3):
    # Skip the "device:/" prefix: scan to the first ':' then past the following '/'.
    var p = 0
    while p < dir.len and dir[p] != ':': inc p
    inc p
    while p < dir.len and dir[p] == '/': inc p
    # Create each cumulative real subdir (sdmc:/config, …/<vendor>, …/<app>[, …/<dep>]).
    for i in p ..< dir.len:
      if dir[i] == '/':
        let sub = dir[0 ..< i]
        if not dirExists(sub):
          discard existsOrCreateDir(sub)  # single-level; never recurses to the root
  else:
    createDir(dir)

proc ensureConfigDir*(app: string): string {.raises: [ConfigPathError, ConfigIOError].} =
  ## Dep-less form: resolve configDir(app) and create the directory (and parents) if missing.
  ## Returns the directory path.
  ## ConfigPathError is raised on invalid app on ALL targets (before any FS access).
  ## On read-only targets (3DS, PSP, WASM), directory creation is skipped.
  ## ConfigIOError is raised only when creation is attempted and fails.
  result = configDir(app)
  when configyFsWritable:
    try:
      createDirTree(result)
    except CatchableError as e:
      raise newException(ConfigIOError,
        "ensureConfigDir failed for " & result & ": " & e.msg)

proc ensureConfigDir*(app, dep: string): string {.raises: [ConfigPathError, ConfigIOError].} =
  ## Full form: resolve configDir(app, dep) and create the directory (and parents) if missing.
  ## Returns the directory path.
  ## ConfigPathError is raised on invalid app/dep on ALL targets (before any FS access).
  ## On read-only targets (3DS, PSP, WASM), directory creation is skipped and the
  ## resolved path is returned as-is (best-effort, non-throwing for FS operations).
  ## ConfigIOError is raised only when creation is attempted and fails.
  result = configDir(app, dep)
  when configyFsWritable:
    try:
      createDirTree(result)
    except CatchableError as e:
      raise newException(ConfigIOError,
        "ensureConfigDir failed for " & result & ": " & e.msg)
