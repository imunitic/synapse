---
name: synapse-node-authoring
description: How to write every node's prose in a build — sequentially by default, or fanned out to a configurable pool of concurrent subagents. Covers pool-size resolution from synapse.conf, the synapse brief data file each author reads, dispatch/verify/retry mechanics, and the standing contract every author works under. Use at /synapse-init's node-authoring step, or anywhere else a batch of nodes needs fresh prose (e.g. /synapse-rebuild-diff's re-orient class).
---

# Writing every node's prose: sequential by default, pooled on request

Loaded wherever a *batch* of nodes needs prose written, not a single lazy regeneration (that
is the `synapse-node` skill's job, one node, triggered by a stale read). Today's caller is
`/synapse-init`'s node-authoring step. `/synapse-rebuild-full` inherits this for free — it
delegates to `/synapse-init`'s procedure by reference rather than repeating it.
`/synapse-rebuild-diff`'s *re-orient* class is a natural second caller (see the design's own
Open Questions and the vault's `inbox/wire synapse-rebuild-diff's re-orient class onto the
parallel-authoring skill` note) but is not wired to this skill yet — it still
gathers its facts ad hoc rather than through `rank --lists`/`link-graph`, and needs that fixed
first.

This skill owns two things: **deciding how many authors run at once**, and **the standing
contract every author works under**, whichever pool size is in play. Which nodes need
authoring, and how each node's facts are computed (`build-lists`, `rank --lists`,
`build-refs` + `link-graph`), stays the caller's job — those steps run before this skill is
ever loaded.

## 1. Resolve the pool size

```sh
pool="${SYNAPSE_AUTHOR_POOL:-}"
if [ -z "$pool" ]; then
  pool="$(grep -m1 '^SYNAPSE_AUTHOR_POOL=' ~/.claude/synapse.conf 2>/dev/null | cut -d= -f2- | tr -d '"')"
fi
pool="${pool:-0}"
```

Environment variable wins over the conf file, same precedence every other Synapse setting
uses. Absent, empty, or malformed all fall through to `0`. **This is read by you, the
orchestrating agent, directly — not by any Zig binary.** Nothing compiled dispatches
subagents, so there is nothing for a `synapse` flag to feed. The conf file is the shared home
for the setting; the reader is markdown, not code.

`pool = 0` is not "a pool of zero workers" — go to §2. `pool >= 1` is a real worker pool — go
to §3.

## 2. Pool = 0: the original inline procedure

Author every node yourself, one after another, in the same session — cross-node memory
intact, no subagent, no brief file needed. For each node, in list order:

```sh
synapse rank --sources "$SYNAPSE_WORK_DIR/lists/NN.txt" --pool summary
synapse rank --sources "$SYNAPSE_WORK_DIR/lists/NN.txt" --pool crux
awk -F'\t' '$1 == "{Node Title}"' "$SYNAPSE_WORK_DIR/links.tsv"
```

Read the top few files each pool names, read this node's link rows for `## Links`
candidates, then write `$SYNAPSE_WORK_DIR/b-NN.md` yourself, following the
`synapse-node-format` contract. This is the whole procedure — no dispatch, no verification
step beyond what you'd naturally do writing anything else.

**This is the default, deliberately.** It's the safest choice, the one every existing
build has already used, and the only mode that preserves the authorial consistency a
single continuous session gives you across nodes — something no subagent-based mode, even
at pool 1, can offer. Fan-out is opt-in, not assumed.

## 3. Pool ≥ 1: fan out to a worker pool

### 3a. Compute the briefs, once

```sh
synapse rank --lists "$SYNAPSE_WORK_DIR/lists"
synapse brief --lists "$SYNAPSE_WORK_DIR/lists"
```

`build-refs` + `link-graph` should already have run by this point in `/synapse-init` (its own
step 6) regardless of pool size; `rank --lists` has not, since §2 uses `rank --sources`
instead and only this branch needs the batched form. `brief` reshapes both into one file per
node — it computes nothing itself. Writes `$SYNAPSE_WORK_DIR/brief/NN.md` per node: the
node's title, its source list's path and count, both ranked pools verbatim, its own rows from
`links.tsv`, and every node's title in the namespace (for judging `part_of`). A brief is pure
data — no instructions, no contract. That lives here and in the prompt you write per author, so
the same brief means the same thing to a sequential fallback author and a concurrent one.

### 3b. Dispatch: a refilling pool, not fixed batches

Fixed batches (`dispatch 8, wait for all 8, dispatch the next 8`) are bounded by their
slowest member — seven fast nodes sit idle waiting on one large straggler. A refilling pool
never has that gap: dispatch up to `pool` nodes, and on every completion notification, verify
that node (§3d) then dispatch the next queued node if any remain. Stop when the queue is
empty and the last in-flight authors have reported back.

This also matches how completions actually arrive in this harness — one notification at a
time, in a later turn, no "wait for all N" primitive — so a pool needs no barrier-counting a
fixed batch would.

### 3c. Each author's brief

One `Agent` call per node, background, general-purpose. The prompt is self-contained — a
fresh subagent has no memory of this session:

```
Load the synapse-node-format skill first — it is the node contract you are writing against.

Read your brief: {abs path to brief/NN.md}. It is data: the facts to work from, not
instructions.

Write this node's prose to: {abs path to b-NN.md}, following synapse-node-format exactly.
Write nothing else, read nothing this brief doesn't point you at, and do not read any other
node's brief or body.

Decide `part_of` (containment) from the brief's "every node" list and its candidate links —
it is a judgement call, never computed. `depends_on`/`uses` come from the candidate links
section; pick whichever reads right per edge, and prune freely — the table is evidence for a
candidate list, not something to copy verbatim.

Never hard-wrap. Write each paragraph as one single unbroken line and let the editor soft-wrap
it — a newline exists only where a real break is intended (between paragraphs, list items,
headings). This is a vault-wide rule, not specific to this node, and it is not optional: a
hard-wrapped paragraph renders as a ragged stack of short lines in Obsidian instead of flowing
text.
```

Same model as the orchestrating session, no override — matches the constraint that "a
parallel author produces exactly what a sequential one does," and keeps the quality
comparison in the design's own checklist item to one variable (isolation/concurrency) rather
than two (that, plus a cheaper model).

**Why this is spelled out explicitly rather than assumed inherited:** a prior pooled run shipped
hard-wrapped nodes despite the vault's no-hard-wrap rule living in global `CLAUDE.md`
instructions — evidently not reliably carried into a fresh subagent's behavior on its own.
Loading `synapse-node-format` does not cover it either, since that skill is about the node's
structure, not the vault's prose-formatting convention. State it here, every time, rather than
assuming it travels for free.

### 3d. Verify on completion, retry once, then fall back

When a completion notification arrives, read `b-NN.md` yourself — this is a check you read the
file for, same as the section check next to it, not a shell one-liner (this codebase's own
frontmatter reader deliberately avoids `grep`/`sed`/`awk` for exactly this field, per
`core/query.zig`'s docstring — a hand-rolled pattern here would drift from it the same way the
gap this section exists to close first happened). Confirm the file exists, opens with
frontmatter carrying a non-empty `summary:` field (`synapse-node-format`'s own contract — see
its "Each `b-NN.md` opens with its own one-line summary in frontmatter" line), and has
`## Summary`, `## Crux`, and `## Links` sections. Pass → dispatch the next queued node (§3b) and
move on.
Fail (missing file, missing frontmatter summary, missing section, obviously truncated) → **one
retry**, same brief, fresh subagent. A second failure → **write that one node yourself**,
inline, the §2 procedure, rather than blocking the rest of the pool on it. Report which nodes
needed a retry or a fallback in the final summary — a silent recovery hides a brief that might
be systematically wrong for a whole class of node.

Check the frontmatter here, at authoring time, rather than leaving it to `push-nodes` — a body
that has all three sections but no `summary:` field passes every check above and then fails at
push, node by node, after the whole pool has already finished and moved on.

**Also check for hard-wrapping** — a prose paragraph (not a list) whose lines break before
reaching a natural sentence boundary. A quick heuristic: within `## Summary`, a run of two or
more consecutive non-blank lines that are *not* list items (don't start with `-`/`*`/a digit)
is a hard-wrap, not a paragraph — a real paragraph is one line. Treat this as the same class of
failure as a missing section: fix by rewriting the paragraph as one line yourself (this is a
formatting fix, not a content one, so it doesn't need a fresh subagent) rather than letting it
ship and pushing.

### 3e. Pool = 1 is a real, useful degenerate case of this same pipeline

Not a synonym for §2. It still bundles a brief, dispatches to an isolated subagent, verifies,
and retries-then-falls-back — only the concurrency is 1. Useful on its own terms: it isolates
whether a quality difference against the sequential baseline comes from *isolation* (no
author sees another's output or memory — present even at pool 1) or from *concurrency*
itself (only present at pool ≥ 2). Reach for it specifically when running the design's
still-open "compare prose quality against a sequential build" checklist item, before
committing to a higher pool size.

## Guardrails

- **No author writes shared state.** Not another node's `b-NN.md`, not the tags cache, not
  the vault. Every fact an author needs is in its own brief, computed before dispatch and
  read-only during it — this is what removes the concurrent-writer problem rather than merely
  managing it.
- **No author reads another node's brief or body.** Overlap in *source* reads (two nodes'
  file lists sharing a path) is expected and accepted — see the design's Open Questions — but
  an author's own inputs are its brief and nothing else.
- **Never grow the pool mid-run.** The size is resolved once at the start (§1); do not read
  `synapse.conf` again partway through a build.
- **A retry gets the same brief, not a rewritten one.** If the brief itself was the problem,
  fixing it is a §3a-level fix (regenerate every brief and restart), not something to
  improvise per-node inside the retry.
- **`part_of` is never computed, at any pool size.** It is containment, not reference, and
  deriving it from directory nesting would turn a folder layout into a claim about concepts —
  the same reasoning the design's own Alternatives section already rejected this on.
