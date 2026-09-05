---
description: Run synapse-bard sync to (re)populate _bard/graph/ from the bible's real source tree — the discoverable entry point for the CLI's own `sync` subcommand, since a plugin user has no reason to already know that binary exists. Use whenever the author wants the Bible-graph refreshed after adding or editing entity files ("sync the bible graph", "refresh _bard/graph", "run bard sync").
---

Run `synapse-bard sync` and report its output back to the author.

## Running sync

Run `synapse-bard sync` (a `Bash` call — this is the CLI binary, not something this command
reimplements). It always does a full re-ingest: walks every top-level, non-`_`/`.`-prefixed folder for
`.md` files, clusters them, and writes one `_bard/graph/{Cluster Title}.md` per cluster, removing any
cluster node no longer produced by the source tree. It's idempotent — safe to run any time, including
when nothing changed — so there's no need to check for drift first. On the first run in a repo, it also
seeds `_bard/vault/Index.md` from the shipped template on its own, with no confirmation needed —
running sync at all is the author's explicit signal the vault should exist.

Relay its own output directly: the `ingested`/`skipped (unsupported)`/`collisions`/`clusters`/`removed`
counts, plus any `skipped (...)`/`COLLISION:` lines it printed, and the `seeded .../Index.md (first
use)` line when present. Don't re-summarize or re-derive these numbers — they're already exactly what
happened.

If it exits non-zero because this isn't a git repository, relay that message and stop.

## Confirm

Report sync's own output.
