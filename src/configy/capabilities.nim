const
  configyHasRealFs* = not defined(emscripten)
    ## True on platforms with a real POSIX/SDK filesystem (not localStorage).

  configyUsesOsPath* = not (defined(ds3) or defined(psp) or defined(vita) or defined(emscripten))
    ## True only on desktop/windows where std/os path operators are safe to use.
    ## Console and WASM paths must use plain string concatenation.

  configyHasSnappy* = true
    ## supersnappy is a required pure-Nim dependency; always available on all targets.

# Conservative: 3DS and PSP default false until the SDK FS is verified.
# WASM is false for v1 (localStorage writes not implemented).
const configyFsWritable* =
  when defined(emscripten):             false
  elif defined(ds3) or defined(psp):    false
  else:                                 true

const configyVendor {.strdefine.} = ""

static:
  when configyVendor.len == 0:
    {.error: "configy: pass -d:configyVendor=<yourorg> when building".}

const VendorNamespace* = configyVendor
  ## Re-export of configyVendor. Readable at runtime for logging/diagnostics.
  ## Caller is responsible for using a filesystem-safe value (no path separators).
