---
description: Create a note in the Writer's notes vault (bare mode — title + frontmatter, category resolved from Index.md), a tracked task note (--task, scaffolds the checklist skeleton synapse-bard-task expects), list every tracked task (--list), or search existing notes (--search) before creating a new one. Use for a note with no design framing, or any task note not compiled from a design discussion. Not for starting/continuing a design conversation (that's synapse-bard-design-note) or compiling a Ready one into a task (that's synapse-bard-task-note) — both of those delegate to this command themselves.
---

Create a note in the Writer's notes vault (`_bard/vault/`) with the title and options, list existing notes, or search existing notes: $ARGUMENTS

## Where the vault lives

`_bard/vault/` at the repo root — plain markdown files, git-tracked, in the same repo and session you're already working in. No Obsidian, no REST API, no separate server: read and write it with the ordinary Read/Write/Edit/Glob tools, same as any other file in this repo. `Grep` over `_bard/vault/**/*.md` is full-text search; there is no ranked/backlink-scored search surface yet (that's a future `synapse-bard` CLI capability, not built — see this repo's own `synapse-bard-001` task note if you're curious).

Unlike the coding-focused `synapse` plugin's vault, this is **always single-project** — one repo is one book bible, one vault. There is no cross-project prefix to resolve, no `synapse-projects.conf` equivalent: a task ID here is just `task-{NNN}`, sequential, nothing else.

## Argument parsing

If `$ARGUMENTS` is `--list` (or starts with `--list`) → **list mode**: see "List mode" below, skip note creation entirely.

If `$ARGUMENTS` starts with `--search` → **search mode**: see "Search mode" below, skip note creation entirely. This is also the mode to reach for programmatically (not just when the user explicitly asks to search) — per the `synapse-bard-vault` skill, checking what was already decided about a character or scene is the highest-priority step before creating a new note, so run a search here before every bare-mode note creation, not only when a search is requested outright.

Otherwise, split `$ARGUMENTS` on `--task`:

- If `--task` is present → **task mode**: scaffold the note as a tracked task, following the `synapse-bard-task` skill's conventions. Task notes always live under `tasks/`.
- Otherwise → **bare mode**: create an empty node (title + frontmatter only). Which category folder it lands in is resolved from `Index.md`, per "Choosing a category (bare mode only)" below.

The title is everything before `--task` (trimmed). Example:

- `/synapse-bard-note "Renwick's motive for the betrayal"` → bare note
- `/synapse-bard-note "Resolve Calla's parentage before book 2 draft" --task` → task note

In task mode, resolve the next sequential `task-{NNN}` (see "Resolving a task ID" below) — there is no prefix to extract from the title, unlike the coding vault.

## List mode

`Glob` for `_bard/vault/tasks/**/*.md`, then `Read` (or `Grep` the frontmatter block) each for `task_id`, `status`, and `title`.

Categorize:
- **Open**: `status` is `TODO`, `IN-PROGRESS`, or `REVIEW` (or missing — treat as open)
- **Closed**: `status` is `DONE`, `CANCELED`, or `CANCELLED`

Sort numerically by task id (`task-9` before `task-10`). Report as two sections, "Tasks — open" and "Tasks — closed", each line `{task-id} — {title} [{status}]`. Omit a section if it has zero entries. End with a total count.

Do not modify any files in list mode.

## Search mode

Everything after `--search` (trimmed, quotes stripped) is the query.

1. `Grep` the query across `_bard/vault/**/*.md`, case-insensitive, with a line or two of context.
2. Report matches as `{title} — {file path relative to repo root}`, deduped by file. If nothing matches, say so plainly — the caller needs a clear "no existing note" signal to proceed with `--task`-less creation.

Do not modify any files in search mode.

## Resolving a task ID (task mode only)

1. `Glob` for `_bard/vault/tasks/**/*.md`.
2. For each, read its `task_id` frontmatter field, filter for ones matching `task-\d+`.
3. Take the highest number found, add 1. If none exist yet, start at 1.
4. Format zero-padded to 3 digits (`task-001`, `task-030`, ...) — widening naturally past 3 digits if the book ever needs it.
5. **Prepend the resolved task ID to the title itself** — the final title becomes `{task-id} — {original title}` (em dash). Use this same final title for both the `title` frontmatter field and the `# ` heading, and use the resolved task ID for `task_id`. Don't let the frontmatter task ID and the visible title disagree.

## Choosing a category (bare mode only)

Task mode always uses `tasks/` — skip this step entirely in task mode.

In bare mode, ask the user which category the note belongs to. Read `Index.md`'s folder list first — every top-level folder listed there except `designs`/`tasks` (structurally fixed, not a bare-mode destination — `designs/` is `/synapse-bard-design-note`'s own destination) is a candidate category, offered with that folder's own `Index.md` description as the option's description. Don't hardcode a fixed option set: a fresh vault's `Index.md` lists `projects`/`research`/`scratchpad`/`inbox` (per the shipped default — `projects/` for per-book/scene iteration logs, `research/` for worldbuilding notes, `scratchpad/`/`inbox/` unchanged in meaning), but the author may have renamed or restructured these, and whatever `Index.md` currently says is what gets offered.

Resolve this to a `category` matching the folder name exactly as `Index.md` currently spells it. The note always lands flat at `{category}/{filename}.md` — never inferred into a subfolder an author might maintain by hand.

## Creating the note

1. Sanitize the title into a filename: replace filesystem-illegal characters (`/ : * ? " < > |`) with `-`, collapse repeated whitespace. No timestamp prefix — the filename is just the (sanitized) title.
2. Fetch machine local time: `date '+%Y-%m-%d %H:%M'` — never use inferred time. Use this for the `created` frontmatter field.
3. Build the file content:

   **Bare mode:**
   ```
   ---
   title: "{title}"
   created: "{now}"
   ---

   ```

   **Task mode:**
   ```
   ---
   title: "{title}"
   created: "{now}"
   task_id: {task-id}
   status: TODO
   last_updated: "{now}"
   ---

   # {title}

   ## Notes

   ```
4. `Write` it. Task mode: path `_bard/vault/tasks/{filename}.md`. Bare mode: path `_bard/vault/{category}/{filename}.md`.

## Confirm

Report the file path back to the user.

- Bare mode: note that the note is intentionally near-empty.
- Task mode: note the task ID resolved, and remind the user to populate the `## Notes` section and checklist before starting work, per the `synapse-bard-task` skill.
