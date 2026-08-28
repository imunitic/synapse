# synapse-bard

A memory and structure system for fiction writing: a YAML-templated book bible
(character/place/faction/item entries) instead of a code repo. Two binaries: `synapse-bard` is the
tooling a person or an agent runs; `synapse-bard-hook` carries its Claude Code hooks and is
registered in `settings.json` rather than invoked directly. Neither binary ever imports
`treesitter` — `synapse-bard` parses YAML frontmatter only, so its whole build links no
libtree-sitter and needs no C compiler, not just the hook side.

- **[bard-graph.md](bard-graph.md)** — **Bible-graph**: the structured half. `sync`'s
  folder-taxonomy clustering (no LLM orientation pass needed), the frontmatter-only extraction
  contract, and `sources:` as the seam between a cluster node and its real entity files.
- **[bard-vault.md](bard-vault.md)** — **Writer's notes vault**: the free-form half. Why it's
  repo-local from day one, the one `SessionStart` hook, `vault-search`/`vault-links`'s
  wikilink-accurate resolution, and how the design→task workflow was adapted for fiction.
- **[cli.md](cli.md)** — reference for every subcommand of `synapse-bard` and every hook of
  `synapse-bard-hook`: usage, arguments and exit codes. **Generated** from what the binaries print
  for `--help`, never hand-written.
- **[bard-config.md](bard-config.md)** — every environment variable and conf file `synapse-bard`
  reads, which is almost none: both stores are repo-local, so there's no external vault location
  or cross-project state to bridge.

Diagrams live in [diagrams/](diagrams/): a Mermaid source (`.mmd`) plus a rendered `.png`, linked
rather than fenced so the docs read the same in GitHub, Markview, and any plain Markdown viewer.
`docs/synapse-bard/generate-diagrams.sh` re-renders whichever sources changed and records each
one's hash, so `--check` (wired into `just docs-check`) fails if a `.mmd` was edited and never
re-rendered — an out-of-date diagram would otherwise sit there looking authoritative.

- `diagrams/bard-overview.png` — the whole plugin in one picture: two repo-local stores under one
  bible repo, no third, externally-hosted store either depends on.
- `diagrams/bard-graph-pipeline.png` — `sync`'s clustering and extraction pipeline.
- `diagrams/bard-vault-overview.png` — the vault's one hook.

## Why this is two stores, not one

The Bible-graph answers "what are the facts" — structured, mechanical, sourced straight from YAML.
The Writer's notes vault answers "what did we decide, and why" — free-form, narrative, authored by
a person. Keeping them as two separate `Store` implementations over two separate directories
(`_bard/graph/`, `_bard/vault/`) rather than merging them keeps that distinction real instead of
collapsing into one undifferentiated pile of notes.

Both stores are repo-local, plain files under `_bard/` in the bible repo itself, because this
plugin's real authoring environment is the Android app's default cloud session: an
Anthropic-managed VM with no network route to anything on the author's own machine. A
remotely-hosted vault is precisely the one thing that session can never reach, so both stores were
designed repo-local from the start rather than routed around the gap afterward. See
[bard-vault.md](bard-vault.md#why-repo-local-and-not-a-hosted-vault-on-another-machine) for the
fuller account, including the design this superseded.

That also means `synapse-bard` needs almost no configuration at all — see
[bard-config.md](bard-config.md).
