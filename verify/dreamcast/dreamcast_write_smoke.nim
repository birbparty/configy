## configy Dreamcast WRITE-path verification gate.
##
## Built with -d:dreamcast via scripts/build_dreamcast_write.sh. Exercises the
## write surface that becomes active when configyFsWritable=true for dreamcast
## (tracked in configy-6b6, flipped after Flycast round-trip verified):
##   ensureConfigDir (VMU no-op), writeConfigJson (raw + Snappy-compressed),
##   writeConfigBytes, read-back round-trips, deleteConfig.
##
## Outputs results to stdout (KOS serial → Flycast serial terminal).
## Headless: main() runs, echoes the marker, returns; KOS exits cleanly.
##
## NB: failed checks raise a CatchableError (via `check`), NEVER doAssert —
## AssertionDefect is a Defect, not a CatchableError, so the `step` template
## would not catch it and all steps after it would be unreported.
##
## When configyFsWritable=false (current default for dreamcast), write steps
## report FAIL:writeConfigJson: target is read-only. This is expected until
## configy-6b6 flips the flag and configy-4xb verifies this smoke on Flycast.
##
## Compiled ONLY with -d:dreamcast; configy/vmu for hardware-state diagnostics.

import std/[json, options, strutils]
import configy
import configy/vmu  # isPresent(), freeBlocks() — dreamcast-only

const
  App = "dcwsmk"
  File = "rt.json"

proc run(): string =
  var L: seq[string]
  var anyFail = false
  template step(name: string, body: untyped) =
    try:
      body
      L.add name & "=PASS"
    except CatchableError as e:
      L.add name & "=FAIL:" & e.msg
      anyFail = true
  proc check(cond: bool, msg: string) =
    if not cond: raise newException(ValueError, msg)

  L.add "vmu_present=" & $isPresent()
  L.add "vmu_free_blocks=" & $freeBlocks()
  L.add "configyFsWritable=" & $isWritable()

  # 1. ensureConfigDir — no-op on VMU (flat FS, no dirs); should never raise.
  step "ensure_create": discard ensureConfigDir(App)
  step "ensure_again":  discard ensureConfigDir(App)

  # 2. writeConfigJson (uncompressed, MagicRaw 0x00) round-trip.
  step "write_json": writeConfigJson(App, File, %*{"k": "dc", "n": 7})
  step "read_json":
    let got = readConfigJson(App, File)
    check(got.isSome and got.get == %*{"k": "dc", "n": 7},
          "json mismatch: " & $got)

  # 3. Snappy-compressed (MagicSnappy 0x01) round-trip.
  #    The compressed payload is wrapped inside the VMS data field, so the
  #    block count grows. Verifies Snappy framing survives VMS wrap/unwrap.
  step "write_json_z":
    writeConfigJson(App, "z.json", %*{"big": "x".repeat(512)}, compress = true)
  step "read_json_z":
    let got = readConfigJson(App, "z.json")
    check(got.isSome and got.get["big"].getStr.len == 512,
          "z mismatch: " & $got)

  # 4. raw bytes round-trip.
  step "write_bytes": writeConfigBytes(App, "b.bin", "raw-bytes")
  step "read_bytes":
    let got = readConfigBytes(App, "b.bin")
    check(got.isSome and got.get == "raw-bytes", "bytes mismatch: " & $got)

  # 5. deleteConfig: true if removed, false if absent.
  step "delete":
    check(deleteConfig(App, File), "delete returned false")
  step "deleted_gone":
    check(not configFileExists(App, File), "still present after delete")

  # Clean up all test files so stale state can't mask a broken write on re-run.
  # rt.json is deleted by the `delete` step; clean it here too for the failure path
  # (e.g. write_json passed but delete failed — rt.json would otherwise persist).
  step "cleanup":
    discard deleteConfig(App, File)
    discard deleteConfig(App, "z.json")
    discard deleteConfig(App, "b.bin")

  L.add "isWritable=" & $isWritable()
  L.add "RESULT=" & (if anyFail: "FAIL" else: "PASS")
  result = L.join("\n") & "\n"

proc main() =
  let report = run()
  echo "== configy Dreamcast write-path gate =="
  echo report

main()
