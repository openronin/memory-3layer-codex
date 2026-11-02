#!/usr/bin/env bash
# PreCompact hook: remind the agent to flush SESSION.md before compaction.
# PreCompact takes a top-level systemMessage, not hookSpecificOutput.additionalContext.
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/memory-3layer"
( bash "$BIN" sync --quiet >/dev/null 2>&1 & )
session=$(bash "$BIN" path project)/SESSION.md
printf '{"systemMessage":"PRE-COMPACT FLUSH REQUIRED. Before compaction, update %s: Goal, State (branch/last/next), Decisions with rationale, File map, Open questions, Blockers, and Recent turns (last ~5 user turns verbatim plus one line on what you did). It is the only artifact that survives compaction with full fidelity. Read it first after compaction."}\n' "$session"
