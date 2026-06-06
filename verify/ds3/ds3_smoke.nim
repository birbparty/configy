## configy 3DS read-path verification gate (Finding 1).
##
## Built with -d:ds3 via scripts/build_3ds.sh and run in Azahar (or on hardware).
## Exercises the read path that is compiled-in and reachable under -d:ds3 —
## configFileExists / readConfigJson — against an sdmc:/ location, then writes a
## machine-readable result to sdmc:/configy_smoke_result.txt so a host can assert
## PASS/FAIL by reading it back from Azahar's virtual SD card.
##
## Why only the read path: under -d:ds3 configyFsWritable is false, so configy's
## write APIs (writeConfigJson/ensureConfigDir/deleteConfig) short-circuit before
## any FS write. The marker file below is written with a RAW writeFile (newlib +
## libctru's sdmc devoptab), NOT configy's write API — it is test-harness I/O.
##
## Vendor: built with -d:configyVendor=smoketest, so configy resolves
##   configFile("smoke", "probe.json") -> sdmc:/config/smoketest/smoke/probe.json
## To exercise the present-file case, plant a valid configy file there on the host
## (see scripts/build_3ds.sh / verification-gate.md) before launching.

import std/strutils
import configy
import ctru

const
  App = "smoke"
  FileName = "probe.json"
  MarkerPath = "sdmc:/configy_smoke_result.txt"

proc runChecks(): string =
  var lines: seq[string]
  lines.add "configy ds3 smoke result"
  lines.add "resolved_path=" & configFile(App, FileName)

  # 1. configFileExists — wraps fileExists; must not raise on ds3.
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
  gfxInitDefault()
  consoleInit(GFX_TOP, nil)

  let report = runChecks()

  # On-screen (libctru redirects stdout to the console after consoleInit)...
  echo "== configy 3DS read-path gate =="
  echo report
  # ...and to a host-readable marker on the SD card.
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
