# memory-3layer — Codex CLI plugin

Agent memory that belongs to no harness: identity, project notes and working state, keyed by
repository and synced through git storages you choose.

```bash
codex plugin marketplace add openronin/memory-3layer-codex
codex plugin add memory-3layer@memory-3layer
```

Then trust the hooks in `/hooks`, and allow writes to the memory directory: see
[docs/codex.md](https://github.com/openronin/memory-3layer/blob/main/docs/codex.md). This package has not yet been run on a real Codex.

Restart the session after installing. Secrets never enter memory, and nothing leaves the machine
until you configure a storage. See [the main repository](https://github.com/openronin/memory-3layer).

## This repository is generated

Every file here is built from [openronin/memory-3layer](https://github.com/openronin/memory-3layer)
and overwritten on each release, so changes made here are lost. Issues and pull requests belong in
that repository; this one only ships version 7.1.0 of the package.

[MIT](LICENSE)
