---
description: Print a read-only report of what in Synapse Vault currently needs a human decision -- design notes still Discussing, design notes marked Ready with no compiled task yet, design notes with open questions, task notes with unchecked items, and task notes stuck in REVIEW. Use whenever the user wants a status check on the vault ("what's outstanding", "what needs my attention", "vault status", "what did we leave open"). Never modifies anything -- a report only, not a task-management action. Not for creating, continuing, or listing a specific note kind (that's synapse-note/synapse-design-note/synapse-task-note's own --list modes) -- this is the one cross-cutting view over all of them at once.
---

# Synapse Status: Vault-Wide Attention Report

A read-only sweep over Synapse Vault answering one question: what currently needs a human decision?
Five categories, one pass, printed as plain chat text -- an org-agenda-style check-in, not a document
to hand to someone else and not a live dashboard (a published Artifact has no route to the local
Obsidian REST API, so nothing here is ever presented that way). Run it on demand, or from a
scheduled `/loop`/cron invocation of this same command -- never wired into `SessionStart`: two of
the five categories need a per-note body read, not just a frontmatter check, and unlike `Index.md`
this report is a periodic human check-in, not something the agent needs injected every session to
behave correctly.

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

Requires the `obsidian` MCP server (`mcp__obsidian__*` tools). If unreachable, say so and stop --
there is no local-file fallback.

## Producing the report

Run all five queries in parallel where the tool call shape allows it; none depends on another's
result.

**1. Design notes still `Discussing`.** Design notes carry status in-body under `## Status`, not in
frontmatter (unlike task notes) -- a content match, scoped to `designs/`:

```
{"and": [
  {"glob": ["designs/*", {"var": "path"}]},
  {"regexp": ["## Status\\nDiscussing", {"var": "content"}]}
]}
```

**2. `Ready` design notes with no compiled task yet.** `/synapse-task-note`'s own "Linking back"
step patches a compiled design note with a `> Compiled task: [[...]]` line right after its title --
"`Ready` and missing that line" is a direct signal, not fuzzy title-matching against `tasks/`:

```
{"and": [
  {"glob": ["designs/*", {"var": "path"}]},
  {"regexp": ["## Status\\nReady", {"var": "content"}]},
  {"!": [{"regexp": ["Compiled task:", {"var": "content"}]}]}
]}
```

**3. Design notes (any status) with a non-empty `## Open Questions`.** Match the heading followed by
at least one bullet -- a heading with nothing under it (fully pruned, per the Ready-gate convention
`/synapse-design-note` now follows) doesn't count as open. Since this section spans every status,
each line in the composed report also shows *which* status the note is currently in, and whether it
has a compiled task note:

```
{"and": [
  {"glob": ["designs/*", {"var": "path"}]},
  {"regexp": ["## Open Questions\\n- ", {"var": "content"}]}
]}
```

Do not chain further `and`/`regexp` conditions onto this query to sort matches by status -- compound
`regexp` conditions against `content` have been observed to return results that are logically
impossible (a query with strictly more AND-ed conditions returning *more* matches than one with
fewer), so any query beyond a single `glob` + single `regexp` pair is unverified and not to be
trusted here. Instead, `mcp__obsidian__vault_read` each match directly and take two things from the
result, no second query needed for either: the line following `## Status` in `content` (normally
`Discussing`/`Ready`/`Reference`, but a note written before the three-word convention can carry free
text instead, e.g. `Superseded by [[...]]` -- report that verbatim rather than forcing it into a
bucket, surfacing an odd note beats losing it) and, from the `links` array, any path under `tasks/`
-- that's the compiled task, if one exists, with no separate `Compiled task:` regex needed since a
resolved wikilink already appears in `links` regardless of where in the body it's written.

**4. Open task notes with at least one unchecked item.** Task notes carry `status:` in frontmatter,
unlike design notes -- filter there first:

```
{"in": [{"var": "frontmatter.status"}, ["TODO", "IN-PROGRESS"]]}
```

Then `mcp__obsidian__vault_read` each match and count `- [ ]` lines in the body. A match with zero
unchecked lines (a checklist that's fully checked but hasn't been promoted to `REVIEW` yet) is still
worth surfacing -- report it under this section with its count shown as 0, rather than silently
dropping it, since that state itself is worth a human noticing.

**5. Task notes stuck in `REVIEW`.** Frontmatter-only, no body read needed -- a fully-checked
checklist waiting specifically on human sign-off, since `synapse-task` deliberately never promotes a
note past `REVIEW` on its own:

```
{"==": [{"var": "frontmatter.status"}, "REVIEW"]}
```

## Composing the report

One section per category, in the order above. Each line names the note (title, or filename if no
`title` frontmatter) plus the one identifying detail that category needs. The Open Questions section
is the one place a note's status and compiled-task link also belong on the line -- every other
section's heading already implies status (the "Discussing" section only ever holds `Discussing`
notes) and compiled-task-ness (the "Ready, not yet compiled" section only ever holds notes without
one), but Open Questions spans every status and both compiled and uncompiled notes, so put the status
first, before the title, so it's the first thing scanned:

```
## Discussing
- {title}

## Ready, not yet compiled
- {title}

## Open questions
- **{status}** — {title} — {compiled task title, or "not compiled"}

## In progress (unchecked items)
- {title} ({N} unchecked)

## Awaiting review
- {title}
```

Omit a section entirely when it has zero matches -- matching `/synapse-note --list`'s own convention
of leaving out empty headers -- rather than printing five headers with nothing under most of them. If
every category is empty, say so in one line ("Vault is clear -- nothing outstanding.") instead of five
empty headers.

Print the report directly in the response, not left only in tool-call output the user would have to
go dig for.

## Constraints

- Read-only end to end. Never calls `vault_write`/`vault_patch`/`vault_move`/`vault_delete`/
  `vault_copy` -- if a step here ever seems to need one, that step is out of scope, not a case to
  special-case around.
- No Artifact/web-UI output. No `SessionStart` wiring. Not a new binary CLI subcommand -- every
  category above is a plain mechanical query already reachable through `mcp__obsidian__*` tools.
- Scoped to `designs/`/`tasks/` only -- never `inbox/`/`research/`/`scratchpad/`.
