#!/usr/bin/env bash
# configy 3DS WRITE-path verification gate — thin wrapper over build_3ds.sh that
# builds verify/ds3/ds3_write_smoke.nim. Requires configyFsWritable=true for ds3
# (see src/configy/capabilities.nim).
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./scripts/build_3ds.sh verify/ds3/ds3_write_smoke.nim
