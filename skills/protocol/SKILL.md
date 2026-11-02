---
name: protocol
description: The full memory-3layer protocol - which layer a fact belongs to, how to keep SESSION.md, rotation, promotion, secrets. Read it when deciding where to save something, when wrapping up a task, before compaction, or when a memory warning appears.
---

Slash commands named below are skills of this plugin: `/recall` is `$recall`, and so on. A `memory-3layer` command means the Client path in the session context. Templates are in the `templates/` directory of this plugin.

# Memory Protocol (memory-3layer)

This is the memory that survives a new machine or a different agent. A harness may also have memory of its own, and the two can run side by side: that memory stays a harness-local cache, and anything that must last goes here.

`<home>` below is the output of `memory-3layer path home` (default `~/.local/share/memory-3layer`). `<key>` is the output of `memory-3layer key`. `memory-3layer path project` prints `<home>/projects/<key>` directly.

## Core principle

> **"Would a server agent at midnight, with no memory and no human, need this?"**
> — yes → it goes **in the repo** (git-tracked, travels with code, visible to teammates and headless agents)
> — no → it goes in **account-local memory** (`<home>/identity/` or per-project `<home>/projects/<key>/`)

Codebase facts (architecture, conventions, gotchas) live with the codebase. Personal preferences and per-task scratch live in account memory. Don't cross the wires.

## Layers

| Layer | Path | Loaded | Git-tracked | Purpose |
|---|---|---|---|---|
| **L0 Identity** | `<home>/identity/IDENTITY.md` | every session start | no (account-personal) | who you are, hard preferences, env-wide credentials |
| **L1a Repo entry** | `<repo>/CLAUDE.md` | every session start (auto by Claude Code when cwd is inside repo) | **yes** | thin: commands, top-level conventions, MUST/MUST NOT, **doc index** pointing at L1b |
| **L1b Repo docs** | `<repo>/.claude-docs/*.md` | on demand via L1a's index | **yes** | thick: `gotchas.md`, `architecture.md`, `conventions.md`, `patterns.md`, `cookbook.md`, etc. — read what the task needs |
| **L1-fallback** | `<home>/projects/<key>/project.md` | every session start (via SessionStart hook) | no | for projects without a repo, or where in-repo L1 isn't appropriate (proprietary, solo) |
| **L2 Session** | `<home>/projects/<key>/SESSION.md` | every session start + after every compact | no | per-task working state — survives compact; bounded window, closed arcs rotate to archive |
| **L2 Archive** | `<home>/projects/<key>/SESSION.archive[.YYYY-MM].md` | on demand via `/recall` only | no | closed arcs relocated out of L2 — searchable, never auto-injected |

`<key>` is the project's git remote without the scheme, credentials or `.git` (`github.com/owner/repo`), so it is the same on every machine, in every worktree and in every subdirectory. The key is chosen in this order, each step falling back to the next: a `.memory-3layer-key` file (set with `memory-3layer pin <key>`), the git remote, the path under `$HOME` (`local/<path>`). Use `pin` for a project with no remote, or one whose remote differs between machines. After a remote changes, `memory-3layer rekey <old> <new>` moves the memory.

One repo has one L2, whatever branches a session touches. Inside the repo, write paths relative to its root: the same project can sit elsewhere on another machine.

`<repo>` = the git repo root for the current cwd (`git rev-parse --show-toplevel`).

L2 is a **bounded window** of active work, not an unbounded journal. Closed arcs don't accumulate in `SESSION.md` — they're relocated **losslessly** to the recall-only L2 archive (full text moves; a one-line stub + pointer stays inline) via `/memory rotate`. The archive is searchable through `/recall` but never auto-injected into context. **Budget:** keep `SESSION.md` to roughly the active task + the last 1–2 closed arcs — soft ~40 KB / hard ~80 KB, configurable in the file printed by `memory-3layer path config` (`0` = no limit). The session-start hook warns when you cross a limit; rotation is a deliberate decision, not silent truncation.

## ON SESSION START — DO THIS FIRST

Before answering the user's first message, run these reads in parallel:

1. `Read <home>/identity/IDENTITY.md` (L0)
2. `<repo>/CLAUDE.md` is auto-loaded by Claude Code when cwd is inside a repo — it's already in your context, treat it as L1a. **Do NOT auto-read every file under `<repo>/.claude-docs/`** — open them on demand based on the index in `<repo>/CLAUDE.md`.
3. `Read <home>/projects/<key>/SESSION.md` if it exists (L2 — your working state from before any compact/restart, treat as authoritative)
4. `Read <home>/projects/<key>/project.md` if it exists (L1-fallback — relevant when repo doesn't have its own `<repo>/CLAUDE.md`)

If neither L1a (`<repo>/CLAUDE.md`) nor L1-fallback exists, and the user starts substantive work, propose creating one — **default to in-repo L1a** (`<repo>/CLAUDE.md` + `<repo>/.claude-docs/`) unless the user opts for the local fallback.

If SESSION.md doesn't exist, create the directory and a fresh SESSION.md from the template below when substantive work begins.

Do this even if a SessionStart hook also fires — idempotent.

## What goes where

| What you learned | Where it goes |
|---|---|
| Architectural pattern, recurring code pattern, layout decision | `<repo>/.claude-docs/architecture.md` or `patterns.md` |
| **Non-obvious gotcha / footgun / "looks wrong but is intentional"** | `<repo>/.claude-docs/gotchas.md` ← **HIGHEST LEVERAGE** |
| Codebase-wide convention (naming, commit style, lint rules) | `<repo>/.claude-docs/conventions.md` |
| New endpoint group, new store, new component category | matching file in `<repo>/.claude-docs/` |
| Top-level command, MUST/MUST NOT, doc-index entry | `<repo>/CLAUDE.md` (keep it thin — it's the entry point, not the manual) |
| What's in flight on the current branch | `<home>/projects/<key>/SESSION.md` (per-task) |
| User identity, hard preference, env-wide credential (SSH wrapper, AWS profile) | `<home>/identity/IDENTITY.md` |
| Project context for a project without an in-repo `CLAUDE.md` | `<home>/projects/<key>/project.md` (L1-fallback) |

**Never put codebase facts in account memory.** They belong in `<repo>/.claude-docs/`. If you find a `project.md` (L1-fallback) fact that's clearly a codebase fact, propose promoting it to in-repo L1.

**Never put account-personal preferences in repo files.** They're not for teammates or server agents.

## Rules

1. **L0 is sacred** — ≤25 lines hard cap. Identity, role, hard preferences, env-wide credentials only. Never project-specific.
2. **L1a (`<repo>/CLAUDE.md`) is thin** — it's loaded into every session in this repo. Bloated entries eat context across all your work. Keep it to: commands, top-level conventions, MUST/MUST NOT, doc index pointing at L1b.
3. **L1b (`<repo>/.claude-docs/*.md`) is read on demand.** Big, typed, lazy. The doc index in L1a says "to do X read Y.md" — agent picks what it needs.
4. **L2 is the killer feature.** Update SESSION.md *as you work*, not at end:
   - After every decision: append to `# Decisions` with rationale
   - After every meaningful action: update `# State` (last action, next step)
   - After identifying a key file: append to `# File map` with `path:line — what`
   - Open questions and blockers get their own sections
   - **Ad-hoc sections are encouraged.** When a phase of work deserves its own block, add it. The template is a floor, not a ceiling. **Give each dated arc a self-summarizing heading** — `# [YYYY-MM-DD] <tag> — <one-line outcome>` — and append a status marker (`СДЕЛАНО` / `ГОТОВО` / `DONE`) when it closes. This makes rotation deterministic and the stub free: the heading IS the summary that stays behind when the body moves to the archive.
   - **L2 is a bounded window, not a journal.** Closed arcs don't pile up forever — when the session-start hook warns you've crossed the soft/hard size limit, run `/memory rotate` to relocate closed arcs to the L2 archive (lossless; recall-only). Never let `SESSION.md` grow unbounded; never truncate active state to shrink it (Goal/State/Open questions/Blockers/active arc are off-limits to rotation).
5. **PreCompact = mandatory flush.** Before compaction: write everything you'd need to resume to SESSION.md. The hook will remind you. After compact, your first action is `Read SESSION.md`.
   - On **every** write to SESSION.md, refresh the top-line `last_updated:` (in YAML frontmatter, or legacy HTML comment) to the current UTC ISO timestamp. The session-start hook uses this to detect stale state.
   - If the SessionStart hook injects a `SESSION.md is stale` warning (>24h since last_updated), do NOT silently continue with the loaded state — surface it to the user: "SESSION.md last touched <X> ago, goal was <Y>. Continue or reset?"
   - If the hook injects an `L2 SOFT/HARD LIMIT` warning, the file has outgrown its budget — run `/memory rotate` (hard = before continuing other work, soft = at the next natural pause). See rule 4.
6. **Promotion, not archival.** Cross-session memory persists ONLY when the user explicitly says so ("remember", "запомни"). On such an explicit signal:
   - About the user / their preferences / cross-project credentials → promote into `IDENTITY.md`
   - About the current codebase (architecture, gotchas, conventions) → propose promoting into `<repo>/CLAUDE.md` or `<repo>/.claude-docs/<file>.md` and let the user commit
   - About a project that has no repo / shouldn't go in repo → `<home>/projects/<key>/project.md` (L1-fallback)
   - Otherwise → ask which layer
   On task wrap-up without an explicit signal: SESSION.md is wiped to the template. **Do not auto-promote.**
7. **Gotchas are the highest-leverage memory.** When you discover a non-obvious foot-gun (config quirk, framework gotcha, API peculiarity, naming collision, "looks wrong but is intentional"), it goes in `<repo>/.claude-docs/gotchas.md`. Future sessions hit the same wall and benefit immediately.
8. **Server-agent test.** Before writing anything to account-local memory, ask: "Would a fresh agent who clones this repo at midnight need this?" If yes, push it in-repo.
9. **Secrets never enter memory, in any layer.** Memory may be synced, so it holds references only: `secret://<name>` (plus where it is used). Values live in the machine-local store managed by ``memory-3layer secret`, outside any synced directory.
   - New value from the user → ask them to run `! memory-3layer secret put <name>`, then write only `secret://<name>`.
   - Use a value → `memory-3layer secret run VAR=<name> -- <command>`. Don't print it; `get` works only in a terminal.
   - `secret://<name>` missing on this machine → ask the user for it. Don't look for a copy in transcripts or logs.
   - `memory-3layer secret scan` reports `file:line` and kind, never the value; `adopt <file>:<line> <name>` moves a found value into the store. The `guard` PreToolUse hook blocks such writes where the harness supports it; it is a net, not a substitute for this rule.

10. **Harness memory is a source, not a store.** `memory-3layer import <harness>` shows what a harness has saved in its own memory, and `--apply` copies it to `<home>/projects/<key>/imported/<harness>/`. The copy is unreviewed: verify a note before relying on it, and move what still holds into `project.md` or the repo docs under rule 6.

## Workflow patterns

### Pre-compact checkpoint
When the user signals an upcoming compact ("compact me", "теперь можно компакт"):
1. Confirm git is clean (or note dirty files explicitly)
2. Confirm pushed to remote (`git status -sb`)
3. Update SESSION.md fully (Goal/State/Decisions/File map/**Recent turns verbatim**)
4. Reply with explicit "PRE-COMPACT CHECKPOINT" line listing: HEAD hash, what's pushed, where the next session should start reading
5. Only after that — let the compact happen

### Post-compact recovery
First tool calls after a compact, in parallel:
- `Read <home>/identity/IDENTITY.md`
- `Read <home>/projects/<key>/SESSION.md`
- `Read <home>/projects/<key>/project.md` (if exists)
- Any specific `<repo>/.claude-docs/<file>.md` SESSION points at as "needed for full picture"
- (`<repo>/CLAUDE.md` is auto-loaded — verify it's actually in your context)

Don't answer the user before doing this — the summarizer paraphrases away the live texture.

### Multi-session handoff (parallel worktrees / chats)
If you're working in a side worktree or another chat is touching the same project, leave a `<!-- NOTE: ... -->` block right after `last_updated` describing what state the OTHER session expects.

### Distillation on task wrap-up
When the user says "task done" / "done" / "wrap it up" without "remember": rewrite SESSION.md to the empty template, preserving only `# Goal: (none — last task: <X>)`. Do **not** auto-promote.

This event-driven reset is the clean case. But tasks often bleed into one another and the explicit "done" never comes — so L2 also has a **state-driven** backstop: the size guardrail. When `SESSION.md` crosses the soft/hard byte limit, the hook warns and `/memory rotate` relocates *closed* arcs to the archive without ending the task. Wrap-up reset and mid-task rotation are complementary: reset is for "this task is over", rotation is for "this task is long and the journal is heavy".

### Bootstrapping in-repo L1
When the user starts substantive work in a repo with no `<repo>/CLAUDE.md`:
1. Propose creating it. Use templates from `the plugin's `templates/` directory, repo/` if available, else write from the shapes shown below.
2. Create `<repo>/.claude-docs/` with at minimum `index.md` (routing table) and `gotchas.md` (start empty — populate as you discover).
3. Add `<repo>/.claude-docs/architecture.md` only when you have something real to write — don't fabricate.
4. Commit as part of the user's work, not a separate commit unless asked.

## SESSION.md template (L2)

```markdown
---
last_updated: <ISO-8601 UTC, e.g. 2026-04-30T15:23:00Z>
tags: [memory/l2, session]
---

<!-- Optional NOTE: any ambient state another session/worktree should know about. -->

# Goal
<1-2 lines: what we're doing and why>

# State
- branch: <git branch or n/a>
- last action: <what just happened>
- next: <what's planned>

# Decisions
<!-- Tag with [HH:MM] for short sessions, or [<phase-tag>] for long multi-day arcs
     (e.g. [BA day], [LLM E2E], [WEB FIX <hash>]). -->
- [HH:MM] <decision> — <rationale>

# File map
- path:line — <what it does>

# Open questions
- <unresolved>

# Blockers
- <none | description>

# Recent turns
<!-- Last ~5 user turns verbatim + 1-line "I did:" each. Drop oldest when exceeding 5.
     Long quotes: keep first sentence verbatim, elide rest with [...].
     If user fired a chain of short messages, group them into one "User:" with -> arrows. -->
- **User:** "<verbatim>"
  **I did:** <1 line>

<!-- Optional ad-hoc sections — add as the work demands. -->
```

## In-repo L1 templates (shapes)

Full templates live in `the plugin's `templates/` directory, repo/` and in the friend-package zip.

**`<repo>/CLAUDE.md` (thin entry point):**
```markdown
# CLAUDE.md — <project name>

Entry point for Claude Code agents. For deeper reference see [`.claude-docs/`](.claude-docs/index.md).

## Documentation index
- [.claude-docs/index.md](.claude-docs/index.md) — routing table; start here when unsure
- [.claude-docs/gotchas.md](.claude-docs/gotchas.md) — non-obvious footguns
- [.claude-docs/architecture.md](.claude-docs/architecture.md) — stack, layout
- [.claude-docs/conventions.md](.claude-docs/conventions.md) — code style, naming, commits

## Commands
- `<build>` / `<test>` / `<lint>` ...

## Boundaries
### MUST
- ...
### MUST NOT
- ...

## Workflow
- Tracker: <Jira/Linear/...>, branches: `<pattern>`. Default branch: `<main|master>`.
```

**`<repo>/.claude-docs/index.md`** — routing table (which file to read for which task).

**`<repo>/.claude-docs/gotchas.md`** — populate as you hit foot-guns.

**`<repo>/.claude-docs/architecture.md`** — stack/layout/dirs/middlewares.

**`<repo>/.claude-docs/conventions.md`** — code style, naming, commit format, lint rules.

Add more files when categories emerge: `patterns.md`, `cookbook.md`, `api.md`, `stores.md`, `ui-components.md` etc. The doc index is the only thing always loaded — additions just need an entry there.

## L1-fallback template (`<home>/projects/<key>/project.md`)

Use this only when the project has no repo or you don't want this in-repo. Same shape as `<repo>/CLAUDE.md` + a "Known gotchas" section folded in. Full template: `the plugin's `templates/` directory, project.md.fallback.template`.

When the L1-fallback grows past one file (deep reverse-engineering projects, multi-component systems, multi-protocol work), apply the **Knowledge store organization** convention below — same as `<repo>/.claude-docs/`.

## Knowledge store organization (when it grows)

Both `<repo>/.claude-docs/` (L1b) and `<home>/projects/<key>/` (L1-fallback when single `project.md` outgrows itself) use the **flat + tags + filename-prefix** convention:

- **Flat by default; shallow grouping allowed when it helps `tree`-readability.** Tags do the primary categorization; subdirs are visual aid only. Rule: **at most one level of nesting**, and only when a category has 5+ peer files of the same type. Never nest deeper. Examples: `protocols/`, `formats/`, `handoffs/` OK; `protocols/v2/handshake/` not OK. Obsidian's tag panel renders hierarchical tags as a tree automatically — you get the visual hierarchy without paying the path-rewrite cost on refactor.
- **Filename prefixes for grouping.** `protocol_<name>.md`, `format_<name>.md`, `handoff_<topic>.md`, `decoded_<thing>.md`, `recipe_<task>.md`. Alphabetical sort gives free visual clustering in `ls`. Underscore between prefix and name; lowercase.
- **`index.md` is the routing source.** Every multi-file knowledge store has one. It's a table mapping "you need to do X" → "read Y.md". Always update it when adding a new doc. For in-repo L1, the index lives at `<repo>/.claude-docs/index.md` AND is mirrored as a doc-index in `<repo>/CLAUDE.md`.
- **Frontmatter tags carry semantic.** `tags: [memory/repo, protocol]`, `tags: [memory/l1, format, binary-layout]`. Hierarchical (`memory/repo`), semantic (`protocol`, `format`, `gotcha`), Obsidian-native.
- **Raw data dumps in `raw/` subdir.** Non-markdown (`.txt`, `.tsv`, `.json`, `.bin`) belongs in `raw/`. This is the **one** meaningful directory split — it separates "notes" from "data". Markdown notes stay flat.

**When to split** a single `project.md` into multi-file:
- File exceeds ~200 lines, OR
- 3+ clearly distinct categories of knowledge accumulating (separate topics, separate consumers), OR
- You'll cross-reference specific subsections from multiple places — a separate file is a clean link target.

When splitting: keep `project.md` (or `CLAUDE.md`) as the **thin entry + doc index**, move each category to its own `<prefix>_<name>.md` with frontmatter tags. Don't migrate everything at once — split as topics emerge.

## Obsidian compatibility

Memory files use YAML frontmatter (`last_updated`, `tags`) so vaults work out of the box.

Vault options:
- `<home>` as vault → L0 + all L2 sessions + L1-fallback project.md files (cross-project graph)
- `<repo>/` as vault → focused on one project's CLAUDE.md + .claude-docs/ (deep dive into one codebase)

Conventions:
- **Frontmatter**, not wikilinks. Use standard markdown links `[text](path)` everywhere — wikilinks `[[note]]` don't work outside Obsidian, and the model needs to follow real paths.
- **Hierarchical tags**: `memory/l0`, `memory/l1`, `memory/l2`, `memory/repo` (for in-repo L1 docs). Add semantic tags freely (`gotcha`, `decision`, `roadmap`).
- **Don't add `.obsidian/` config to memory files** — leave per-vault settings to the user.
- **Frontmatter is parsed by the staleness hook** via regex match on `last_updated:` anywhere in the file — legacy HTML-comment format `<!-- last_updated: ... -->` still works.

## Retrieval & code-intel tools (Karpathy LLM-OS framing)

The context window is RAM — finite, expensive. The file system is disk — abundant, cheap. Memory layers are files on disk; tools are how we read disk on demand without preloading it into RAM.

Three tools available via slash commands:

- **`/recall <query>`** — hybrid search (BM25 + GGUF embeddings + LLM rerank) across `<home>` (L0 + L1-fallback + L2). 100% local via qmd. Use for: "did we already see this gotcha?", "what was the MongoDB legacy quirk in mpcmf?", any knowledge-recall question across projects.

- **`/codemap def|callers|callees|outline <symbol>`** — on-demand symbol map for the current repo via universal-ctags + ripgrep. No daemon, no DB. Cache: `<repo>/.codemap.tags` (gitignore-friendly), auto-rebuilds when source files are newer. Use for: "where is X defined?", "who calls Y?", "what's the structure of this codebase?".

- **`/memory status | auto on|off | refresh | rotate`** — protocol controls. `auto on` flips THIS session into auto-capture mode (model writes observations to SESSION.md / gotchas without waiting for "запомни"); `auto off` returns to default explicit-promotion. `refresh` forces qmd index rebuild. `rotate [--dry-run]` relocates closed L2 arcs to the recall-only archive (lossless), keeping `SESSION.md` within its size budget — triggered by the hook's L2 size warning or run manually.

- **`/memstat [--watch]`** — "task manager" for the memory subsystem. Shows running qmd/ctags processes (PID, RAM, runtime), index progress (vectors embedded vs pending, % coverage), refresh schedule, recent log activity, and a stall/health check (samples vector delta to confirm a running embed is making progress). Use when `node.exe` is eating CPU and you want to know what it's doing / whether it hung.

The SessionStart hook auto-refreshes only the lightweight FTS/BM25 index (`qmd update`) in background, debounced 6h. The heavy vector step (`qmd embed`, CPU-bound minutes-long GGUF inference) is **manual only** — run `/memory refresh` when you want fresh vectors for `/recall --hybrid`. BM25 (the `/recall` default) doesn't need vectors. `/codemap`'s tags rebuild on demand if stale. No daemons.

**When to reach for which:**
- Knowledge / notes / past decisions → `/recall`
- Code structure / "where defined" / "who calls" → `/codemap`
- Pure text search inside a single file you know → `Read` / `Grep`
- Don't preload all `.claude-docs/*.md` upfront — use `/recall` first, then `Read` only the 1-2 files the hits surfaced.

## Recent turns — discipline

Update `# Recent turns` **before any potentially-large operation** and on PreCompact. Verbatim. If a user turn is long, keep first sentence + `[...]`. Drop oldest when exceeding 5.

Rapid chain of short messages → group with `->`:
```
- **User:** "проверь" -> "ну?" -> "ок коммить"
  **I did:** <one summary line>
```

## What NOT to save (any layer)

- Code patterns derivable from a quick repo scan (gotchas are non-obvious; structure is obvious)
- Git history facts — `git log` is authoritative
- CLAUDE.md duplicates
- Trivia ("user said hi today")
- Secret values — write `secret://<name>`, an env-var name or a path instead (rule 9)

## Recovery

Post-compact / post-restart: first tool calls are `Read <home>/identity/IDENTITY.md` + `Read <home>/projects/<key>/SESSION.md` + `Read <home>/projects/<key>/project.md` (if exists). The repo's own `CLAUDE.md` is auto-loaded — verify it's in your context. The hook normally injects this reminder, but if not, do it anyway.
