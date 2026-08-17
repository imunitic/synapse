---
name: synapse-bard-vault
description: The Writer's notes vault (_bard/vault/) is durable memory for decisions and rationale that outlive a session, git-tracked in this repo. Only its Index.md is auto-injected -- every other note is pull-only. Load this BEFORE answering from your own reasoning about a character, scene, or plot decision, and before creating or editing any note in the vault.
---

# The Writer's notes vault: search it first

Knowledge, not a procedure. Nothing here tells you what to do next; it tells you what is true
about the store you are about to read from or write to.

## Where it lives, and how you reach it

`_bard/vault/` at the repo root — plain markdown files, git-tracked, in the same repo and session
you're already working in. There is no Obsidian, no REST API, no separate server standing between
you and it: `Read`/`Write`/`Edit`/`Glob`/`Grep`, the same tools you use on any other file in this
repo, are the whole interface. This is the entire point of a repo-local vault — it works identically
whether you're in an interactive session or the Android app's default cloud session, which can never
reach a service running on the author's own machine.

**Prefer `synapse-bard vault-search <query>` over `Grep` when you're looking for the most relevant
note, not just any match.** It's the same full-text substring search, but ranked by each matching
note's backlink count — the vault's most-referenced note on a topic surfaces first, which a raw
`Grep` has no way to do (it can only report matches in whatever order the filesystem hands them
back). `Grep` still has its place for anything positional or regex-shaped `vault-search` doesn't
cover; reach for `vault-search` first when what you actually want is "the note this vault treats
as central to X."

**Prefer `synapse-bard vault-links <note>` over `Grep` when the question is "which notes link
here."** `Grep -r "\[\[note-name"` finds only the literal string, so it misses a `[[note-name|some
other alias]]` link and can't tell a real link from an incidental substring match. `vault-links`
resolves the same way Obsidian itself does — filename stem, `.md` suffix optional, alias-aware, no
self-backlink — and takes either a full vault-relative path or just the stem, same as a
`[[wikilink]]` target would.

**The Bible-graph side (`_bard/graph/`) is different: `synapse-bard` has a real CLI for it
(`synapse-bard-002`).** Anything about a character's established relationships, appearance, voice, or
other frontmatter facts goes through `synapse-bard query`/`field`/`search`, not `Grep` on
`_bard/graph/*.md` directly — the CLI resolves wikilinks to their target's real kind and can find
backlinks (`--inbound`) a raw grep can't produce correctly, the same "consult before grepping" habit
this section already asks for on the vault side.

```
synapse-bard query <slug>              an entity's resolved outbound relationships
synapse-bard query <slug> --inbound    who references <slug> -- backlinks
synapse-bard field <slug> <key>        one raw frontmatter field, verbatim (e.g. images,
                                        appearance.* is not reachable via query -- query only
                                        ever surfaces wikilink-bearing fields)
synapse-bard search <text>             full-text over _bard/graph/
synapse-bard search --field <key>:<value>   e.g. --field faction:"The Radiant Dominion"
```

## Only `Index.md` is pushed. Everything else is pull.

If `synapse-bard-hook`'s `SessionStart` handler is wired up (see this repo's own `synapse-bard-001`
task note), it injects `_bard/vault/Index.md` — folder layout only. Every other note exists and is
never injected, so the only thing standing between you and a written-down answer is deciding to
look.

**The failure this exists to prevent is not "not knowing". It is re-deriving, in the reply, a thing
the vault already says** — a character's established motivation, a plot mechanic already settled, a
"we're not resolving X until book 2" decision. A wrong answer gets corrected; a re-derived one is
invisible, costs a turn, and quietly contradicts continuity the author already fixed on purpose.

Search before you answer when the question is about:

- a character's established motivation, backstory, or a scene already drafted
- whether a plot or worldbuilding decision was already made, and why it went that way
- tone, phrasing, or continuity conventions specific to this book
- anything that starts "I think this was already decided…"

```
Grep "query" _bard/vault/**/*.md      full-text, unranked
Glob _bard/vault/**/*.md              when you already know roughly where it is
Read _bard/vault/{path}               pull the whole note -- there is no section-only read yet
```

A search that returns nothing is a real result and worth one line in the note you then write — a
negative result cannot be rediscovered by searching for it.

## Editing safely

There is no partial-patch API here, unlike a REST-backed vault — `Write` always replaces the whole
file, `Edit` matches an exact string. The safe pattern is the same one a REST-backed vault has to be
told to fall back to: **read the whole file, change what needs changing, write the whole file
back.** There is no frontmatter-reserialization footgun, no nested-heading-path footgun, because
there is no separate patch operation to misuse in the first place.

- **Never hand-edit `_bard/graph/`.** Those nodes are extracted from the Bible's own `template:`
  frontmatter by `synapse-bard`'s `BardFrontmatterExtractor` — a hand edit there is immediately
  stale the next time the graph is rebuilt from source. If a fact is wrong, fix it in the actual
  Bible entity file, not in `_bard/graph/`.
- **A new top-level folder under `_bard/vault/` must never fall behind `Index.md`.** If you create
  `_bard/vault/{new-folder}/` for the first time, add its entry to `Index.md`'s folder layout in the
  same action.

## Undo

`_bard/vault/` is git-tracked, but nothing auto-commits it the way the coding side's
`synapse-hook db-sync` does — there is no `synapse-bard-hook` equivalent yet. An uncommitted mistake
is only as recoverable as your editor's own undo or the session's own file history; a committed
mistake is one `git show <sha>:<path>` away, same as any other tracked file. If you're about to make
a destructive edit and the author hasn't committed recently, say so before proceeding.
