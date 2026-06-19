#!/usr/bin/env bash
# configy Dreamcast build via Docker (haydenkow/nu_dckos).
#
# The native KOS toolchain on macOS Apple Silicon is incomplete (GCC pass-1 only;
# newlib and libkallisti.a are not compiled). This script uses the pre-built Docker
# container instead, which has a complete KOS + sh-elf-gcc 4.7.3.
#
# Two-phase:
#   1. nim c --compileOnly on the host  →  generates .c files in nimcache/
#   2. sh-elf-gcc inside Docker         →  compiles + links against KOS
#
# Usage:
#   ./scripts/build_dreamcast_docker.sh [source.nim]
#   ./scripts/build_dreamcast_docker.sh verify/dreamcast/dreamcast_write_smoke.nim
#
# Output: ./<basename>.elf  (next to nimcache dir in repo root)
#
# Requirements:
#   - nim in PATH (host)
#   - Docker running with haydenkow/nu_dckos image pulled

set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

DOCKER_IMAGE="haydenkow/nu_dckos"
DOCKER_REPO="/configy"   # mount point for REPO_ROOT inside container

SRC="${1:-verify/dreamcast/dreamcast_smoke.nim}"
BASE="$(basename "$SRC" .nim)"
NIMCACHE="$REPO_ROOT/nimcache_dc_${BASE}"
OUT_ELF="$REPO_ROOT/${BASE}.elf"

# Nim stdlib is copied into the nimcache dir so Docker can access it
# (Docker Desktop on macOS does not share /opt/homebrew by default).
DOCKER_NIMLIB="$DOCKER_REPO/nimcache_dc_${BASE}/nimlib"

# Nim stdlib location on host — derived from the nim executable's location.
# 'nim' lives at <prefix>/bin/nim, stdlib is at <prefix>/nim/lib.
NIM_BIN="$(command -v nim 2>/dev/null || true)"
if [[ -z "$NIM_BIN" ]]; then
  echo "[build_dreamcast_docker] ERROR: nim not in PATH"
  exit 1
fi
NIM_PREFIX="$(dirname "$(dirname "$NIM_BIN")")"
NIM_LIB="${NIM_LIB:-$NIM_PREFIX/nim/lib}"
if [[ ! -f "$NIM_LIB/nimbase.h" ]]; then
  # Homebrew installs nim differently — try the Cellar path
  BREW_NIM_LIB="$(brew --cellar nim 2>/dev/null)/$(brew list --versions nim 2>/dev/null | awk '{print $2}')/nim/lib"
  if [[ -f "$BREW_NIM_LIB/nimbase.h" ]]; then
    NIM_LIB="$BREW_NIM_LIB"
  else
    echo "[build_dreamcast_docker] ERROR: nimbase.h not found at $NIM_LIB or $BREW_NIM_LIB"
    echo "[build_dreamcast_docker] Set NIM_LIB env var to the nim stdlib directory."
    exit 1
  fi
fi

# --- Check Docker ---
if ! command -v docker &>/dev/null; then
  echo "[build_dreamcast_docker] ERROR: docker not in PATH"
  exit 1
fi
if ! docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
  echo "[build_dreamcast_docker] Pulling $DOCKER_IMAGE..."
  docker pull "$DOCKER_IMAGE"
fi

echo "[build_dreamcast_docker] Source: $SRC"
echo "[build_dreamcast_docker] NIM_LIB: $NIM_LIB"

# --- Phase 1: nim --compileOnly on host ---
echo "[build_dreamcast_docker] Phase 1: generating C via nim --compileOnly..."
nim c --compileOnly \
  -d:dreamcast \
  -d:release \
  -d:configyVendor=smoketest \
  --path:src --path:verify/dreamcast \
  --nimcache:"$NIMCACHE" \
  "$SRC"
echo "[build_dreamcast_docker] C files generated in $NIMCACHE"

# Copy nim stdlib into nimcache so Docker can mount it (Docker Desktop on macOS
# restricts sharing outside /Users — /opt/homebrew is not shared by default).
NIM_STDLIB_COPY="$NIMCACHE/nimlib"
if [[ ! -d "$NIM_STDLIB_COPY" ]]; then
  echo "[build_dreamcast_docker] Copying nim stdlib for Docker access..."
  cp -r "$NIM_LIB" "$NIM_STDLIB_COPY"
fi

# --- Phase 2: build Docker compile+link script from nimcache JSON ---
echo "[build_dreamcast_docker] Phase 2: adapting nimcache for Docker paths..."

DOCKER_SCRIPT="$(mktemp /tmp/dc_docker_build_XXXX.sh)"
trap 'rm -f "$DOCKER_SCRIPT"' EXIT

python3 - <<PYEOF > "$DOCKER_SCRIPT"
import json, os, re, sys

nimcache = "$NIMCACHE"
base = "$BASE"
repo = "$REPO_ROOT"
nim_lib = "$NIM_LIB"
kos_host = "/Users/punk1290/dreamcast-toolchain/dc/kos"
docker_repo = "$DOCKER_REPO"
docker_nimlib = "$DOCKER_NIMLIB"
docker_kos = "/opt/toolchains/dc/kos"

with open(f"{nimcache}/{base}.json") as f:
    d = json.load(f)

def adapt(s):
    s = s.replace(repo, docker_repo)
    s = s.replace(nim_lib, docker_nimlib)
    s = s.replace(kos_host, docker_kos)
    return s

print("#!/usr/bin/env bash")
print("set -eo pipefail")
print("# KOS environ.sh references KOS_INC_PATHS_CPP without initializing it first;")
print("# temporarily disable -u so sourcing it doesn't abort under set -euo pipefail.")
print("set +u; source /opt/toolchains/dc/kos/environ.sh; set -u")
print(f"echo '[docker] kos-cc version (sh-elf-gcc):'")
print("sh-elf-gcc --version | head -1")
print()

# Compile each .c → .o using kos-cc so KOS_CFLAGS get injected
# (-D_arch_dreamcast -D_arch_sub_pristine and KOS include paths).
# The KOS include paths and arch flags from nim.cfg's passC are already in
# KOS_CFLAGS — strip them from the nim-generated compile cmd to avoid
# duplicates, keeping only nim-specific flags (fmax-errors, strict-aliasing,
# nimlib -I, etc.)
print("echo '[docker] Compiling C files with kos-cc...'")
# Patterns to strip (already in KOS_CFLAGS): KOS -I flags and -ml -m4-single-only
# -ffunction-sections -fdata-sections  (kos-cc will inject them via KOS_CFLAGS)
KOS_STRIP_PATTERNS = [
    r'-I/opt/toolchains/dc/kos/\S+',
    r'-ml\b',
    r'-m4-single-only\b',
    r'-ffunction-sections\b',
    r'-fdata-sections\b',
    r'-ftls-model=\S+',
]
for src_file, compile_cmd in d.get("compile", []):
    adapted = adapt(compile_cmd)
    # Replace 'gcc -c' at the start with 'kos-cc -c'
    adapted = re.sub(r'^\s*gcc\s+', 'kos-cc ', adapted)
    # Strip flags already provided by kos-cc via KOS_CFLAGS
    for pat in KOS_STRIP_PATTERNS:
        adapted = re.sub(pat, '', adapted)
    # Collapse extra whitespace
    adapted = re.sub(r'  +', ' ', adapted).strip()
    print(adapted)

print()
print("echo '[docker] Linking...'")

# Build link command from the object files list + KOS flags
objs = [adapt(src_file + ".o") for src_file, _ in d.get("compile", [])]
obj_list = " ".join(objs)

link = (
    f"sh-elf-gcc"
    f"  -ml -m4-single-only"
    f"  -Wl,-Ttext=0x8c010000 -Wl,--gc-sections"
    f"  -T/opt/toolchains/dc/kos/utils/ldscripts/shlelf.xc"
    f"  -nodefaultlibs"
    f"  {obj_list}"
    f"  -L{docker_kos}/lib/dreamcast"
    f"  -L{docker_kos}/addons/lib/dreamcast"
    f"  -Wl,--start-group -lkallisti -lc -lm -Wl,--end-group"
    f"  -lgcc"
    f"  -o {docker_repo}/{base}.elf"
)
print(link)
print()
print(f"echo '[docker] Linked: {docker_repo}/{base}.elf'")
PYEOF

chmod +x "$DOCKER_SCRIPT"
echo "[build_dreamcast_docker] Docker build script: $DOCKER_SCRIPT"

# --- Phase 3: Run Docker ---
echo "[build_dreamcast_docker] Phase 3: running Docker (${DOCKER_IMAGE})..."
docker run --rm \
  -v "$REPO_ROOT:$DOCKER_REPO" \
  -v "$DOCKER_SCRIPT:/dc_build.sh:ro" \
  "$DOCKER_IMAGE" \
  bash /dc_build.sh

echo "[build_dreamcast_docker]"
echo "[build_dreamcast_docker] Done: $OUT_ELF"
echo "[build_dreamcast_docker] Boot in Flycast: File > Boot Binary > ${BASE}.elf"
