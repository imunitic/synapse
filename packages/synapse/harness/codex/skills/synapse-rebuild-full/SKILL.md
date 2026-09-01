---
name: synapse-rebuild-full
description: Wipe a repo's Synapse namespace and rebuild it from scratch via the synapse-init skill, for the case where diff-driven triage isn't the right tool — the graph has drifted too far, or a clean rebuild is just wanted directly. Preserves any hand-written `## Notes` content first and auto-merges what it can back into the new nodes. For ordinary same-branch drift, use the synapse-rebuild-diff skill instead — it's cheaper and never deletes a node outright.
---

# Synapse Rebuild Full: Wipe and Rebuild a Namespace From Scratch

The synapse-rebuild-diff skill triages drift node by node — reseat, patch, or re-orient — and never
deletes anything. This skill is the other tool: it deletes the current namespace outright and
rebuilds it from nothing via the synapse-init skill's own First-time-build procedure. Reach for it
when the graph has drifted past the point where triage is worth it (most nodes would land in
*re-orient* anyway), when the namespace is corrupted or was built badly, or when a clean rebuild is
simply what's wanted — never as a reflex for ordinary drift, which the synapse-rebuild-diff skill
handles more cheaply and without touching anything irreplaceable.

**Unlike the synapse-rebuild-diff skill, this skill does not care which branch is checked out beyond
the ordinary sense.** It isn't diffing against anything — it resolves `{repo}@{branch}` for
whatever's currently checked out and rebuilds *that* namespace, exactly as the synapse-init skill
does. There is no branch-identity guardrail here because there is nothing to compare against; the
branch you're on is simply the branch being rebuilt.

## When this runs

Invoked whenever the user wants a repo's Synapse namespace wiped and rebuilt from scratch — no
arguments to parse, always operates on the repo and branch containing the current working directory.

## Prerequisites

- Requires the `synapse` CLI on `PATH`. If it errors (no vault configured), say so and stop —
  same requirement the synapse-init skill has.
- Must be run from inside a git repository, on a named branch (not detached `HEAD`) — same
  requirement the synapse-init skill has, since `synapse_namespace` needs a branch to key on.

## Procedure

### 1. Resolve the namespace

Same resolution the synapse-init skill uses: repo root (`git rev-parse --show-toplevel`), namespace
key (`{repo}@{branch}`, printed by `synapse namespace`), remote (for the index note's
verification field).

Check whether `synapse/{repo}@{branch}/Index.md` exists.

- **Doesn't exist** → there is nothing to wipe. This is just a first build, not a rebuild — hand off
  directly to the synapse-init skill and stop here. Do not run the wipe step at all in this case; it
  would only fail on a directory that isn't there.
- **Exists, `remote` mismatches** → belongs to a different repo sharing this key. Same refusal the
  synapse-init skill gives in this case: stop, name both remotes, do not touch it.
- **Exists, `remote` matches** → continue to step 2.

### 2. Preview the wipe and get explicit confirmation

```sh
synapse graph-wipe --dry-run
```

Report its output plainly: node count, and — the one thing this step exists to surface — how many
nodes carry hand-written `## Notes` content that's about to be deleted, and which ones. `## Notes` is
human-authored, lives outside every generated fence, and no rebuild regenerates it; a wipe is the one
operation in this pair of skills that actually deletes files rather than overwriting them with
preservation, so it earns an explicit stop here that the synapse-rebuild-diff skill deliberately does
not have.

**Get an explicit yes before continuing.** This is a hard-to-reverse filesystem operation on content
that includes irreplaceable human prose — do not proceed past this point on an assumption, even if
the human is the one who asked for this rebuild in the first place. Asking for it signals intent to
rebuild; it is not itself confirmation of a delete that touches N nodes with hand-written notes
attached, which the human hasn't seen a number for yet.

### 3. Wipe

Once confirmed:

```sh
synapse graph-wipe
```

This deletes `synapse/{repo}@{branch}/` and, if any node had non-empty `## Notes`, first dumps that
content verbatim to `scratchpad/{repo}@{branch} — preserved notes before full rebuild.md`. See
`synapse graph-wipe`'s own header for the exact mechanics (belt-and-braces path check, same
discipline `synapse graph-clean` uses for its own deletion).

### 4. Rebuild from scratch

Run the synapse-init skill's **First-time build** procedure (its steps 1–8) against the now-empty
namespace, by reference rather than repeating it here — enumerate, read hint files, orientation pass,
cluster into `manifest.tsv`, gate, write each node, build `_index.bin`, build `Index.md`. Same
procedure, same judgment calls, nothing rebuild-specific about this phase: from the namespace's
perspective this is identical to a first build, because as of step 3 it is one.

### 5. Merge preserved notes back

Skip this step entirely if step 2 found nothing preserved (no staging note was created).

**Only once the new `Index.md` exists** — not during clustering, not node-by-node as nodes are
written. Read the staging note (`scratchpad/{repo}@{branch} — preserved notes before full rebuild.md`)
and classify each preserved note's old title + content against the finished new node list, the same
technique the synapse-init skill's `_unassigned` sweep already uses for classifying files against an
existing node list: read the note against the new summaries, judge which node it best fits.

- **Confident match** → append the note's content into that node's `## Notes` section (every node
  written by `synapse write-node` already carries one, empty if nothing else was there — never a
  "create the section" case) with a one-line provenance breadcrumb: `(carried over from "{old node
  title}" during full rebuild on {date})`. The note is losing its original context by moving to a new
  home, and that breadcrumb is the only way a future reader recovers why it's there.

  **Report the placement even though it succeeded.** Say which old node's notes went to which new
  node, for every single one, not only the ones that failed to place. A wrong auto-placement is most
  dangerous exactly when it's silent — this is the one class of content in the whole system marked
  irreplaceable, and "it succeeded" is not the same claim as "it succeeded correctly."
- **No confident match** → leave it in the staging note, and say why: no equivalent concept survived
  the re-cluster, or more than one new node looked equally plausible. Do not guess past a stated
  uncertainty here — a note in the wrong node is worse than a note sitting in scratchpad waiting for a
  human to place it.

Once every preserved note has been classified: if every one found a confident home, delete the
staging note — nothing is left needing manual attention. If any remain unplaced, leave the staging
note live containing only the leftovers, trimmed of everything that did get merged.

### 6. Report

- Old node count vs. new node count.
- Whether any notes were preserved, and the outcome of every single one from step 5 (merged where, or
  left for manual placement and why) — not just a summary count.
- If the staging note still exists, say so explicitly and give its path — it needs a human look.

## Guardrails

- **Never wipe without running `--dry-run` first and getting explicit confirmation on its output.**
  The preview step exists specifically so "how many notes are about to be deleted" is answered before
  it happens, not after.
- **Never invent a placement for a preserved note that isn't a confident match.** Leaving it in
  scratchpad, flagged, is the correct outcome when nothing else is — don't fill the gap with a guess
  to make the report look cleaner.
- **Never merge into a node's generated region.** The merge target is always `## Notes`, appended, never
  touching anything inside the `<!-- synapse:generated:start -->`…`<!-- synapse:generated:end -->`
  fence — that region belongs to `synapse write-node` alone.
- **Never treat this as the default repair path.** The synapse-rebuild-diff skill is cheaper,
  preserves every node rather than deleting them, and is the right tool for ordinary drift. Use this
  skill when triage genuinely isn't worth it, not as a heavier habit that replaces the lighter one.

## Integration

- Delegates the actual rebuild to the synapse-init skill's First-time-build procedure — this skill
  owns only the wipe-with-preservation step before it and the note-merge step after it.
- The wipe itself is `synapse graph-wipe` (via `synapse graph-wipe`), mirroring
  `synapse graph-clean` as the only other destructive tool in the system.
- Resolves the namespace the same way the synapse-init and synapse-rebuild-diff skills do -- one
  chain, in `core/identity.zig` — never re-derives repo/branch/remote independently.
