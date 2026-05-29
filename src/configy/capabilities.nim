const
  configyHasRealFs* = not defined(emscripten)

  configyFsWritable* =
    when defined(emscripten):             false
    elif defined(ds3) or defined(psp):    false
    else:                                 true

  configyUsesOsPath* = not (defined(ds3) or defined(psp) or defined(vita) or defined(emscripten))

const configyVendor {.strdefine.} = ""

static:
  when configyVendor.len == 0:
    {.error: "configy: pass -d:configyVendor=<yourorg> when building".}

const VendorNamespace* = configyVendor

const configyHasSnappy* = true
