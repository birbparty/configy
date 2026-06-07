const
  configyHasRealFs* = not defined(emscripten)
    ## True on platforms with a real POSIX/SDK filesystem (not localStorage).

  configyUsesOsPath* = not (defined(ds3) or defined(psp) or defined(vita) or defined(emscripten))
    ## True only on desktop/windows where std/os path operators are safe to use.
    ## Console and WASM paths must use plain string concatenation.

  configyHasSnappy* = true
    ## supersnappy is a required pure-Nim dependency; always available on all targets.

# 3DS: read path verified on devkitARM (os:linux+newlib+libctru); sdmc:/ reads work in
#   Azahar (see verify/ds3/ and scripts/build_3ds.sh). configyFsWritable is now TRUE for
#   ds3: sdmc:/ is writable and a leaf writeFile there already works (the read smoke's
#   marker). Directory creation uses stock std/os.createDir, which mkdir's/stats the bare
#   sdmc:/ device root first — whether libctru's sdmc devoptab tolerates that (vs needing
#   a -d:ds3 createDirTree shim that skips the root) is decided by the real-hardware run.
#   Write round-trip (ensureConfigDir/createDir, writeConfigJson raw+compressed,
#   writeConfigBytes, deleteConfig) verification status: see
#   .agents/plans/3ds-writable/RESULTS.md.
# Vita: read path verified on real PS Vita hardware (os:linux+newlib; see verify/vita/
#   and .agents/plans/vita-support/RESULTS.md) — std/os reaches ux0: via newlib's
#   sceIo*-backed syscalls with no shim. configyFsWritable is now TRUE for vita:
#   ux0:data/ is the writable homebrew dir, newlib backs mkdir/write/remove with
#   sceIo*, and the write round-trip (ensureConfigDir/createDir, writeConfigJson raw+
#   compressed, writeConfigBytes, deleteConfig) is verified on real PS Vita hardware
#   (all steps PASS, isWritable=true) as of 2026-06-06 — see
#   .agents/plans/vita-writable/RESULTS.md. createDir over ux0: works because newlib
#   maps sceIoMkdir's already-exists error to EEXIST, which std/os.createDir tolerates
#   (confirmed on-device, not just Vita3K).
# PSP: configyFsWritable false until the SDK FS is verified (unverified on a real
#   toolchain). WASM is false for v1 (localStorage writes not implemented).
const configyFsWritable* =
  when defined(emscripten): false
  elif defined(psp):        false
  else:                     true

const configyVendor {.strdefine.} = ""

static:
  when configyVendor.len == 0:
    {.error: "configy: pass -d:configyVendor=<yourorg> when building".}

const VendorNamespace* = configyVendor
  ## Re-export of configyVendor. Readable at runtime for logging/diagnostics.
  ## Caller is responsible for using a filesystem-safe value (no path separators).
