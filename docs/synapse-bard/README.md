# synapse-bard

Sibling plugin to Synapse, built for a different consumer: a YAML-templated fiction book bible
(character/place/faction/item entries) instead of a code repo. Two binaries, mirroring
`synapse`/`synapse-hook`'s own relationship — `synapse-bard` is the tooling a person or an agent
runs; `synapse-bard-hook` carries its Claude Code hooks and is registered in `settings.json`
rather than invoked directly. Unlike `synapse`, neither binary ever imports `treesitter` —
`synapse-bard` parses YAML frontmatter only, so its whole build links no libtree-sitter and needs
no C compiler, not just the hook side.

`synapse-bard sync` builds `_bard/graph/` from a bible repo's own folder structure — one node per
source folder (a "cluster"), each carrying a `sources:` manifest of its member entities, mirroring
Synapse's own code-graph shape rather than one file per entity. `query`/`field`/`fields`/`search`
resolve against that graph: `query` for an entity's resolved relationships, `field` for one raw
frontmatter value, `fields` for a template's own field names (so an agent knows what's worth
asking instead of guessing one key at a time), `search` for full-text or structured `key:value`
lookups.

- **[cli.md](cli.md)** — reference for every subcommand of `synapse-bard` and every hook of
  `synapse-bard-hook`: usage, arguments and exit codes. **Generated**, the same way Synapse's own
  is — from what the binaries print for `--help`, never hand-written.

No deeper design-note-style docs live here yet — the Bible-graph and Writer's notes vault design
is tracked as design notes and task notes in the Synapse Vault, not published to this repo. This
directory currently only has the mechanically-generated CLI surface.
