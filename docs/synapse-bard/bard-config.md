# Configuration Reference

Short, because there's genuinely little to configure. Checked directly against the source, not
assumed: neither `synapse-bard` nor `synapse-bard-hook` reads a single `*.conf` file or a
`SYNAPSE_BARD_*`/`BARD_*` environment variable anywhere.

## Why there's nothing here to tune

Both of `synapse-bard`'s stores ([Bible-graph](bard-graph.md), [Writer's notes vault](bard-vault.md))
live under `_bard/` inside the one repo being worked in: no external location to point at, no
cross-project state to disambiguate.

## The one thing every command resolves, automatically

`common.Roots.resolve` (`src/apps/bard/common.zig`) finds `repo_root`, `_bard/graph/`, and
`_bard/vault/` with one `core.identity.resolve` call per invocation — the same repo-root discovery
`bard_hook`'s own `SessionStart` handler uses for `_bard/vault/Index.md`. It walks up from the
current directory to find the repo root the way git itself would, so a command run from a
subdirectory still finds `_bard/` at the top rather than looking for it relative to wherever the
shell happened to be. Nothing about this is configurable, and nothing needs to be: there is exactly
one repo a `synapse-bard` invocation could mean, with no cross-repo namespace to key or
disambiguate.

## `CLAUDE_PLUGIN_ROOT` / `SYNAPSE_BARD_CONTENT_ROOT`: the environment variables that matter

Both `synapse-bard-claude.md` (the standing instructions) and `Index.md.template` (the vault's
bootstrap default) are read by `synapse-bard-hook`'s `SessionStart` handler through
`CLAUDE_PLUGIN_ROOT` first, then `SYNAPSE_BARD_CONTENT_ROOT` — the npm-install counterpart
`synapse-bard-setup configure claude` sets in `settings.json`'s own `env` block, since npm never
sets `CLAUDE_PLUGIN_ROOT` the way a marketplace plugin install did. Both unset simply means neither
file is found, reported plainly rather than guessed at.

## What a fresh bible repo needs, and what it doesn't

No `synapse.conf`, no per-machine setup step, no interactive prompt on first run. The one thing a
repo needs to activate `synapse-bard` from a session that can never run a terminal command itself
(the Android app's default cloud session is exactly this: a fresh VM cloned from the repo every
time, with no persistence outside it) is a single committed `SessionStart` hook whose entire body
is:

```
npm install -g @imunitic/synapse-bard@latest && synapse-bard-setup configure claude
```

`synapse-bard-setup configure claude` is itself idempotent — re-running it never duplicates a hook
entry or a copied skill/command, so running it fresh every session (since nothing about a cloud
session persists between them) is safe rather than wasteful. `npm install -g` resolves against
`registry.npmjs.org`, which sits on the default network allowlist every Claude Code cloud
environment gets, and a `SessionStart` hook running `npm install` is the documented way Claude
Code's own cloud-environment docs describe giving a project the same setup in the cloud as locally.
No install step of the author's own, ever.
