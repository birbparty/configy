## configy 3DS WRITE-path verification gate.
##
## Built with -d:ds3 (configyFsWritable=true) via scripts/build_3ds_write.sh and
## packaged as a .3dsx. Exercises the write surface that becomes active once 3DS is
## writable — ensureConfigDir/createDir, writeConfigJson (raw + compressed),
## writeConfigBytes, deleteConfig — round-tripping each against sdmc:, then writes a
## machine-readable result to sdmc:/configy_write_smoke_result.txt for host-side
## PASS/FAIL assertion (and shows it on the top screen). Press START to exit.
##
## Built with STOCK std/os.createDir: ensureConfigDir's createDir mkdir's/stats the
## bare sdmc:/ device root first (the crux). The hardware run decides whether libctru's
## sdmc devoptab tolerates that or a -d:ds3 createDirTree shim is needed.
##
## NB: failed checks raise a CatchableError (via `check`), NEVER doAssert —
## AssertionDefect is a Defect, not a CatchableError, so the `step` template would not
## catch it and the marker would never be written (indistinguishable from "never ran").

import std/[json, options, strutils]
import configy
import ctru

const
  App = "wsmoke"
  MarkerPath = "sdmc:/configy_write_smoke_result.txt"

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

  # 1. ensureConfigDir creates the tree; both calls hit the already-exists path on
  #    existing prefixes — and stock createDir mkdir's/stats the bare sdmc:/ root first
  #    (the crux this hardware run settles).
  step "ensure_create": discard ensureConfigDir(App)
  step "ensure_again":  discard ensureConfigDir(App)

  # 2. writeConfigJson (uncompressed, MagicRaw 0x00) round-trip.
  step "write_json": writeConfigJson(App, "rt.json", %*{"k": "3ds", "n": 7})
  step "read_json":
    let got = readConfigJson(App, "rt.json")
    check(got.isSome and got.get == %*{"k": "3ds", "n": 7}, "json mismatch: " & $got)

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
  step "delete":       check(deleteConfig(App, "rt.json"), "delete returned false")
  step "deleted_gone": check(not configFileExists(App, "rt.json"), "still present after delete")

  # Clean up remaining test files so a stale z.json/b.bin can't mask a re-run failure.
  step "cleanup":
    discard deleteConfig(App, "z.json")
    discard deleteConfig(App, "b.bin")

  L.add "isWritable=" & $isWritable()
  result = L.join("\n") & "\n"

proc main() =
  gfxInitDefault()
  consoleInit(GFX_TOP, nil)

  let report = run()
  echo "== configy 3DS write-path gate =="
  echo report
  # Marker via raw writeFile (proven on sdmc:; independent of the API under test).
  var wroteMarker = false
  try:
    writeFile(MarkerPath, report)
    wroteMarker = true
  except CatchableError as e:
    echo "marker write failed: " & e.msg
  echo "marker_written=" & $wroteMarker & " (" & MarkerPath & ")"
  echo "\nPress START to exit."

  while aptMainLoop():
    hidScanInput()
    if (hidKeysDown() and KEY_START) != 0:
      break
    gfxFlushBuffers()
    gfxSwapBuffers()
    gspWaitForVBlank()

  gfxExit()

main()
