---
name: memory
description: Memory controls: status, auto-capture on or off, index refresh, and rotation of closed arcs out of SESSION.md when a size warning appears.
---

# /memory — Memory mode controls

Manage memory protocol behaviour. Default is **explicit-promotion** mode (user must say "запомни"/"remember" to persist cross-session). This command can flip to **auto-capture** for the current session, OR show status.

## Sub-commands

`/memory` (no args, or `/memory status`) — show current mode + collection health + last index times.

`/memory auto on` — enable **auto-capture** for the rest of THIS session. While on, append surprising/non-obvious findings to SESSION.md `# Decisions` and (if codebase-related) `<repo>/.claude-docs/gotchas.md` continuously, without waiting for explicit "запомни". Decisions stay rationale-tagged. Recent turns still verbatim.

`/memory auto off` — disable auto-capture (return to explicit-promotion). This is the default at every session start.

`/memory refresh` — force `memory-3layer refresh && qmd embed` for all collections NOW (use if hooks didn't fire).

`/memory rotate [--dry-run]` — relocate CLOSED arcs out of `SESSION.md` into a recallable archive, keeping L2 a bounded window of active work. Lossless: the full arc text moves to the archive verbatim; only a one-line stub stays inline. Triggered by the L2 size guardrail in the session-start hook (soft/hard limits in `~/.claude/.memory-config`), or run manually anytime.

## How to execute

1. For **status**: run `qmd status` and `qmd collection list` via Bash, plus read the auto-capture flag from `$(memory-3layer path state)/auto` (presence = on, absence = off). Report concisely.

2. For **`auto on`**: `touch "$(memory-3layer path state)/auto"`. Then explicitly tell the user: *"Auto-capture: ON for this session. I'll start writing observations to SESSION.md/gotchas without waiting for 'запомни'. Use `/memory auto off` to stop."*

3. For **`auto off`**: `rm -f "$(memory-3layer path state)/auto"`. Confirm: *"Auto-capture: OFF. Back to explicit-promotion."*

4. For **`refresh`**: `memory-3layer refresh && qmd embed`. Report counts (`N new, M updated`).

5. For **`rotate`** (model-driven — you do the parsing; there is no shell script, because the arc/status convention is the user's, not a fixed template, and a regex over it would be brittle and locale-specific):

   a. `source "$(memory-3layer path config)" 2>/dev/null` to read `L2_KEEP_ARCS` (default 2) and `L2_ARCHIVE_BY_MONTH` (default 1). The file is `$(memory-3layer path project)/SESSION.md`.

   b. Read `SESSION.md`. Split it into **dated arcs** — ad-hoc sections whose heading looks like `# [YYYY-MM-DD] <tag> — <summary>` (the user's journaling convention). Everything that is NOT a dated arc — `Goal`, `State`, `Decisions`, `File map`, `Open questions`, `Blockers`, `Recent turns`, and the frontmatter — is **structural** and is never moved.

   c. **Eligible for relocation** = dated arcs marked closed (status marker `СДЕЛАНО` / `ГОТОВО` / `DONE` in the heading or body), EXCEPT the most recent `L2_KEEP_ARCS` closed arcs (keep those inline for continuity). An arc with no closing marker is **active** → never moved. If the user uses a different closing convention, honor whatever they actually write; when unsure whether an arc is closed, leave it.

   d. **Archive target** (alongside `SESSION.md`, in the same project directory, so search already indexes it): `SESSION.archive.YYYY-MM.md` when `L2_ARCHIVE_BY_MONTH=1` (group by the arc's own date), else a single `SESSION.archive.md`. Create with frontmatter `tags: [memory/l2, archive]` on first write; append thereafter. **Never** auto-write into the repo (`<repo>/.claude-docs/`) — a curated changelog is a separate, manual decision.

   e. For each eligible arc: **append its full text verbatim** to the archive, then **replace it in `SESSION.md` with a one-line stub**: the original heading line + ` → archived: SESSION.archive.YYYY-MM.md`. This is relocation, not summarization — no information is lost; the stub is just a pointer.

   f. Refresh `last_updated`. Report: `N arcs (~X KB) relocated → <archive file>; SESSION.md now ~Y KB`. To restore an arc later, read the archive file directly (or surface it via `/recall`).

   g. **`--dry-run`**: list which arcs WOULD move and to which file, with the projected size before/after. Write nothing.

   h. **Guardrails:** never move structural sections or active arcs. If nothing is eligible (everything is active, or the file is small), say so and make no changes — if the file is over the hard limit yet nothing is eligible, that means the *active* working set is genuinely large; tell the user rather than truncating live state.

## Behaviour when auto-capture is ON (model must follow)

- After any non-trivial decision: write 1-line entry to SESSION.md `# Decisions` with rationale.
- After any discovery of a non-obvious project gotcha: append to the relevant `gotchas.md` (in-repo `<repo>/.claude-docs/gotchas.md` if L1a exists, else `$(memory-3layer path project)/gotchas.md` if it exists, else the project's `project.md` under `## Known gotchas`).
- Do NOT auto-promote to IDENTITY.md (L0 stays sacred even in auto-mode).
- Do NOT auto-modify `<repo>/CLAUDE.md` (in-repo L1a is thin by design).
- Still refresh `last_updated` on every SESSION.md write.

## Check-this rule

At the start of EVERY response, check `$(memory-3layer path state)/auto`. If present, follow auto-capture behaviour. If absent, follow default (explicit-promotion). This check is cheap (one stat call) and ensures the toggle takes effect immediately within the session.

## Windows-only troubleshooting

If `qmd` is not on PATH (Git Bash / Windows), prepend to qmd commands:
```bash
export PATH="/c/Program Files/nodejs:/c/Users/$USERNAME/AppData/Roaming/npm:$PATH"
```
