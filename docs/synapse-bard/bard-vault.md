# Writer's notes vault: repo-local, from the start

While an author and a writing agent iterate on a scene, they make decisions that have nothing to do
with [the Bible-graph](bard-graph.md)'s structured facts — tone choices, deferred plot resolutions,
phrasing preferences, "we're not resolving X until book 2" — but are exactly the kind of context a
session shouldn't have to silently re-derive or lose. `_bard/vault/` is where that free-form,
decision-level layer lives: plain markdown files, git-tracked, in the same repo and session already
in use for everything else.

![One hook, not four](diagrams/bard-vault-overview.png)

## Why repo-local, and not an Obsidian vault like Synapse's own

[Synapse Vault](../synapse/synapse-vault.md) is a single, cross-project Obsidian instance reached over its
Local REST API — durable exactly because it's *not* tied to any one repo. That design assumes the
session running Claude Code can reach a REST API on the vault owner's own machine — a route
`_bard/vault/`'s primary execution environment doesn't have: the Android app's default cloud
session is an Anthropic-managed VM with no network route to anything on the author's own machine
at all. An externally-hosted vault is exactly the one thing that execution mode can never reach.

So `_bard/vault/` is a second `Store` implementation of the same port `_bard/graph/` already
uses (`ports.Store` — `read`/`write`/`list`/`search`), backed by a plain directory instead of an
HTTP API. No Obsidian, no REST API, no cert, no network dependency in any execution environment the
repo gets cloned into — the same property [Bible-graph](bard-graph.md) already had, now shared
rather than being the one component that didn't have it. Opening `_bard/vault/` in Obsidian on a
desktop remains available purely as a human browsing convenience; the agent's own reads and writes
never depend on it being open, or existing at all.

## Folder layout

Notes live in subdirectories, unlike the graph's flat `_bard/graph/{Cluster}.md` layout — the same
five-folder taxonomy [Synapse Vault](../synapse/synapse-vault.md#folder-layout) uses maps onto fiction writing
with minimal reinterpretation (`projects/` → per-book/scene iteration logs, `research/` →
worldbuilding research, `designs/` → story/plot design discussions, `scratchpad/`/`inbox/`
unchanged), but nothing beyond `designs/`/`tasks/` is pre-created — the writing agent grows the rest
organically through actual use, same as the coding vault's own bootstrap. `Index.md` at the vault
root is the one file excluded from every listing and search — bootstrap, not a note.

## The one hook: `SessionStart`

Gated on `_bard/` already existing at the repo root — nothing here creates it, so its absence means
bard has never been deliberately used in this repo. A repo with no fiction bible at all, the plugin
merely installed, gets no injection at all.

Once `_bard/` exists, `synapse-bard-hook session-start` injects two pieces, joined with a blank
line, nothing emitted at all if both are empty: the plugin's own standing instructions
(`synapse-bard-claude.md`) and `_bard/vault/Index.md` itself, so its folder layout is live
information from turn one. If no `Index.md` exists yet — a repo where `synapse-bard sync` created
`_bard/graph/` but the vault side was never touched — the hook offers to seed one from the plugin's
shipped `Index.md.template` rather than writing it unasked — the same "offer, don't seed" rule the
coding side's `SessionStart` hook follows.

Much simpler than [Synapse Vault's four hooks](../synapse/synapse-vault.md#the-four-hooks), and deliberately
so: `_bard/vault/` is always repo-relative, so there's no external `synapse.conf`/
`SYNAPSE_VAULT_DIR` to resolve, no cross-repo namespace to catalogue, no remote to verify before a
write. There's also, as of this writing, no `Stop`-hook nudge, no per-prompt injection, and — the
one gap worth naming plainly — **no auto-commit hook**. `_bard/vault/` is git-tracked the same as
any other part of the repo, but nothing commits it automatically the way the coding vault's own
`db-sync` hook does. An uncommitted mistake here is only as recoverable as the session's own file
history or a human's deliberate `git commit`; a committed one is one `git show <sha>:<path>` away,
same as any other tracked file. If a destructive edit is about to happen and nothing's been
committed recently, that's worth saying before proceeding, not after.

## `vault-search` / `vault-links`: resolving wikilinks the way Obsidian does

Both close the same gap: `Grep` can string-match `[[note-name` but can't tell a real link from a
coincidental substring, doesn't resolve an aliased `[[note-name|display text]]` link at all, and has
no notion of *rank* or *direction*. `BardVaultStore` resolves links the same way Obsidian itself
does — by the **target's filename stem**, `.md` suffix optional, alias text after a `|` ignored —
and both commands are thin CLI doors onto that resolution:

```
synapse-bard vault-search <query>    full-text over _bard/vault/, ranked by backlink count
synapse-bard vault-links <note>      every note that links to <note>
```

**`vault-search`** is an exhaustive substring scan — no embeddings, no maintained index, refreshed
cheaply on every read rather than kept warm by a daemon, since a book bible's whole vault is well
inside grep-speed territory. What makes it more than `Grep` is the ranking: hits sort by how many
*other* notes link to the matching note (most-linked first, node path ascending as a deterministic
tiebreak), the same "in-edge coupling" idea the
[Graft project](https://github.com/NanoNets/Graft)'s own ranking uses for a code graph, applied here
to a wikilink graph instead of a call graph. A note with zero backlinks that still matches the query
is still returned — backlink count is a rank, not a filter.

**`vault-links`** answers "which notes link *here*" directly, the vault-side equivalent of the
graph's own `query --inbound`. It takes either a full vault-relative path or just a bare stem — both
`"designs/synapse-bard/Bible-graph.md"` and `"Bible-graph"` resolve to the same note, the same
flexibility a `[[wikilink]]` target itself has. Returns `null` (reported as "no note by this name")
for a target that resolves to nothing at all, distinct from a real, empty answer for a note that
genuinely has zero inbound links — the caller needs to tell "wrong name" apart from "correctly
unlinked."

Both exclude a note linking to itself — no self-backlink, matching what "backlink" means in
Obsidian's own panel — and both dedupe a note that links the same target more than once down to one
count, since three mentions from the same source is still one linking note, not three.

## Design → task workflow, adapted

`synapse-bard-note` / `synapse-bard-design-note` / `synapse-bard-task-note` / `synapse-bard-task`
fork [Synapse's own design→task workflow](../synapse/design-task-workflow.md) with fiction-specific wording and
examples throughout — characters, scenes, plot decisions — rather than a genericized,
audience-neutral version shared between both plugins. These are natural-language guidance files
that shape how an agent talks about its own behavior, not runtime logic; a shared "principles" layer
would force blander wording that serves a novelist's agent worse, for a maintenance saving that's
low-value anyway since human-reviewed prose rarely drifts the way shared code does.

Two real adaptations, not word-for-word ports:

- **No project-prefix machinery.** Synapse's originals resolve a project via
  `synapse-projects.conf` because one Obsidian vault serves many coding repos at once;
  `_bard/vault/` is always single-project (one repo, one book), so a task ID is a plain sequential
  `task-001` and a design note carries no `project:` frontmatter field at all.
- **No Obsidian MCP tools.** `_bard/vault/`/`_bard/graph/` are plain files in the same repo and
  session already in use, so these skills use `Read`/`Write`/`Edit`/`Glob`/`Grep` directly, plus
  `vault-search`/`vault-links` above where those beat a raw grep. There's no partial-patch API to
  have hazards in either — `Write`/`Edit` are always whole-file or exact-string, so the
  frontmatter-reserialization and nested-heading-path footguns the coding vault's own docs warn
  about simply don't exist here.

The one piece that stayed **shared code, not shared prose**: the task status-transition rule
(`TODO → IN-PROGRESS → REVIEW`, never straight to `DONE`) lives once, in `core.task_status`, and
both `synapse-task` and `synapse-bard-task` call it — a real rule needing to stay identical across
both plugins is a different thing from wording that's better fiction-flavored on one side.
