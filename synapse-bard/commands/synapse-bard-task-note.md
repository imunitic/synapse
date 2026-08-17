# Writer's Notes Vault Task Note: Compile a Design into a Tracked Checklist

Compiles a `Ready` design note (from `/synapse-bard-design-note`) into a single tracked task, using
the vault's existing task-tracking machinery instead of a bespoke format: creation goes through
`/synapse-bard-note --task`, and status transitions from then on belong entirely to the
`synapse-bard-task` skill. This command's only job is the compile step — turning a design into an
ordered checklist — not tracking progress itself.

One design compiles into **one** task note, one `task_id`, and the checklist items *are* the
steps.

## Usage

```
/synapse-bard-task-note "topic"    # Compile the task note for a Ready design note
```

No `--continue`/`--list` here — once created, the task note's own progress (checked items,
`status:` frontmatter) is what `/synapse-bard-note --list` and the `synapse-bard-task` skill already
track. Use those instead of reinventing a parallel view.

## Prerequisites

- Requires a matching design note (`_bard/vault/designs/`) with `Status: Ready`.
- No matching note → "No Ready design note found for '{topic}'. Run
  `/synapse-bard-design-note \"{topic}\"` first." Never generate a checklist from scratch.
- Matching note but `Status: Discussing` → "Design note for '{topic}' is still in Discussing. Finish
  it first."
- Matching note but `Status: Reference` → "Design note for '{topic}' concluded as Reference —
  nothing to compile. Reopen it with `/synapse-bard-design-note \"{topic}\"` and mark it Ready if
  that's changed."
- A task note already exists for this design (check the design note's `> Compiled task:` annotation,
  or `Grep` `_bard/vault/tasks/**/*.md` for a link to it) → show its current state (title, `status:`,
  checked/total) and ask: view it, or recompile (only on explicit confirmation — recompiling rewrites
  the checklist, so any progress on items that no longer exist is lost).

  **A recompile updates the existing note in place. It never creates a second one and never bumps
  the `task_id`.** One design has exactly one task note for its whole life; a design that gets
  revised mid-draft is the normal case, not a new task. Preserve `task_id`, `created`, `status`, the
  filename, and any `## Notes` content the author added; replace the checklist and the
  pre-implementation notes. Carry forward `- [x]` marks for items that survive the recompile
  unchanged — work already done doesn't become undone because the plan around it grew.

  Record *why* in the note itself, in one line at the top of the body: what the old plan got wrong
  and what changed. A recompiled task with no explanation reads like a plan that was always this
  shape, which hides the fact that drafting found a gap.

## Compiling the checklist

1. Read the design note in full.
2. Break the approach into an ordered list of small, sequential, independently-completable steps.
3. For each step, write it as a short `- [ ] {Do}` line. **Almost every bard task is the "non-code"
   case** — no fenced interface block, since there's no API surface to pin down. A substantive step
   still gets a one-line nested description when it isn't self-explanatory: what scene it touches,
   which Bible-graph entities it should update, what continuity constraint it has to respect. Don't
   invent separate Files/Tests/AC fields — fold what matters into the item's own description (e.g.
   "...; must not contradict Renwick's established backstory in `mentors/renwick.md`").
4. Note explicit exclusions — things a reasonable draft might also attempt that are out of scope
   (e.g. "does not resolve Maren's arc, that's a later book") — for the `## Notes` section below,
   not a separate heading.

## Creating the note

Follow `/synapse-bard-note`'s task-mode procedure exactly (its "Creating the note" section) — don't
duplicate that scaffolding here, just supply its inputs:

- **Title:** a short, plain description of the compiled plan (e.g. "Aidan's knowledge-gap reveal") —
  `/synapse-bard-note --task` resolves the `task_id` itself.
- **Body:** the checklist from "Compiling the checklist" above, under the single top-level heading.
- **`## Notes` (pre-implementation):**
  - Design reference: `[[{design note title}]]`
  - Key constraints (established canon, character traits, plot beats that can't move)
  - Deliberate exclusions (from step 4 above) and why

## Linking back

After creation, edit the design note: add `> Compiled task: [[{task note title}]]` near the top of
the body (a small annotation line, same idea as any other cross-reference you'd drop near a note's
title). This is a one-time link; the design note's `Status` itself does not change and does not need
to track the task's progress — the task note's `status:` frontmatter is the authoritative progress
signal from here on.

## Confirm

Report the created path and title, and remind the author that `status:` transitions (TODO →
IN-PROGRESS → REVIEW) happen automatically via the `synapse-bard-task` skill once work starts — this
command doesn't set or watch that field itself.

## Integration

- Reads `/synapse-bard-design-note`'s `Ready` output only — never invents a design.
- Delegates note creation to `/synapse-bard-note --task` and status tracking to the
  `synapse-bard-task` skill — this command owns only the design → checklist compile step.

---

## Example

```
User: /synapse-bard-task-note "Aidan's knowledge gap"

Claude: [reads _bard/vault/designs/Aidan's knowledge gap.md, Status: Ready]
        [no existing linked task note]

        Compiled checklist:
        - [ ] Draft the corridor scene beat where Calla registers the "anti-spark" reaction
        - [ ] Update aidan-dayne.md's story.what_they_know field to reflect the settled gap
        - [ ] Plant the second-read Easter egg cue in the Book 1 ending scene
        - [ ] Confirm the reveal timing doesn't contradict Drisdan's captivity arc outline

        Created: _bard/vault/tasks/task-004 — Aidan's knowledge-gap reveal.md
        Linked back from _bard/vault/designs/Aidan's knowledge gap.md.

        Status transitions happen automatically via the synapse-bard-task skill once you start
        work.
```
