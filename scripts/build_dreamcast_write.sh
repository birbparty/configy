#!/usr/bin/env bash
# configy Dreamcast WRITE-path verification gate — thin wrapper over build_dreamcast.sh
# that builds verify/dreamcast/dreamcast_write_smoke.nim.
# Requires configyFsWritable=true for dreamcast (see src/configy/capabilities.nim,
# tracked configy-6b6 — the write flag is off until Flycast VMU round-trip verified).
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./scripts/build_dreamcast.sh verify/dreamcast/dreamcast_write_smoke.nim
