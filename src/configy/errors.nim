type
  ConfigError* = object of CatchableError
    ## Base for all configy errors. Catch this to handle any configy failure.

  ConfigPathError* = object of ConfigError
    ## A path could not be resolved or validated (e.g. empty app/dep name,
    ## path-traversal attempt in a relative path component).

  ConfigIOError* = object of ConfigError
    ## A filesystem operation failed (create dir, read, write). Wraps the
    ## underlying OSError/IOError; the original message is preserved.

  ConfigParseError* = object of ConfigError
    ## Stored data existed but could not be parsed (bad magic byte, corrupt
    ## Snappy payload, invalid JSON, or failed to(T) conversion).

  ConfigUnsupportedError* = object of ConfigError
    ## The operation is not supported on this platform/target
    ## (e.g. a write attempt where the FS is known read-only, or a
    ##  not-yet-implemented WASM path).

# ── VMU failure mode → error type mapping (Dreamcast store.nim routing) ─────
#
# All KOS VMU failure modes are covered by the existing taxonomy; no new type
# is needed. Reference when implementing vmu.nim procs and store.nim dispatch.
#
# maple_enum_dev(0,1) == nil  → ConfigIOError      "VMU not present"
# vmufs_free_blocks < needed  → ConfigIOError      "VMU full (N blocks free, need M)"
# vmu_pkg_build < 0           → ConfigIOError      "vmu_pkg_build failed"
# vmufs_write < 0             → ConfigIOError      "vmufs_write failed"
# vmufs_read  < 0             → ConfigIOError      "vmufs_read failed"
# vmufs_delete == -2          → ConfigIOError      "vmufs_delete failed"
# vmufs_delete == -1 (absent) → (no error — delete is idempotent; skip silently)
# vmu_pkg_parse < 0 (bad CRC) → ConfigParseError  "VMU file CRC check failed"
# configyFsWritable == false  → ConfigUnsupportedError (not writable on platform)
# empty/invalid path segment  → ConfigPathError   (raised before any KOS call)
#
# Hash collision policy: two logical paths that map to the same 11-char VMU
# filename silently overwrite each other. Accepted risk — <10 files per typical
# deployment makes collision negligibly unlikely in a 36^11 namespace.
