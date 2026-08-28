---
name: synapse-task
description: Update vault task notes' status frontmatter and Notes sections, enforcing status transitions so active work is IN-PROGRESS and completed checklists move only to REVIEW (not DONE).
---

# Synapse Task Status Skill

Tracks status for task notes created via `/synapse-note --task` and compiled via `/synapse-task-note`,
using a `status:` frontmatter field and GFM `- [ ]`/`- [x]` checklists (the vault's native format,
no conversion needed).

## When to invoke (proactive — do not wait to be asked)

Applies to any task note, in any project — a task note is identified by having
`task_id` and `status` frontmatter fields, not by which prefix `task_id` uses
(`proj-NNN`, `sb-NNN`, or any other project's prefix from
`~/.claude/synapse-projects.conf`). Never gate this skill on a specific
prefix.

Invoke this skill **automatically** in two situations:

1. **Starting work on a task** — as soon as the user confirms work is
   beginning, before writing any code. Set `status: IN-PROGRESS` and update
   `last_updated`. No notes needed at this point.

2. **Finishing work on a task** — after all phases are committed and
   the task note's checklist has been updated. Set `status: REVIEW` (if all
   items checked) or `status: IN-PROGRESS` (if any remain), update
   `last_updated`, and append an implementation summary to the `## Notes`
   section.

Never wait to be asked — apply this skill proactively at both transitions.

## What this skill does

- Updates the `status:` frontmatter field (`TODO` → `IN-PROGRESS` or
  `REVIEW`).
- Updates `last_updated` in frontmatter.
- At task completion: appends concise implementation bullets to the
  existing `## Notes` section (or creates one if none exists).

## Status transitions

| Checklist state | `status:` value |
|-----------------|-----------------|
| Any `[ ]` unchecked | `IN-PROGRESS` |
| All `[x]` checked | `REVIEW` |

**Never set `DONE` through this workflow.** Do not manually write `DONE`
into `status:` either — always go through this skill, which caps at
`REVIEW`.

## Procedure

1. Find the task note: `synapse vault-search --fields content` with
   `{"==": [{"var": "frontmatter.task_id"}, "<task-id>"]}` on stdin, where `<task-id>`
   is the specific task's ID (whatever prefix it uses — `proj-035`, `sb-008`,
   etc.) — one call returns the matched note's path and full body together, no
   separate read needed.
2. Inspect its checklist items (`- [ ]` / `- [x]`).
3. Determine the new `status:` value: `IN-PROGRESS` if any unchecked,
   `REVIEW` if all checked.
4. Fetch machine local time: `date '+%Y-%m-%d %H:%M'` — never use inferred
   time.
5. Update `status:` and `last_updated:` with two `synapse frontmatter set`
   calls, one per field: `synapse frontmatter set <path> status <value>`
   then `synapse frontmatter set <path> last_updated "{now}"`. Each call
   changes exactly that one line and nothing else, entirely inside the
   compiled binary — the note's body never enters your context at all.
   When the command isn't available, fall back to **read-modify-write**:
   `synapse vault-read` the file, replace the one line in the returned content,
   `synapse vault-write` the whole file back — byte-preserving, because you write
   back what you read.

   `synapse vault-patch <path> --frontmatter <key> --replace` is also byte-preserving now (it
   delegates to the same field-local mechanism `frontmatter set` uses internally), unlike the old
   Obsidian MCP tool of the same shape — but it only ever writes a plain scalar, and it's a full
   read-apply-write round trip through the patch layer for one field. `frontmatter set` stays the
   right tool for this step: narrower, and the one call that exists specifically for it.
6. **For completion only:** append implementation bullets to the existing
   `## Notes` section with `synapse vault-patch`:

   ```
   printf '%s\n' "- bullet one" "- bullet two" | \
     synapse vault-patch "{path}" --heading "{H1 title}::Notes" --append --create
   ```

   Append is safe here too. **The target must be the full nested path** (`H1::Notes`), not just
   `"Notes"`: since `## Notes` is nested under the top-level `# {title}` heading, a bare leaf name
   fails with "target not found in {path}" -- check `synapse vault-doc-map <path>` rather than
   guessing. `--create` creates the section (and any missing parent) if it doesn't exist yet.

The vault-patch hazards below are the task-note-specific instance of a general rule; the
`synapse-vault` skill carries the full list (H1 replace, nested heading paths, frontmatter) for
every note, not just task notes.

**Do not use `vault-patch --heading "{H1 title}" --replace` to edit checklist items.** A top-level
heading's own section extends through *all* nested subheadings (including `## Notes`), not just
the leading paragraph/checklist directly under it — a replace there silently deletes everything
past the checklist, including the Notes section. To check off checklist items,
instead `synapse vault-read` the full file, edit the `- [ ]` → `- [x]` lines in the
returned content, and `synapse vault-write` the whole file back.

## Notes format

Append flat bullets to the existing notes section. Keep them factual and short:

- What was implemented / changed
- Key design decisions or deviations from the spec
- Files added or modified
- Validation result (`just check` / test counts)

Avoid creating a new heading if a notes section already exists at any
level. Append to the last existing notes section.

## Task file structure

Each task note, in any project, has **exactly one top-level heading** (the
task itself, `# {title}`). Implementation steps go as `- [ ]` checklist items
**under that heading**, not as additional headings. Do not create `##
Step` sub-headings for implementation steps.

Correct structure:
```md
# Implement something

Description of the task.
- [ ] Step one
- [ ] Step two
- [ ] Step three
```

Wrong structure (do not do this):
```md
# Implement something
## Step one
## Step two
```

### Inline code examples in checklist items

Only applicable to code tasks. Non-code tasks (research, documentation,
configuration, simple one-liners) need no code blocks at all.

For code tasks, substantive checklist items (type definitions, API
surfaces, interface signatures) must include a fenced code block showing
the exact interface, directly under the checklist item text, indented to
match:

```md
- [ ] Implement Foo

  One-line description of what this covers and any non-obvious constraints.

  ```ocaml
  // path/to/file
  interface or type definition goes here
  ```
```

Draw the signatures directly from the design document. Do not paraphrase
or abbreviate — the checklist item is the implementor's authoritative
reference.

### Notes section (pre-implementation)

Every new task note must have a `## Notes` section, **written before
implementation begins** (not only appended after completion). For tasks
backed by a design document, populate it with:

- Design reference: file path and task ID
- Key constraints the implementor must not miss
- Deliberate exclusions (what is out of scope and why)

For research or simple tasks with no design doc, a brief one-liner stating
the goal or context is sufficient. Omit the section only if there is
genuinely nothing non-obvious to capture.

```md
## Notes

Design reference: docs/design/foo_design.md (task-NNN).

- Key constraint one
- Key constraint two
- Out of scope: X (reason), Y (reason)
```

Post-implementation summaries are appended under `## Notes` as dated
sub-headings (`### YYYY-MM-DD — ...`), as shown in the completion
procedure above.

## Creating a GitHub issue from a task

When the user asks to create a GitHub issue from a task note:

1. **Title** — `<TASK-ID> — <description>`, where `<TASK-ID>` is the
   `task_id` frontmatter field (whatever project's prefix it uses — e.g.
   `proj-030`, `sb-008`) and `<description>` is the heading with any leading
   task-id prefix stripped (`<TASK-ID>`, `<TASK-ID> —`, or `<TASK-ID> - `).
   Example: heading `# proj-035 - Widget catalog rework` → title
   `proj-035 — Widget catalog rework`.
2. **Body** — the full content of the top-level heading section: the
   description paragraph and all checklist items (with any inline code
   blocks) — already GFM Markdown, so this goes straight into
   `gh issue create --body-file` unchanged.
3. **First comment** — the full content of the `## Notes` section,
   including any dated sub-headings and their bullets, straight into
   `gh issue comment --body-file` unchanged.
4. **State** — `gh issue create` has no `--state` flag; every issue is
   created open, then closed as a separate step if needed. Leave it open
   for `TODO`, `IN-PROGRESS`, and `REVIEW`. For `DONE`, close it after
   creating: `gh issue close <n>` (defaults to `state_reason: completed`).
   For `CANCELED`/`CANCELLED`, close it with `gh issue close <n> --reason
   "not planned"`.

```sh
gh issue create --title "..." --repo <owner>/<repo> --body-file body.md
gh issue comment <issue-number> --repo <owner>/<repo> --body-file notes.md
```

To edit an already-created issue/comment instead of creating a new one:
`gh issue edit <n> --body-file <file>` for the issue body; comments have no
`gh` subcommand for editing, use `gh api
repos/<owner>/<repo>/issues/comments/<comment-id> -X PATCH -f
body="$(cat <file>)"` (get the comment ID from the URL `gh issue comment`
printed when it was created, or `gh api
repos/<owner>/<repo>/issues/<n>/comments`).

## Guardrails

- **Never write `DONE`** — not in `status:`, not manually, not through any
  other path. The cap is always `REVIEW`.
- **Never `git commit` or `git push` in the project repo while a task note
  tracked by this skill is anything but `DONE`.** Work through the whole
  checklist stays uncommitted in the working tree — do not commit after each
  checked-off item; that fragments the history and loses the thread of what
  the task actually did. Commit (and push) only once the task note's
  `status` is `DONE` and the human has explicitly asked for that specific
  commit/push — a prior "commit and push" is not a standing license for the
  next one, and setting `DONE` is itself a human action this skill never
  takes (see "Never write `DONE`" above).
- **Never create a task note via a bare `vault-write`.** Always
  `/synapse-note --task`, or `/synapse-task-note` when compiling one from a
  `Ready` design note. A freeform write skips both the skeleton (checklist
  items plus a single `## Notes` section) and every guardrail in this file —
  there is no partial-credit version of following this skill.
- **Never restructure an existing task note's shape via `vault-write`/
  `vault-patch` outside this skill's own procedure.** Ad hoc edits that add
  new headings, drop the checklist, or otherwise diverge from the skeleton
  are what this guardrail exists to prevent — not just wrong `status:`
  values.
- Preserve `task_id` untouched — it is set manually (or resolved once by
  `/synapse-note --task`) and must not be auto-generated or overwritten.
- If checklist content is ambiguous or missing, default to `IN-PROGRESS`.
- Keep notes wording deterministic; avoid speculative claims.
