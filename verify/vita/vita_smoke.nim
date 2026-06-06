## configy Vita read-path verification gate.
##
## Built with -d:vita via scripts/build_vita.sh and packaged as a .vpk for Vita3K
## (or real hardware). Exercises the read path that is compiled-in and reachable
## under -d:vita — configFileExists / readConfigJson — against a ux0: location,
## then writes a machine-readable result to ux0:data/configy_smoke_result.txt so a
## host can assert PASS/FAIL by reading it back from Vita3K's ux0 passthrough dir.
##
## Headless: no graphics init. main() runs the checks, writes the marker, returns;
## newlib's _exit maps to sceKernelExitProcess so the module exits cleanly.

import std/strutils
import configy

const
  App = "smoke"
  FileName = "probe.json"
  MarkerPath = "ux0:data/configy_smoke_result.txt"

# Minimal raw sceIo FFI. newlib already backs std/os writeFile via sceIo (so a
# plain writeFile reaches ux0:), but the marker is the ONE observable output the
# host asserts on, so we also write it via raw sceIo as belt-and-suspenders —
# guaranteeing it lands regardless of the std/os path. Mirrors the reference's
# raylib-nim-multiplatform/src/debug_vita.nim.
type SceUID = cint
proc sceIoOpen(file: cstring, flags: cint, mode: cint): SceUID
  {.importc, header: "psp2/io/fcntl.h".}
proc sceIoWrite(fd: SceUID, data: pointer, size: csize_t): cint
  {.importc, header: "psp2/io/fcntl.h".}
proc sceIoClose(fd: SceUID): cint {.importc, header: "psp2/io/fcntl.h".}

const
  # Values from VitaSDK psp2common/kernel/iofilemgr.h (enum SceIoMode).
  # NOTE: 0x0001 is SCE_O_RDONLY — WRONLY is 0x0002.
  SCE_O_WRONLY = 0x0002
  SCE_O_CREAT  = 0x0200
  SCE_O_TRUNC  = 0x0400

proc writeMarkerSce(path, s: string) =
  let fd = sceIoOpen(path.cstring,
                     cint(SCE_O_WRONLY or SCE_O_CREAT or SCE_O_TRUNC), 0o666)
  if fd >= 0:
    if s.len > 0:
      discard sceIoWrite(fd, unsafeAddr s[0], csize_t(s.len))
    discard sceIoClose(fd)

proc runChecks(): string =
  var lines: seq[string]
  lines.add "configy vita smoke result"
  lines.add "resolved_path=" & configFile(App, FileName)

  # 1. configFileExists — wraps fileExists; must not raise on vita.
  try:
    lines.add "exists_ok=true"
    lines.add "exists=" & $configFileExists(App, FileName)
  except CatchableError as e:
    lines.add "exists_ok=false"
    lines.add "exists_error=" & e.msg

  # 2. readConfigJson — none() for an absent file (must NOT raise);
  #    some(parsed) for a planted valid configy file.
  try:
    let got = readConfigJson(App, FileName)
    lines.add "read_ok=true"
    lines.add "read_isNone=" & $got.isNone
    if got.isSome:
      lines.add "read_parsed=" & $got.get
  except CatchableError as e:
    lines.add "read_ok=false"
    lines.add "read_error=" & e.msg

  result = lines.join("\n") & "\n"

proc main() =
  let report = runChecks()
  # Primary: std/os writeFile (newlib -> sceIo). Fallback: raw sceIo (always lands).
  try:
    writeFile(MarkerPath, report)
  except CatchableError:
    discard
  writeMarkerSce(MarkerPath, report)

main()
