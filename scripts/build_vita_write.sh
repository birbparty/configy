#!/usr/bin/env bash
# configy Vita WRITE-path verification gate — thin wrapper over build_vita.sh that
# builds verify/vita/vita_write_smoke.nim with its own TITLE_ID (CFGW00001), so it
# installs alongside the read smoke (CFGY00001) in one Vita3K / on one card.
# Requires configyFsWritable=true for vita (see src/configy/capabilities.nim).
set -euo pipefail
cd "$(dirname "$0")/.."
exec ./scripts/build_vita.sh verify/vita/vita_write_smoke.nim CFGW00001
