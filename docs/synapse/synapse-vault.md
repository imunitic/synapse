# Synapse Vault

A permanent, curated knowledge base — an Obsidian vault — that persists across every project and
every session, separate from (and complementary to) Claude Code's own `~/.claude` auto-memory
system. Auto-memory is for *how to work with this user*; the Vault is for durable, browsable notes
about the work itself.

It is also the host for [Synapse Graph](synapse-graph.md), which stores its per-repo code graphs here as
ordinary notes under `synapse/{repo}@{branch}/` rather than in a folder of their own. One store, one
search, one sync concern.

![Synapse Vault overview](diagrams/synapse-vault-overview.png)

The boxes name the four hooks; what each one does is here rather than crammed inside the box.

| Hook | Fires | What it does |
|---|---|---|
| `synapse-hook session-start` | `SessionStart` | Injects `Index.md`, this repo's Graph pointer if a namespace covers the current branch, and a catalogue of the other namespaces in the vault. A plain path lookup — never a model call, so a repo that never opted in pays nothing. |
| `synapse-hook prompt-context` | `UserPromptSubmit` | One fixed standing line per turn naming the Graph/Code Cache tools available for a repo with a namespace -- no search, no node list, no network. Set `SYNAPSE_DISABLE_PROMPT_INJECTION` to skip it. |
| `synapse-hook stop-nudge` | `Stop`, every 25 turns | Forces a real "did anything here belong in the vault?" check-in rather than relying on the agent to remember unprompted. Also pushes the vault to its git remote every `SYNAPSE_VAULT_PUSH_EVERY` turns (default 5), detached so the turn never waits on the network. |
| `synapse-hook db-sync` | `PostToolUse` | Commits vault changes to the vault's own git history on any vault-modifying write. That history is what makes a destructive mistake recoverable. |

## The vault

A regular Obsidian vault, running headless at login with the **Local REST API** plugin installed.
That plugin is the only valid way anything here talks to the vault — hooks call it directly over
HTTP (they're plain scripts, not agent turns), and Claude Code talks to it through the `obsidian`
MCP server, which just wraps the same API. Nothing here assumes a fixed vault path; the API always
targets whichever vault the running Obsidian instance currently has open.

`~/.claude/synapse.conf` holds the one piece of genuinely machine-local state:
`OBSIDIAN_VAULT_DIR`, used only as a fallback for grepping the vault as plain files if the MCP
tools are ever unreachable.

## Folder layout

Every note lands in one of these, chosen by what kind of thing it is, not what project it's about:

| Folder | What goes there |
|---|---|
| `tasks/` | Concrete, tracked tasks — created only via `/synapse-task-note` or `/synapse-note --task`, never freeform |
| `research/` | General research on a topic, project-related or not |
| `scratchpad/` | High-churn notes iterating on whether an idea works at all, not yet worth filing anywhere else |
| `inbox/` | Needs more input or reflection before it's settled, or otherwise doesn't cleanly fit the others — reviewed periodically, meant to stay small |
| `designs/` | Cross-project design discussions, already agreed rather than tasks that execute them (see [design-task-workflow.md](design-task-workflow.md)) |
| `synapse/` | Per-repo code-graph namespaces: node notes plus the machine-only `_manifest.tsv` and `_profile.txt`. The reverse index and the caches are not here -- they are derived and live in the work dir (see [synapse-graph.md](synapse-graph.md)) |

Folder depth is capped at two levels. A new top-level folder requires adding a matching section to
the vault's own `Index.md` in the same action — the index is agent-maintained and must never fall
behind what's actually on disk.

## Filenames and frontmatter

Filenames are the human-readable title itself — no timestamp prefix, no slug — since Obsidian's
sidebar and graph view show the filename directly. Frontmatter carries what the filename doesn't:
`title`, `created`, and for task notes `task_id`/`status`.

## The four hooks

Nothing here runs on a schedule; everything is triggered by an actual session event.

**`SessionStart` → `synapse-hook session-start`**
Injects the vault's top-level `Index.md` into context at the start of every session, so its
contents are live information from turn one rather than something Claude has to remember to go
read. Also does two extra cheap checks. It resolves the current repo (if any) and appends a pointer to a
matching Synapse namespace, if one exists and its `remote` field actually matches this repo. And it
lists every *other* namespace in the vault as a `name | remote` catalogue, because one session
routinely spans several repos and without it only the starting repo's graph is ever announced. Both
are derived per session and stored nowhere — see [synapse-graph.md](synapse-graph.md) for the detail.

**`UserPromptSubmit` → `synapse-hook prompt-context`**
One fixed standing line per turn, in a repo with a namespace: the graph exists, here are the tools
that read it. No search, no node list, no network — a per-turn nudge that survives context
compaction, unlike a `SessionStart` injection. Names the Graph and the Code Cache separately, each
announced only when actually present. `SYNAPSE_DISABLE_PROMPT_INJECTION` (any value) disables it.
See [synapse-graph.md](synapse-graph.md#what-every-prompt-is-told) for why this replaced an earlier
per-prompt search.

**`Stop` → `synapse-hook stop-nudge`**
A turn-count-based nudge, firing every 25 turns, asking: *did anything in this stretch belong in
the Vault and not get written down?* This exists because "remember to write notes" is
exactly the shape of standing instruction that's easy to silently forget under task pressure — a
periodic, mechanical prompt is more reliable than trusting recall alone.

The same hook also pushes the vault to its git remote every `SYNAPSE_VAULT_PUSH_EVERY` turns
(default 5, only if the vault has a remote configured at all) — piggybacked here rather than on
`db-sync` because `Stop` is the only one of the five events that fires once per turn rather than
once per tool call, and because it already carries a turn counter to key the interval off. The
push itself runs detached (`synapse-hook vault-push`, spawned and not waited on) so a turn never
stalls on the network; a failure is logged to `.git/synapse-push.log` inside the vault rather than
surfaced mid-turn.

**`PostToolUse` → `synapse-hook db-sync`**
Fires on every vault-modifying MCP call (`vault_write`/`patch`/`append`/`delete`/`move`) and, if
the vault itself is a git repo, commits the change immediately. This is what makes the vault's own
history a usable audit trail of every note ever written or edited, without anyone having to
remember to commit it themselves.

## The standing instruction

The behavioral half of this system lives in `npm-pkg/synapse-claude.md`, injected directly by the
`SessionStart` hook (`synapse-hook session-start`) into every session's context — the same
mechanism that injects `Index.md`, not a `CLAUDE.md` `@import` line. The hook reads
`$CLAUDE_PLUGIN_ROOT/synapse-claude.md` when running as a Claude Code plugin, or
`$SYNAPSE_CONTENT_ROOT/synapse-claude.md` when installed via npm (`synapse-setup configure claude`
sets it), falling back to a path resolved relative to its own binary otherwise. `~/.claude/CLAUDE.md`
is never touched — it stays entirely
the user's own file, with nothing shipped into it to drift out of sync. Its core claim: this is
a *primary* memory system, not an optional nicety, and specific triggers (a non-trivial bug fixed,
a stated preference or decision, a milestone, research worth not redoing, a note gone stale)
obligate writing or updating a note without waiting to be asked. Linking to existing related notes
is called out as the highest-priority step — before creating anything new, search first — and a
note that's outgrowing its own scope should be split rather than left to sprawl.
