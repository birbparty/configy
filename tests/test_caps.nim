import std/unittest
import configy/capabilities
import configy/fs

# Capability const characterization tests.
#
# These assert the CURRENT expected values for each platform's compile-time
# capability predicates. They act as a regression gate: any change to
# capabilities.nim that perturbs an existing platform's values will fail here.
#
# When a new platform arm is added (e.g. dreamcast), add the matching suite
# below BEFORE implementing the arm — the suite fails until the arm is correct.

suite "capability consts — desktop (non-console, non-WASM)":
  when not defined(ds3) and not defined(psp) and not defined(vita) and
       not defined(emscripten) and not defined(dreamcast):

    test "configyHasRealFs is true on desktop":
      check configyHasRealFs == true

    test "configyUsesOsPath is true on desktop":
      check configyUsesOsPath == true

    test "configyHasSnappy is true on desktop":
      check configyHasSnappy == true

    test "configyFsWritable is true on desktop":
      check configyFsWritable == true

    test "isWritable() returns true on desktop":
      check isWritable() == true

suite "capability consts — Nintendo 3DS (-d:ds3)":
  when defined(ds3):

    test "configyHasRealFs is true on 3DS (sdmc: is a real FS)":
      check configyHasRealFs == true

    test "configyUsesOsPath is false on 3DS (device-prefix paths, not POSIX)":
      check configyUsesOsPath == false

    test "configyHasSnappy is true on 3DS":
      check configyHasSnappy == true

    test "configyFsWritable is true on 3DS (sdmc:/ write verified on hardware)":
      check configyFsWritable == true

    test "isWritable() returns true on 3DS":
      check isWritable() == true

suite "capability consts — PS Vita (-d:vita)":
  when defined(vita):

    test "configyHasRealFs is true on Vita (ux0: is a real FS)":
      check configyHasRealFs == true

    test "configyUsesOsPath is false on Vita (device-prefix paths)":
      check configyUsesOsPath == false

    test "configyHasSnappy is true on Vita":
      check configyHasSnappy == true

    test "configyFsWritable is true on Vita (ux0:data/ write verified on hardware)":
      check configyFsWritable == true

    test "isWritable() returns true on Vita":
      check isWritable() == true

suite "capability consts — PSP (-d:psp)":
  when defined(psp):

    test "configyHasRealFs is true on PSP (ms0: is a real FS)":
      check configyHasRealFs == true

    test "configyUsesOsPath is false on PSP (device-prefix paths)":
      check configyUsesOsPath == false

    test "configyHasSnappy is true on PSP":
      check configyHasSnappy == true

    test "configyFsWritable is false on PSP (unverified SDK FS)":
      check configyFsWritable == false

    test "isWritable() returns false on PSP":
      check isWritable() == false

suite "capability consts — WASM/emscripten (-d:emscripten)":
  when defined(emscripten):

    test "configyHasRealFs is false on WASM (localStorage, not a real FS)":
      check configyHasRealFs == false

    test "configyUsesOsPath is false on WASM":
      check configyUsesOsPath == false

    test "configyHasSnappy is true on WASM":
      check configyHasSnappy == true

    test "configyFsWritable is false on WASM (localStorage v1 writes not implemented)":
      check configyFsWritable == false

    test "isWritable() returns false on WASM":
      check isWritable() == false

suite "capability consts — Dreamcast (-d:dreamcast) [PENDING: will fail until arm lands]":
  when defined(dreamcast):

    test "configyHasRealFs is true on Dreamcast (VMU is a real block FS)":
      check configyHasRealFs == true

    test "configyUsesOsPath is false on Dreamcast (device-prefix paths via /vmu/a1/)":
      check configyUsesOsPath == false

    test "configyHasSnappy is true on Dreamcast":
      check configyHasSnappy == true

    test "configyFsWritable is false on Dreamcast initially (flipped after Flycast verification)":
      # This test pins the Layer 1 value. It will need updating when the
      # configyFsWritable=true flip lands in task configy-6b6.
      check configyFsWritable == false

    test "isWritable() returns false on Dreamcast (no VMU runtime probe yet)":
      check isWritable() == false
