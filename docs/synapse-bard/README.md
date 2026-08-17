# synapse-bard

Sibling plugin to Synapse, built for a different consumer: a YAML-templated fiction book bible
(character/place/faction/item entries) instead of a code repo. Two binaries, mirroring
`synapse`/`synapse-hook`'s own relationship — `synapse-bard` is the tooling a person or an agent
runs; `synapse-bard-hook` carries its Claude Code hooks and is registered in `settings.json`
rather than invoked directly. Unlike `synapse`, neither binary ever imports `treesitter` —
`synapse-bard` parses YAML frontmatter only, so its whole build links no libtree-sitter and needs
no C compiler, not just the hook side.

- **[bard-graph.md](bard-graph.md)** — **Bible-graph**: the structured half. `sync`'s
  folder-taxonomy clustering (no LLM orientation pass needed, unlike Synapse's own), the
  frontmatter-only extraction contract, `sources:` as the seam between a cluster node and its real
  entity files, and why there's no staleness/crux/grounding machinery here at all.
- **[bard-vault.md](bard-vault.md)** — **Writer's notes vault**: the free-form half. Why it's
  repo-local from day one rather than an Obsidian vault like Synapse's own, the one `SessionStart`
  hook (and the three Synapse Vault hooks it deliberately doesn't have), `vault-search`/
  `vault-links`'s wikilink-accurate resolution, and how the design→task workflow was adapted rather
  than shared.
- **[cli.md](cli.md)** — reference for every subcommand of `synapse-bard` and every hook of
  `synapse-bard-hook`: usage, arguments and exit codes. **Generated**, the same way Synapse's own
  is — from what the binaries print for `--help`, never hand-written.
- **[bard-config.md](bard-config.md)** — every environment variable and conf file `synapse-bard`
  reads, which is almost none: both stores are repo-local, so nearly everything Synapse's own
  config reference exists to bridge (an external vault location, cross-project state) simply
  doesn't apply here.

Diagrams live in [diagrams/](diagrams/), same convention as Synapse's own: a Mermaid source (`.mmd`)
plus a rendered `.png`, linked rather than fenced so the docs read the same in GitHub, Markview, and
any plain Markdown viewer. `docs/synapse-bard/generate-diagrams.sh` re-renders whichever sources
changed and records each one's hash, so `--check` (wired into `just docs-check`) fails if a `.mmd`
was edited and never re-rendered — an out-of-date diagram would otherwise sit there looking
authoritative.

- `diagrams/bard-overview.png` — the whole plugin in one picture: two repo-local stores under one
  bible repo, no third, externally-hosted store either depends on.
- `diagrams/bard-graph-pipeline.png` — `sync`'s clustering and extraction pipeline, and what it
  deliberately has no equivalent of (staleness, crux, grounding).
- `diagrams/bard-vault-overview.png` — the vault's one hook, contrasted directly against
  [Synapse Vault's four](../synapse/synapse-vault.md#the-three-hooks).

## Why this is two stores, not one shared with Synapse's own Vault

The Bible-graph answers "what are the facts" — structured, mechanical, sourced straight from YAML.
The Writer's notes vault answers "what did we decide, and why" — free-form, narrative, authored by
a person. Keeping them as two separate `Store` implementations over two separate directories
(`_bard/graph/`, `_bard/vault/`) rather than merging them mirrors why Synapse itself keeps code-graph
nodes and free-form vault notes as two systems sharing one host rather than one undifferentiated
pile of notes.

What's different from Synapse's own arrangement is *where* that host lives. Synapse Vault is one
Obsidian instance shared across every project on the machine, reached over its Local REST API —
durable exactly because it outlives any single repo. `synapse-bard`'s two stores are both
repo-local instead, plain files under `_bard/` in the bible repo itself, because this plugin's real
authoring environment is the Android app's default cloud session: an Anthropic-managed VM with no
network route to anything on the author's own machine. An externally-hosted vault is precisely the
one thing that session can never reach, so both stores were designed repo-local from the start
rather than routed around the gap afterward. See [bard-vault.md](bard-vault.md#why-repo-local-and-not-an-obsidian-vault-like-synapses-own)
for the fuller account, including the design this superseded.

That also means `synapse-bard` needs almost no configuration at all — see
[bard-config.md](bard-config.md).
