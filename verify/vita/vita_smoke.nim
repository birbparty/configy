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
proc sceIoMkdir(dir: cstring, mode: cint): cint
  {.importc, header: "psp2/io/stat.h".}

const
  # Values from VitaSDK psp2common/kernel/iofilemgr.h (enum SceIoMode).
  # NOTE: 0x0001 is SCE_O_RDONLY — WRONLY is 0x0002.
  SCE_O_WRONLY = 0x0002
  SCE_O_CREAT  = 0x0200
  SCE_O_TRUNC  = 0x0400

proc writeMarkerSce(path, s: string): bool =
  ## Returns true if the marker was opened and written. SCE_O_TRUNC means this
  ## fully overwrites whatever writeFile already wrote to `path` (same content —
  ## the two writers are primary + fallback to the SAME file, not two outputs).
  let fd = sceIoOpen(path.cstring,
                     cint(SCE_O_WRONLY or SCE_O_CREAT or SCE_O_TRUNC), 0o666)
  if fd < 0:
    return false
  if s.len > 0:
    if sceIoWrite(fd, unsafeAddr s[0], csize_t(s.len)) < 0:
      discard sceIoClose(fd)
      return false
  discard sceIoClose(fd)
  return true

proc runChecks(): string =
  var lines: seq[string]
  lines.add "configy vita smoke result"
  lines.add "resolved_path=" & configFile(App, FileName)

  # 1. configFileExists — wraps fileExists; must not raise on vita.
  #    Emit exists_ok=true only AFTER the call returns, so a raise can't leave
  #    both exists_ok=true and exists_ok=false in the marker.
  try:
    let exists = configFileExists(App, FileName)
    lines.add "exists_ok=true"
    lines.add "exists=" & $exists
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
  # ux0:data/ normally exists, but mkdir it best-effort so a missing dir doesn't
  # make both marker writers silently no-op. Ignore the result (e.g. already-exists).
  discard sceIoMkdir("ux0:data", 0o777)
  # Primary: std/os writeFile (newlib -> sceIo). Fallback: raw sceIo. Both target
  # the SAME path; the fallback's SCE_O_TRUNC overwrites with identical content.
  var wrote = false
  try:
    writeFile(MarkerPath, report)
    wrote = true
  except CatchableError:
    discard
  if writeMarkerSce(MarkerPath, report):
    wrote = true
  # Headless: no console to print to. If neither write succeeded the host simply
  # sees no marker (indistinguishable from "app never ran"); echo is a best-effort
  # breadcrumb for anyone running with a console/stdout capture attached.
  if not wrote:
    echo "configy vita smoke: FAILED to write marker " & MarkerPath

main()
