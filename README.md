# Synapse

[![tests](https://github.com/imunitic/synapse/actions/workflows/tests.yml/badge.svg)](https://github.com/imunitic/synapse/actions/workflows/tests.yml)

Memory for Claude Code: durable notes that outlive a session, and a per-repo code graph so a
codebase does not get re-explored from scratch every time. Three components, independent enough that
you can use one without the others:

- **Synapse Vault** — an Obsidian vault holding the notes: research, decisions, project logs, design
  discussions. Cross-project by default and searchable as ordinary Markdown.
- **Synapse Graph** — a per-repo semantic code graph, hosted *inside* the Vault under
  `synapse/{repo}@{branch}/`, so it is stored and searched like any other note. Dormant until
  `/synapse-init` is run in a repo.
- **Synapse Tools** — the scripts, commands, skills and hooks that build and maintain both.
- **Synapse Code Cache** — the vault-free acceleration layer underneath the Graph (tags, refs,
  call-graph). See [`docs/synapse-code-cache.md`](docs/synapse-code-cache.md).

This repository packages the **Tools**, plus the templates and config they need. It does not contain
your notes: the Vault's content is a separate sync concern (git, Obsidian Sync, iCloud, manual copy —
your call).

## Synapse Vault — the notes

- `claude/CLAUDE.md` — the global memory-system instructions: when to write a note, where it goes,
  and the linking rules.
- `claude/synapse.conf.template` — path config; set `OBSIDIAN_VAULT_DIR` per machine.
- `claude/hooks/synapse-session-start.sh` — `SessionStart`: injects the Vault's index and this repo's
  Graph namespace pointer, if one exists.
- `claude/hooks/synapse-stop-nudge.sh` — a turn-count-based `Stop` hook that nudges a "worth
  capturing?" check-in every 25 turns.
- `claude/hooks/synapse-db-sync.sh` — commits Vault changes to the Vault's own local git repo,
  if one exists.
- `claude/commands/synapse-note.md` — note creation (bare / `--task` / `--list` / `--search`).
- `claude/commands/synapse-design-note.md`, `claude/commands/synapse-task-note.md` — a design-discussion →
  compiled-checklist pipeline, cross-project by default (lives in the Vault, not a repo's gitignored
  `docs/notes/`).
- `claude/skills/synapse-task/` — proactive task-status tracking.
- `claude/skills/synapse-node-format/`, `claude/skills/synapse-orientation/`,
  `claude/skills/synapse-vault/` — loadable knowledge rather than procedure: the node contract, how to
  orient in an unfamiliar tree, and vault-editing rules (pull-only apart from `Index.md`), each shared
  across multiple components rather than owned by one.

## Synapse Graph — the per-repo code graph

A few dozen LLM-authored node notes per repo, one per subsystem or concept, each carrying a
plain-English summary, a quoted `crux`, typed links, and the exhaustive list of files it covers.

- `claude/commands/synapse-init.md` — first-time build: orientation pass, clustering into a
  `manifest.tsv`, then node notes plus two derived projections. Also the manual `_unassigned`-sweep
  fallback for an already-initialized but dormant repo.
- `claude/commands/synapse-rebuild.md` — manual repair for major drift (branch switch, long absence,
  large merge): triages each flagged node into **reseat**, **patch from the diff**, or **re-orient**.
- `claude/hooks/synapse-staleness.sh` — `PostToolUse` Tier 1: flags a just-edited file's nodes `stale`
  and re-verifies any evidence that file's nodes cite, via the Local REST API directly.
- `claude/skills/synapse-node/` — Tier 2: the lazy staleness check, regeneration and unassigned sweep
  Claude runs itself whenever a node's body is actually read.

## Synapse Tools — the scripts

- `claude/bin/synapse.sh` — the porcelain: one command with subcommands over everything below (e.g.
  `synapse.sh query stale`, `synapse.sh build-lists --reenumerate`), without collapsing the plumbing
  into it. Run `synapse.sh --help` for the full subcommand list, or `synapse.sh <subcommand> --help`
  for one script's own usage.

Every plumbing script below lives in `claude/lib/synapse/` and prints its own usage for `--help`;
`docs/scripts.md` is generated from those same header blocks.

- `claude/lib/synapse/synapse-query.sh` — read-only queries: `stale`, `drift`, `grounding`, `links`,
  `symbol <name> "{Node}"` (exact-name def/ref lookup within a node's sources), `body`, `sources`,
  `field`. None of them ever pull.
- `claude/lib/synapse/synapse-callers.sh` (`synapse-query.sh callers`) — repo-wide "who calls this exact
  name," over the flat index `synapse-build-refs.sh` writes. Needs no graph, node, or vault. See
  [`docs/synapse-code-cache.md`](docs/synapse-code-cache.md).
- `claude/lib/synapse/synapse-vocab.sh` — reduces a whole repo to `group ⇥ word ⇥ count` from tree-sitter
  symbol names, stopworded and aggregated by directory. Evidence for clustering. `--lists` keys by
  cluster instead, for `synapse-gate.sh`.
- `claude/lib/synapse/synapse-rank.sh` — decides what is worth reading when authoring a node: code by
  definitions-per-KB, declarative files by their code consumer, everything else zero. `--pool` splits
  summary (keeps everything) from crux (implementation only) reading order.
- `claude/lib/synapse/synapse-gate.sh` — the one quality check `/synapse-init` never had: flags a cluster with
  no differentiating vocabulary, so a bad cluster is caught before someone tries to write its summary
  and finds nothing to say.
- `claude/lib/synapse/synapse-enumerate.sh` — enumerates tracked files for a repo (drops binaries, lockfiles,
  minified output, submodule gitlinks, oversized files), standalone and vault-free. See
  [`docs/synapse-code-cache.md`](docs/synapse-code-cache.md).
- `claude/lib/synapse/synapse-build-lists.sh` — expands `manifest.tsv` into one path list per node on top of
  `synapse-enumerate.sh`'s output, printing `enumerated/covered/unassigned`.
- `claude/lib/synapse/synapse-write-node.sh` — writes one node: hashes sources, computes `sources_digest`,
  records the baseline commit, slices the `crux`, PUTs it. Refuses to write into a namespace whose
  `remote` belongs to a different repo.
- `claude/lib/synapse/synapse-push-nodes.sh` — loops the writer over every node with both a path list and an
  authored `b-NN.md`.
- `claude/lib/synapse/synapse-build-index.sh` — builds `_index.json`, the reverse index the Tier 1 hook reads.
- `claude/lib/synapse/synapse-build-project-index.sh` — builds `Index.md` from each node's own `summary`
  field.
- `claude/lib/synapse/synapse-identity.sh` — sourced, not executed: the one place a namespace (`{repo}@{branch}`)
  is named.
- `claude/lib/synapse/synapse-graph-clean.sh` — the only destructive tool here: removes namespaces whose
  branch upstream is gone. `--dry-run` available.
- `claude/lib/synapse/synapse-tags.sh` — optional tree-sitter acceleration; fails soft to a direct file read
  when tree-sitter, a compiler, or grammar support is missing.
- `claude/lib/synapse/synapse-tags-cache.sh` — keeps a per-file tag cache current, chunked and parallelized.
  Disable with `SYNAPSE_DISABLE_SYMBOL_CACHE`.
- `claude/lib/synapse/synapse-build-refs.sh` — projects the tags cache into a flat, sorted reference index —
  the artifact `synapse-callers.sh` reads.

Full design rationale and benchmark numbers for the Vault/Graph/Tools sections above (why each script
is shaped the way it is, measured costs, edge cases) are not repeated here — they are working notes
kept alongside the project, not part of the public interface this README documents.

## What's NOT portable (per-machine, regenerated fresh each time)

- The Obsidian Local REST API plugin's self-signed cert + API key — each install generates its own.
  `setup-obsidian-mcp.sh` extracts these *after* you've installed the plugin; it does not carry them
  over from another machine.
- The `obsidian` MCP server registration in `~/.claude.json` (contains the bearer token —
  machine-local, not meant to be copied or committed).
- `NODE_EXTRA_CA_CERTS` in `~/.claude/settings.json` (the path is machine-specific anyway).

## New machine setup

```sh
git clone <this repo> ~/synapse   # or copy the folder over
cd ~/synapse
./setup.sh
```

`setup.sh` installs the portable tooling into `~/.claude/`, merges hook entries into
`~/.claude/settings.json` (idempotent — safe to re-run, does not clobber unrelated settings), and
prints the manual steps below.

1. Install Obsidian, open (or create) your Vault.
2. **Settings → Community plugins → Browse**, install + enable:
   - **Local REST API with MCP** (required — the actual bridge)
   - **Headless Mode** (optional but recommended — lets Obsidian run as a background daemon with no
     visible window; enable "Start headless" in its settings)
   - **Iconic** (optional — folder/file icons)
3. Run:
   ```sh
   ./setup-obsidian-mcp.sh /path/to/your/vault
   ```
   This extracts the plugin's generated cert + API key, wires `NODE_EXTRA_CA_CERTS`, and registers the
   `obsidian` MCP server at user scope (available from any project, any directory). Safe to re-run if
   you ever reinstall the plugin — new cert and key each time.
4. Edit `~/.claude/synapse.conf`: set `OBSIDIAN_VAULT_DIR` to the Vault path.
5. (Recommended) Add Obsidian to macOS login items so it is always running:
   ```sh
   osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Obsidian.app", hidden:false}'
   ```
6. Restart Claude Code.

`setup.sh` is safe to re-run at any time. It migrates config filenames it recognises, rewrites hook
paths in `settings.json` rather than adding a second copy, and reports any file under `~/.claude/` that
it no longer installs, so nothing is left running that the docs stop describing.

## Testing

```sh
brew install bats-core parallel just     # if not already installed
just check                               # syntax + suite + generated artefacts, what CI runs
just test-changed                        # inner loop: only the tests covering what you edited
just test tests/synapse-query.bats       # one file
bats --jobs "$(getconf _NPROCESSORS_ONLN)" tests/   # the suite directly, what `just test` wraps
```

`--jobs` needs GNU `parallel` on `PATH`; without it `bats` falls back to running serially (slower but
correct). `just test-changed` narrows to the tests that name the files you edited, derived by grep
rather than a maintained list — a lower bound on coverage, so `just check` stays the gate before
committing.

Every test runs against a throwaway `$HOME`, git repo and Vault created in `tests/test_helper.bash` —
nothing touches your real `~/.claude` or Vault, and tests share no state, which is what makes
`--jobs` safe. The same suite runs in CI on **Linux** (`.github/workflows/tests.yml`); macOS is
covered by development itself.

The two generated artefacts (`docs/scripts.md`, the Mermaid diagrams under `docs/diagrams/`) are each
verified by running their generator's `--check` mode, so an edit that was never regenerated fails a
test instead of shipping something confidently wrong.

Not covered by the suite: `claude/commands/*.md` and `claude/skills/synapse-node/SKILL.md` are
natural-language procedures Claude follows, not code — there is nothing for a test framework to
execute there.

## Dependencies

`jq`, `bats-core` (tests only), the `claude` CLI. Optional: `tree-sitter` CLI plus a C compiler for
the Graph's tree-sitter acceleration (`synapse-tags.sh`), GNU `parallel` for `bats --jobs`, and Node
(for `npx`) to re-render the diagrams — everything degrades gracefully if any of them is missing, so
none is a hard requirement.

## License

MIT — see [LICENSE](LICENSE).
