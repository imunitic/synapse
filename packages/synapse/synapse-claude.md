# Synapse Vault as permanent memory

The user keeps a permanent, curated knowledge base — **Synapse Vault** —
as a memory system separate from and complementary to the `~/.claude`
auto-memory system: use the Vault for durable, browsable
knowledge-base notes, not for session bookkeeping. Reach it through the
`synapse` CLI's `vault-*` subcommands, never a raw file edit or an MCP tool
call — see "Reading and writing the vault" below for why. A SessionStart hook
already injects the vault's `Index.md` at the start of every session, so
you shouldn't need to go read it yourself. Don't re-read it reflexively,
but do treat its injected contents as live information, not background
flavor. If the hook instead reports that the configured vault has no
`Index.md` yet, offer to seed it from the shipped default
(`${CLAUDE_PLUGIN_ROOT}/Index.md.template`) before creating or
linking any note in this session — never copy it yourself without asking;
seeding the vault's foundational bootstrap file warrants a confirmation
step the way an ordinary note-write doesn't.

**This is a primary, load-bearing memory system, not an optional nicety.**
Actively use it — don't wait to be asked, and don't wait for a hook to
remind you either: the periodic nudge below is a backstop for a session
that runs long and drifts, not the trigger that authorizes writing in the
first place. You MUST create or update a note whenever, during a session,
any of the following happens. Before deciding
which folder, check `Index.md`'s folder list for the matching category —
don't rely on categories already in memory from earlier in the session,
since a vault owner's own `Index.md` is the only authority on what exists
and what each folder means:

- A non-trivial bug is diagnosed and fixed, especially if the root cause
  or the fix was non-obvious.
- The user states a preference, a decision, or a piece of standing
  context ("we always do X", "the reason we do Y is...") that isn't
  already captured in a note.
- A project reaches a milestone, or its direction/scope changes.
- You do research (reading docs, comparing libraries/approaches,
  evaluating tradeoffs) that would be wasteful to redo from scratch next
  time.
- An existing note is now stale or wrong in light of what just happened —
  update it in place rather than leaving it to rot.

If none of these clearly apply, err on the side of asking yourself the
question rather than silently skipping it — a nudge hook periodically
prompts exactly this check; treat that prompt as a real question requiring
a real yes/no answer, not a formality to wave past.

- **Linking is the highest-priority step, not an afterthought.** Before
  writing a new note, search for related existing notes (see "Searching
  notes" below) and link to them — prefer linking over duplicating content
  every time a related note exists. If genuinely nothing else applies,
  link the new note back to the index itself rather than leaving it an
  orphan with zero backlinks.
- **Split growing notes rather than letting one balloon.** During a long
  session (e.g. a multi-hour debugging or optimization effort), don't just
  keep appending every new finding to the same note indefinitely. Once a
  note is accumulating genuinely separate findings/topics rather than one
  cohesive update, split the new material into its own linked note instead
  of growing the original further. A handful of focused, well-linked notes
  is more useful later than one sprawling one — easier to search, easier to
  link into from elsewhere, easier to skim.
- Folders: two are structurally fixed, and hardcoded here on purpose —
  `designs/` (design directions already discussed and agreed, created by
  `/synapse-design-note`) and `tasks/` (concrete tracked tasks, created
  only by `/synapse-task-note` or `/synapse-note --task`, never freeform).
  Every install has both; the commands that write to them assume those
  exact names regardless of what a vault's `Index.md` says. Beyond those
  two, `Index.md`'s own folder list is the authority on what exists and
  what each one is for — check it rather than assuming a fixed set. A
  fresh vault ships with `research/`, `scratchpad/`, and `inbox/` as a
  starting point (see `${CLAUDE_PLUGIN_ROOT}/Index.md.template`), but a vault owner's own
  `Index.md` may have renamed or restructured them; if nothing about a
  note fits an existing category, use whichever folder `Index.md` itself
  marks as the catch-all (`inbox/` by default) rather than forcing a bad
  fit or inventing a folder for a one-off. Agents may create new folders
  beyond what `Index.md` lists, but folder depth is capped at two levels
  (`folder/subfolder`, never deeper). Creating a new top-level folder
  requires adding a matching entry to `Index.md` in the same action — the
  index must never fall behind what's actually on disk.
- **`tasks/` and `designs/` both group one level deeper by project**,
  using the two-level cap above: `tasks/{project}/` and
  `designs/{project}/` (e.g. `tasks/widget/`, `designs/synapse/`). A design
  note already carries its project as a `project:` frontmatter field, so
  its subfolder is that value directly. A task note has no such field —
  decide from its task-prefix family per `Index.md`'s `tasks/` section
  (`proj-NNN` → `widget`, `sb-NNN` → `synapse`) or, for a non-prefixed note,
  from its title naming that same project. Either way, a note with no
  established project family stays flat directly in `tasks/` or
  `designs/` — don't invent a one-note subfolder.
- **`inbox/` notes are always freeform-titled, never numbered.** This
  includes the standalone-idea subtype ("worth doing someday" items that
  surface mid-discussion) — it gets a plain descriptive title like any
  other inbox note, not a sequential id. `inbox/{high,medium,low}/`
  subfolders may exist as an optional, human-managed-only triage layer —
  an agent never creates them, never infers a priority, and never moves a
  note into or between them. Always write a new inbox note flat into
  `inbox/` root; the user triages it by hand whenever they choose to.

## Reading and writing the vault

The vault is reached through the `synapse` CLI — `synapse vault-read`/`vault-write`/`vault-list`/
`vault-search`/`vault-search-text`/`vault-doc-map`/`vault-patch`/`vault-backlinks`/`vault-links`/
`vault-unresolved`/`vault-orphans`/`vault-deadends`/`vault-ambiguous`/`vault-rename` — for reads
*and* for writes, never by resolving a vault path or calling an `mcp__obsidian__*` tool directly.
Which concrete store the CLI talks to (`SYNAPSE_VAULT_INTEGRATIONS unset`, the default; `obsidian`, opted
into for a running Obsidian app's own live search relevance and graph data; or `git`, opted into for
the vault to own its own version control -- commit on every write, push/pull in the background) is
resolved once,
inside the compiled binary, from `SYNAPSE_VAULT_INTEGRATIONS`/`SYNAPSE_VAULT_DIR` — never something a skill
or an agent turn needs to know or branch on. By default that means no Obsidian dependency
whatsoever: `read`/`write`/`list`/`search`/the link graph/rename are all plain disk I/O and direct
computation against the vault folder. Under the opted-in `obsidian` backend, `search`/the link
graph/rename go through Obsidian's own CLI over its local socket instead when Obsidian is running,
falling back to the same disk-backed behavior automatically and silently (a one-line stderr note,
nothing an agent turn needs to react to) whenever it isn't — no precondition to check or fail on
either way.

**Every write to a note goes through `synapse vault-write` or `vault-patch`. Never the `Write`/`Edit`
tools on the on-disk path, and never a raw `mcp__obsidian__*` tool call either** — not for a one-line
change, and least of all when `Write`/`Edit` are already in hand from editing code earlier in the
same turn, because that proximity is precisely what causes this to be violated. The vault being an
ordinary directory means the wrong path *works*: Obsidian's file watcher converges, the auto-commit
hook matches `Write|Edit`/`Bash` running `vault-write`/`vault-patch`, and nothing visibly breaks —
which is why the habit never self-corrects on its own. The reason is not a
failure mode to dodge; it is that an invariant upheld only when convenient is worth nothing. Nothing
else in the system can rely on it, and every note then has to be re-checked by hand instead of
trusted. Synapse's own tooling holds this line — `synapse write-node` goes through the same `Store`
abstraction the CLI does, rather than writing files directly — so agent writes have no reason to
differ. If the CLI itself ever fails (not installed, no vault configured), that's a real precondition
failure to report and stop on, never a reason to fall back to a raw file edit.

Every shipped command and skill, `/synapse-vault-tidy` included, reaches the vault only through
the `synapse` CLI's `vault-*` subcommands — none of them calls an `mcp__obsidian__*` tool.

- You may create and edit notes in this vault **without asking for
  permission first**, as long as each note is placed in the folder
  matching its category per `Index.md`.
- Filenames are human-readable titles (not timestamp-prefixed — Obsidian's
  sidebar/graph display the filename directly, so a timestamp prefix reads
  poorly there). Sanitize filesystem-illegal characters (`/ : * ? " < > |`)
  but otherwise keep the title as-is.
- Frontmatter carries what the filename no longer does: `title`, `created`
  (real timestamp at creation time), and for task notes `task_id` /
  `status` (`TODO`/`IN-PROGRESS`/`REVIEW`/`DONE`/`CANCELED`).
- Link with Obsidian wikilinks: `[[filename]]` or `[[filename|display
  text]]` (no extension, exact filename minus `.md`).
- **Never hard-wrap note bodies. A newline exists if and only if a break is
  intended in the output** — source line structure mirrors the output's block
  structure. Write each paragraph and each list item as one single unbroken
  line and let the editor soft-wrap it. Sentence and clause boundaries are
  *not* logical breaks: the paragraph is the unit and sentences flow within
  it. Line-based constructs — headings, list items, table rows, frontmatter,
  code blocks — legitimately own their newlines and keep them.

  The point is not merely that rewrapping by hand is tedious (though it is,
  and stray newlines are diff and search-context noise). It is that this
  makes the text **renderer-independent**: if a newline never appears where
  no break is wanted, then "does a single newline render as `<br>` or as a
  space?" never arises, and strict CommonMark, non-strict CommonMark,
  Obsidian, pandoc and GitHub all produce the same result — the ambiguous
  input case is simply gone. This is HTML's content model applied to plain
  text: a newline is markup meaning "break here", not cosmetic formatting of
  the source file.

  It also keeps **line length a view decision rather than a content one**.
  Hard-wrapping is the author asserting a measure, baking one viewport into
  the text; unwrapped, the same bytes are correct at every width — Obsidian's
  "Readable line length" on or off, a narrow split pane, a wide monitor,
  mobile, print. Hard-wrapped prose fails both ways and is unfixable at read
  time: at 80 columns it double-wraps raggedly in a narrow pane, and sits as a
  fixed narrow ribbon in a wide one. Wanting a ~66-character measure is right
  (it's a real typographic optimum, which is why that setting exists) — put it
  in the renderer, which can adapt, not in the content, which can't.

  **Corollary — never fake a break.** Don't rely on a soft newline inside a
  paragraph or blockquote to produce separate lines, and don't reach for
  trailing double-spaces or a trailing `\`. If several entries each need
  their own line, they *are* separate items: use a list, which owns its line
  breaks, nested inside the blockquote if the blockquote framing is wanted
  (`> - entry`). Consecutive bare `>` lines render as one flowing paragraph
  under strict CommonMark, and separating them with blank `>` lines makes
  them full paragraphs with paragraph spacing — neither is what "three
  labelled lines" means.

  Accepted costs, both tooling-side rather than content-side: a line-based
  diff treats a paragraph as atomic (use word-level diffing — `--word-diff`,
  or a review UI that highlights intra-line changes), and very long lines are
  awkward in tools that don't soft-wrap (`less` without `-S`, narrow terminal
  diffs).
- Create notes via the `/synapse-note` command. **Task notes are a hard
  exception, not a style preference:** create them only with
  `/synapse-note --task` (or compile one from a `Ready` design note with
  `/synapse-task-note`), and make every status transition, checklist edit,
  or `## Notes` append only through the `synapse-task` skill's own
  procedure — never a bare `vault-write`/`vault-patch` on a task note, not
  even mid-session, not even for a quick update. Bypassing the command/skill
  doesn't just risk drifting from the checklist-items-plus-`## Notes`
  skeleton every other task note shares — the skill is also where the
  guardrails live, most importantly that `status:` never reaches `DONE`
  through it, capped at `REVIEW` instead, and a freeform write has no such
  cap. If the command or skill genuinely doesn't fit what a task note needs,
  that's a signal to fix the command/skill, not a license to route around
  it once.

## Searching notes

Prefer `synapse vault-search-text`/`vault-search` over raw file grepping — they read the vault
directly and don't require re-deriving paths:

- `synapse vault-search-text <query>` — full-text search with relevance scoring and match context,
  for "does a note about X already exist" checks.
- `synapse vault-search --fields <f1,f2,...>` — JsonLogic queries over note metadata (frontmatter
  fields, tags, content, path globs — not `links`/`backlinks`, which no CLI subcommand exposes yet)
  when you need a structured filter rather than free text, e.g. finding all notes with a given
  `task_id` or `status`. `--fields` projects exactly the columns needed back in the same call, so a
  follow-up read is rarely necessary.
- `synapse vault-list` / `vault-read` for direct navigation when you already know roughly where
  something is. `synapse vault-doc-map <path>` lists a note's heading paths, block ids, and
  frontmatter keys, for picking a real `vault-patch` target instead of guessing one.

# Git commits

Do not add a `Co-Authored-By: Claude ...` trailer to commit messages.
Enforced via `attribution.commit: ""` in `~/.claude/settings.json`, which
suppresses it mechanically — this note is a backstop in case that setting
ever gets reverted or overridden by a project-level settings file.
