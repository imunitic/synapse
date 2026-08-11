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
5. (Recommended) Set Obsidian to start automatically at login, so it is always running:
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
6. Restart Claude Code.

`setup.sh` is safe to re-run at any time. It migrates config filenames it recognises, rewrites hook
paths in `settings.json` rather than adding a second copy, and reports any file under `~/.claude/` that
it no longer installs, so nothing is left running that the docs stop describing.

**Using it:** the human-facing entry points are `/synapse-init`, `/synapse-rebuild-diff`, and
`/synapse-rebuild-full` — `/synapse-init` builds a repo's first Graph namespace,
`/synapse-rebuild-diff` repairs one after major same-branch drift (triage, nothing deleted),
`/synapse-rebuild-full` wipes a namespace and rebuilds it from scratch when triage isn't the right
tool. Neither of the two repair commands requires knowing anything below this point. The underlying
`claude/bin/synapse.sh` porcelain and the plumbing it dispatches to aren't something you're expected
to run by hand; they're documented in [`docs/scripts.md`](docs/scripts.md) for whoever goes looking.

## Synapse Vault — the notes

- `claude/synapse-claude.md` — the global memory-system instructions: when to write a note, where it
  goes, and the linking rules. Installed to `~/.claude/synapse-claude.md` and refreshed on every
  `setup.sh` run; `~/.claude/CLAUDE.md` itself stays entirely yours, with one `@import` line pointing
  at it.
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
- `claude/commands/synapse-rebuild-diff.md` — manual repair for major same-branch drift (a pull, a
  rebase, a long absence): triages each flagged node into **reseat**, **patch from the diff**, or
  **re-orient**. Refuses outright on a cross-branch mismatch.
- `claude/commands/synapse-rebuild-full.md` — wipes the current namespace and rebuilds it from
  scratch via `/synapse-init`, for when triage isn't the right tool. Preserves any hand-written
  `## Notes` first (`claude/lib/synapse/synapse-graph-wipe.sh`) and auto-merges what it can back into
  the new nodes afterward.
- `claude/hooks/synapse-staleness.sh` — `PostToolUse` Tier 1: flags a just-edited file's nodes `stale`
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

`jq`, `bats-core` (tests only), the `claude` CLI. Zig 0.16 to build the `synapse` binary — a
build-time dependency, not a runtime one, and `setup.sh` copies the result rather than compiling
anything itself. Optional: a C compiler for the Graph's tree-sitter acceleration (grammars
are still native libraries, built on first use), GNU `parallel` for `bats --jobs`, and Node (for
`npx`) to re-render the diagrams — everything except Zig degrades gracefully if missing.

The `tree-sitter` CLI is no longer among them: libtree-sitter is linked into the binary and the
grammar's own `queries/tags.scm` is run in-process.

## License

MIT — see [LICENSE](LICENSE).
