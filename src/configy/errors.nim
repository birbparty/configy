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
# maple_enum_dev(0,1) == nil  → ConfigIOError      "VMU not present" (runtime
#                                absence, not a platform-support question;
#                                applies to both read and write paths)
# isPresent() == false        → guard before freeBlocks(); freeBlocks() clamps
#                                absence and FAT errors to 0, so a 0 return
#                                alone is ambiguous — always probe isPresent()
#                                first in the capacity-check code path
# vmufs_free_blocks < needed  → ConfigIOError      "VMU full (N blocks free, need M)"
# vmu_pkg_build < 0           → ConfigIOError      "vmu_pkg_build failed"
# vmufs_write < 0             → ConfigIOError      "vmufs_write failed"
# vmufs_read  < 0             → ConfigIOError      "vmufs_read failed"
# vmufs_delete == 0           → return true  (deleted)
# vmufs_delete == -1 (absent) → return false (not found — idempotent; matches
#                                deleteConfig's bool contract; do NOT raise)
# vmufs_delete == -2          → ConfigIOError      "vmufs_delete failed"
# vmu_pkg_parse < 0 (bad CRC) → ConfigParseError  "VMU file CRC check failed"
# configyFsWritable == false  → ConfigUnsupportedError (not writable on platform)
# empty/invalid path segment  → ConfigPathError   (raised before any KOS call)
#
# Hash collision policy: two logical paths that collide to the same VMU filename
# silently overwrite each other (last writer wins via VMUFS_OVERWRITE). Accepted
# risk — see vmu_hash.nim FROZEN FORMAT CONTRACT for collision probability
# (~57 effective bits across the 11-char base-36 namespace).
