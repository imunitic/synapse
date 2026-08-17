# Writer's Notes Vault Design Note: Free-Form Story/Plot Design Discussion

A free-form "think it through out loud" pipeline for a design conversation about the book — tone
choices, plot mechanics, character motivation problems, worldbuilding decisions — written to
`_bard/vault/designs/`, this repo's own notes vault. Use it for a decision that's bigger than a
single scene note but not yet a tracked task: "how does the Flame actually work as a threat," "what
does Aidan know and when," "does this subplot resolve in book 1 or get deferred."

Not every design discussion ends with something to build. See `Status: Reference` below for the
"no implementation attached" ending — a worldbuilding decision that's just settled, nothing to draft
from it directly.

## Usage

```
/synapse-bard-design-note "topic"           # Start or resume a design discussion
/synapse-bard-design-note --continue        # Resume an incomplete design note
/synapse-bard-design-note --list            # List every design note, regardless of status
```

## Prerequisites

- `_bard/vault/designs/` may not exist yet on first use — creating it (via the first `Write`) is
  fine, just add a `designs/` entry to `_bard/vault/Index.md`'s folder layout in the same action if
  it's missing (per the `synapse-bard-vault` skill's folder-layout rule: a new top-level folder must
  never fall behind the index).

## Handling Arguments

**No arguments:**
1. Check for incomplete design notes: `Glob` `_bard/vault/designs/**/*.md`, `Grep` for `## Status`
   lines reading `Discussing`.
2. If found: show a short state summary — title and current section — and offer to resume.
3. If none: ask "What are we designing?"

**With a topic:**
1. Search first — `Grep` the topic text across `_bard/vault/designs/**/*.md` (per the
   `synapse-bard-vault` skill: check what was already decided before starting a new discussion).
   Also check for an obvious title match.
2. If found with `Status: Discussing` → ask "Resume this design?" or "Start fresh?"
3. If found with `Status: Ready` → ask "Already marked Ready. Reopen to revise, or start a new note?"
4. If found with `Status: Reference` → ask "This concluded as Reference (no implementation intended).
   Reopen to revise, or is that still accurate?"
5. Otherwise: start a new design note.

**--continue:**
1. Find notes with `Status: Discussing` (same lookup as "No arguments").
2. Multiple → list them, ask which to continue.
3. One → resume it.
4. None → "No incomplete design note found. Start one with `/synapse-bard-design-note \"topic\"`."

**--list:**
1. `Glob` `_bard/vault/designs/**/*.md`, `Read` each (or `Grep` for `## Status`) to pull title and
   status.
2. None found → "No design notes yet. Start one with `/synapse-bard-design-note \"topic\"`."
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
  ready, generate the task with `/synapse-bard-task-note \"{topic}\"` — no rush, nothing here
  expires."
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

- `/synapse-bard-task-note "{topic}"` reads the matching `Ready` note as its only input.

---

## Example

```
User: /synapse-bard-design-note "Aidan's knowledge gap"

Claude: [searches _bard/vault/designs/ for existing matches — none found]

        What are we designing?

User: How much Aidan actually knows about the Flame's true nature versus what he believes,
      and where that gap gets revealed to the reader.

Claude: [creates _bard/vault/designs/Aidan's knowledge gap.md, Status: Discussing]

        Does the reveal need to land before or after Drisdan's captivity arc?
...
User: After — it works better as a second-read payoff once the reader already suspects.
      Mark it ready.

Claude: Design note ready: _bard/vault/designs/Aidan's knowledge gap.md.
        Generate the task with /synapse-bard-task-note "Aidan's knowledge gap" whenever you're
        ready.
```
