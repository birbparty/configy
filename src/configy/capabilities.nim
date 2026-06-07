const
  configyHasRealFs* = not defined(emscripten)
    ## True on platforms with a real POSIX/SDK filesystem (not localStorage).

  configyUsesOsPath* = not (defined(ds3) or defined(psp) or defined(vita) or defined(emscripten))
    ## True only on desktop/windows where std/os path operators are safe to use.
    ## Console and WASM paths must use plain string concatenation.

  configyHasSnappy* = true
    ## supersnappy is a required pure-Nim dependency; always available on all targets.

# 3DS: read path verified on devkitARM (os:linux+newlib+libctru) as of 2026-06-06
#   — compiles, links, and reads sdmc:/ correctly in Azahar (see verify/ds3/ and
#   scripts/build_3ds.sh). configyFsWritable stays false: writes are not yet
#   verified/enabled on 3DS (would be a future change; sdmc:/ is writable).
# Vita: read path compiles + links + passes vita-elf-create on VitaSDK
#   (os:linux+newlib), runs correctly in Vita3K, AND runs correctly on real PS Vita
#   hardware as of 2026-06-06 (see verify/vita/ and RESULTS.md). newlib backs file
#   I/O with sceIo* so std/os reaches ux0: with no shim. Hardware run (absent-file
#   case) wrote the expected marker -> exists=false, read_isNone=true, no raise --
#   which also RETIRES the -Wl,-q relocation risk: the module loaded and ran at a
#   non-link base without data-aborting. Planted-file case (found + JSON parsed)
#   confirmed in Vita3K.
#   configyFsWritable stays false (conservative: writes unverified on hardware;
#   ux0:data/ IS writable and newlib backs writes via sceIo*, so enabling them later
#   is low-cost). NOTE: flipping this to false only compiles out fs.nim's createDir;
#   store.nim's write APIs gate at runtime via isWritable() — a runtime read-only
#   posture, not a link-surface change.
# PSP: default false until the SDK FS is verified (unverified on a real toolchain).
# WASM is false for v1 (localStorage writes not implemented).
const configyFsWritable* =
  when defined(emscripten):                            false
  elif defined(ds3) or defined(psp) or defined(vita): false
  else:                                                true

const configyVendor {.strdefine.} = ""

static:
  when configyVendor.len == 0:
    {.error: "configy: pass -d:configyVendor=<yourorg> when building".}

const VendorNamespace* = configyVendor
  ## Re-export of configyVendor. Readable at runtime for logging/diagnostics.
  ## Caller is responsible for using a filesystem-safe value (no path separators).
