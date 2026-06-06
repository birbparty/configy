## Minimal libctru FFI for the 3DS verification gate exerciser.
##
## Only the handful of symbols needed to bring up a console, pump the apt main
## loop, and read button input so the smoke test is observable on-screen and can
## be exited cleanly (which flushes the sdmc: SD card to the host). NOT a general
## libctru binding — scoped to verify/ds3/ds3_smoke.nim.
##
## Requires the devkitARM include path (-I/opt/devkitpro/libctru/include), which
## the @if ds3: block in nim.cfg supplies.

{.passC: "-I/opt/devkitpro/libctru/include".}

type
  GfxScreen* {.importc: "gfxScreen_t", header: "<3ds.h>".} = enum
    GFX_TOP = 0
    GFX_BOTTOM = 1
  PrintConsole* {.importc: "PrintConsole", header: "<3ds.h>".} = object

const
  KEY_START* = 1'u32 shl 3   ## 3DS START button mask (from <3ds.h> KEY_START).

proc gfxInitDefault*() {.importc, header: "<3ds.h>".}
proc gfxExit*() {.importc, header: "<3ds.h>".}
proc gfxFlushBuffers*() {.importc, header: "<3ds.h>".}
proc gfxSwapBuffers*() {.importc, header: "<3ds.h>".}
proc gspWaitForVBlank*() {.importc, header: "<3ds.h>".}

proc consoleInit*(screen: GfxScreen, console: ptr PrintConsole): ptr PrintConsole
  {.importc, header: "<3ds.h>", discardable.}

proc hidScanInput*() {.importc, header: "<3ds.h>".}
proc hidKeysDown*(): uint32 {.importc, header: "<3ds.h>".}

proc aptMainLoop*(): bool {.importc, header: "<3ds.h>".}
