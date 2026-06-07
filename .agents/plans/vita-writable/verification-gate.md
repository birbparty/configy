# Vita Write Gate — Design

Companion to [`plan.md`](./plan.md). Concrete design for verifying configy's **write
path** on a real Sony PS Vita once `configyFsWritable` is flipped to `true` for
`-d:vita`. Mirrors the read gate ([`../vita-support/verification-gate.md`](../vita-support/verification-gate.md)),
which is already ✅ verified on hardware — so this reuses the same toolchain, build
script shape, marker-on-`ux0:` mechanism, and Vita3K/hardware tiers, and focuses only
on the write surface.

---

## What must be proven (the write surface)

Flipping the flag activates four things that are currently gated off on Vita. Each
must be exercised end-to-end:

1. **`ensureConfigDir(app[, dep])`** — now compiles in `createDir`. Must create the
   nested tree under `ux0:data/config/<vendor>/<app>/[<dep>/]` and **not raise when
   it already exists** (the second call). ← this is [the crux](./plan.md#the-crux-stdoscreatedir-over-a-ux0-prefixed-path).
2. **`writeConfigJson`** (uncompressed) — write → read back → deep-equal.
3. **`writeConfigJson(compress = true)`** — exercises `supersnappy.compress` + the
   `MagicSnappy` (`0x01`) read branch on-device (the read gate only ever exercised
   `MagicRaw` `0x00`). Write → read back → deep-equal.
4. **`writeConfigBytes`** raw round-trip, and **`deleteConfig`** → `configFileExists`
   returns `false` afterward.

All write APIs auto-create their directory (`ensureConfigFile` → `ensureConfigDir`),
so step 1 is implicitly hit by 2–4 as well; step 1 also tests it explicitly + the
already-exists path.

---

## Artifacts to add (Phase 0 — no toolchain needed)

### 1. `verify/vita/vita_write_smoke.nim`

A second exerciser alongside `vita_smoke.nim` (leave the read smoke untouched — it is
the verified read gate). Headless, same marker mechanism, but it must be built with
the **writable** flip in place (it is the change under test). Pin the same
`configyVendor=smoketest`. Sketch:

```nim
import std/[json, options, strutils]
import configy

const
  App = "wsmoke"
  File = "rt.json"
  Marker = "ux0:data/configy_write_smoke_result.txt"

proc run(): string =
  var L: seq[string]
  # IMPORTANT: signal a failed check with `raise newException(...)` (a CatchableError),
  # NOT `doAssert`. doAssert raises AssertionDefect, which is a Defect — NOT a
  # CatchableError — so the `step` template's `except CatchableError` would NOT catch
  # it; it would unwind past `run()`, the marker would never be written, and the host
  # could not tell "a step failed" from "the app never ran". (verify/vita/vita_smoke.nim
  # avoids doAssert for exactly this reason; doAssert is also live here since the build
  # is -d:release, not -d:danger.)
  template step(name: string, body: untyped) =
    try: body; L.add name & "=PASS"
    except CatchableError as e: L.add name & "=FAIL:" & e.msg
  proc check(cond: bool, msg: string) =
    if not cond: raise newException(ValueError, msg)

  # 1. ensureConfigDir creates the tree. Both calls hit the already-exists (EEXIST)
  #    path on existing prefixes (ux0:data/, …/config/); ensure_again guarantees the
  #    LEAF is also exercised on the exists path. This is the crux (std/os.createDir
  #    over a ux0:-prefixed path).
  step "ensure_create": discard ensureConfigDir(App)
  step "ensure_again":  discard ensureConfigDir(App)

  # 2. writeConfigJson (uncompressed, MagicRaw 0x00) round-trip.
  step "write_json": writeConfigJson(App, File, %*{"k": "vita", "n": 7})
  step "read_json":
    let got = readConfigJson(App, File)
    check(got.isSome and got.get == %*{"k": "vita", "n": 7}, "json mismatch: " & $got)

  # 3. compressed (MagicSnappy 0x01) round-trip — the read gate only ever saw MagicRaw.
  step "write_json_z": writeConfigJson(App, "z.json", %*{"big": "x".repeat(512)}, compress = true)
  step "read_json_z":
    let got = readConfigJson(App, "z.json")
    check(got.isSome and got.get["big"].getStr.len == 512, "z mismatch: " & $got)

  # 4. raw bytes round-trip; delete returns true; file gone afterward.
  #    NB: deleteConfig returns bool (true=removed) and is NOT {.discardable.} —
  #    a bare call would not compile; check/assign its result.
  step "write_bytes": writeConfigBytes(App, "b.bin", "raw-bytes")
  step "read_bytes":
    let got = readConfigBytes(App, "b.bin")
    check(got.isSome and got.get == "raw-bytes", "bytes mismatch: " & $got)
  step "delete":       check(deleteConfig(App, File), "delete returned false")
  step "deleted_gone": check(not configFileExists(App, File), "still present after delete")

  # Clean up the remaining test files so a stale z.json/b.bin from a prior run can't
  # mask a future write failure (a re-run's read-back would pass on old data). Leaves
  # the marker for host read-back.
  step "cleanup":
    discard deleteConfig(App, "z.json")
    discard deleteConfig(App, "b.bin")

  L.add "isWritable=" & $isWritable()
  result = L.join("\n") & "\n"

# Marker write: reuse the writeFile + raw-sceIo belt-and-suspenders from vita_smoke.nim
# (factor it into a tiny shared helper, or duplicate the ~15 lines). The marker MUST be
# written for every outcome — that is why no step is allowed to raise a Defect.
when isMainModule:
  let report = run()
  # ... writeFile(Marker, report); sceIo fallback ...
```

> Note: the marker is written via the same `writeFile`/`sceIo*` helper as the read
> smoke (proven to reach `ux0:`); it does **not** go through configy's write API, so a
> bug in the API under test can't suppress its own failure report.

### 2. Build script

Either extend `scripts/build_vita.sh` to take the source + TITLE_ID as args, or add
`scripts/build_vita_write.sh` mirroring it with `SRC=verify/vita/vita_write_smoke.nim`
and `TITLE_ID=CFGW00001`. Same guard (exit 0 when VitaSDK absent), same librt stub,
same `vita-elf-create → make-fself → mksfoex → pack-vpk` pipeline, same
`$VITASDK`-authoritative `nim c` flags. `createDir`→`mkdir`→`sceIoMkdir` was already
referenced by the read smoke (its marker FFI calls `sceIoMkdir` directly), but
`deleteConfig`→`removeFile`→`_unlink_r`→`sceIoRemove` is **newly** referenced by this
build. Both resolve from `SceIofilemgr_stub`, which is already on the link line, so no
new `-l` flag is expected — confirm zero unresolved at link.

---

## Phase 2 — Run it (Vita3K + real hardware)

Identical mechanics to the read gate (see `../vita-support/verification-gate.md` and
`RESULTS.md`): install the `.vpk`, boot it (`Vita3K -r CFGW00001`; retry if it drops
to the GUI), read the marker back from the host `ux0` dir (Vita3K) or the card
(hardware).

**Expected marker (all PASS):**
```
ensure_create=PASS
ensure_again=PASS          <-- the crux: createDir tolerant of already-exists on ux0:
write_json=PASS
read_json=PASS
write_json_z=PASS
read_json_z=PASS
write_bytes=PASS
read_bytes=PASS
delete=PASS
deleted_gone=PASS
cleanup=PASS
isWritable=true
```

**If `ensure_*` FAIL** with an mkdir/OS error → the crux resolved negatively
(`std/os.createDir` can't tolerate the already-exists `ux0:data` component, or can't
create nested dirs). Switch to the contingency: a `-d:vita` `sceIoMkdir`-based
`ensureConfigDir` in `fs.nim` that ignores the Sce "already exists" code, then
re-run. Record the verdict either way.

**Hardware is the gold check.** `-Wl,-q` relocation correctness is already retired by
the read gate (same toolchain/flags), so the *new* risk here is purely the FS
operations — but those (especially `createDir`) still warrant a real-card run, since
Vita3K's host-passthrough FS may be more forgiving than the Vita's exFAT/`sceIo`
stack on edge cases (already-exists, nested creation, delete).

---

## Acceptance criteria

- [ ] `configyFsWritable` is `true` for `-d:vita`; `ds3`/`psp` unchanged (`false`).
- [ ] `verify/vita/vita_write_smoke.nim` + its build target exist; the read smoke is
      untouched.
- [ ] Builds: links to ARM ELF, `vita-elf-create` passes, `.vpk` produced, no new
      unresolved symbols.
- [ ] Vita3K marker: all steps PASS, `isWritable=true`.
- [ ] **Real-hardware marker: all steps PASS** (the gold check), incl. the
      already-exists `ensure_again` and the compressed round-trip.
- [ ] The crux is recorded in RESULTS: `std/os.createDir` sufficed, or the
      `sceIoMkdir` shim was implemented + verified.
- [ ] `nim check -d:vita`, desktop `nimble test`, and all `--compileOnly` platform
      rows still green; read-path contract unchanged.
- [ ] `configy.nimble` bumped to `0.3.0`; behavior change documented.

---

## Explicitly NOT part of this gate

- **No ds3/psp write enablement** — Vita only.
- **No directory-removal semantics** in `deleteConfig` (file removal only).
- **No new read-path work** — that gate is done; this only adds the write surface.
- **No comment-only "done"** — the hardware round-trip is mandatory.

---

## Reference file map

| artifact | source to mirror |
|----------|------------------|
| `verify/vita/vita_write_smoke.nim` | `verify/vita/vita_smoke.nim` (marker helper, structure) |
| `scripts/build_vita_write.sh` (or arg-ize `build_vita.sh`) | `scripts/build_vita.sh` |
| run / read-back procedure | `../vita-support/RESULTS.md` ("Vita3K runtime" + "Real-hardware run") |
| the flag + gating | `capabilities.nim`, `fs.nim`, `store.nim` (see plan.md "Current state") |
