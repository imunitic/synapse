---
description: Print a read-only report of what in Synapse Vault currently needs a human decision -- design notes still Discussing, design notes marked Ready with no compiled task yet, Ready design notes with open questions still outstanding, task notes with unchecked items, and task notes stuck in REVIEW. Use whenever the user wants a status check on the vault ("what's outstanding", "what needs my attention", "vault status", "what did we leave open"). Never modifies anything -- a report only, not a task-management action. Not for creating, continuing, or listing a specific note kind (that's synapse-note/synapse-design-note/synapse-task-note's own --list modes) -- this is the one cross-cutting view over all of them at once.
---

# Synapse Status: Vault-Wide Attention Report

A read-only sweep over Synapse Vault answering one question: what currently needs a human decision?
Five categories, one pass, printed as plain chat text -- an org-agenda-style check-in, not a document
to hand to someone else and not a live dashboard (a published Artifact has no route to the vault, so
nothing here is ever presented that way). Run it on demand, or from a scheduled `/loop`/cron
invocation of this same command -- never wired into `SessionStart`: some of the five categories need
a per-note content read, not just a frontmatter check, and unlike `Index.md` this report is a
periodic human check-in, not something the agent needs injected every session to behave correctly.

Scoped to `designs/`/`tasks/` only -- the two folders `/synapse-design-note`/`/synapse-note --task`
structurally require, so every Synapse install has them in the same shape. The free-form taxonomy
(`inbox/`/`research/`/`scratchpad/`) is per-install customizable (see `Index.md`), not guaranteed to
exist or mean the same thing across installs, and `inbox/` specifically is for the vault owner's own
periodic look on their own schedule -- this report doesn't cover it.

## Usage

```
/synapse-status    # Print the current vault status report
```

## Prerequisites

Requires the `synapse` CLI on `PATH`. Backend-agnostic -- every query below goes through `synapse
vault-search`, so it works the same regardless of which `Store` backend is configured. If the
CLI errors (no vault configured), say so and stop -- there is no other fallback.

## Producing the report

Run each query below via `synapse vault-search --fields <fields>`, with the JsonLogic query on stdin.
`--fields` asks for exactly the columns the query needs back -- no separate read per match required,
since a matched row already carries them.

**1. Design notes still `Discussing`.** Design notes carry status in-body under `## Status`, not in
frontmatter (unlike task notes) -- a content match, scoped to `designs/`. Needs the title and the
note's own `note_id` (every design note gets one, minted by `/synapse-design-note` itself):

```
synapse vault-search --fields frontmatter.title,frontmatter.note_id <<'EOF'
{"and": [
  {"glob": ["designs/*", {"var": "path"}]},
  {"regexp": ["## Status\nDiscussing", {"var": "content"}]}
]}
EOF
```

**2. `Ready` design notes with no compiled task yet.** `/synapse-task-note`'s own "Linking back"
step patches a compiled design note with a `> Compiled task: [[...]]` line right after its title --
"`Ready` and missing that line" is a direct signal, not fuzzy title-matching against `tasks/`. Needs
the title and `note_id`:

```
synapse vault-search --fields frontmatter.title,frontmatter.note_id <<'EOF'
{"and": [
  {"glob": ["designs/*", {"var": "path"}]},
  {"regexp": ["## Status\nReady", {"var": "content"}]},
  {"!": [{"regexp": ["Compiled task:", {"var": "content"}]}]}
]}
EOF
```

**3. `Ready` design notes with a non-empty `## Open Questions`, excluding ones whose compiled task is
already `DONE`.** Match the heading followed by at least one bullet -- a heading with nothing under
it (fully pruned, per the Ready-gate convention `/synapse-design-note` now follows) doesn't count as
open. A `Discussing` note with open questions isn't actionable yet (it's still being worked out in
conversation, surfaced already by query 1), and a note whose compiled task has already shipped is
stale noise -- so this query narrows to the two states that actually need a human decision: `Ready`
with open questions and no compiled task, or `Ready` with open questions and a compiled task that
hasn't reached `DONE`. `vault-search` has no cross-note join, so this takes two queries: the first
finds `Ready`-with-open-questions design notes and pulls each one's compiled-task title (if any)
straight out of its own `content`; the second resolves those titles' status against `tasks/`.

```
synapse vault-search --fields frontmatter.title,frontmatter.note_id,content <<'EOF'
{"and": [
  {"glob": ["designs/*", {"var": "path"}]},
  {"regexp": ["## Status\nReady", {"var": "content"}]},
  {"regexp": ["## Open Questions\n- ", {"var": "content"}]}
]}
EOF
```

For each match, pull the target of a `> Compiled task: [[...]]` line out of its `content`, if present
-- parsed straight out of the wikilink text rather than resolved through any vault-wide link index.
Collect the distinct compiled-task titles found across all matches. If none of the matches have a
`Compiled task:` line, skip the second query entirely -- every match stays in (no compiled task means
the "either" branch is already satisfied). Otherwise, resolve those titles' status in one follow-up
call:

```
synapse vault-search --fields frontmatter.title,frontmatter.status <<'EOF'
{"and": [
  {"glob": ["tasks/*", {"var": "path"}]},
  {"in": [{"var": "frontmatter.title"}, ["{title one}", "{title two}"]]}
]}
EOF
```

Keep a match from the first query only if it has no `Compiled task:` line, or its compiled task's
title isn't found in the second query's results with `frontmatter.status` equal to `DONE` -- a title
the second query didn't return at all (a stale or broken link) counts as "not `DONE`" and stays in,
since a broken link is itself worth a human noticing rather than a reason to drop the note silently.

A `regexp` pattern containing a literal newline (`\n`) must be written with a single backslash, byte-
for-byte, in the JSON text piped to `vault-search` -- the heredocs above are unquoted-delimiter
(`<<'EOF'`), so nothing here re-escapes it; `\\n` would reach the JSON parser as a literal backslash
followed by `n`, never matching a real line break, and every `regexp` query in this command would
silently stop finding anything under a multi-line pattern.

**4. Open task notes with at least one unchecked item.** Task notes carry `status:` in frontmatter,
unlike design notes -- filter there first, and request `content` to count `- [ ]` lines directly from
the row rather than reading each match again. `task_id` is already frontmatter on every task note, no
extra minting step needed:

```
synapse vault-search --fields frontmatter.title,frontmatter.task_id,content <<'EOF'
{"in": [{"var": "frontmatter.status"}, ["TODO", "IN-PROGRESS"]]}
EOF
```

A match with zero unchecked lines (a checklist that's fully checked but hasn't been promoted to
`REVIEW` yet) is still worth surfacing -- report it under this section with its count shown as 0,
rather than silently dropping it, since that state itself is worth a human noticing.

**5. Task notes stuck in `REVIEW`.** Frontmatter-only, no body needed -- a fully-checked checklist
waiting specifically on human sign-off, since `synapse-task` deliberately never promotes a note past
`REVIEW` on its own:

```
synapse vault-search --fields frontmatter.title,frontmatter.task_id <<'EOF'
{"==": [{"var": "frontmatter.status"}, "REVIEW"]}
EOF
```

## Composing the report

One section per category, in the order above. Each line leads with the note's own id in brackets
(`note_id` for a design note, `task_id` for a task note) — the whole point of every note now carrying
one is that a human can act on a line directly ("open sb-068") without the title as an intermediate
step — followed by the title, plus whatever other identifying detail that category needs. A note
somehow missing its id (pre-dates the field, or the backfill hasn't reached it yet) drops the bracket
entirely rather than printing an empty one, the same graceful-degradation the title-less case already
gets. Every section's heading already implies status now (the "Discussing" section only ever holds
`Discussing` notes, "Open questions" only ever holds `Ready` ones per query 3 above), but Open
questions still spans both compiled and uncompiled notes, so its line also names the compiled task
(or says there isn't one) -- the one piece of state that section doesn't already imply:

```
## Discussing
- [{note_id}] {title}

## Ready, not yet compiled
- [{note_id}] {title}

## Open questions
- [{note_id}] {title} — {compiled task title, or "not compiled"}

## In progress (unchecked items)
- [{task_id}] {title} ({N} unchecked)

## Awaiting review
- [{task_id}] {title}
```

Omit a section entirely when it has zero matches -- matching `/synapse-note --list`'s own convention
of leaving out empty headers -- rather than printing five headers with nothing under most of them. If
every category is empty, say so in one line ("Vault is clear -- nothing outstanding.") instead of five
empty headers.

Print the report directly in the response, not left only in tool-call output the user would have to
go dig for.

## Constraints

- Read-only end to end. Never calls `vault-write`/`vault-patch` -- if a step here ever seems to need
  one, that step is out of scope, not a case to special-case around.
- No Artifact/web-UI output. No `SessionStart` wiring. Not a new binary CLI subcommand -- every
  category above is a plain mechanical query already reachable through `synapse vault-search`.
- Scoped to `designs/`/`tasks/` only -- never `inbox/`/`research/`/`scratchpad/`.
