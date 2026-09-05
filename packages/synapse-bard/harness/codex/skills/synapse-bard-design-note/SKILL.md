---
name: synapse-bard-design-note
description: Start or continue a free-form, single-project design discussion about the book — tone choices, plot mechanics, character motivation problems, worldbuilding decisions — written to the Writer's notes vault, thinking through a problem/approach/tradeoffs out loud before anything is drafted. Use whenever the author wants to open, resume, or reason through a story decision ("let's create/write a design note", "let's think through X", "let's design this", "let's talk this through"). Not for a note that's already ready to become tracked work (that's the synapse-bard-task-note skill), or a plain vault note with no design framing (that's the synapse-bard-note skill).
---

# Writer's Notes Vault Design Note: Free-Form Story/Plot Design Discussion

A free-form "think it through out loud" pipeline for a design conversation about the book — tone
choices, plot mechanics, character motivation problems, worldbuilding decisions — written to
`_bard/vault/designs/`, this repo's own notes vault. Use it for a decision that's bigger than a
single scene note but not yet a tracked task: "how does the Flame actually work as a threat," "what
does Aidan know and when," "does this subplot resolve in book 1 or get deferred."

Not every design discussion ends with something to build. See `Status: Reference` below for the
"no implementation attached" ending — a worldbuilding decision that's just settled, nothing to draft
from it directly.

## When this runs, and what the user means

There is no flag syntax here — read intent from how the author asks:

- **A topic named or described** ("let's design X", "let's think through Y"): go to "With a topic"
  below.
- **Asking to pick up where a design left off** ("let's continue the design note", "resume that
  design"): go to "Resuming an incomplete design" below.
- **Asking what design notes exist** ("what design notes are there", "list the designs"): go to
  "Listing design notes" below.
- **No specific signal, just "let's write a design note"**: check for incomplete design notes first
  (same lookup as "Resuming an incomplete design"); if one exists, offer to resume it; if none, ask
  "What are we designing?"

## Prerequisites

- `_bard/vault/designs/` may not exist yet on first use — creating it (via the first write) is
  fine, just add a `designs/` entry to `_bard/vault/Index.md`'s folder layout in the same action if
  it's missing (per the `synapse-bard-vault` skill's folder-layout rule: a new top-level folder must
  never fall behind the index).

## Handling intent

**No specific signal:**
1. Check for incomplete design notes: search `_bard/vault/designs/**/*.md` for `## Status` lines
   reading `Discussing`.
2. If found: show a short state summary — title and current section — and offer to resume.
3. If none: ask "What are we designing?"

**With a topic:**
1. Search first — grep the topic text across `_bard/vault/designs/**/*.md` (per the
   `synapse-bard-vault` skill: check what was already decided before starting a new discussion).
   Also check for an obvious title match. If the topic centers on a specific character or entity,
   also run `synapse-bard query <slug>`/`field <slug> <key>` — established relationships or facts
   already settled in the Bible-graph shouldn't get re-litigated as if they were open.
2. If found with `Status: Discussing` → ask "Resume this design?" or "Start fresh?"
3. If found with `Status: Ready` → ask "Already marked Ready. Reopen to revise, or start a new note?"
4. If found with `Status: Reference` → ask "This concluded as Reference (no implementation intended).
   Reopen to revise, or is that still accurate?"
5. Otherwise: start a new design note.

**Resuming an incomplete design:**
1. Find notes with `Status: Discussing` (same lookup as "No specific signal").
2. Multiple → list them, ask which to continue.
3. One → resume it.
4. None → "No incomplete design note found. What are we designing?"

**Listing design notes:**
1. Find every note under `_bard/vault/designs/**/*.md`, pulling title and `## Status` from each.
2. None found → "No design notes yet. What are we designing?"
3. Group into **Active** (`Discussing`, `Ready`) and **Closed** (`Reference`) — active first, title
   and status in backticks, not bold.

---

## Workflow

Free-form conversation, no fixed step order. Create the note on the first substantive answer and
update it after every meaningful exchange — don't wait until the end.

**Write it as settled understanding, not as a transcript of how it was reached.** Updating after
every exchange is about *when* to write, not license to narrate the conversation in the prose
itself. A section should read as if authored fresh today, stating the problem/approach/constraints
as they now stand — never as a log of what changed ("corrected during discussion," "the author
pointed out," "originally X, now Y"). This applies strictly to `## Problem`, `## Constraints`, and
`## Open Questions` — always direct, current statements, no exceptions.

`## Approach` is the one place a *trail* can be legitimate content — a rejected alternative and why
it failed is real, useful information for whoever reads this later (including the author, months
from now, mid-draft), worth keeping even once the chosen approach makes it moot. But phrase it as a
fact about the story ("X doesn't work because it breaks Y's established motivation," "confirmed
against the outline"), never as commentary on the discussion that found it ("we realized," "first
tried"). Test: would the sentence still make sense to someone who wasn't in the conversation and has
no idea anything was ever revised? If not, rewrite it as a direct statement.

Angles worth covering (skip whatever's not relevant):
- What's the story problem, and why does it need deciding now (a scene coming up, a continuity
  question, a plot mechanic that needs to be consistent before more chapters build on it)?
- What's the chosen approach? If there were real alternatives, a one-line "why not" for each.
- What are the hard constraints (established canon, a character's fixed traits, a plot beat that
  can't move)?
- Anything risky, or that needs deciding now vs. can be deferred to a later book?

### Concluding: Ready or Reference

- **Something to build** (a scene to draft, a Bible-graph entity to update, a task worth tracking)
  → `Status: Ready`. Confirm: "Design note ready: `_bard/vault/designs/{title}.md`. Whenever you're
  ready, generate the task with the synapse-bard-task-note skill on "{topic}" — no rush, nothing
  here expires."
- **Nothing to build** (a settled worldbuilding fact, a resolved continuity question) →
  `Status: Reference`. Confirm: "Design note concluded as Reference:
  `_bard/vault/designs/{title}.md`. No task note needed."

If genuinely unsure which, ask the author directly.

There is no closing/renaming step here — nothing reads these notes automatically at session start,
so the `## Status` line is the only lifecycle marker that matters. It simply stays
`Ready`/`Reference` indefinitely.

---

## Design Note Format

```
---
title: "{Topic}"
created: "{now}"
---

# {Topic}

## Status
Discussing | Ready | Reference

## Problem
{What are we deciding, why does it matter, why now}

## Approach
{Chosen approach}

### Alternatives considered (optional)
- {Option}: why not

## Constraints
{Established canon, fixed character traits, plot beats that can't move}

## Open Questions (optional)
- {Anything deferred or unresolved}
```

Fetch machine local time for `created` (`date '+%Y-%m-%d %H:%M'`) — never infer it. No `project:`
frontmatter field — this vault is always single-project.

No `Notes`/changelog section — it stays a small, single-conclusion note; there's no long-running
edit history here worth tracking separately.

## Filename

`_bard/vault/designs/{Topic}.md` — sanitize filesystem-illegal characters (`/ : * ? " < > |`). No
slug, no numbering — the filename is just the title.

---

## Integration

- The synapse-bard-task-note skill reads the matching `Ready` note as its only input.

---

## Example

```
User: let's design Aidan's knowledge gap

Assistant: [searches _bard/vault/designs/ for existing matches — none found]

           What are we designing?

User: How much Aidan actually knows about the Flame's true nature versus what he believes,
      and where that gap gets revealed to the reader.

Assistant: [creates _bard/vault/designs/Aidan's knowledge gap.md, Status: Discussing]

           Does the reveal need to land before or after Drisdan's captivity arc?
...
User: After — it works better as a second-read payoff once the reader already suspects.
      Mark it ready.

Assistant: Design note ready: _bard/vault/designs/Aidan's knowledge gap.md.
           Generate the task with the synapse-bard-task-note skill on "Aidan's knowledge gap"
           whenever you're ready.
```
