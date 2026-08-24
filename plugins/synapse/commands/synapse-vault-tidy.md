---
description: Run one on-demand vault-tidy pass over Synapse Vault -- surface recategorization candidates (notes that no longer fit their folder, clusters that deserve a new top-level category, categories that have gone stale) into a single inbox/ proposal, silently fill in the one class of missing-frontmatter default that has an unambiguous fix, and fold the rest of note health (broken links, orphaned notes, duplicate titles) into that same proposal since none of them has a safe mechanical repair either. Use whenever the user wants the vault's own organization checked or tidied ("tidy the vault", "check vault health", "any notes drifted out of their folder", "find orphaned/duplicate notes"). Never invoked automatically -- no SessionStart wiring, no autonomous scheduling; run it yourself, or under your own /loop if you want a cadence. Scoped to everything except designs/, tasks/, and synapse/ (the code graph's own generated namespace), which stay entirely /synapse-status's (the first two) or /synapse-init's (the third) territory.
---

# Synapse Vault Tidy: Recategorization Proposals and Note-Health Fixes

A single on-demand pass over Synapse Vault's free-form taxonomy (`inbox/`/`research/`/`scratchpad/`/
whatever a given install's `Index.md` currently lists) that a person would otherwise have to notice
and fix by hand: a note's folder fit drifting since it was filed, several notes sharing enough in
common to deserve a category of their own, a category that stopped earning its keep, a link that
broke when its target moved, a note nothing points to or from, two notes that are really the same
thing under slightly different titles. Nothing here runs unprompted — it exists because nothing else
in the vault periodically re-checks any of this, not because it's meant to run behind the user's
back.

Never touches `designs/`, `tasks/`, or `synapse/` — the first two are `/synapse-design-note`'s and
`/synapse-note --task`'s own interface for directing project work (any gap found there is
`/synapse-status`'s territory, not this command's); `synapse/` is the code graph's own generated
namespace, a different note kind entirely, owned and kept fresh by `/synapse-init` and the
`synapse-node`/`synapse-node-format` skills. `Index.md` and any vault-root `README.md` are also out
of scope — foundational files, not taxonomy notes.

## Usage

```
/synapse-vault-tidy    # Run one vault-tidy pass
```

## Prerequisites

Requires the `obsidian` MCP server (`mcp__obsidian__*` tools). If unreachable, say so and stop —
there is no local-file fallback.

No compiled code anywhere in this command. `adapters/obsidian/store.zig`'s `ObsidianStore` only
implements `write`, for the code graph's own node-authoring flow — vault reads deliberately go
through these same MCP tools rather than the compiled binary, the same way `/synapse-status` and
`/synapse-rebuild-diff`'s vault-side checks already work.

## Step 1: Inventory sweep

Enumerate every note in scope and read each one exactly once — every later step reuses this same
sweep rather than re-reading anything.

```
{"and": [
  {"!": [{"glob": ["designs/*", {"var": "path"}]}]},
  {"!": [{"glob": ["tasks/*", {"var": "path"}]}]},
  {"!": [{"glob": ["synapse/*", {"var": "path"}]}]},
  {"!=": [{"var": "path"}, "Index.md"]},
  {"!=": [{"var": "path"}, "README.md"]}
]}
```

`mcp__obsidian__search_query` with that filter, then `mcp__obsidian__vault_read` each match. Keep
the full result (`path`, `frontmatter`, `tags`, `links`, `backlinks`, `unresolvedLinks`, `stat`,
`content`) per note — Steps 2–4 below only ever reason over the structured fields, never `content`
itself; the judgment layer in Step 5 is the first point anything actually reads note *bodies*, and
only for the subset flagged by then. `content` is fetched for free in this same call regardless, so
there's no separate "light" read to bother with.

## Step 2: Frontmatter defaults (fixed directly)

The only note-health fix applied silently, because it's the only one with exactly one correct
answer per note. Design and task notes are out of scope entirely; the plain/free-form schema is
just two fields (`title`, `created` — see `synapse-note`'s bare-mode format), both derivable without
guessing:

- Missing `title` → the filename with its `.md` extension stripped.
- Missing `created` → `stat.ctime`, formatted `YYYY-MM-DD HH:MM` to match every other note's
  convention.

Apply via read-modify-write on the whole file (`vault_read` → edit the one frontmatter line in the
returned content → `vault_write` the whole file back) — never `vault_patch` with
`targetType: frontmatter`, which re-serializes the entire YAML block and silently reformats
unrelated fields, the same hazard `synapse-vault`/`synapse-task` already document.

## Step 3: Note-health findings (reported, not fixed)

From the same inventory, no additional reads. Each of these three has no safe mechanical repair —
fixing any of them means guessing at intent — so they become findings for the Step 6 proposal
instead of a silent edit:

- **Broken links** — `unresolvedLinks` non-empty.
- **Orphaned notes** — `links` empty *and* `backlinks` empty.
- **Duplicate/near-duplicate titles** — group notes by title normalized (lowercased, trimmed,
  internal whitespace collapsed); any group with 2+ members is a finding. This is a mechanical
  string-normalization match, not fuzzy similarity — genuinely fuzzy "these might be the same
  note" calls belong to the judgment layer in Step 5, not here.

## Step 4: Recategorization signal layer

Mechanical, from the same inventory, still no note-body reasoning:

- **Weak folder fit** — a note (not already an orphan from Step 3) that shares no tag with any
  other note in its own folder, and where fewer than half of its combined `links`+`backlinks` point
  to notes within that same folder.
- **Uncovered clusters** — a tag or keyword held by 3+ notes spanning 2+ different folders, where no
  existing top-level folder name (from `Index.md`'s current list) already matches it.
- **Stale categories** — a scope-eligible top-level folder whose newest note's `stat.mtime` is more
  than 90 days old (no new note gained in that window) is flagged as a merge-back candidate, the
  same way a newly proposed split is flagged — one signal, checked at a different point in a
  category's life.

## Step 5: Recategorization judgment layer

For each Step 4 candidate — a weak-fit note, a cluster, or a stale folder — read its full content
(and, for a cluster, every member's content) and decide with real judgment, not the mechanical
signal alone:

- Weak-fit note: does it genuinely belong in a different existing category, or was the signal a
  false positive (a note that's fine where it is, just thin on tags/links)?
- Cluster: given what these notes actually say, is this a real emerging category, or just a
  coincidental shared keyword?
- Stale folder: has it truly stopped being useful, or is low volume expected and fine (a narrow but
  still-active category)?

Never moves a note or creates a folder here — every conclusion becomes one line in the Step 6
proposal, for the vault owner to act on.

## Step 6: Compose the proposal

One note, `inbox/Vault tidy — {YYYY-MM-DD}.md` (fetch machine local time, never infer it), written
via `vault_write` (creates `inbox/` automatically if it doesn't exist yet; if `inbox/` isn't already
in `Index.md`'s folder list, add it there in the same pass, matching the folder-layout rule every
other command that can create a top-level folder already follows). Two sections:

```
## Recategorization
- {note or cluster}: {proposed move/new category/merge}, because {reasoning}

## Note health
- Broken link in {note}: → {target text that doesn't resolve}
- Orphaned: {note}
- Possible duplicate: {note A} / {note B}
```

Omit either section if Steps 3–5 found nothing for it. If both are empty, don't write a proposal at
all — say so directly instead of creating an empty note.

This command never edits `Index.md` itself beyond the `inbox/` bootstrap case above — creating or
renaming a category is the vault owner's call, made by hand using
[[sb — Make vault folder taxonomy user-customizable via Index.md.template]]'s already-shipped
mechanism, not something this command does on its own.

## Step 7: Report

Print a short summary directly in the response, not left only in tool-call output:

- Count of frontmatter defaults silently filled, with filenames.
- Count of recategorization candidates and note-health findings written to the proposal, with a
  link to `inbox/Vault tidy — {date}.md`.
- If nothing was found anywhere: "Vault's in good shape — nothing to fix or propose."

## Constraints

- Never touches — moves, edits, or reorganizes — anything inside `designs/`, `tasks/`, or
  `synapse/`. `Index.md` and a vault-root `README.md` are also out of scope.
- Recategorization never auto-moves a note or auto-creates a folder — proposal only, to `inbox/`.
- Only the frontmatter-default class of note-health fix (Step 2) is applied directly and silently.
  Broken links, orphaned notes, and duplicate titles are proposal findings, never auto-repaired.
- Invoked on demand only — no `SessionStart` wiring, no autonomous scheduling. Run it directly, or
  under a `/loop` the user sets up themselves.
- No compiled code — every step above is a plain `mcp__obsidian__*` call; `ObsidianStore` gets no
  new read path.
