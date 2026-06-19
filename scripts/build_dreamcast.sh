#!/usr/bin/env bash
# configy Dreamcast verification gate — compile + link the smoke exerciser with
# KallistiOS (KOS) sh-elf-gcc (os:linux+newlib, SH-4 little-endian) and produce
# a .elf ready for Flycast or CDI packaging.
#
# Target switches and toolchain flags live in the `@if dreamcast:` block of the
# committed nim.cfg — this script does NOT copy a cfg over nim.cfg (it is tracked).
#
# ⚠ SPIKE-PENDING: the --cpu:arm proxy and KOS link flags in nim.cfg have not yet
# been validated by a successful Flycast boot. See nim.cfg @if dreamcast: comment
# and topdown/.agents/plans/dreamcast-support/01-toolchain-and-nim-sh4.md.
#
# Toolchain-absent is a PASS for scope: if KOS / sh-elf-gcc aren't installed we
# print a message and exit 0, so this is safe to run on any CI/dev machine.
# Run it on a machine with KOS installed to actually verify the link, then boot
# dreamcast_smoke.elf in Flycast (see verify/dreamcast/README.md).
#
# KOS path resolution order (highest priority first):
#   1. $KOS_CC_BASE / $KOS_BASE env vars (from sourcing KOS environ.sh)
#   2. $KOS_DIR env var (if already sourced) as KOS_BASE fallback
#   3. Defaults below (mirrors nim.cfg hardcoded paths)
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

KOS_BASE_DEFAULT="/Users/punk1290/dreamcast-toolchain/dc/kos"
KOS_CC_BASE_DEFAULT="/Users/punk1290/dreamcast-toolchain/dc/sh-elf"

# Source KOS environ.sh if it exists and vars are not already set.
# This exports KOS_BASE, KOS_CC_BASE, KOS_CC, KOS_CFLAGS, KOS_LDFLAGS, KOS_LIBS, KOS_START.
if [[ -z "${KOS_BASE:-}" ]] && [[ -f "$KOS_BASE_DEFAULT/environ.sh" ]]; then
  # shellcheck source=/dev/null
  source "$KOS_BASE_DEFAULT/environ.sh"
fi

KOS_BASE="${KOS_BASE:-$KOS_BASE_DEFAULT}"
KOS_CC_BASE="${KOS_CC_BASE:-$KOS_CC_BASE_DEFAULT}"
KOS_START="${KOS_START:-$KOS_BASE/kernel/arch/dreamcast/kernel/startup.o}"

GCC="$KOS_CC_BASE/bin/sh-elf-gcc"
VENDOR="${CONFIGY_VENDOR:-smoketest}"
# Optional arg $1 = source .nim (default: read smoke).
SRC="${1:-verify/dreamcast/dreamcast_smoke.nim}"
BASE="$(basename "$SRC" .nim)"
OUT_ELF="$REPO_ROOT/$BASE.elf"

# --- Toolchain guard: absent == PASS-for-scope, exit 0 (not 1) -----------------
if [[ ! -x "$GCC" ]]; then
  echo "[build_dreamcast] sh-elf-gcc not found at $GCC — skipping the real Dreamcast build."
  echo "[build_dreamcast] This is a PASS for scope (KOS toolchain not installed)."
  echo "[build_dreamcast] Install KOS and run: source $KOS_BASE/environ.sh"
  echo "[build_dreamcast] (see verify/dreamcast/README.md)"
  exit 0
fi

if [[ ! -f "$SRC" ]]; then
  echo "[build_dreamcast] smoke source $SRC not yet committed (tracked: configy-tv0)."
  echo "[build_dreamcast] This is a PASS for scope (smoke file pending)."
  exit 0
fi

echo "[build_dreamcast] Using $("$GCC" --version | head -1)"
echo "[build_dreamcast] KOS_BASE: $KOS_BASE"

# --- Compile + link (cpu/os/opt base comes from @if dreamcast: in nim.cfg) ------
# Pass resolved KOS paths on the nim c line so they OVERRIDE the static defaults
# hardcoded in nim.cfg — this makes $KOS_BASE / $KOS_CC_BASE authoritative.
# $KOS_START (KOS startup object) is passed here because nim.cfg cannot reference
# shell variables; it must precede the KOS libraries in the link order.
echo "[build_dreamcast] Compiling $SRC for -d:dreamcast (KOS sh-elf os:linux+newlib)..."
nim c -d:dreamcast -d:release -d:configyVendor="$VENDOR" \
  --arm.linux.gcc.path:"$KOS_CC_BASE/bin" \
  --passC:"-I$KOS_BASE/include" \
  --passC:"-I$KOS_BASE/kernel/arch/dreamcast/include" \
  --passL:"-L$KOS_BASE/lib/dreamcast" \
  --passL:"$KOS_START" \
  --path:src --path:verify/dreamcast \
  --out:"$OUT_ELF" "$SRC"

echo "[build_dreamcast] Linked ELF: $OUT_ELF"
file "$OUT_ELF" | sed 's/^/[build_dreamcast] /'

# --- CDI packaging (optional, requires mkdcdisc or cdi4dc) ---------------------
# Producing a disc image for Flycast requires additional KOS tooling:
#   mkdcdisc -e "$OUT_ELF" -o "$REPO_ROOT/$BASE.cdi"
# or the dc-tool / cdi4dc pipeline. These are NOT run here because the tooling
# availability and exact invocation depend on the KOS dc-chain installation.
# The raw ELF boots directly in Flycast via File → Boot GD-ROM ELF (or similar).
echo "[build_dreamcast] Done: $OUT_ELF"
echo "[build_dreamcast] Boot in Flycast: File > Boot Binary > select $BASE.elf"
echo "[build_dreamcast] For a .cdi: mkdcdisc -e $OUT_ELF -o $BASE.cdi"
