---
name: recall
description: Search memory across projects: past decisions, gotchas, notes. Use for "did we already see this?" or any question about earlier work.
---

# /recall — Hybrid search over memory

Search across L0 identity, L1-fallback project notes, and L2 session memory using qmd (BM25 + GGUF embeddings + LLM rerank, all local).

## Usage

`/recall <query>` — full-text BM25 search across all memory collections. **Default mode** — fast, always works, no model loading.

`/recall --hybrid <query>` — full hybrid: BM25 + vector + LLM rerank. Requires `qmd embed` to be complete; loads ~2GB of GGUF models on first call of the session. Use when BM25 misses something obviously relevant.

Optional flags:
- `--here` — scope to current project's memory only (key from `memory-3layer key`)
- `-c <collection>` — scope to one collection
- `-n <N>` — top-N hits (default 5)

## How to execute

1. Run via Bash.

2. **BM25 default** (no `--hybrid` flag):
   ```bash
   memory-3layer search "<USER_QUERY>"
   ```

3. **Hybrid mode** (with `--hybrid`):
   ```bash
   qmd query "<USER_QUERY>" -c memory-3layer -n 5
   ```
   First call of the session takes 10-60s to load embedding/reranker/query-expansion models. Subsequent calls are fast.

4. Scoping:
   - `--here`: `memory-3layer search --here "<USER_QUERY>"`. It lists the ranked files of this project; read the ones that fit. qmd has no path filter, so hybrid mode can't be limited to one project.
   - `-c <name>` / `-n <N>`: pass through to qmd

5. Display qmd's markdown output verbatim. Do NOT paraphrase paths/snippets. After hits, add one short orientation line (e.g. "looks like the relevant note is in `air/SESSION.md`").

6. **If hybrid mode fails** (`Error loading model` / `ErrorExtensionNotPresent`): silently fall back to `qmd search`, mention it once. Common cause: Vulkan/CUDA prebuilt mismatch on Windows.

## Examples

- `/recall MongoDB legacy driver` — BM25, finds mpcmf projects with `\MongoClient` legacy adapter
- `/recall --hybrid гочи WSL DNS` — hybrid, finds `CURLOPT_IPRESOLVE_V4` semantic-similar even without exact phrase match
- `/recall --here armenia weekly window` — scope to current project

## Collections available

- `memory-3layer` — everything under `memory-3layer path home`: identity, project.md, SESSION.md, archives, topic files

## When BM25 vs hybrid

- **BM25 default is enough 80% of the time** — your memory files contain the exact terminology you're searching for ("MongoDB", "Vulkan", "Kubernetes ingress"). BM25 wins on speed + zero loading cost.
- **Use `--hybrid`** for semantic queries where you don't remember the exact words ("that thing about DNS resolution failures", "the gotcha with timezone handling").

## Windows-only troubleshooting

If `qmd` is not on PATH (Git Bash / Windows), prepend:
```bash
export PATH="/c/Program Files/nodejs:/c/Users/$USERNAME/AppData/Roaming/npm:$PATH"
export QMD_LLAMA_GPU=none   # Vulkan default crashes on some AMD/Intel GPUs
```
