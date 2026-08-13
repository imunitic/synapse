# Synapse

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
  nodes). See [`docs/synapse-code-cache.md`](docs/synapse-code-cache.md).
- **Synapse Tools** — the scripts, commands, skills and hooks that build and maintain both.

This repository packages the **Tools**, plus the templates and config they need. It does not contain
your notes: the Vault's content is a separate sync concern (git, Obsidian Sync, iCloud, manual copy —
your call).

## New machine setup

```sh
git clone <this repo> ~/synapse   # or copy the folder over
cd ~/synapse
zig build                          # or: just build
./setup.sh
```

`setup.sh` installs the portable tooling into `~/.claude/`, merges hook entries into
`~/.claude/settings.json` (idempotent — safe to re-run, does not clobber unrelated settings), and
prints the manual steps below.

**The build step is not optional, and `setup.sh` refuses to run without it.** `synapse` and
`synapse-hook` are the tooling — nothing stands behind them — and the hook entries this writes name
`~/.claude/bin/synapse-hook` by path. Wiring that up before the binary exists would give every turn
and every edit a hook that cannot launch, so an unbuilt checkout is a hard stop that installs
nothing rather than a warning. `setup.sh` does not run a compiler itself; if you have prebuilt
binaries elsewhere, point `$SYNAPSE_BIN` and `$SYNAPSE_HOOK_BIN` at them instead of building.

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
7. Restart Claude Code.

`setup.sh` is safe to re-run at any time. It migrates config filenames it recognises, rewrites hook
paths in `settings.json` rather than adding a second copy, and reports any file under `~/.claude/` that
it no longer installs, so nothing is left running that the docs stop describing.

**Using it:** the human-facing entry points are `/synapse-init`, `/synapse-rebuild-diff`, and
`/synapse-rebuild-full` — `/synapse-init` builds a repo's first Graph namespace,
`/synapse-rebuild-diff` repairs one after major same-branch drift (triage, nothing deleted),
`/synapse-rebuild-full` wipes a namespace and rebuilds it from scratch when triage isn't the right
tool. Neither of the two repair commands requires knowing anything below this point. The `synapse`
binary underneath them isn't something you're expected to run by hand; its subcommands are
documented in [`docs/cli.md`](docs/cli.md) for whoever goes looking.

## Synapse Vault — the notes

- `claude/synapse-claude.md` — the global memory-system instructions: when to write a note, where it
  goes, and the linking rules. Installed to `~/.claude/synapse-claude.md` and refreshed on every
  `setup.sh` run; `~/.claude/CLAUDE.md` itself stays entirely yours, with one `@import` line pointing
  at it.
- `claude/synapse.conf.template` — path config; set `OBSIDIAN_VAULT_DIR` per machine.
- `synapse-hook session-start` — `SessionStart`: injects the Vault's index and this repo's
  Graph namespace pointer, if one exists.
- `synapse-hook stop-nudge` — a turn-count-based `Stop` hook that nudges a "worth
  capturing?" check-in every 25 turns.
- `synapse-hook db-sync` — commits Vault changes to the Vault's own local git repo,
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
- `claude/commands/synapse-rebuild-diff.md` — manual repair for major same-branch drift (a pull, a
  rebase, a long absence): triages each flagged node into **reseat**, **patch from the diff**, or
  **re-orient**. Refuses outright on a cross-branch mismatch.
- `claude/commands/synapse-rebuild-full.md` — wipes the current namespace and rebuilds it from
  scratch via `/synapse-init`, for when triage isn't the right tool. Preserves any hand-written
  `## Notes` first (`synapse graph-wipe`) and auto-merges what it can back into
  the new nodes afterward.
- `synapse-hook staleness` — `PostToolUse` Tier 1: flags a just-edited file's nodes `stale`
  and re-verifies any evidence that file's nodes cite, via the Local REST API directly.
- `claude/skills/synapse-node/` — Tier 2: the lazy staleness check, regeneration and unassigned sweep
  Claude runs itself whenever a node's body is actually read.

## What's NOT portable (per-machine, regenerated fresh each time)

- The Obsidian Local REST API plugin's self-signed cert + API key — each install generates its own.
  `setup-obsidian-mcp.sh` extracts these *after* you've installed the plugin; it does not carry them
  over from another machine.
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

Two traps in that. Shipped instructions under `claude/` **look** like documentation and are not: they
install into `~/.claude`, and `tests/legacy-commands.bats` plus `tests/setup.bats` cover them — that
is how a skill telling Claude to run a nonexistent command got caught. And `docs/cli.md` and the
diagrams are *generated*, so a change upstream of them needs `just fix`, not `just docs-check`.

`--jobs` needs GNU `parallel` on `PATH`; without it `bats` falls back to running serially (slower but
correct). `just test-changed` derives its selection by grep rather than from a maintained list — a
lower bound on coverage, which is the right trade per commit and the wrong one before a push.

`just check` runs the suite in the Linux container, which is not a preference: the same 438 tests take
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

The two generated artefacts (`docs/cli.md`, the Mermaid diagrams under `docs/diagrams/`) are each
verified by running their generator's `--check` mode, so an edit that was never regenerated fails a
test instead of shipping something confidently wrong.

`claude/commands/*.md` and `claude/skills/*/SKILL.md` are natural-language procedures, so no test
executes them — but `tests/legacy-commands.bats` does check the one thing about them that is
mechanically true or false: **every command they tell Claude to run has to exist.** It cross-checks
each `` `synapse <sub>` `` against the binary's own `--help`, and applies the same rule to the text
the hooks inject and to the `Index.md` the builder writes. That guard exists because the Zig rewrite
left three deleted wrappers in the per-turn nudge and a never-existing `synapse query callers` in a
skill's table, with the whole suite green.

## Dependencies

`jq`, `bats-core` (tests only), the `claude` CLI. Zig 0.16 to build the two binaries — a build-time
dependency, not a runtime one: `setup.sh` copies the result rather than compiling anything itself,
and refuses to install until it exists (see "New machine setup"). Optional: a C compiler for the Graph's tree-sitter acceleration (grammars
are still native libraries, built on first use), GNU `parallel` for `bats --jobs`, and Node (for
`npx`) to re-render the diagrams — everything except Zig degrades gracefully if missing.

The `tree-sitter` CLI is no longer among them: libtree-sitter is linked into the binary and the
grammar's own `queries/tags.scm` is run in-process.

## License

MIT — see [LICENSE](LICENSE).
