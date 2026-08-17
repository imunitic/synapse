# The Writer's notes vault as permanent memory

`_bard/vault/` is a durable, browsable knowledge base — decisions, rationale, and continuity that
outlive a session — plain markdown files, git-tracked, in this repo. A `SessionStart` hook already
injects the vault's `Index.md` at the start of every session, so you shouldn't need to go read it
yourself. Don't re-read it reflexively, but do treat its injected contents as live information, not
background flavor. If the hook instead reports that the vault has no `Index.md` yet, offer to seed
it from the shipped default (`Index.md.template` in the `synapse-bard` plugin) before creating or
linking any note in this session — never copy it yourself without asking; seeding the vault's
foundational bootstrap file warrants a confirmation step the way an ordinary note-write doesn't.

**This is a primary, load-bearing memory system, not an optional nicety.** Actively use it — don't
wait to be asked. You MUST create or update a note whenever, during a session, any of the following
happens. Before deciding which folder, check `Index.md`'s folder list for the matching category —
don't rely on categories already in memory from earlier in the session, since the vault's own
`Index.md` is the only authority on what exists and what each folder means:

- A plot, worldbuilding, or continuity decision gets settled — including a small one made in
  passing, not just a big structural call.
- The author states a preference or a piece of standing context about tone, a character, or the
  world ("she's always guarded around Gael", "we're not resolving X until book 2") that isn't
  already captured in a note.
- A scene, arc, or book reaches a milestone, or its direction/scope changes.
- You do worldbuilding research (reading reference material, comparing approaches, working out how
  a magic system or a political structure actually functions) that would be wasteful to re-derive
  from scratch next time.
- An existing note is now stale or wrong in light of what just happened — update it in place rather
  than leaving it to rot.

If none of these clearly apply, err on the side of asking yourself the question rather than silently
skipping it.

- **Linking is the highest-priority step, not an afterthought.** Before writing a new note, search
  for related existing notes (`Grep`/`Glob` over `_bard/vault/**/*.md`) and link to them — prefer
  linking over duplicating content every time a related note exists. If genuinely nothing else
  applies, link the new note back to the index itself rather than leaving it an orphan.
- Folders: two are structurally fixed — `designs/` (created by `/synapse-bard-design-note`) and
  `tasks/` (created only by `/synapse-bard-task-note` or `/synapse-bard-note --task`, never
  freeform). Beyond those two, `Index.md`'s own folder list is the authority on what exists — check
  it rather than assuming a fixed set. Creating a new top-level folder requires adding a matching
  entry to `Index.md` in the same action.
- See the `synapse-bard-vault` skill for the mechanics of reading and editing the vault safely
  (there's no partial-patch API here — read the whole file, change what needs changing, write the
  whole file back) and for the "search before you answer" habit in full. This file states the
  obligation to write; that one states how.
- **Task notes are a hard exception, not a style preference.** Create them only with
  `/synapse-bard-note --task` (or compile one from a `Ready` design note with
  `/synapse-bard-task-note`), and make every status transition, checklist edit, or `## Notes` append
  only through the `synapse-bard-task` skill's own procedure — never a bare `Write`/`Edit` on a task
  note, not even mid-session, not even for a quick update. The skill is where the guardrails live,
  most importantly that `status:` never reaches `DONE` through it, capped at `REVIEW` instead — a
  freeform write has no such cap.

## Never hard-wrap note bodies

A newline exists if and only if a break is intended in the output — source line structure mirrors
the output's block structure. Write each paragraph and each list item as one single unbroken line
and let the editor soft-wrap it. Sentence and clause boundaries are *not* logical breaks: the
paragraph is the unit and sentences flow within it. Line-based constructs — headings, list items,
frontmatter, code blocks — legitimately own their newlines and keep them.

This isn't a style preference, it's a rendering-correctness rule: if a newline never appears where
no break is wanted, "does a single newline render as `<br>` or as a space?" never comes up, and every
renderer (Obsidian, GitHub, a plain `cat`) produces the same result. It also keeps line length a view
decision rather than a content one — the same unwrapped bytes are correct at every width, where
hard-wrapped prose is wrong at some width no matter what you pick.

Never fake a break either: don't rely on a soft newline inside a paragraph to force separate lines,
and don't reach for trailing double-spaces. If several entries each need their own line, they *are*
separate items — use a list.

## The Bible-graph has a query CLI — use it, not `Grep`, on `_bard/graph/`

`synapse-bard` ships a real command surface over the structured entity data in `_bard/graph/`. For
anything about a character or entity's established relationships, appearance, voice, or other
frontmatter facts, reach for these before grepping the raw YAML directly — the CLI resolves a
wikilink to its target's real kind and can find backlinks a raw grep can't produce correctly at all:

```
synapse-bard query <slug>              an entity's resolved outbound relationships
synapse-bard query <slug> --inbound    who references <slug> -- backlinks
synapse-bard field <slug> <key>        one raw frontmatter field, verbatim (e.g. images --
                                        query only ever surfaces wikilink-bearing fields, so
                                        appearance/voice/images are otherwise invisible to it)
synapse-bard search <text>             full-text over _bard/graph/
synapse-bard search --field <key>:<value>   e.g. --field faction:"The Radiant Dominion"
```

`<slug>` is the wikilink target text without `.md` (`calla-starweaver`, not `Calla Starweaver` and
not `calla-starweaver.md`). There is no equivalent CLI over `_bard/vault/` yet — that side is still
`Grep`-driven, per the `synapse-bard-vault` skill.
