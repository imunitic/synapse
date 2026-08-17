---
name: synapse-bard-task
description: Update task notes' status frontmatter and Notes sections in the Writer's notes vault, enforcing status transitions so active work is IN-PROGRESS and completed checklists move only to REVIEW (not DONE).
---

# Writer's Notes Vault Task Status Skill

Tracks status for task notes created via `/synapse-bard-note --task` and compiled via
`/synapse-bard-task-note`, using a `status:` frontmatter field and GFM `- [ ]`/`- [x]` checklists.

## When to invoke (proactive — do not wait to be asked)

Applies to any task note in `_bard/vault/tasks/` — identified by having `task_id` and `status`
frontmatter fields.

Invoke this skill **automatically** in two situations:

1. **Starting work on a task** — as soon as the author confirms work is beginning (drafting a
   scene, updating Bible-graph entities, resolving a plot point), before doing any of it. Set
   `status: IN-PROGRESS` and update `last_updated`. No notes needed at this point.

2. **Finishing work on a task** — after the checklist has been updated. Set `status: REVIEW` (if
   all items checked) or `status: IN-PROGRESS` (if any remain), update `last_updated`, and append an
   implementation summary to the `## Notes` section.

Never wait to be asked — apply this skill proactively at both transitions.

## What this skill does

- Updates the `status:` frontmatter field (`TODO` → `IN-PROGRESS` or `REVIEW`).
- Updates `last_updated` in frontmatter.
- At task completion: appends concise summary bullets to the existing `## Notes` section (or
  creates one if none exists).

## Status transitions

| Checklist state | `status:` value |
|-----------------|-----------------|
| Any `[ ]` unchecked | `IN-PROGRESS` |
| All `[x]` checked | `REVIEW` |

This is the same rule `core.task_status` encodes in the `synapse-bard` codebase itself
(`nextStatus`/`isAutomaticTarget`) — there's no CLI command exposing it yet, so compute it by hand
from the checklist using this table, not a separate source of truth.

**Never set `DONE` through this workflow.** Do not manually write `DONE` into `status:` either —
always go through this skill, which caps at `REVIEW`.

## Procedure

1. Find the task note: `Glob` `_bard/vault/tasks/**/*.md`, `Grep`/`Read` to match `task_id`.
2. Inspect its checklist items (`- [ ]` / `- [x]`).
3. Determine the new `status:` value: `IN-PROGRESS` if any unchecked, `REVIEW` if all checked. An
   empty or missing checklist is ambiguous, not "done" — default to `IN-PROGRESS`.
4. Fetch machine local time: `date '+%Y-%m-%d %H:%M'` — never use inferred time.
5. Update `status:` and `last_updated:` by **read-modify-write**: `Read` the file, `Edit` the one
   `status:` / `last_updated:` line, write the rest back unchanged. This is the only edit mode this
   vault has — see `synapse-bard-vault`'s own "Editing safely" section.
6. **For completion only:** append summary bullets to the existing `## Notes` section with `Edit`
   (match the section's last existing content and append after it). If no `## Notes` section exists,
   add one.

## Notes format

Append flat bullets to the existing notes section. Keep them factual and short:

- What scene, entity, or plot point was drafted / changed
- Key decisions or deviations from the compiled plan
- Files added or modified (`_bard/graph/` entities, manuscript files, etc.)
- Anything left open for a later pass

Avoid creating a new heading if a notes section already exists at any level. Append to the last
existing notes section.

## Task file structure

Each task note has **exactly one top-level heading** (the task itself, `# {title}`). Steps go as
`- [ ]` checklist items **under that heading**, not as additional headings. Do not create `##
Step` sub-headings for implementation steps.

Correct structure:
```md
# Aidan's knowledge-gap reveal

Description of the task.
- [ ] Step one
- [ ] Step two
- [ ] Step three
```

Wrong structure (do not do this):
```md
# Aidan's knowledge-gap reveal
## Step one
## Step two
```

### Notes section (pre-draft)

Every new task note must have a `## Notes` section, **written before drafting begins** (not only
appended after completion). For tasks backed by a design note, populate it with:

- Design reference: file path and task ID
- Key constraints (established canon, character traits, plot beats that can't move)
- Deliberate exclusions (what is out of scope and why)

For simple tasks with no design note, a brief one-liner stating the goal or context is sufficient.
Omit the section only if there is genuinely nothing non-obvious to capture.

```md
## Notes

Design reference: _bard/vault/designs/{topic}.md (task-004).

- Key constraint one
- Key constraint two
- Out of scope: X (reason), Y (reason)
```

Post-drafting summaries are appended under `## Notes` as dated sub-headings (`### YYYY-MM-DD —
...`), as shown in the completion procedure above.

## Guardrails

- **Never write `DONE`** — not in `status:`, not manually, not through any other path. The cap is
  always `REVIEW`.
- **Never create a task note via a bare `Write`.** Always `/synapse-bard-note --task`, or
  `/synapse-bard-task-note` when compiling one from a `Ready` design note. A freeform write skips
  both the skeleton (checklist items plus a single `## Notes` section) and every guardrail in this
  file — there is no partial-credit version of following this skill.
- **Never restructure an existing task note's shape outside this skill's own procedure.** Ad hoc
  edits that add new headings, drop the checklist, or otherwise diverge from the skeleton are what
  this guardrail exists to prevent — not just wrong `status:` values.
- Preserve `task_id` untouched — it is resolved once by `/synapse-bard-note --task` and must not be
  auto-generated or overwritten.
- If checklist content is ambiguous or missing, default to `IN-PROGRESS`.
- Keep notes wording deterministic; avoid speculative claims.
