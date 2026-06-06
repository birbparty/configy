# configy — 3DS verification gate

Verifies that configy compiles, **links**, and runs its read path on a real
Nintendo 3DS toolchain (devkitARM, `--os:linux` + newlib, libctru) — closing the
host-`nim check`-only gap described in
[`../../.agents/plans/3ds-support/`](../../.agents/plans/3ds-support/).

## What's here

- `ds3_smoke.nim` — exerciser. Calls `configFileExists` / `readConfigJson`
  (configy's read path, compiled-in under `-d:ds3`) against an `sdmc:/` location,
  prints results on-screen, and writes `sdmc:/configy_smoke_result.txt` for
  host-side assertion. Press **START** to exit.
- `ctru.nim` — minimal libctru FFI (console + apt loop + input) used only by the
  exerciser.

The build script is at [`../../scripts/build_3ds.sh`](../../scripts/build_3ds.sh).
Target switches + devkitARM toolchain flags live in the `@if ds3:` block of the
repo-root `nim.cfg` (not copied over it — `nim.cfg` is tracked).

## Prerequisites

```sh
dkp-pacman -S 3ds-dev        # devkitARM + libctru + 3dsxtool, into /opt/devkitpro
export DEVKITPRO=/opt/devkitpro
export PATH=$PATH:$DEVKITPRO/tools/bin:$DEVKITPRO/devkitARM/bin
```

[Azahar](https://azahar-emu.org/) (or real hardware) is needed for the runtime
check. The build script installs nothing; without the toolchain it exits 0 with a
message (a PASS for scope), so it is safe on any machine/CI.

## Run

```sh
./scripts/build_3ds.sh                 # compile + link + package ds3_smoke.3dsx
open -a Azahar ./ds3_smoke.3dsx        # runtime check
```

### Assert the result (host-side)

Azahar's virtual SD card is a host directory (default macOS:
`~/Library/Application Support/Azahar/sdmc/`). After the run:

```sh
cat "$HOME/Library/Application Support/Azahar/sdmc/configy_smoke_result.txt"
```

- **Absent file (default):** expect `read_isNone=true` and `exists=false` — i.e.
  `readConfigJson` returned `none()` and did not raise.
- **Planted file:** before launching, write a valid configy file (magic byte
  `0x00` + JSON) on the host at
  `…/Azahar/sdmc/config/smoketest/smoke/probe.json`
  (the `smoketest` segment must equal the compiled-in `configyVendor`). Relaunch;
  expect `exists=true` and `read_isNone=false` with `read_parsed=…`.

  Minimal planted file (raw magic byte + `{}`):
  ```sh
  SD="$HOME/Library/Application Support/Azahar/sdmc/config/smoketest/smoke"
  mkdir -p "$SD"
  printf '\x00{}' > "$SD/probe.json"
  ```

## Scope

Read path only. Under `-d:ds3` `configyFsWritable` is false, so configy's write
APIs short-circuit; the marker file uses a raw `writeFile`, not configy's API.
Enabling/verifying configy *writes* on 3DS is Finding 2 (deferred). Do not add an
`--os:Standalone` variant — the real target is os:linux+newlib.
