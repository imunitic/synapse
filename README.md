# <img src="docs/logo.svg" width="28" height="28" alt=""> Synapse

[![tests](https://github.com/imunitic/synapse/actions/workflows/tests.yml/badge.svg)](https://github.com/imunitic/synapse/actions/workflows/tests.yml)

Memory for Claude Code: durable notes that outlive a session, and a per-repo code graph so a
codebase does not get re-explored from scratch every time. Three components, independent enough that
you can use one without the others:

- **Synapse Vault** — an Obsidian vault holding the notes: research, decisions, project logs, design
  discussions. Cross-project by default and searchable as ordinary Markdown.
- **Synapse Graph** — a per-repo semantic code graph, hosted *inside* the Vault under
  `synapse/{repo}@{branch}/`, so it is stored and searched like any other note. Dormant until
  `/synapse-init` is run in a repo. Underneath it is the **Code Cache** — tags, refs and call
  graph, no vault involved — which is a layer of the Graph rather than a fourth component, even
  though the binary alone is enough to use it (`synapse callers` needs no graph, no vault and no
  nodes). See [`docs/synapse/synapse-code-cache.md`](docs/synapse/synapse-code-cache.md).
- **Synapse Tools** — the scripts, commands, skills and hooks that build and maintain both.

This repository packages the **Tools**, plus the templates and config they need. It does not contain
your notes: the Vault's content is a separate sync concern (git, Obsidian Sync, iCloud, manual copy —
your call).

## New machine setup

Synapse installs via npm — one package (`@imunitic/synapse`), one setup command, three harnesses
(Claude Code, Codex CLI, OpenCode):

```sh
npm install -g @imunitic/synapse
synapse-setup configure claude       # or: codex / opencode
```

`npm install` alone already puts the right compiled binaries (`synapse`, `synapse-hook`) on disk —
`@imunitic/synapse` depends on a per-platform package (`@imunitic/synapse-darwin-arm64` etc.) that
npm resolves automatically for the machine it's running on, so there's nothing to fetch or build
afterward. `zig build` is only for contributing to Synapse itself; see [Dependencies](#dependencies).

> Not yet published to the npm registry. Until then, run from a checkout instead:
> ```sh
> git clone https://github.com/imunitic/synapse
> cd synapse/packages/synapse
> node bin/synapse-setup.cjs configure claude   # or: codex / opencode
> ```
> This needs the platform binaries built locally first (`zig build`, or `just build`) and copied
> into `platforms/{platform}-{arch}/bin/` — see [Dependencies](#dependencies).

1. Install Obsidian, open (or create) your Vault.
2. **Settings → Community plugins → Browse**, install + enable:
   - **Local REST API with MCP** (required — the actual bridge)
   - **Headless Mode** (optional but recommended — lets Obsidian run as a background daemon with no
     visible window; enable "Start headless" in its settings)
   - **Iconic** (optional — folder/file icons)
3. Point Synapse at the vault — create `~/.claude/synapse.conf` (or, on a machine that's adopted
   XDG config directories, `$XDG_CONFIG_HOME/synapse/synapse.conf`) with one line:
   ```sh
   SYNAPSE_VAULT_DIR="$HOME/path/to/your/vault"
   ```
   Nothing prompts for this during `npm install` — `synapse-setup configure claude` is the step that
   actually wires things up, and it doesn't ask for this either. Skip it and the next session's
   `SessionStart` hook says so directly instead of staying silent.
4. Restart Claude Code, or start a fresh session — `synapse-setup configure claude` already
   registered the `obsidian` MCP server and wrote `NODE_EXTRA_CA_CERTS` for you, and a
   `SessionStart` hook keeps that registration current on every future session (new cert and key
   whenever the Obsidian plugin reinstalls), no script to re-run by hand.
5. Check the result:
   ```sh
   synapse doctor
   ```
   One line per precondition, and it exits non-zero if any of them is broken. Worth running
   even when everything seems fine, because almost every guard in the system is *silent* by
   design — a hook that errors is worse than one that quietly does nothing, so a half-installed
   machine looks exactly like a working one with nothing to say. `doctor` is the one place that
   speaks: a missing certificate, an Obsidian that is not running, a namespace whose recorded
   remote no longer matches, a hook registered twice (which makes it fire twice).
6. (Recommended) Set Obsidian to start automatically at login, so it is always running:
   - **macOS**:
     ```sh
     osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Obsidian.app", hidden:false}'
     ```
     or **System Settings → General → Login Items → +**.
   - **Linux**: drop an XDG autostart entry (works across GNOME/KDE/XFCE):
     ```sh
     mkdir -p ~/.config/autostart
     cat > ~/.config/autostart/obsidian.desktop <<'EOF'
     [Desktop Entry]
     Type=Application
     Name=Obsidian
     Exec=obsidian
     X-GNOME-Autostart-enabled=true
     EOF
     ```
     Adjust `Exec=` to match your install (e.g. the AppImage path, or `flatpak run md.obsidian.Obsidian`
     for a Flatpak install).
   - **Windows**: press **Win+R**, type `shell:startup`, hit Enter, then drop a shortcut to
     `Obsidian.exe` into the folder that opens.

**Using it:** the human-facing entry points are `/synapse-init`, `/synapse-rebuild-diff`, and
`/synapse-rebuild-full` — `/synapse-init` builds a repo's first Graph namespace,
`/synapse-rebuild-diff` repairs one after major same-branch drift (triage, nothing deleted),
`/synapse-rebuild-full` wipes a namespace and rebuilds it from scratch when triage isn't the right
tool. Neither of the two repair commands requires knowing anything below this point. The `synapse`
binary underneath them isn't something you're expected to run by hand; its subcommands are
documented in [`docs/synapse/cli.md`](docs/synapse/cli.md) for whoever goes looking.

### Codex CLI and OpenCode

Synapse also runs under [Codex CLI](https://github.com/openai/codex) and
[OpenCode](https://opencode.ai) — same compiled `synapse`/`synapse-hook` binaries, same Vault, same
Graph, adapted per harness rather than reimplemented, and the same `synapse-setup configure
<harness>` command shown above:

```sh
synapse-setup configure codex       # or: opencode
```

- **Hooks** — `SessionStart`/`UserPromptSubmit`/`PostToolUse`/`Stop` equivalents, registered in each
  harness's own hook mechanism (Codex: the global `~/.codex/hooks.json`; OpenCode: a plugin file
  copied to `~/.config/opencode/plugin/`). Merges into anything already there rather than
  overwriting it.
- **The `obsidian` MCP connection** — registered against the Local REST API plugin's plain-HTTP
  fallback (`http://127.0.0.1:{port}/mcp/`) rather than the HTTPS endpoint the Claude Code hook
  uses, since neither harness has a way to trust that endpoint's self-signed cert. **Requires the
  plugin's plain-HTTP server enabled first**: in Obsidian, **Settings → Local REST API → Enable HTTP
  server**.
- **Skills and commands** — the shared `packages/synapse/skills/` copied into each harness's own skill
  directory (`~/.codex/skills/`, `~/.config/opencode/skill/`), plus, for OpenCode only, the shared
  `packages/synapse/commands/` copied into `~/.config/opencode/command/` (its command format already matches
  this repo's own argument convention verbatim). Codex has no equivalent positional-argument
  mechanism, so its 8 command-equivalents are separately hand-authored under
  `packages/synapse/harness/codex/skills/` and copied in alongside the shared skills instead.

OpenCode needs no manual step at all — its plugin resolves the installed binary's path directly.
Codex needs one: it reads the vault's bearer token from a named env var, never inline in
`config.toml`, so `configure codex` prints the export line to add to your shell profile:

```sh
export SYNAPSE_OBSIDIAN_API_KEY="{key}"
```

Add it, restart your terminal, then restart Codex — it additionally prompts to trust the
newly-written hooks on its next session, approve that interactively. Re-run `configure <harness>`
any time to pick up a newer Synapse release or repair a broken install; it's idempotent and safe to
run repeatedly.

## Synapse Vault — the notes

- `packages/synapse/synapse-claude.md` — the global memory-system instructions: when to write a note, where it
  goes, and the linking rules. Injected directly by the `SessionStart` hook every session (the same
  mechanism that injects `Index.md`), not via a `CLAUDE.md` `@import` line — `~/.claude/CLAUDE.md`
  stays entirely yours, untouched.
- `packages/synapse/synapse.conf.template` — path config; set `SYNAPSE_VAULT_DIR` per machine.
- `synapse-hook session-start` — `SessionStart`: injects the Vault's index and this repo's
  Graph namespace pointer, if one exists.
- `synapse-hook stop-nudge` — a turn-count-based `Stop` hook that nudges a "worth
  capturing?" check-in every 25 turns, and pushes the Vault to its git remote every
  `SYNAPSE_VAULT_PUSH_EVERY` turns (default 5), detached so a turn never waits on the network.
- `synapse-hook db-sync` — commits Vault changes to the Vault's own local git repo,
  if one exists.
- `packages/synapse/commands/synapse-note.md` — note creation (bare / `--task` / `--list` / `--search`).
- `packages/synapse/commands/synapse-design-note.md`, `packages/synapse/commands/synapse-task-note.md` — a design-discussion →
  compiled-checklist pipeline, cross-project by default (lives in the Vault, not a repo's gitignored
  `docs/notes/`).
- `packages/synapse/skills/synapse-task/` — proactive task-status tracking.
- `packages/synapse/skills/synapse-node-format/`, `packages/synapse/skills/synapse-orientation/`,
  `packages/synapse/skills/synapse-vault/` — loadable knowledge rather than procedure: the node contract, how to
  orient in an unfamiliar tree, and vault-editing rules (pull-only apart from `Index.md`), each shared
  across multiple components rather than owned by one.

## Synapse Graph — the per-repo code graph

A few dozen LLM-authored node notes per repo, one per subsystem or concept, each carrying a
plain-English summary, a quoted `crux`, typed links, and the exhaustive list of files it covers.

- `packages/synapse/commands/synapse-init.md` — first-time build: orientation pass, clustering into a
  `manifest.tsv`, then node notes plus two derived projections. Also the manual `_unassigned`-sweep
  fallback for an already-initialized but dormant repo.
- `packages/synapse/commands/synapse-rebuild-diff.md` — manual repair for major same-branch drift (a pull, a
  rebase, a long absence): triages each flagged node into **reseat**, **patch from the diff**, or
  **re-orient**. Refuses outright on a cross-branch mismatch.
- `packages/synapse/commands/synapse-rebuild-full.md` — wipes the current namespace and rebuilds it from
  scratch via `/synapse-init`, for when triage isn't the right tool. Preserves any hand-written
  `## Notes` first (`synapse graph-wipe`) and auto-merges what it can back into
  the new nodes afterward.
- `synapse-hook staleness` — `PostToolUse` Tier 1: flags a just-edited file's nodes `stale`
  and re-verifies any evidence that file's nodes cite, via the Local REST API directly.
- `packages/synapse/skills/synapse-node/` — Tier 2: the lazy staleness check, regeneration and unassigned sweep
  Claude runs itself whenever a node's body is actually read.

## What's NOT portable (per-machine, regenerated fresh each time)

- The Obsidian Local REST API plugin's self-signed cert + API key — each install generates its own.
  The `obsidian-mcp-refresh.cjs` `SessionStart` hook extracts these automatically, every session,
  *after* you've installed the Obsidian plugin; it does not carry them over from another machine.
- The `obsidian` MCP server registration in `~/.claude.json` (contains the bearer token —
  machine-local, not meant to be copied or committed).
- `NODE_EXTRA_CA_CERTS` in `~/.claude/settings.json` (the path is machine-specific anyway).

## Testing

```sh
brew install bats-core parallel just     # if not already installed
just test-changed                        # per commit: only the tests covering what you edited
just test tests/synapse-query.bats       # one file
just test-linux                          # the whole suite in the container, ~30s
just check                               # the full gate, ~26s -- before pushing
just check-local                         # same, bats on the host instead -- no podman needed
bats --jobs "$(getconf _NPROCESSORS_ONLN)" tests/   # the suite directly, what `just test` wraps
```

**What to run when.** `just check` is the pre-push gate, not a per-commit ritual — running it
reflexively is a way of not thinking about what a change can break, and the thinking is the part that
catches things. Per commit, run what the change touches; `just test-changed` picks that automatically
from your diff, and `just test-linux` is the honest answer whenever a change is broad or you are
unsure. A change to prose in `docs/` or this README has no test to fail and needs neither.

Two traps in that. Shipped instructions under `plugins/*/` **look** like documentation and are not: they
install as a Claude Code plugin, and `tests/legacy-commands.bats` covers them — that
is how a skill telling Claude to run a nonexistent command got caught. And each project's `cli.md`
(under `docs/synapse/`, `docs/synapse-bard/`) plus the diagrams are *generated*, so a change
upstream of them needs `just fix`, not `just docs-check`.

`--jobs` needs GNU `parallel` on `PATH`; without it `bats` falls back to running serially (slower but
correct). `just test-changed` derives its selection by grep rather than from a maintained list — a
lower bound on coverage, which is the right trade per commit and the wrong one before a push.

`just check` runs the suite in the Linux container, which is not a preference: the same ~480 tests take
~30s there against six to seven minutes on the host, because macOS `fork`/`exec` costs 6.5ms where
Linux costs 0.24ms. That took the gate from ~8min to 2:20, and finding the same tax inside
`ci/check-layering.sh` — two forked greps per source line, 113s — took it to ~40s. `just check-local`
is the same gate with host bats, for a machine without podman — and it is also how you tell a
container artefact from a real finding, since the container's `DebugAllocator` reports leaks the
native build stays silent about.

Every test runs against a throwaway `$HOME`, git repo and Vault created in `tests/test_helper.bash` —
nothing touches your real `~/.claude` or Vault, and tests share no state, which is what makes
`--jobs` safe. The same suite runs in CI on **Linux** (`.github/workflows/tests.yml`); macOS is
covered by development itself.

The generated artefacts (each project's `cli.md`, the Mermaid diagrams under `docs/synapse/diagrams/`)
are each verified by running their generator's `--check` mode, so an edit that was never regenerated fails a
test instead of shipping something confidently wrong.

`packages/synapse/commands/*.md` and `packages/synapse/skills/*/SKILL.md` are natural-language procedures, so no test
executes them — but `tests/legacy-commands.bats` does check the one thing about them that is
mechanically true or false: **every command they tell Claude to run has to exist.** It cross-checks
each `` `synapse <sub>` `` against the binary's own `--help`, and applies the same rule to the text
the hooks inject and to the `Index.md` the builder writes. That guard exists because the Zig rewrite
left three deleted wrappers in the per-turn nudge and a never-existing `synapse query callers` in a
skill's table, with the whole suite green.

## Dependencies

For using it day to day: npm itself (the compiled binaries ship as ordinary per-platform
optionalDependencies, `npm install` fetches and verifies them the same way it does any other
package, no separate fetch script or `tar` step involved), whichever harness's own CLI (`claude`,
`codex`, or `opencode`), and `curl` (the compiled binary's own calls to Obsidian's Local REST API —
`write-node`, `doctor`). Node itself is assumed, the same way it already is for every harness here —
`synapse-setup` and the shipped hooks (`resolve-binaries.cjs`, `obsidian-mcp-refresh.cjs`) run on it
directly, no `jq` of its own. Nothing to build, nothing to install by hand — see "New machine setup".

For contributing to Synapse itself: Zig 0.16 (`just build`/`zig build`), `bats-core` (tests), a C
compiler for the Graph's tree-sitter acceleration (grammars are native libraries, built on first
use), GNU `parallel` for `bats --jobs`, and Node (for `npx`) to re-render the diagrams — everything
except Zig degrades gracefully if missing.

The `tree-sitter` CLI is no longer among them: libtree-sitter is linked into the binary and the
grammar's own `queries/tags.scm` is run in-process.

## License

MIT — see [LICENSE](LICENSE).
