# Synapse Configuration Reference

Every conf file under `~/.claude/` and every `SYNAPSE_*`/`OBSIDIAN_*` environment variable the
compiled binaries and hooks read, in one place. Unlike [cli.md](cli.md), this is hand-maintained,
not generated: a `--help` string has one canonical declaration site to generate from, an
`env.get("SYNAPSE_...")` call does not — it's just scattered through `src/`. Treat this page as
best-effort-current rather than push-button-verified — the gap it closes is the same "config
sprawl" a multi-agent codebase audit flagged from the source side (documentation coverage was
bimodal: vault- and work-dir-adjacent settings were documented, grammar/cache/identity-adjacent
ones existed only in source comments and the bats suite).

## `~/.claude/synapse.conf` — the one hand-edited file

Everything else under `~/.claude/` is either self-populating (discovered and cached automatically)
or a plain list a human edits directly; this is the one file `setup.sh` asks you to edit by hand
after install. Shell-syntax subset: `KEY=value`, `KEY="value"`, an optional `export` prefix,
`#`-comments, blank lines, and inside a value a leading `~` or `$VAR`/`${VAR}` expanding against
whatever the *caller's* environment holds — not just `$HOME` as a special case. Not supported:
`~user`, `${VAR:-default}`, command substitution, arithmetic. An unset variable expands to nothing,
the way a shell does; a resulting bad path is reported, never silently substituted with a guess.
`second-brain.conf` (this file's name before 2026-08-04) is tried as a fallback, for a machine not
reinstalled since.

| Key | Default if unset | What it controls |
|---|---|---|
| `OBSIDIAN_VAULT_DIR` | — (required) | The vault path. Also directly overridable by an `OBSIDIAN_VAULT_DIR` environment variable, which wins over the file. |
| `SYNAPSE_GRAMMARS_DIR` | `~/.cache/synapse/grammars` | Where tree-sitter grammar repos are cloned and their compiled `.so`/`.dylib` libraries cached — shared across every project, not per-repo. |
| `SYNAPSE_VAULT_PUSH_EVERY` | `5` | How many `Stop`-hook turns between vault auto-pushes to its git remote. `0` disables pushing. Only acts when the vault has an upstream and is genuinely ahead of it. |
| `SYNAPSE_AUTHOR_POOL` | `0` | How many nodes `/synapse-init`'s final step authors concurrently via the `synapse-node-authoring` skill. `0` is the original one-at-a-time, same-session procedure — the only choice that preserves cross-node authorial memory. Read directly by the orchestrating agent, not by any compiled binary. |

## Self-populating registries (JSON)

Discovered once per language/extension during grammar or namespace discovery, then cached
permanently — never hand-curated in the ordinary case, though all three are plain JSON and safe to
edit directly if a cached decision needs correcting.

- **`synapse-grammars.conf`** — one entry per file extension: `{"repo": "...", "scope": "...",
  "queries": "tags"|"locals"|"generated", "path": "...", "symbol": "..."}` for a usable grammar, or
  `{"unsupported": true}` when none of the three discovery tiers verified (see
  [Grammar discovery](synapse-code-cache.md#grammar-discovery-tagsscm-localsscm-or-generated) in
  synapse-code-cache.md). `path`/`symbol` are only needed for a multi-grammar repo
  (`tree-sitter-ocaml`'s three sub-grammars sharing one clone). No environment-variable path
  override.
- **`synapse-namespace-rules.conf`** (`SYNAPSE_NAMESPACE_RULES_CONF` overrides the path) — object
  keyed by bare extension, one rule per ecosystem's own "what does this file call itself" signal (a
  Java `package` line, a Rust crate's `Cargo.toml` name). Feeds `synapse vocab`'s `namespaces.tsv`.
  Silently answers nothing for an extension with no rule yet, never guesses.
- **`synapse-kind-synonyms.conf`** (`SYNAPSE_KIND_SYNONYMS_CONF` overrides the path) — an *ordered
  array*, not an object: `[{"match": "<spelling>", "scope": "<optional tree-sitter scope>", "kind":
  "<Tag.kind>"}]`, first match wins. Normalizes a `locals.scm` grammar's own capture-kind spellings
  onto `Tag.kind`'s shared vocabulary (Tier 2 of grammar discovery); an unmapped spelling is dropped,
  never defaulted to a guessed kind.

## Plain per-line conf files

- **`synapse-ignore-files.conf`** — no environment-variable override. One extended regular
  expression per line (blank lines and `#`-comments ignored), matched against the repo-relative
  path with `grep -vE`, OR'd together — deliberately not gitignore syntax (no anchoring rules, no
  `**` globs, no negation). `$SYNAPSE_EXTRA_EXCLUDE_RE` layers one more pattern on top, OR'd with
  whatever the file holds, for a one-off invocation that doesn't want a persistent rule.
- **`synapse-prompt-stopwords.conf`** — no environment-variable override. One English function word
  per line (570 words, from [stopwords-json](https://github.com/6/stopwords-json), MIT), matched
  whole-line with `grep -vxFf`. Filtered out of a raw prompt before `synapse vocab` builds a search
  pattern from it, and shared with `synapse vocab`'s own symbol-vocabulary reduction so the two
  never disagree on what counts as noise.
- **`synapse-module-boilerplate.conf`** (`SYNAPSE_MODULE_BOILERPLATE_CONF` overrides the path) —
  hand-curated, not self-populating: one literal path-segment chain per line (e.g. `src/main/java`),
  stripped wholesale when `synapse query`/`write-node`'s `## Sources` mirror aggregates a node's
  sources into module buckets. Anything *not* listed keeps one path segment past `src/` instead of
  collapsing it, since for most non-Java layouts that next segment is the real subsystem, not
  boilerplate.

## Machine-local, not read by any compiled binary

- **`synapse-projects.conf`** — `project-name=prefix` pairs (e.g. `my-app=myapp`) resolving a
  repo to its task-note ID prefix for `/synapse-note --task` and friends. Deliberately outside the
  portable `claude/` package and never copied between machines, so contexts that shouldn't mix
  (personal vs. work projects) never land in the same file. Self-managed by `/synapse-note` — it
  appends a newly resolved pair the first time it has to ask — and safe to hand-edit any time. Read
  by the orchestrating agent running a `/synapse-*` command, never by a Zig binary.

## Every environment variable, by what it touches

Conf-file path overrides (`SYNAPSE_*_CONF`, `OBSIDIAN_VAULT_DIR`) are listed with their files above,
not repeated here.

| Variable | Read by | What it does |
|---|---|---|
| `SYNAPSE_NAMESPACE`, `SYNAPSE_REPO_ROOT`, `SYNAPSE_BRANCH`, `SYNAPSE_REMOTE` | `context.zig`, `common.zig` (hooks) | Identity overrides, normally exported together by the (still-bash) identity wrapper so a compiled command never re-resolves identity independently of what the wrapper already decided. All four are read as a set — if any one is unset, identity is re-resolved from the checkout instead of mixing an exported value with a freshly-derived one. Not meant to be hand-set; setting one without the others risks exactly the disagreement this exists to prevent. |
| `SYNAPSE_GRAMMARS_DIR` | `Extractor`/grammar loading | Directory override; see the `synapse.conf` table above. |
| `SYNAPSE_GRAMMAR_LOCK_TRIES` | `Extractor.lock_tries` | How many 200ms retries a grammar clone or compile lock waits before giving up (~60s at the default of 300, `grammar.default_lock_tries`). Bounds the wait on a wedged lock left by a crashed process, not the clone/compile itself. |
| `SYNAPSE_GRAMMARS_QUERY_PATH` | `Extractor.query_override_dir` | Directory holding hand-authored `{ext}.scm` files that preempt the entire tier cascade for that extension, tags.scm included — checked fresh every run, never cached, for the rare grammar none of the three automatic tiers handle well. |
| `SYNAPSE_WORK_DIR` | `context.zig` | Overrides `~/.claude/synapse-work/{namespace}`, the derived cache location for `_tags_cache.bin`/`_refs.tsv`/vocabulary artifacts. Lets `enumerate`/`build-lists`/`build-refs`/`callers` run with no vault at all. |
| `SYNAPSE_DISABLE_SYMBOL_CACHE` | `query_cmd.zig` | Any value disables `synapse query symbol`'s cache entirely — no cache I/O, no tagging. Matches the prompt-injection hook's own on/off knob. |
| `SYNAPSE_EXTRA_EXCLUDE_RE` | `enumerate_cmd.zig` | One extra ERE, OR'd with `synapse-ignore-files.conf`'s patterns; see the plain-conf-files section above. |
| `SYNAPSE_MAX_FILE_BYTES` | `enumerate_cmd.zig` | Per-file size cap during enumeration, default 1,048,576 (1 MiB). A file over this is skipped and the skip is reported, never silent — a silent skip would make `enumerated` disagree with the repo. |
| `SYNAPSE_TEST_PATH_RE` | `rank_cmd.zig` | Overrides `core.rank.isTest`'s built-in test-file heuristic with `grep -vE <re>` over the path list, for a repo whose test-path convention the built-in rule doesn't recognize. |
| `SYNAPSE_DISABLE_PROMPT_INJECTION` | `prompt_context.zig` (hook) | Any value skips the `UserPromptSubmit` hook's one-line "this repo has a code graph" pointer entirely. |
| `SYNAPSE_VAULT_PUSH_EVERY` | `stop_nudge.zig` (hook) | See the `synapse.conf` table above. |
| `SYNAPSE_AUTHOR_POOL` | orchestrating agent, `/synapse-init` | See the `synapse.conf` table above. |
| `SYNAPSE_BIN`, `SYNAPSE_HOOK_BIN` | `setup.sh` only | Point the installer at prebuilt binaries instead of `zig-out/bin/`, for a release tarball with no toolchain to build them with. Not read by the running binaries themselves — a build-time/install-time override only. |
| `NODE_EXTRA_CA_CERTS` | Obsidian's Local REST API MCP client, not Synapse's own code | Wired into `~/.claude/settings.json` by `setup-obsidian-mcp.sh`, pointing at the plugin's self-signed cert. Machine-specific; regenerated by that script, never hand-set. |
