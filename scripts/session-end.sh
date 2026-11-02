#!/usr/bin/env bash
# SessionEnd hook: send what changed. It runs detached, because the harness is exiting.
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/memory-3layer"
nohup bash "$BIN" sync --quiet >/dev/null 2>&1 &
disown 2>/dev/null
exit 0
