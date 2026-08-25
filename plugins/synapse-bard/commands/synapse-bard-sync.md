---
description: Run synapse-bard sync to (re)populate _bard/graph/ from the bible's real source tree — the discoverable entry point for the CLI's own `sync` subcommand, since a plugin user has no reason to already know that binary exists. Use whenever the author wants the Bible-graph refreshed after adding or editing entity files ("sync the bible graph", "refresh _bard/graph", "run bard sync").
---

Run `synapse-bard sync` and report its output back to the author, then, if this looks like the first
time bard has been used in this repo, offer to seed the Writer's notes vault.

## Running sync

Run `synapse-bard sync` (a `Bash` call — this is the CLI binary, not something this command
reimplements). It always does a full re-ingest: walks every top-level, non-`_`/`.`-prefixed folder for
`.md` files, clusters them, and writes one `_bard/graph/{Cluster Title}.md` per cluster, removing any
cluster node no longer produced by the source tree. It's idempotent — safe to run any time, including
when nothing changed — so there's no need to check for drift first.

Relay its own output directly: the `ingested`/`skipped (unsupported)`/`collisions`/`clusters`/`removed`
counts, plus any `skipped (...)`/`COLLISION:` lines it printed. Don't re-summarize or re-derive these
numbers — they're already exactly what happened.

If it exits non-zero because this isn't a git repository, relay that message and stop — there's nothing
to offer to seed in that case.

## Offering to seed the vault (first use only)

After a successful sync, check whether `_bard/vault/Index.md` exists (`Read` or `Glob`). If it doesn't,
this is likely the first time bard has been used in this repo — offer to seed the Writer's notes vault
from the shipped default (`${CLAUDE_PLUGIN_ROOT}/Index.md.template`), the same offer
`synapse-bard-claude.md` describes. Never copy it without asking first; seeding the vault's foundational
bootstrap file warrants a confirmation step the way an ordinary note-write doesn't. If the author
declines or the file already exists, say nothing further about it.

## Confirm

Report sync's own output, and, if offered, whether the vault was seeded.
