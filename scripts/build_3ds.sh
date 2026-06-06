#!/usr/bin/env bash
# configy 3DS verification gate (Finding 1) — compile + link the read-path
# exerciser with devkitARM (os:linux + newlib + libctru) and package a .3dsx.
#
# Target switches and toolchain flags live in the `@if ds3:` block of the
# committed nim.cfg — this script does NOT copy a cfg over nim.cfg (it is tracked).
#
# Toolchain-absent is a PASS for scope: if devkitARM/3dsxtool aren't installed we
# print a message and exit 0, so this is safe to run on any CI/dev machine.
# Run it on a machine with devkitPro to actually verify the link, then open the
# .3dsx in Azahar and check sdmc:/configy_smoke_result.txt (see verification-gate.md).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
export DEVKITARM="${DEVKITARM:-$DEVKITPRO/devkitARM}"
export PATH="$DEVKITPRO/tools/bin:$DEVKITARM/bin:$PATH"

GCC="$DEVKITARM/bin/arm-none-eabi-gcc"
AR="$DEVKITARM/bin/arm-none-eabi-ar"
VENDOR="${CONFIGY_VENDOR:-smoketest}"
SRC="verify/ds3/ds3_smoke.nim"
OUT_ELF="$REPO_ROOT/ds3_smoke"
OUT_3DSX="$REPO_ROOT/ds3_smoke.3dsx"

# --- Toolchain guard: absent == PASS-for-scope, exit 0 (not 1) -----------------
if [[ ! -x "$GCC" ]] || ! command -v 3dsxtool >/dev/null 2>&1; then
  echo "[build_3ds] devkitARM / 3dsxtool not found — skipping the real 3DS build."
  echo "[build_3ds] This is a PASS for scope (toolchain not installed)."
  echo "[build_3ds] Install with: dkp-pacman -S 3ds-dev   (see verify/ds3/README.md)"
  exit 0
fi

echo "[build_3ds] Using $("$GCC" --version | head -1)"

# --- libdl/librt stubs: Nim injects -ldl AND -lrt for os:linux targets ---------
# The 3DS (devkitARM newlib) has neither. configy pulls in -lrt via std/os→times.
# Empty stub archives satisfy the linker flags; created at repo root because
# nim.cfg's `--passL:"-L."` searches the link CWD.
cleanup() { rm -f "$REPO_ROOT/libdl.a" "$REPO_ROOT/librt.a"; }
trap cleanup EXIT
"$AR" rcs "$REPO_ROOT/libdl.a"
"$AR" rcs "$REPO_ROOT/librt.a"

# --- Compile + link (cpu/os/opt/toolchain come from @if ds3: in nim.cfg) -------
echo "[build_3ds] Compiling $SRC for -d:ds3 (devkitARM os:linux+newlib)..."
nim c -d:ds3 -d:release -d:configyVendor="$VENDOR" \
  --path:src --path:verify/ds3 \
  --out:"$OUT_ELF" "$SRC"

echo "[build_3ds] Linked ELF: $OUT_ELF"
file "$OUT_ELF" | sed 's/^/[build_3ds] /'

# --- Package .3dsx (required for Azahar) ---------------------------------------
echo "[build_3ds] Packaging .3dsx..."
3dsxtool "$OUT_ELF" "$OUT_3DSX"
echo "[build_3ds] Done: $OUT_3DSX"
echo "[build_3ds] Run it:  open -a Azahar \"$OUT_3DSX\""
echo "[build_3ds] Then read back: <Azahar sdmc>/configy_smoke_result.txt"
