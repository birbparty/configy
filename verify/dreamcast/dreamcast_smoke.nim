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
  var anyFail = false
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
    anyFail = true

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
    anyFail = true

  lines.add "RESULT=" & (if anyFail: "FAIL" else: "PASS")
  result = lines.join("\n") & "\n"

proc thd_sleep(ms: cint) {.importc: "thd_sleep", header: "<kos/thread.h>".}
  ## KOS cooperative sleep — yields the CPU for `ms` milliseconds.

proc main() =
  # Run the checks exactly once; capture the report.
  let report = runChecks()
  # Broadcast the report on a loop. A one-shot echo + exit is uncatchable under
  # Flycast: KOS runs main() to completion in milliseconds (before any host
  # reader can attach to the SCIF pty) and exits. Continuously re-emitting the
  # cached report — the same pattern inputty's example uses — lets a host-side
  # reader attach at any time and capture a complete RESULT line. newlib stdout
  # is block-buffered (SCIF is not a TTY), so flush after every batch.
  for _ in 0 ..< 40:  # ~20s capture window at 500ms cadence, then exit cleanly
    echo "== configy Dreamcast read-path gate =="
    echo report
    flushFile(stdout)
    thd_sleep(500)

main()
