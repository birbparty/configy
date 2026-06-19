#!/usr/bin/env bash
# configy Dreamcast CDI builder.
#
# Uses einsteinx2/dcdev-kos-toolchain:gcc-9 (GCC 9 + full KOS) — same image
# as inputty, proven to produce working Flycast ELFs.
#
# Pipeline:
#   1. nim --compileOnly on host → C files + nimbase.h in nimcache/
#   2. sh-elf-gcc in Docker → link ELF, strip .stack section → .elf
#   3. sh-elf-objcopy in Docker → raw binary → 1ST_READ.BIN
#   4. makeip in Docker → IP.BIN
#   5. mkisofs in Docker → bootable ISO
#   6. cdi4dc in Docker → CDI (opens in Flycast via File → Open)
#
# Usage:
#   ./scripts/build_dreamcast_cdi.sh [source.nim]
#   ./scripts/build_dreamcast_cdi.sh verify/dreamcast/dreamcast_write_smoke.nim
#
# Output: ./<basename>.elf  and  ./<basename>.cdi

set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
DOCKER_IMAGE="einsteinx2/dcdev-kos-toolchain:gcc-9"
DOCKER_REPO="$REPO_ROOT"   # mount at same absolute path (matches inputty's pattern)

SRC="${1:-verify/dreamcast/dreamcast_smoke.nim}"
BASE="$(basename "$SRC" .nim)"
NIMCACHE="$REPO_ROOT/nimcache_cdi_${BASE}"
OUT_ELF="$REPO_ROOT/${BASE}.elf"
OUT_CDI="$REPO_ROOT/${BASE}.cdi"

# Nim stdlib — only nimbase.h is needed in the nimcache (inputty pattern)
NIM_BIN="$(command -v nim 2>/dev/null || true)"
if [[ -z "$NIM_BIN" ]]; then echo "ERROR: nim not in PATH"; exit 1; fi
NIM_PREFIX="$(dirname "$(dirname "$NIM_BIN")")"
NIM_LIB="${NIM_LIB:-$NIM_PREFIX/nim/lib}"
if [[ ! -f "$NIM_LIB/nimbase.h" ]]; then
  BREW_NIM_LIB="$(brew --cellar nim 2>/dev/null)/$(brew list --versions nim 2>/dev/null | awk '{print $2}')/nim/lib"
  [[ -f "$BREW_NIM_LIB/nimbase.h" ]] && NIM_LIB="$BREW_NIM_LIB"
fi
[[ -f "$NIM_LIB/nimbase.h" ]] || { echo "ERROR: nimbase.h not found"; exit 1; }

echo "[cdi] Source:  $SRC"
echo "[cdi] Output:  $OUT_CDI"
echo "[cdi] Docker:  $DOCKER_IMAGE"

# ── Phase 1: nim --compileOnly ─────────────────────────────────────────────
echo "[cdi] Phase 1: nim --compileOnly..."
nim c --compileOnly \
  -d:dreamcast ${DC_RELEASE:--d:release} ${DC_NIMFLAGS:-} -d:configyVendor=smoketest \
  --path:src --path:verify/dreamcast \
  --nimcache:"$NIMCACHE" \
  "$SRC"
cp "$NIM_LIB/nimbase.h" "$NIMCACHE/nimbase.h"
echo "[cdi] C files + nimbase.h in $NIMCACHE"

# ── Phases 2–6: all inside Docker ─────────────────────────────────────────
docker run --rm \
  -v "$DOCKER_REPO:$DOCKER_REPO" \
  -w "$DOCKER_REPO" \
  "$DOCKER_IMAGE" \
  bash -c "
set -euo pipefail
set +u; source /opt/toolchains/dc/kos/environ.sh; set -u

NIMCACHE='$NIMCACHE'
BASE='$BASE'
REPO='$REPO_ROOT'
OUT_ELF='$OUT_ELF'
OUT_CDI='$OUT_CDI'

# ── Phase 2: compile + link (inputty pattern) ─────────────────────────────
echo '[cdi] Phase 2: compile + link (sh-elf-gcc GCC 9)...'
CFLAGS=\"-c -w -fmax-errors=3 -fno-strict-aliasing -ml -m4-single-only -ffunction-sections ${DC_OPT:--Os} -fno-ident\"
INCLUDES=\"-I\$NIMCACHE -I/opt/toolchains/dc/sh-elf/include -I/opt/toolchains/dc/kos/include -I/opt/toolchains/dc/kos/addons/include\"

OBJ_FILES=()
for cfile in \"\$NIMCACHE\"/*.c; do
  objfile=\"\${cfile%.c}.o\"
  sh-elf-gcc \$CFLAGS \$INCLUDES -o \"\$objfile\" \"\$cfile\"
  OBJ_FILES+=(\"\$objfile\")
done
echo \"  compiled \${#OBJ_FILES[@]} objects\"

sh-elf-gcc \$KOS_LDFLAGS \$KOS_START \
  -L/opt/toolchains/dc/sh-elf/sh-elf/lib \
  -o \"\$OUT_ELF\" \
  \"\${OBJ_FILES[@]}\" \
  -Wl,--start-group -lkallisti -lc -lm -lgcc -Wl,--end-group
echo \"  linked: \$OUT_ELF\"

# Strip .stack section (Flycast ELF loader chokes on it)
sh-elf-objcopy -R .stack \"\$OUT_ELF\" \"\$OUT_ELF\"

# ── Phase 3: raw binary ───────────────────────────────────────────────────
echo '[cdi] Phase 3: ELF → 1ST_READ.BIN...'
BUILDTMP=\"\$REPO/cdi_build_\$BASE\"
mkdir -p \"\$BUILDTMP/cd\"
sh-elf-objcopy -O binary \"\$OUT_ELF\" \"\$BUILDTMP/cd/1ST_READ.BIN.raw\"
/opt/toolchains/dc/kos/utils/scramble/scramble \"\$BUILDTMP/cd/1ST_READ.BIN.raw\" \"\$BUILDTMP/cd/1ST_READ.BIN\"
rm \"\$BUILDTMP/cd/1ST_READ.BIN.raw\"
ls -lh \"\$BUILDTMP/cd/1ST_READ.BIN\"

# ── Phase 4: IP.BIN ───────────────────────────────────────────────────────
echo '[cdi] Phase 4: IP.BIN...'
cat > \"\$BUILDTMP/ip.txt\" <<'IPTXT'
Hardware ID   : SEGA SEGAKATANA
Maker ID      : SEGA ENTERPRISES
Device Info   : 0000 CD-ROM1/1
Area Symbols  : JUE
Peripherals   : E000F10
Product No    : T0000
Version       : V1.000
Release Date  : 20260619
Boot Filename : 1ST_READ.BIN
SW Maker Name : CONFIGY
Game Title    : CONFIGY SMOKE
IPTXT
cp /opt/toolchains/dc/kos/utils/makeip/IP.TMPL \"\$BUILDTMP/\"
cd \"\$BUILDTMP\" && /opt/toolchains/dc/kos/utils/makeip/makeip ip.txt IP.BIN && cd \"\$REPO\"
ls -lh \"\$BUILDTMP/IP.BIN\"

# ── Phase 5: ISO ──────────────────────────────────────────────────────────
echo '[cdi] Phase 5: mkisofs → bootable ISO...'
mkisofs -C 0,11702 -V CONFIGY -G \"\$BUILDTMP/IP.BIN\" \
  -r -l -x .rr_moved \
  -o \"\$BUILDTMP/output.iso\" \
  \"\$BUILDTMP/cd/\"

# ── Phase 6: CDI ──────────────────────────────────────────────────────────
echo '[cdi] Phase 6: cdi4dc → CDI...'
/opt/toolchains/dc/kos/utils/img4dc/cdi4dc/cdi4dc \
  \"\$BUILDTMP/output.iso\" \"\$OUT_CDI\"

echo \"[cdi] Cleaning up build tmp...\"
rm -rf \"\$BUILDTMP\"
"

echo ""
echo "[cdi] Done:"
ls -lh "$OUT_ELF" "$OUT_CDI"
echo ""
echo "[cdi] Load in Flycast: File → Open → ${BASE}.cdi"
