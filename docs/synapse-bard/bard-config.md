# Configuration Reference

Short, because there's genuinely little to configure. Checked directly against the source, not
assumed: neither `synapse-bard` nor `synapse-bard-hook` reads a single `*.conf` file or a
`SYNAPSE_BARD_*`/`BARD_*` environment variable anywhere.

## Why there's nothing here to tune

Both of `synapse-bard`'s stores ([Bible-graph](bard-graph.md), [Writer's notes vault](bard-vault.md))
live under `_bard/` inside the one repo being worked in: no external location to point at, no
cross-project state to disambiguate.

## The one thing every command resolves, automatically

`common.Roots.resolve` (`src/apps/bard/common.zig`) finds `repo_root`, `_bard/graph/`, and
`_bard/vault/` with one `core.identity.resolve` call per invocation — the same repo-root discovery
`bard_hook`'s own `SessionStart` handler uses for `_bard/vault/Index.md`. It walks up from the
current directory to find the repo root the way git itself would, so a command run from a
subdirectory still finds `_bard/` at the top rather than looking for it relative to wherever the
shell happened to be. Nothing about this is configurable, and nothing needs to be: there is exactly
one repo a `synapse-bard` invocation could mean, with no cross-repo namespace to key or
disambiguate.

## `CLAUDE_PLUGIN_ROOT`: the one environment variable that matters

Both `synapse-bard-claude.md` (the plugin's standing instructions) and `Index.md.template` (the
vault's bootstrap default) are read by `synapse-bard-hook`'s `SessionStart` handler through
`CLAUDE_PLUGIN_ROOT` — the variable Claude Code exports to every hook invocation, pointing at the
installed plugin's own bundled files. There's no `argv0`-relative fallback for a pre-plugin
install to support — `synapse-bard` has no pre-plugin history, so `CLAUDE_PLUGIN_ROOT` unset simply
means neither file is found, reported plainly rather than guessed at.

## What a fresh bible repo needs, and what it doesn't

No `synapse.conf`, no per-machine setup step, no interactive prompt on first run. The one thing a
repo needs to activate the plugin from a session that can never run `/plugin` itself (the Android
app's default cloud session has no such command) is committing the plugin's registration directly
into *that repo's* own `.claude/settings.json` — a project-scoped `extraKnownMarketplaces` entry
plus `enabledPlugins`, not a `synapse-bard`-specific mechanism but the same fields any Claude Code
plugin uses for the same purpose:

```json
{
  "extraKnownMarketplaces": {
    "synapse": { "source": { "source": "github", "repo": "imunitic/synapse" } }
  },
  "enabledPlugins": { "synapse-bard@synapse": true }
}
```

From there, `synapse-bard`/`synapse-bard-hook` fetch and cache themselves the same way `synapse`
does — `hooks/fetch-and-run.cjs` downloads the platform-matching tarball from the `dist` branch into
`~/.cache/synapse-bard/bin` (a cache path distinct from `synapse`'s own, so both can be installed
side by side without colliding) and re-checks only when `plugin.json`'s version moves. No install
step of the author's own, ever.

Fetched from `raw.githubusercontent.com`, not a GitHub Release download URL: in an Anthropic-hosted
cloud sandbox, release-asset downloads route through a repo-scoped GitHub proxy that 403s any repo
other than the one the session is attached to — always the bible repo, never this one. Raw file
content from a public repo routes through the general security proxy instead, unscoped, so this is
the one URL shape that actually reaches an Android-app cloud session.
