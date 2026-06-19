## configy Dreamcast read-path verification gate.
##
## Built with -d:dreamcast via scripts/build_dreamcast.sh. Exercises the read
## surface that is compiled-in and reachable under -d:dreamcast —
## configFileExists / readConfigJson — against the VMU at slot a1, then writes
## a machine-readable result to stdout (KOS serial → Flycast serial terminal)
## for host-side PASS/FAIL assertion.
##
## Headless: no graphics init. main() runs the checks, echoes the marker, returns;
## KOS exits when main() returns.
##
## Compiled ONLY with -d:dreamcast; configy/vmu is imported directly for the
## isPresent() hardware-state probe which is independent of configyFsWritable.

import std/strutils
import configy
import configy/vmu  # isPresent(), freeBlocks() — dreamcast-only

const
  App = "dcsmk"
  FileName = "probe.json"

proc runChecks(): string =
  var lines: seq[string]
  lines.add "configy dreamcast smoke result"
  lines.add "vmu_present=" & $isPresent()
  lines.add "vmu_free_blocks=" & $freeBlocks()
  lines.add "configyFsWritable=" & $isWritable()
  lines.add "resolved_path=" & configFile(App, FileName)

  # 1. configFileExists — must not raise on absent VMU or absent file;
  #    existsVmuFile returns false on both (nil-safe).
  try:
    let exists = configFileExists(App, FileName)
    lines.add "exists_ok=true"
    lines.add "exists=" & $exists
  except CatchableError as e:
    lines.add "exists_ok=false"
    lines.add "exists_error=" & e.msg

  # 2. readConfigJson — none() when file absent (must NOT raise on absent VMU/file).
  #    If probe.json was planted on the VMU beforehand, isSome=true and read_parsed
  #    shows the content.
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
  echo "== configy Dreamcast read-path gate =="
  echo report
  # KOS: stdout → serial → Flycast serial terminal. No secondary write needed
  # (unlike Vita, serial is reliably captured by Flycast without extra FFI).

main()
