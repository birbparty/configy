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
