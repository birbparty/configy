## configy Vita WRITE-path verification gate.
##
## Built with -d:vita (configyFsWritable=true) via scripts/build_vita_write.sh and
## packaged as a .vpk. Exercises the write surface that becomes active once vita is
## writable — ensureConfigDir/createDir, writeConfigJson (raw + compressed),
## writeConfigBytes, deleteConfig — round-tripping each against ux0:, then writes a
## machine-readable result to ux0:data/configy_write_smoke_result.txt for host-side
## PASS/FAIL assertion. Headless; runs, writes the marker, exits.
##
## NB: failed checks raise a CatchableError (via `check`), NEVER doAssert —
## AssertionDefect is a Defect, not a CatchableError, so the `step` template would
## not catch it and the marker would never be written (indistinguishable from "never
## ran"). doAssert is also live here (-d:release, not -d:danger).

import std/[json, options, strutils]
import configy

const
  App = "wsmoke"
  File = "rt.json"
  MarkerPath = "ux0:data/configy_write_smoke_result.txt"

# Minimal raw sceIo FFI for the marker (mirrors vita_smoke.nim). The marker is
# written OUTSIDE configy's write API so a bug in the API under test cannot suppress
# its own failure report.
type SceUID = cint
proc sceIoOpen(file: cstring, flags: cint, mode: cint): SceUID
  {.importc, header: "psp2/io/fcntl.h".}
proc sceIoWrite(fd: SceUID, data: pointer, size: csize_t): cint
  {.importc, header: "psp2/io/fcntl.h".}
proc sceIoClose(fd: SceUID): cint {.importc, header: "psp2/io/fcntl.h".}
proc sceIoMkdir(dir: cstring, mode: cint): cint
  {.importc, header: "psp2/io/stat.h".}

const
  SCE_O_WRONLY = 0x0002
  SCE_O_CREAT  = 0x0200
  SCE_O_TRUNC  = 0x0400

proc writeMarkerSce(path, s: string): bool =
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

proc run(): string =
  var L: seq[string]
  template step(name: string, body: untyped) =
    try:
      body
      L.add name & "=PASS"
    except CatchableError as e:
      L.add name & "=FAIL:" & e.msg
  proc check(cond: bool, msg: string) =
    if not cond: raise newException(ValueError, msg)

  # 1. ensureConfigDir creates the tree; both calls hit the already-exists (EEXIST)
  #    path on existing prefixes — the crux (std/os.createDir over ux0:).
  step "ensure_create": discard ensureConfigDir(App)
  step "ensure_again":  discard ensureConfigDir(App)

  # 2. writeConfigJson (uncompressed, MagicRaw 0x00) round-trip.
  step "write_json": writeConfigJson(App, File, %*{"k": "vita", "n": 7})
  step "read_json":
    let got = readConfigJson(App, File)
    check(got.isSome and got.get == %*{"k": "vita", "n": 7}, "json mismatch: " & $got)

  # 3. compressed (MagicSnappy 0x01) round-trip.
  step "write_json_z":
    writeConfigJson(App, "z.json", %*{"big": "x".repeat(512)}, compress = true)
  step "read_json_z":
    let got = readConfigJson(App, "z.json")
    check(got.isSome and got.get["big"].getStr.len == 512, "z mismatch: " & $got)

  # 4. raw bytes round-trip; delete returns true; file gone afterward.
  step "write_bytes": writeConfigBytes(App, "b.bin", "raw-bytes")
  step "read_bytes":
    let got = readConfigBytes(App, "b.bin")
    check(got.isSome and got.get == "raw-bytes", "bytes mismatch: " & $got)
  step "delete":       check(deleteConfig(App, File), "delete returned false")
  step "deleted_gone": check(not configFileExists(App, File), "still present after delete")

  # Clean up remaining test files so a stale z.json/b.bin can't mask a re-run failure.
  step "cleanup":
    discard deleteConfig(App, "z.json")
    discard deleteConfig(App, "b.bin")

  L.add "isWritable=" & $isWritable()
  result = L.join("\n") & "\n"

proc main() =
  let report = run()
  discard sceIoMkdir("ux0:data", 0o777)  # best-effort; ignore already-exists
  try:
    writeFile(MarkerPath, report)
  except CatchableError:
    discard
  discard writeMarkerSce(MarkerPath, report)

main()
