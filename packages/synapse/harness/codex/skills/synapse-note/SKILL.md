---
name: synapse-note
description: Create a plain note in Synapse Vault (bare mode — title + frontmatter, category resolved from the vault's index note), a tracked task note (task mode, scaffolds the checklist skeleton the synapse-task skill expects), list every tracked task, or search existing notes before creating a new one. Use for a note with no design framing, or any task note not compiled from a design discussion. Not for starting/continuing a design conversation (that's the synapse-design-note skill) or compiling a Ready one into a task (that's the synapse-task-note skill) — both of those delegate to this skill themselves.
---

# Synapse Note: Plain Vault Notes, Task Notes, Listing, and Search

Create a note in Synapse Vault with a title and mode, list existing tracked tasks, or search
existing notes before creating a new one.

## Determining what the user wants

There is no flag syntax here — read intent from how the user asks, then follow the matching mode
below:

- **Listing every tracked task** ("list my tasks", "what tasks are open") → **list mode**: see
  "List mode" below, skip note creation entirely.
- **Searching for an existing note** ("is there already a note about X", "search the vault for X")
  → **search mode**: see "Search mode" below, skip note creation entirely. This is also the mode to
  reach for programmatically (not just when the user explicitly asks to search) — per the Synapse
  Vault CLAUDE.md instructions, linking to an existing note is the highest-priority step before
  creating a new one, so run a search here before every bare-mode note creation, not only when a
  search is requested outright.
- **Asking to create a tracked, checklist-based task** ("make a task for X", "track this as a
  task") → **task mode**: scaffold the note as a tracked task, following the `synapse-task` skill's
  conventions. Task notes always live under `tasks/`.
- **Asking to create any other note** ("make a note about X", "save this as a note") → **bare
  mode**: create an empty node (title + frontmatter only). Which category folder it lands in is
  resolved from the vault's index note, per "Choosing a category (bare mode only)" below — not a
  fixed set. The typical categories are `research/`, `scratchpad/`, or `inbox/` — any plain note
  that isn't a task or design note.

The title is whatever the user is naming or describing, minus any mode-signaling phrasing. Example:

- "make a note about my idea" → bare note titled "My idea"
- "track this as a task: implement Foo" → task note titled "Implement Foo"; if no task ID is
  already present in that phrasing, "Resolving a missing task ID" below assigns one to `task_id`
  in frontmatter only, without changing the title

In task mode, also attempt to extract a task ID from the title by matching a `{prefix}-\d+` pattern
(letters, a hyphen, then digits) — the user sometimes already names one directly (e.g. "track
proj-035 — implement Foo"). Use it as `task_id` in frontmatter.

If no match is found, **don't just leave it blank** — see "Resolving a missing task ID" below before
proceeding.

## List mode

Run `synapse vault-search --fields frontmatter.task_id,frontmatter.status,frontmatter.title` with the JsonLogic query `{"var": "frontmatter.task_id"}` on stdin — one call returns every file that has a `task_id` set, each row already carrying `task_id`/`status`/`title` together, no second query or extra read needed.

Categorize:
- **Prefixed notes**: `task_id` matches `{prefix}-\d+`. Group by the distinct prefix found (whatever
  prefixes actually appear — don't assume a fixed set). Within each prefix, split further into:
  - **Open**: `status` is `TODO`, `IN-PROGRESS`, or `REVIEW` (or missing — treat as open)
  - **Closed**: `status` is `DONE`, `CANCELED`, or `CANCELLED`
- **Other notes**: no `task_id`, or one that doesn't match `{prefix}-\d+`

Sort each prefix group's notes numerically by task id (`{prefix}-9` before `{prefix}-10`); sort other notes alphabetically by title. Report one section per prefix found — "{prefix} notes — open", "{prefix} notes — closed" — plus "Other notes", each line as `{task-id or filename} — {title} [{status}]`. Omit a section header if it has zero entries. End with a total count.

Do not modify any files in list mode.

## Search mode

The user's search text is the query — whatever they named after asking to search, quotes stripped.

1. Run `synapse vault-search-text "{query}"` — this gives full-text relevance-ranked matches with context, the closest equivalent to a title/body search.
2. If the query looks like it's targeting metadata specifically (a tag, a task ID, a status value) rather than free text, also run `synapse vault-search --fields frontmatter.title` with an appropriate JsonLogic filter on stdin (e.g. `{"==": [{"var": "frontmatter.task_id"}, "proj-032"]}`).
3. Report matches as `{title} — {file path relative to vault root}`, deduped across both. If nothing matches, say so plainly — the caller (agent or user) needs a clear "no existing note" signal to proceed with task-mode-less creation.

Do not modify any files in search mode.

## Resolving a missing task ID (task mode only)

Triggered when task mode is requested but the title doesn't match `{prefix}-\d+`.

The known project/prefix pairs live in a plain local file named `synapse-projects.conf` (one
`project-name=prefix` line each) — read/appended as a plain text file, not the `vault-*` subcommands,
since it's outside the vault. It is deliberately **not** part of the portable
Synapse package and never copied between machines, so contexts that shouldn't mix (e.g.
personal vs. work projects) never end up in the same file. It's self-managed — this skill appends
newly resolved pairs to it — but also plain text, so the user can add, fix, or remove a line by hand
at any time.

Resolve *which* file that is with the same tiered lookup every `synapse-*.conf` file uses for
reading: first `$XDG_CONFIG_HOME/synapse/synapse-projects.conf` if `$XDG_CONFIG_HOME` is set, else
`~/.config/synapse/synapse-projects.conf`; then `~/.claude/synapse-projects.conf`. Read whichever of
those exists first. Append a newly resolved pair (step 5 below) to that same file.

If neither exists yet, decide where to create it fresh: `$XDG_CONFIG_HOME/synapse/synapse-projects.conf`
if `$XDG_CONFIG_HOME` is set; else `~/.config/synapse/synapse-projects.conf` if `~/.config` already
exists as a directory on this machine (it's adopted XDG conventions for other tools even without ever
setting the env var); else `~/.claude/synapse-projects.conf` as the final fallback — today's default,
unchanged for anyone who has never touched an XDG config directory.

1. Identify the current project from context: the repo's `CLAUDE.md` (title/"About" section) or
   `git remote`.
2. Check the resolved `synapse-projects.conf` for a line whose project name matches (loosely —
   case/whitespace-insensitive). If found, use that prefix directly — no need to ask.
3. If the file doesn't have it yet, fall back to deducing from the vault itself (useful the first
   time this runs, or for a project whose notes predate this file): `synapse vault-search-text` for
   the project/repo name across existing notes, and/or `synapse vault-search` on
   `{"var": "frontmatter.task_id"}` to see which prefixes exist, then check whether any of those
   prefixed notes reference this project. If exactly one prefix confidently matches, use it.
4. If nothing confidently matches (new project, or an ambiguous/multiple match), ask the user
   directly: "What's the project prefix for this task?" — plain free-text, not a multiple-choice
   list. Don't offer or hint at any other project's prefix as an option.
5. Whenever step 3 or step 4 resolves a pair not already in the conf file (including a fresh
   `project-name=prefix` line matching what was just deduced or asked), append it — so the next task
   for this project resolves from step 2 without a search or a question.
6. Once the prefix is known, find the next number. `task_id` and `note_id` (the id every note gets
   — see "Assigning a note_id" below) share one counter per prefix, so this has to check both
   fields, not just `task_id` alone: run `synapse vault-search --fields
   frontmatter.task_id,frontmatter.note_id` with `{"or": [{"!=": [{"var": "frontmatter.task_id"},
   null]}, {"!=": [{"var": "frontmatter.note_id"}, null]}]}` on stdin, filter both returned columns
   client-side for values matching `{prefix}-\d+`, take the highest number found across both, add
   1. If none exist yet for that prefix, start at 1.
7. Format the new task ID **zero-padded to 3 digits** (`{prefix}-001`, `{prefix}-030`,
   `{prefix}-037`, ...), matching the org-roam-era convention — widening
   naturally past 3 digits if a prefix ever needs it.
8. **The title itself is never prefixed with the task ID.** `task_id` lives in frontmatter only —
   the same convention `note_id` already uses for bare and design notes, now consistent across all
   three kinds. `title`, the `# ` heading, and the filename all stay exactly the given topic.

The synapse-design-note and synapse-task-note skills read the same conf file directly for the same
reason — they don't duplicate this resolution logic, just this file.

## Choosing a category (bare mode only)

Task mode always uses `tasks/` — skip this step entirely in task mode.

In bare mode, ask the user which category the note belongs to. Read the vault's index note's
folder list first — every top-level folder listed there except `designs`/`tasks`/`synapse`
(structurally fixed, not a bare-mode destination — see the vault-conventions skill's Folders
bullet) is a candidate category, offered with that folder's own index-note description as the
option's description. Don't hardcode a fixed option set: a fresh vault's index note lists
`research`/`scratchpad`/`inbox` (see the vault's own bootstrap template), but a vault owner's own
index note may have renamed or restructured these, and whatever it currently says is what gets
offered.

Resolve this to a `category` matching the folder name exactly as
the index note currently spells it, before moving on to the creation steps
below. No project-slug question is needed here — vault filenames are
the title itself, not a slug-prefixed timestamp, so there's no separate
namespacing concern to resolve. The note always lands flat at
`{category}/{filename}.md` — never inferred into a subfolder such as a
triage/priority one a vault owner might maintain by hand (e.g.
`inbox/{high,medium,low}/`, per that folder's own index-note description);
sorting a note into one of those, if a category has one, is never an
agent's call to make.

## Assigning a note_id (bare mode only)

Task mode already gets its id via "Resolving a missing task ID" above. Bare mode needs one too —
every note gets a `note_id`, not just tasks — but unlike task mode, this step never blocks with a
question: a quick bare note shouldn't require an interrupt just to get an id.

1. Try steps 1-3 of "Resolving a missing task ID" above (repo context, the resolved
   `synapse-projects.conf`, then deducing from the vault itself) to resolve a project prefix. Skip
   step 4 entirely — if none of the first three resolve one, fall through to step 2 below instead of
   asking.
2. If a prefix resolved: mint the next number the same shared-counter way as that section's step 6
   (checking both `task_id` and `note_id` across the vault for that prefix). If no prefix resolved:
   mint `note-NNN` instead — its own flat, project-less counter, found the same way (`synapse
   vault-search --fields frontmatter.note_id`, filter for `note-\d+`, take the highest, add 1; start
   at 1 if none exist yet).
3. Carry the resolved `{id}` into "Creating the note" below as `note_id`. Unlike task mode, the title
   itself is untouched — no id prefix on the visible title or the `title` frontmatter field for a bare
   note.

## Resolving the project folder (task mode only)

Task notes are grouped one level deeper by project, `tasks/{project}/{filename}.md` — see the
vault's index note's `tasks/` section. The prefix (`proj`, `sb`, ...) is not itself the folder name
— it names the *task*, not the *project* — so resolve what project it belongs to, regardless of how
the prefix became known (matched from the title, resolved in "Resolving a missing task ID" above,
or supplied directly by a caller like the synapse-task-note skill):

1. Reverse-lookup the prefix in the resolved `synapse-projects.conf` (same tiered lookup as
   "Resolving a missing task ID" above) — find the line whose value after `=` equals the prefix;
   its key is the project name.
2. If no line matches, check the index note's `tasks/` section, which documents the prefix-to-project
   mapping directly (e.g. `proj-NNN` → `widget`).
3. If still unresolved (a genuinely new prefix with no mapping anywhere), ask the user for the
   project name and append `{project-name}={prefix}` to the conf file — so the next task note
   under this prefix resolves without asking.

## Creating the note

1. Sanitize the title into a filename: replace filesystem-illegal
   characters (`/ : * ? " < > |`) with `-`, collapse repeated whitespace.
   No timestamp prefix, no project-slug prefix — the filename is just the
   (sanitized) title.
2. Resolve tags through the `synapse-vault` skill's configured
   `synapse-tag-vocabulary.conf` procedure. Choose only configured entries; an empty list is valid
   when no tag applies, but the field itself is mandatory.
3. Fetch machine local time once: `date '+%Y-%m-%d %H:%M:%S %Z'` — never use inferred
   time. Use the exact same value for `created` and `updated`.
4. Build the file content. Bare notes require a concise Summary. Task notes require lead prose and
   at least one real flat checklist item before the first write.

   **Bare mode:**
   ```
   ---
   schema: vault-note/v1
   title: "{title}"
   note_id: {id}
   created: "{now}"
   updated: "{now}"
   tags: [{comma-separated tags, or empty}]
   ---

   # {title}

   ## Summary

   {essential content}
   ```

   **Task mode:**
   ```
   ---
   schema: vault-task-note/v1
   title: "{title}"
   project: {prefix}
   task_id: {task-id}
   created: "{now}"
   updated: "{now}"
   tags: [{comma-separated tags, or empty}]
   status: TODO
   ---

   # {title}

   {task description}

   ## Checklist

   - [ ] {first implementation step}

   ## Notes

   {constraints or context}
   ```
5. Write it with `synapse vault-write <path>` (content on stdin). Task mode: path
   `tasks/{project}/{filename}.md` (project resolved in "Resolving the
   project folder" above). Bare mode: path `{category}/{filename}.md`
   (category resolved above).

## Confirm

Report the file path back to the user.

- Bare mode: report the Summary that was captured.
- Task mode: note the task ID extracted or resolved, and remind the user
  that future status transitions are managed by the `synapse-task` skill.
