#!/usr/bin/env bash
# configy Vita verification gate — compile + link the read-path exerciser with
# VitaSDK (os:linux + newlib), run vita-elf-create (the real -Wl,-q test), and
# package a .vpk.
#
# Target switches and toolchain flags live in the `@if vita:` block of the
# committed nim.cfg — this script does NOT copy a cfg over nim.cfg (it is tracked).
#
# Toolchain-absent is a PASS for scope: if VitaSDK isn't installed we print a
# message and exit 0, so this is safe to run on any CI/dev machine. Run it on a
# machine with VitaSDK to verify the link + vita-elf-create, then install the .vpk
# in Vita3K (or hardware) and check ux0:data/configy_smoke_result.txt (see
# ../.agents/plans/vita-support/verification-gate.md).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

export VITASDK="${VITASDK:-/usr/local/vitasdk}"
export PATH="$VITASDK/bin:$PATH"

GCC="$VITASDK/bin/arm-vita-eabi-gcc"
AR="$VITASDK/bin/arm-vita-eabi-ar"
VENDOR="${CONFIGY_VENDOR:-smoketest}"
TITLE_ID="${CONFIGY_VITA_TITLEID:-CFGY00001}"
SRC="verify/vita/vita_smoke.nim"
OUT_ELF="$REPO_ROOT/vita_smoke"
OUT_VELF="$REPO_ROOT/vita_smoke.velf"
OUT_EBOOT="$REPO_ROOT/eboot.bin"
OUT_SFO="$REPO_ROOT/param.sfo"
OUT_VPK="$REPO_ROOT/vita_smoke.vpk"

# --- Toolchain guard: absent == PASS-for-scope, exit 0 (not 1) -----------------
if [[ ! -x "$GCC" ]] || ! command -v vita-elf-create >/dev/null 2>&1 \
   || ! command -v vita-pack-vpk >/dev/null 2>&1; then
  echo "[build_vita] VitaSDK (arm-vita-eabi-gcc / vita-* tools) not found — skipping the real Vita build."
  echo "[build_vita] This is a PASS for scope (toolchain not installed)."
  echo "[build_vita] Install: git clone https://github.com/vitasdk/vdpm && cd vdpm && ./bootstrap-vitasdk.sh"
  echo "[build_vita] (see verify/vita/README.md)"
  exit 0
fi

echo "[build_vita] Using $("$GCC" --version | head -1)"

# --- librt stub: Nim injects -ldl AND -lrt for os:linux targets ----------------
# Vita ships a REAL libdl.a (so -ldl resolves natively) but has NO librt. configy
# pulls in -lrt via std/os→times. An empty librt.a stub satisfies the linker flag;
# created at repo root because nim.cfg's `--passL:"-L."` searches the link CWD.
cleanup() {
  rm -f "$REPO_ROOT/librt.a" "$OUT_VELF" "$OUT_EBOOT" "$OUT_SFO"
}
trap cleanup EXIT
"$AR" rcs "$REPO_ROOT/librt.a"

# --- Compile + link (cpu/os/opt/toolchain come from @if vita: in nim.cfg) -------
echo "[build_vita] Compiling $SRC for -d:vita (VitaSDK os:linux+newlib)..."
nim c -d:vita -d:release -d:configyVendor="$VENDOR" \
  --path:src --path:verify/vita \
  --out:"$OUT_ELF" "$SRC"

echo "[build_vita] Linked ELF: $OUT_ELF"
file "$OUT_ELF" | sed 's/^/[build_vita] /'

# --- .velf (the real -Wl,-q test) ---------------------------------------------
echo "[build_vita] vita-elf-create (consumes -Wl,-q relocations)..."
vita-elf-create "$OUT_ELF" "$OUT_VELF"

# --- Sign + metadata + package .vpk -------------------------------------------
echo "[build_vita] vita-make-fself..."
vita-make-fself "$OUT_VELF" "$OUT_EBOOT"
echo "[build_vita] vita-mksfoex (TITLE_ID=$TITLE_ID)..."
vita-mksfoex -s "TITLE_ID=$TITLE_ID" "configy vita smoke" "$OUT_SFO"
echo "[build_vita] vita-pack-vpk..."
vita-pack-vpk -s "$OUT_SFO" -b "$OUT_EBOOT" "$OUT_VPK"

echo "[build_vita] Done: $OUT_VPK"
echo "[build_vita] Install in Vita3K (or hardware), run it, then read back:"
echo "[build_vita]   <Vita3K ux0>/data/configy_smoke_result.txt"
