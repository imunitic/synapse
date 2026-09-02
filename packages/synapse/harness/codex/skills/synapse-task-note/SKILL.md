---
name: synapse-task-note
description: Compile a Ready design note into a single tracked, checklist-based task note in Synapse Vault — delegates the actual note creation to the synapse-note skill's task mode under the hood. Use whenever the user wants to turn a settled design discussion into actionable, tracked work ("let's compile a task note", "let's turn this into a task", "make this a task now") — not for starting or continuing the design discussion itself (that's the synapse-design-note skill).
---

# Synapse Task Note: Compile a Design into a Tracked Checklist

Compiles a `Ready` design note (from the synapse-design-note skill) into a single tracked task, using
the vault's existing task-tracking machinery instead of a bespoke format: creation goes through the
synapse-note skill's task mode, and status transitions from then on belong entirely to the
synapse-task skill. This skill's only job is the compile step — turning a design into an ordered
checklist — not tracking progress itself.

One design compiles into **one** task note, one `task_id`, and the checklist items *are* the
steps — matching how every other task in the vault already works (see the synapse-task skill's
"Task file structure").

## When this runs

Invoked whenever the user wants to compile a settled design into a tracked task ("let's compile a
task note", "let's turn this into a task", "make this a task now") — the design the user means is
whatever they're currently discussing or naming, not a positional argument to parse.

Once created, the task note's own progress (checked items, `status:` frontmatter) is what the
synapse-note skill's list mode and the synapse-task skill already track. Use those instead of
reinventing a parallel view — this skill has no separate list/continue mode of its own.

## Prerequisites

- Requires a matching design note (`designs/`) with `Status: Ready`.
- No matching note → "No Ready design note found for '{topic}'. Start or continue that design note
  first." Never generate a checklist from scratch.
- Matching note but `Status: Discussing` → "Design note for '{topic}' is still in Discussing. Finish
  it first."
- Matching note but `Status: Reference` → "Design note for '{topic}' concluded as Reference —
  nothing to compile. Reopen the design discussion and mark it Ready if that's changed."
- A task note already exists for this design (check the design note's `> Compiled task:` annotation,
  or `search_query` for a `tasks/` note linking to it) → show its current state (title, `status:`,
  checked/total) and ask: view it, or recompile (only on explicit confirmation — recompiling rewrites
  the checklist, so any progress on items that no longer exist is lost).

  **A recompile updates the existing note in place. It never creates a second one and never bumps
  the `task_id`.** One design has exactly one task note for its whole life; a design that gets
  revised mid-implementation is the normal case, not a new task. Preserve `task_id`, `created`,
  `status`, the filename, and any `## Notes` content the human added; replace the checklist and the
  pre-implementation notes. Carry forward `- [x]` marks for items that survive the recompile
  unchanged — work already done doesn't become undone because the plan around it grew.

  Record *why* in the note itself, in one line at the top of the body: what the old plan got wrong
  and what changed. A recompiled task with no explanation reads like a plan that was always this
  shape, which hides the fact that implementation found a gap.

## Compiling the checklist

1. Read the design note in full.
2. Break the approach into an ordered list of small, sequential, independently-completable steps.
3. For each step, write it the way the synapse-task skill's own checklist convention expects: a short
   `- [ ] {Do}` line; for substantive steps (type definitions, API surfaces, interface signatures)
   add a one-line nested description plus a fenced code block showing the exact interface, per that
   skill's "Inline code examples in checklist items". Don't invent separate Files/Tests/AC fields —
   fold what matters into the item's own description instead (e.g. "...; test: X returns Y").
4. Note explicit exclusions — things a reasonable implementer might also attempt that are out of
   scope — for the `## Notes` section below, not a separate heading.

## Creating the note

Follow the synapse-note skill's task-mode procedure exactly (its "Creating the note" section) —
don't duplicate that scaffolding here, just supply its inputs:

- **Title:** a short, plain description of the compiled plan (e.g. "Rollup direct storage
  implementation") — stays exactly this, never prefixed with the resolved `task_id`; the
  synapse-note skill's task mode resolves the project prefix and `task_id` itself and puts them in
  frontmatter only.
- **Project:** derive from the source design note's `project:` frontmatter — that prefix is already
  resolved (the design note went through the synapse-design-note skill's resolution when it was
  created, which reads/appends the resolved `synapse-projects.conf`, per the synapse-note skill's
  tiered lookup), so supply it directly instead of re-deriving or re-asking. This is the *prefix*
  (`ecs`, `sb`, ...), not the `tasks/{project}/` folder name — the synapse-note skill's task mode's
  own "Resolving the project folder" step turns it into the folder name. Never hardcode a specific
  project/prefix pair in this skill's own instructions — the conf file is machine-local and
  deliberately outside the portable Synapse package, so projects from unrelated contexts (e.g.
  personal vs. work) must never end up in the same place.
- **Body:** the checklist from "Compiling the checklist" above, under the single top-level heading —
  exactly the structure the synapse-task skill's "Task file structure" requires (no `## Step`
  sub-headings).
- **`## Notes` (pre-implementation):** populate per the synapse-task skill's own convention —
  - Design reference: `[[{design note title}]]`
  - Key constraints the implementor must not miss
  - Deliberate exclusions (from step 4 above) and why

## Linking back

After creation, patch the design note: add `> Compiled task: [[{task note title}]]` near the top —
right after the `# {title}` heading, before `## Status`:

```
printf '> Compiled task: [[%s]]\n\n' "{task note title}" | \
  synapse vault-patch "{design note path}" --heading "{design note title}" --prepend
```

A small annotation line, same idea as any other cross-reference you'd drop near a note's title. This
is a one-time link; the design note's `Status` itself does not change and does not need to track the
task's progress — a plain `synapse vault-search-text` for the task note's title already surfaces the
live task note from the design note, and the task's `status:` frontmatter is the authoritative
progress signal from here on.

## Confirm

Report the created path and title, and remind the user that `status:` transitions (TODO →
IN-PROGRESS → REVIEW) happen automatically via the synapse-task skill once work starts — this
skill doesn't set or watch that field itself.

## Integration

- Reads the synapse-design-note skill's `Ready` output only — never invents a design.
- Delegates note creation to the synapse-note skill's task mode and status tracking to the
  synapse-task skill — this skill owns only the design → checklist compile step.

---

## Example

```
User: let's compile a task note for "rollup direct storage"

Codex: [reads designs/{project}/Rollup direct storage.md, Status: Ready]
       [no existing linked task note]

       Compiled checklist:
       - [ ] Add ReplacingMergeTree target table for the daily rollup
       - [ ] Point the rollup MV at the new table instead of AggregatingMergeTree
       - [ ] Migrate existing daily/monthly rollups (drop+recreate, sort-key change)
       - [ ] Update the 5 retrofitted dashboards' rollup queries to drop argMaxMerge

       Project already known: {PROJECT} → {prefix}-005.

       Created: tasks/{project}/Rollup direct storage implementation.md (task_id: {prefix}-005)
       Linked back from designs/{project}/Rollup direct storage.md.

       Status transitions happen automatically via the synapse-task skill once you start work.
```
