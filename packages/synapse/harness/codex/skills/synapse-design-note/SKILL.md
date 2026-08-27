---
name: synapse-design-note
description: Start or continue a free-form, cross-project design discussion, written to Synapse Vault rather than tied to one repo — thinking through a problem/approach/tradeoffs out loud before anything is built. Use whenever the user wants to open, resume, or reason through a design ("let's create/write a design note", "let's think through X", "let's design this", "let's talk this through"). Not for a note that's already ready to become tracked work (that's the synapse-task-note skill), or a plain vault note with no design framing (that's the synapse-note skill, whose project-resolution logic this skill reuses).
---

# Synapse Design Note: Cross-Project Personal Design Discussion

A free-form "think it through out loud" pipeline for a design conversation, written to Synapse
Vault rather than any one repo. Use it when the design conversation isn't (or shouldn't be) tied
to one repo's lifecycle — it's findable from any project immediately, with no separate
pointer-note step, because the vault itself is already the cross-project store.

Not every design discussion ends with something to build. See `Status: Reference` below for the
"no implementation attached" ending.

## When this runs, and what the user means

There is no flag syntax here — read intent from how the user asks:

- **A topic named or described** ("let's design X", "let's think through Y"): go to "With a topic"
  below.
- **Asking to pick up where a design left off** ("let's continue the design note", "resume that
  design"): go to "Resuming an incomplete design" below.
- **Asking what design notes exist** ("what design notes are there", "list the designs"): go to
  "Listing design notes" below.
- **No specific signal, just "let's write a design note"**: check for incomplete design notes first
  (same lookup as "Resuming an incomplete design"); if one exists, offer to resume it; if none,
  ask "What are we designing?"

## Prerequisites

- Requires the `synapse` CLI on `PATH`. If it errors (no vault configured), say so and stop —
  there is no other fallback for this skill.
- If `designs/` doesn't exist in the vault yet, `synapse vault-write` creates it implicitly on
  first write — but add a `designs/` entry to the vault's index note's folder layout in the same
  action (per the Synapse Vault folder-layout rule: a new top-level folder must never fall behind the
  index).

## Determining the project

Every design note is tagged with the project it belongs to — both in the title
(`{PROJECT} — {Topic}`) and as `project: {prefix}` in frontmatter (the same short prefix the
synapse-note skill's task mode uses for task IDs) — so a flat `designs/` folder still reads clearly,
and both note kinds can be filtered together via `synapse vault-search`.

Same resolution the synapse-note skill uses for a missing task ID (its "Resolving a missing task
ID"), reading the same file:

1. Infer the project from the current repo: check its project `CLAUDE.md` (title/"About" section) or
   `git remote`.
2. Check the resolved `synapse-projects.conf` (plain `project-name=prefix` lines, read/appended
   as a plain file, not the vault — resolve which file that is with the same tiered lookup as the
   synapse-note skill's "Resolving a missing task ID": `$XDG_CONFIG_HOME/synapse/synapse-projects.conf`
   or `~/.config/synapse/synapse-projects.conf`, then `~/.claude/synapse-projects.conf`, first one
   that exists) for a loosely-matching project name. If found, use that prefix directly.
3. If not in the file yet, fall back to searching the vault for a prefix already in use for this
   project. If exactly one confidently matches, use it — and append the pair to the conf file.
4. If nothing confidently matches, ask the user for a short project tag — plain free-text, not a
   multiple-choice list, never hinting at any other project's tag as an example — then append the
   resolved pair to the conf file.

Never hardcode a specific project/prefix pair in this skill's own instructions — the conf file is
machine-local and deliberately outside the portable Synapse package, so projects from
unrelated contexts (e.g. personal vs. work) never end up in the same place.

## Handling intent

**No specific signal:**
1. Check for incomplete design notes: `synapse vault-search --fields frontmatter.title` with the
   query below on stdin — one call, no separate read needed:

   ```
   {"and": [
     {"glob": ["designs/*", {"var": "path"}]},
     {"regexp": ["## Status\\nDiscussing", {"var": "content"}]}
   ]}
   ```
2. If found: show a short state summary — title and current section — and offer to resume.
3. If none: ask "What are we designing?"

**With a topic:**
1. Search first — `synapse vault-search-text "{topic}"` for the topic text, then filter matches to
   `designs/` paths (per the Synapse Vault rule: link/reuse over duplicate). Also check for an
   obvious title match.
2. If found with `Status: Discussing` → ask "Resume this design?" or "Start fresh?"
3. If found with `Status: Ready` → ask "Already marked Ready. Reopen to revise, or start a new note?"
4. If found with `Status: Reference` → ask "This concluded as Reference (no implementation intended).
   Reopen to revise, or is that still accurate?"
5. Otherwise: start a new design note (see "Determining the project" above for the title/frontmatter
   tag).

**Resuming an incomplete design:**
1. Find notes with `Status: Discussing` (same lookup as "No specific signal").
2. Multiple → list them, ask which to continue.
3. One → resume it.
4. None → "No incomplete design note found. Tell me what you'd like to design and I'll start one."

**Listing design notes:**
1. `synapse vault-search --fields frontmatter.title,content` with `{"glob": ["designs/*", {"var":
   "path"}]}` on stdin — every design note regardless of status, title and `## Status` line both in
   the same row.
2. None found → "No design notes yet. Tell me what you'd like to design and I'll start one."
3. Group into **Active** (`Discussing`, `Ready`) and **Closed** (`Reference`) — active first, title
   and status in backticks, not bold.

---

## Workflow

Free-form conversation, no fixed step order. Create the note on the first substantive answer and
update it after every meaningful exchange — don't wait until the end.

**Write it as settled understanding, not as a transcript of how it was reached.** Updating after
every exchange is about *when* to write, not license to narrate the conversation in the prose
itself. A section should read as if authored fresh today, stating the problem/approach/constraints
as they now stand — never as a log of what changed ("corrected during discussion," "reworked during
a live investigation," "the user pointed out," "originally X, now Y"). This applies strictly to
`## Problem`, `## Constraints`, and `## Open Questions` — always direct, current statements, no
exceptions.

`## Approach` is the one place a *trail* can be legitimate content — a rejected alternative and why
it failed is real, useful information for whoever reads this later, worth keeping even once the
working approach makes it moot. But phrase it as a fact about the solution space ("X fails because
Y, confirmed by Z"), never as commentary on the discussion that found it ("investigation showed,"
"the first attempt was"). Test: would the sentence still make sense to someone who wasn't in the
conversation and has no idea anything was ever revised? If not, rewrite it as a direct statement.

**Prune `## Open Questions` the moment a question resolves — every time the note is touched, not
just at conclusion.** This section must only ever contain what is currently, actually unresolved:
a reader (or the agent checking for a blocking question before marking `Ready`, below) has to be
able to tell in one pass whether anything is still open, not read through a history of past answers
to find the one real one. When a question is answered during discussion, delete its bullet outright
— if the answer matters going forward, fold it into `## Approach` (as a direct settled fact, same
rule as above) or `### Alternatives considered` (if something specific was tried and rejected along
the way). Never leave a "Resolved on {date}" or "Revised ({review}): ..." bullet parked under Open
Questions as a historical record — that is exactly the changelog-as-current-state failure the rule
above already prohibits, just easier to miss here because the section reads as a list either way.

Angles worth covering (skip whatever's not relevant):
- What problem are we solving, and why now?
- What's the chosen approach? If there were real alternatives, a one-line "why not" for each.
- What are the hard constraints?
- Anything risky, or that needs deciding now vs. can be deferred?

### Concluding: Discussing, Ready, or Reference

A design note starts `Discussing` and stays there by default — reaching `Ready` is a deliberate
judgment call, not the automatic result of an `## Approach` section existing. Before marking
`Ready`, check both explicitly:
- Is `## Approach` complete and actionable as written, with no hedge language standing in for a
  decision that hasn't actually been made ("a plausible shape," "TBD," "leaning toward," "something
  like")? If the approach still contains that kind of placeholder, it isn't `Ready` yet regardless
  of how much has been discussed.
- Does every `## Open Questions` bullet, if any survive the pruning above, sit off the critical
  path — genuinely deferred, not something the synapse-task-note skill would need answered to turn
  this into real work? A `Ready` note is not required to have zero open questions (a deferred, non-
  blocking question is fine to carry forward), but a note with a *blocking* open question is not
  `Ready`, no matter how developed the rest of it is.

- **Both hold** → `Status: Ready`. Confirm: "Design note ready: `designs/{title}.md`.
  Whenever you're ready to implement, ask me to compile it into a task note — no rush, nothing
  here expires."
- **Genuinely nothing to build** → `Status: Reference`. Confirm: "Design note concluded as
  Reference: `designs/{title}.md`. No task note needed."
- **Anything else** (the approach is still hedged, or an open question blocks it) → stays
  `Status: Discussing`. This is the default outcome, not a fallback to apologize for — most
  conversations end here, and that's fine; nothing here expires either.

If genuinely unsure which, ask the user directly.

There is no closing/renaming step here — nothing reads these notes automatically at session start,
so the `## Status` line is the only lifecycle marker that matters. It simply stays
`Ready`/`Reference` indefinitely.

---

## Design Note Format

```
---
title: "{PROJECT} — {Topic}"
project: {prefix}
created: "{now}"
---

# {PROJECT} — {Topic}

## Status
Discussing | Ready | Reference

## Problem
{What are we solving, why does it matter, why now}

## Approach
{Chosen approach}

### Alternatives considered (optional)
- {Option}: why not

## Constraints
{Hard constraints, non-negotiables}

## Open Questions (optional)
- {Anything deferred or unresolved}
```

Fetch machine local time for `created` (`date '+%Y-%m-%d %H:%M'`) — never infer it.

No `Notes`/changelog section — it stays a small, single-conclusion note; there's no long-running
edit history here worth tracking separately.

## Filename

`designs/{PROJECT} — {Topic}.md` — sanitize filesystem-illegal characters (`/ : * ? " < > |`). No
slug, no numbering — Obsidian filenames are the title itself.

---

## Integration

- The synapse-task-note skill reads the matching `Ready` note as its only input.

---

## Example

```
User: let's design "rollup direct storage"

Codex: [searches designs/ for existing matches — none found]

       What are we designing?

User: Replacing the AggregatingMergeTree rollup resolution with direct-value storage.

Codex: [creates designs/{PROJECT} — Rollup direct storage.md, Status: Discussing]

       What's driving this over just tuning the current argMaxMerge query?
...
User: The resolution cost alone dominates the query, tuning won't fix that. Mark it ready.

Codex: Design note ready: designs/{PROJECT} — Rollup direct storage.md.
       Ask me to compile the task note whenever you're ready to implement.
```
