---
name: synapse-vault
description: Synapse Vault is durable memory, and only its Index.md is ever auto-injected — every other note is pull-only. Load this BEFORE answering from your own reasoning about tooling behaviour, a past decision, a convention, a gotcha, or anything a previous session might have written down; and before creating or editing any note in the vault. Covers what to search with, and the vault_patch operations that silently destroy a note.
---

# Synapse Vault: search it first, and do not destroy it

Knowledge, not a procedure — like `synapse-node-format`. Nothing here tells you what to do
next; it tells you what is true about the store you are about to read from or write to.

## Only `Index.md` is pushed. Everything else is pull.

The SessionStart hook injects the vault's `Index.md` — folder layout and the namespace
catalogue. That is all. The other notes exist and are never injected, so the only thing standing
between you and a written-down answer is deciding to look.

**The failure this exists to prevent is not "not knowing". It is re-deriving, in the reply, a
thing the vault already says** — sometimes in three places at once. A wrong answer gets corrected;
a re-derived one is invisible, costs a turn, and quietly asserts that the memory system does not
work.

Search before you answer when the question is about:

- how a tool behaves, especially an option you have not used before
- whether a decision was already made, and why it went that way
- a convention, a naming rule, a threshold, a measured number
- anything that starts "I think it works like…"

```
mcp__obsidian__search_simple    full-text, relevance-ranked, with match context
mcp__obsidian__search_query     JsonLogic over frontmatter, tags, links, backlinks, path globs
mcp__obsidian__vault_list       when you already know roughly where it is
mcp__obsidian__vault_read       with targetType/target to pull one section, not the whole note
```

A search that returns nothing is a real result and worth one line in the note you then write —
a negative result cannot be rediscovered by searching for it.

## What silently destroys a note

Every item below returns success.

- **`vault_patch` + `operation: replace` targeting the H1 replaces the entire document.**
  `targetScope` defaults to `content` = "everything below this heading until one of the same or
  higher level", and below the H1 there is no higher level, so that is the whole note. To insert
  between the title and the first H2 — a status or metadata blockquote, the usual reason to touch
  that region — use **`operation: prepend` against the H1**. Never `replace`.
- **Heading targets are nested paths.** An H2 is `H1 title::H2 title`; a bare `H2 title` fails
  with "target not found in document", which reads like the heading is missing rather than like
  the path is wrong. `mcp__obsidian__vault_get_document_map` returns the exact `::` paths.
- **`operation: append` against the bare H1 can land one heading level too deep.** When the
  document's last section has a subheading of its own (e.g. `## Approach` ending in
  `### Alternatives considered`), an appended `## Notes` can come back as `### Notes`, nested
  under that last subsection instead of sitting as a sibling top-level heading. Target the
  specific preceding heading directly, or check `mcp__obsidian__vault_get_document_map` after —
  it shows the real heading tree, so a wrong level is visible immediately rather than assumed
  from the call's own success response.
- **Never `vault_patch` frontmatter.** `targetType: frontmatter` reads as field-local and is not:
  it re-serialises the whole YAML block, so unrelated values lose their quotes, long lines get
  re-wrapped, and an array value comes back as a quoted string instead of a real YAML list. Use
  `synapse frontmatter set <path> <key> <value>` (or `--add-tag`/`--remove-tag` for `tags`
  specifically; `synapse frontmatter get <path> <key>` reads one back) — it changes one field in
  the compiled binary, byte-preserving, without ever
  pulling the note's body into your context. It only handles a flat scalar or comma-separated
  array field; for anything it doesn't cover (a block-style value, or an edit outside
  frontmatter), fall back to reading the file, changing the one line, and writing the whole file
  back.
- **Do not patch for whitespace-precise edits.** A blank line between a heading and the block
  under it is exactly what a patch may normalise away. A disk-level file edit with a unique anchor
  is more predictable; Obsidian picks up external changes automatically.
- **Never hardcode the vault path.** The REST API targets whichever vault the running headless
  Obsidian has open. If you must reach disk, the path comes from `OBSIDIAN_VAULT_DIR` in
  `~/.claude/synapse.conf`.

## Verify with a structural invariant, not by re-reading what you wrote

Re-reading the region you just changed can only confirm the change landed. It is silent about
everything else the operation touched, which for a destructive edit is the entire question.

Count the H2s (`awk '/^## /' file`) or compare the byte size against what you read. **A
verification that cannot fail in the direction you are worried about is not a verification.**

## If you do destroy something

`synapse-hook db-sync` auto-commits every vault edit, so the intact version is one
`git show <sha>:<path>` away in the vault's own git history. That hook is a vault-wide undo for
destructive tool calls, not merely a record of intentional edits.

## Tagging is part of writing a note, not a separate pass

Every note-authoring command (`synapse-note`, `synapse-design-note`, `synapse-task-note`) applies tags as one of the steps in creating or substantially updating a note. There is no separate tagging pass or command — `/synapse-vault-tidy`'s recategorization signal reads tag data, it never writes it.

The vocabulary is `synapse-tag-vocabulary.conf` — one tag per line, `#`-comments allowed, agent-maintained but freely human-editable. It resolves with the same tiered lookup `synapse-projects.conf` uses: first `$XDG_CONFIG_HOME/synapse/synapse-tag-vocabulary.conf` if `$XDG_CONFIG_HOME` is set, else `~/.config/synapse/synapse-tag-vocabulary.conf`, then `~/.claude/synapse-tag-vocabulary.conf` — read whichever of those exists first. If none exists yet, create it fresh at `$XDG_CONFIG_HOME/synapse/synapse-tag-vocabulary.conf` when `$XDG_CONFIG_HOME` is set, else `~/.config/synapse/synapse-tag-vocabulary.conf` if `~/.config` already exists as a directory, else `~/.claude/synapse-tag-vocabulary.conf` as the final fallback. It lives outside the portable Synapse package, same as `synapse-projects.conf` — never committed there, never copied between machines.

Before adding a tag to a note, read the conf and prefer an existing entry over minting a new one. Add a new entry only for a genuinely new concept the existing vocabulary doesn't cover, and append it to the conf when you do. A note's tag set is agent-owned working content: a command may add or remove a tag freely, including one a human added by hand — there is no special protection that would block reconsidering it.

Tagging many existing notes at once (a backfill) should be rare to the point of not recurring — every note created through the authoring commands above is tagged inline as part of being written, so a vault only ever needs a backfill once, for notes that predate tagging being wired in at all. If one is ever needed anyway, resolve tags mechanically first: title text, folder path, and frontmatter (`task_id` prefix, `project` field) matched against the vocabulary settle the large majority of notes with no content read at all. Read a note's body only when those signals don't already resolve to at least one vocabulary tag. A full `vault_read` on every note in a large backfill spends session context on a decision cheap signals usually already make.

## The graph side of the vault

`synapse/{repo}@{branch}/` is not free-form notes. Nodes are written by `synapse write-node`
and regenerated by the `synapse-node` skill — never hand-edited, because the writer computes
`sources` hashes, `sources_digest` and the `## Sources` mirror, and a hand edit desynchronises
them. `_profile.txt` and `_manifest.tsv` are human-readable and may be edited directly. The
machine-only artifacts -- `_index.bin`, `_refs.tsv`, `_tags_cache.bin` -- are not here at all: they
live in `~/.claude/synapse-work/{repo}@{branch}/`, because they are derived, rebuildable and large,
and the vault is version-controlled.
