# configy — Vita verification gate

Verifies that configy compiles, **links**, passes **`vita-elf-create`** (the real
`-Wl,-q` test), and runs its read path on a real Sony PS Vita toolchain (VitaSDK,
`--os:linux` + newlib) — closing the host-`nim check`-only gap described in
[`../../.agents/plans/vita-support/`](../../.agents/plans/vita-support/).

## What's here

- `vita_smoke.nim` — exerciser. Calls `configFileExists` / `readConfigJson`
  (configy's read path, compiled-in under `-d:vita`) against a `ux0:` location,
  and writes `ux0:data/configy_smoke_result.txt` for host-side assertion. Headless
  (no graphics); it runs, writes the marker, and exits. Includes a tiny raw
  `sceIo*` FFI used only as a belt-and-suspenders marker writer.

The build script is at [`../../scripts/build_vita.sh`](../../scripts/build_vita.sh).
Target switches + VitaSDK toolchain flags live in the `@if vita:` block of the
repo-root `nim.cfg` (not copied over it — `nim.cfg` is tracked).

## Why no `sceIo*` shim in configy itself

VitaSDK's newlib `libc.a` backs standard C file I/O (`open`/`read`/`stat`) with
`sceIo*` in its syscall layer, so configy's `std/os`-based read path reaches `ux0:`
**with no shim** (unlike the 3DS, there is no devoptab to register, and there is no
`libScePosix`). Verify yourself:

```sh
arm-vita-eabi-nm /usr/local/vitasdk/arm-vita-eabi/lib/libc.a | grep sceIo
```

## Prerequisites

```sh
# VitaSDK (installs the arm-vita-eabi toolchain + vita-* tools into /usr/local/vitasdk)
git clone https://github.com/vitasdk/vdpm && cd vdpm && ./bootstrap-vitasdk.sh
export VITASDK=/usr/local/vitasdk
export PATH=$VITASDK/bin:$PATH

# Emulator (macOS) for the runtime tier
brew install vita3k        # or download from https://vita3k.org
```

The build script installs nothing; without the toolchain it exits 0 with a message
(a PASS for scope), so it is safe on any machine/CI.

## Run

```sh
./scripts/build_vita.sh                 # compile + link + vita-elf-create + package vita_smoke.vpk
```

Then install `vita_smoke.vpk` in Vita3K (or hardware) and run it.

### Assert the result (host-side)

After the app runs, read the marker from Vita3K's `ux0` passthrough directory
(confirm the exact host path for your Vita3K version — it differs from Azahar's SD
path):

```sh
cat "<Vita3K ux0>/data/configy_smoke_result.txt"
```

- **Absent file (default):** expect `read_isNone=true` and `exists=false` — i.e.
  `readConfigJson` returned `none()` and did not raise.
- **Planted file:** before running, write a valid configy file (magic byte `0x00`
  + JSON) on the host at
  `<Vita3K ux0>/data/config/smoketest/smoke/probe.json`
  (the `smoketest` segment must equal the compiled-in `configyVendor`). Re-run;
  expect `exists=true` and `read_isNone=false` with `read_parsed=…`.

  ```sh
  UX0="<Vita3K ux0>/data/config/smoketest/smoke"
  mkdir -p "$UX0"
  printf '\x00{}' > "$UX0/probe.json"
  ```

## Scope & caveats

- **Read path only.** Under `-d:vita` `configyFsWritable` is false, so configy's
  write APIs short-circuit (`writeConfigJson` raises at runtime; `createDir` is
  compiled out). The marker uses a raw `sceIo*`/`writeFile`, not configy's API.
- **`-Wl,-q` / Vita3K caveat.** `-Wl,-q` (`--emit-relocs`) is mandatory and is
  tested by a successful `vita-elf-create`. **Vita3K loads at the link base and
  hides** relocation bugs that only manifest on hardware — a Vita3K runtime pass is
  weaker than the 3DS Azahar pass. Hardware is the only gold check.
- Do **not** add an `--os:standalone` variant — the real target is os:linux+newlib.
