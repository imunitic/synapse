# Synapse Configuration Reference

Every `synapse-*.conf` file and every `SYNAPSE_*` environment variable the compiled
binaries and hooks read, in one place. Unlike [cli.md](cli.md), this is hand-maintained, not
generated: a `--help` string has one canonical declaration site to generate from, an
`env.get("SYNAPSE_...")` call does not — it's just scattered through `src/`. Treat this page as
best-effort-current rather than push-button-verified — before it existed, documentation coverage
was bimodal: vault- and work-dir-adjacent settings were documented, while grammar/cache/identity-
adjacent ones existed only in source comments and the bats suite. This page closes that gap.

## Where a conf file actually lives

Every `synapse-*.conf` file resolves through the same three-tier order, first match wins:

1. `$XDG_CONFIG_HOME/synapse/{name}` if `$XDG_CONFIG_HOME` is set, else `~/.config/synapse/{name}`
   — for anyone who's adopted XDG config directories.
2. `~/.claude/{name}` — today's default location, and where every pre-plugin install already has
   its files. Survives indefinitely as a tier, not as a stopgap.
3. The installed package's bundled `{name}.template`, read live from `$SYNAPSE_CONTENT_ROOT`
   (`$CLAUDE_PLUGIN_ROOT` remains a compatibility lookup) — only reached when neither tier above
   has a file at all. Read-only by construction: this tier is never a write
   target, and nothing here is ever copied or seeded into `~/.claude/` on install the way a
   pre-plugin install once did. A curated-default registry (see below) effectively ships "for free"
   this way — no seeding step, no install-time copy, just the shipped file read directly until a
   real override appears at tier 1 or 2.

A self-managed file with no default content at all (`synapse-projects.conf` is the only current
example — plain-text, agent-appended, never touched by a compiled binary) follows a related but
distinct rule when nothing resolves yet: create fresh at tier 1 if `$XDG_CONFIG_HOME` is set, else
tier 1's `~/.config/synapse/` if that directory already exists, else `~/.claude/` as the final
fallback — never tier 3, which is read-only by construction and was never a real option for a file
meant to be written to.

## `synapse.conf` — the one hand-edited file

Everything else is either self-populating (discovered and cached automatically) or a plain list a
human edits directly; this is the one file a fresh install actually requires editing, since
`SYNAPSE_VAULT_DIR` is inherently machine-specific and nothing can guess it. A plugin install has
no interactive step to prompt for this — the `SessionStart` hook says so directly, every session,
until the file exists and resolves to a real directory. Resolved via the same three-tier order
every `synapse-*.conf` file uses (see "Where a conf file actually lives" below): typically
`~/.claude/synapse.conf`, or `$XDG_CONFIG_HOME/synapse/synapse.conf` on a machine that's adopted
XDG config directories. Shell-syntax subset: `KEY=value`, `KEY="value"`, an optional `export` prefix,
`#`-comments, blank lines, and inside a value a leading `~` or `$VAR`/`${VAR}` expanding against
whatever the *caller's* environment holds — not just `$HOME` as a special case. Not supported:
`~user`, `${VAR:-default}`, command substitution, arithmetic. An unset variable expands to nothing,
the way a shell does; a resulting bad path is reported, never silently substituted with a guess.
`second-brain.conf` (this file's name before 2026-08-04) is tried as a fallback, for a machine not
reinstalled since.

Every key below resolves through `core.conf.resolve` (`vaultDir` is that same function, fixed to
`SYNAPSE_VAULT_DIR`): a real environment variable of the same name wins if set and non-empty;
otherwise the first conf file in the tier order above that defines the key. Setting one in
`synapse.conf` and exporting it as a real environment variable are both real, working ways to
configure it — the row below just documents the value, not which of the two you used.

| Key | Default if unset | What it controls |
|---|---|---|
| `SYNAPSE_VAULT_DIR` | — (required) | The vault path. |
| `SYNAPSE_VAULT_INTEGRATIONS` | — (plain disk store) | A comma-separated, outer-to-inner list of integrations layered on the one real store, `DiskStore` -- `git` (owns the vault's own git lifecycle -- see [synapse-vault.md](synapse-vault.md#version-control-synapse_vault_integrationsgit)) and/or `obsidian` (prefers a live Obsidian app's own search/link-graph -- see [synapse-extended-store.md](synapse-extended-store.md)), in either order or combination. `git,obsidian` means `GitStore` wraps `ObsidianStore` wraps the disk store. `disk` is never named -- it's always the implicit innermost element -- and naming it, an unrecognized name, or a name repeated is each a hard error, not a silent fallback. |
| `SYNAPSE_GRAMMARS_DIR` | `~/.cache/synapse/grammars` | Where tree-sitter grammar repos are cloned and their compiled `.so`/`.dylib` libraries cached — shared across every project, not per-repo. |
| `SYNAPSE_GRAMMARS_QUERY_PATH` | — (no overrides) | Directory of hand-authored `{ext}.scm` tags queries that preempt the entire grammar tier cascade for that extension, for the rare grammar neither automatic tier handles well (one shipping `locals.scm` and `node-types.json` but no `queries/tags.scm`, say). The same directory holds `{ext}.locals.scm`, the analogous override for local-reference filtering (see [synapse-code-cache.md](synapse-code-cache.md)). Checked fresh every run, never cached. |
| `SYNAPSE_GRAMMAR_LOCK_TRIES` | `300` (~60s) | How many 200ms retries a grammar clone or compile lock waits before giving up. Bounds the wait on a wedged lock left by a crashed process, not the clone or compile itself. |
| `SYNAPSE_VAULT_PUSH_EVERY` | `5` | When `git` is one of the configured integrations, how many local commits pile up before `GitStore` spawns a detached push. `0` disables pushing. Only acts when the vault has an upstream and is genuinely ahead of it. |
| `SYNAPSE_AUTHOR_POOL` | `0` | How many nodes `/synapse-init`'s final step authors concurrently via the `synapse-node-authoring` skill. `0` is the original one-at-a-time, same-session procedure — the only choice that preserves cross-node authorial memory. Read directly by the orchestrating agent, not by any compiled binary -- this one specifically is never a real environment variable, only ever text in the conf file an agent reads. |

## Self-populating registries (JSON)

Discovered once per language/extension during grammar or namespace discovery, then cached
permanently — never hand-curated in the ordinary case, though all three are plain JSON and safe to
edit directly if a cached decision needs correcting.

- **`synapse-grammars.conf`** — one entry per file extension: `{"repo": "...", "scope": "...",
  "queries": "tags"|"locals"|"generated", "path": "...", "symbol": "..."}` for a usable grammar, or
  `{"unsupported": true}` when neither discovery tier verified (see
  [Grammar discovery](synapse-code-cache.md#grammar-discovery-tagsscm-localsscm-or-generated) in
  synapse-code-cache.md). `path`/`symbol` are only needed for a multi-grammar repo
  (a grammar whose sub-grammars share one upstream clone). No environment-variable path
  override.
- **`synapse-namespace-rules.conf`** (`SYNAPSE_NAMESPACE_RULES_CONF` overrides the path) — object
  keyed by bare extension, one rule per ecosystem's own "what does this file call itself" signal (a
  source file's own in-language namespace declaration, or a build manifest's declared package
  name). Feeds `synapse vocab`'s `namespaces.tsv`
  and `synapse build-namespaces`'s per-file `_namespaces.tsv`. Silently answers nothing for an
  extension with no rule yet, never guesses. A rule may carry an optional `"aliases"` array
  (`[{"prefix": "...", "terminator": "..."}]`, terminator optional, unbounded), each entry an
  independent extraction against the *same* nearest-ancestor file as the rule's own primary
  `prefix`/`terminator` — for an ecosystem where one file has more than one valid self-reference
  (a build system's internal name versus the name it publishes for other files to depend on),
  giving that file more than one row in `_namespaces.tsv`.
- **`synapse-dependency-rules.conf`** (`SYNAPSE_DEPENDENCY_RULES_CONF` overrides the path) — same
  shape and extension-keyed registry as `synapse-namespace-rules.conf`, kept as a separate file
  because it answers a different question about the same file (what it *depends on*, not what it
  *is*) and a rule per extension leaves no room for both facts in one object. Feeds `_deps.tsv`, the
  per-file dependency-edge artifact `core/links.zig` consumes to narrow an ambiguous reference to
  the candidate the referencing file actually declares a dependency on. Ships with only whichever
  rule has already been dogfooded against a real ambiguous-reference finding; `synapse-orientation`'s
  own skill doc carries the qualification test and self-population procedure every other language's
  rule gets written from.
- **`synapse-kind-synonyms.conf`** (`SYNAPSE_KIND_SYNONYMS_CONF` overrides the path) — normalizes a
  `locals.scm` grammar's own capture-kind spellings onto `Tag.kind`'s shared vocabulary (`"class"`,
  `"method"`, `"call"`, `"function"`, ...), since `locals.scm` was written for nvim-treesitter's
  scope tracking, not for a shared tags vocabulary the way `tags.scm` converges on one across
  grammars (Tier 2 of grammar discovery).

  An *ordered array*, not an object — order **is** the mechanism, a JSON array guarantees it and an
  object's keys don't:

  ```json
  [
    {"match": "ctor", "scope": "source.langA", "kind": "constructor"},
    {"match": "ctor", "kind": "method"},
    {"match": "", "kind": "variable"}
  ]
  ```

  Tried top to bottom, **first match wins — by list position, not by which rule is more specific.**
  Above, a bare `ctor` scoped to `langA` gets `constructor` because that rule comes first; every
  other grammar's `ctor` falls through to the general `method` rule below it. Reversing the two
  would make the scoped rule dead code — nothing checks "is there a more specific rule later," so a
  general rule placed first always wins. `scope` is a tree-sitter scope (`source.langB`) or absent
  to match any grammar; `match` may be the empty string, a real, matchable value for a bare
  `@local.definition` capture with no kind suffix at all (some grammars' own `locals.scm` do this
  — the third rule above). An unmapped spelling is dropped, never defaulted to a guessed
  kind; a malformed entry (missing or wrong-typed `match`/`kind`) is silently skipped at load, and
  every rule around it still applies.

  Also read when Tier 2 generates from `node-types.json` (no `locals.scm`, or filling what it
  doesn't cover), where the same file can do two things instead of one — relabel a kind the
  suffix/prefix heuristic already guessed, or **force-classify a type the heuristic missed
  outright**, one it would otherwise never treat as declaration-shaped at all. `match` there is the
  grammar's raw node *type name* (e.g. `"TypeDecl"`, `"SubroutineBody"`), not a
  `@local.definition` suffix. Some grammars need exactly this: a node type naming a full
  function-with-implementation but carrying none of the recognized suffixes
  (`_declaration`/`_definition`/`decl`/`def`), so without a rule it never becomes a candidate to
  relabel — a matching rule is what lets it be classified at all. Same rule list, same precedence,
  two different `match` vocabularies depending on which source material is being classified;
  unmapped keeps the `node-types.json` classifier's own verdict (a guess, or nothing) instead of
  being dropped — that path has no "no tag" state the way a `locals.scm` capture does.

## Curated-default registries (JSON)

Unlike the self-populating registries above, this file is never empty in the ordinary case: it
ships with real content via `packages/synapse/*.conf.template`, read live as tier 3 of the resolution order
above the moment nothing overrides it at tier 1 or 2 — no seeding, no install-time copy. Once a
real file resolves at tier 1 or 2 instead, it is authoritative on its own — an extension it doesn't
mention is simply unmapped, never silently filled in from anything else. A compiled-in fallback
table exists only for the case where no conf resolves at all (no plugin installed and nothing at
tier 1/2 either — a from-source checkout with nothing configured, or a hermetic test environment).

- **`synapse-fence-languages.conf`** (`SYNAPSE_FENCE_LANGUAGES_CONF` overrides the path) — object
  keyed by file extension (with its leading dot, e.g. `".java"`), valued with the fence language a
  crux block's code fence opens with (`"java"`, `"ocaml"`, ...). Matched by suffix, same as the
  compiled-in fallback in `core.emit.languageFor` — add a line for any extension the shipped
  template doesn't cover.

## Plain per-line conf files

- **`synapse-ignore-files.conf`** — extra paths to drop from the graph entirely, on top of the
  built-in exclusions (compiled objects, archives, media, model weights, lockfiles, minified
  bundles, source maps): a machine-wide list of whatever *this machine's* projects carry that's
  noise everywhere (vendored dependencies, tracked-but-generated sources, fixture corpora, IDE
  metadata). An excluded path gets no owning node at all — it's invisible to search and to
  staleness tracking, not merely deprioritized — which is the right call for build output and
  vendored code, and the wrong one for a file that's just *uninteresting to read* (a generated
  config whose edits still change behavior still wants its own node, flagged stale when it
  changes). No environment-variable override. One extended regular expression per line (blank
  lines and `#`-comments ignored), matched against the repo-relative path with `grep -vE`, OR'd
  together — deliberately not gitignore syntax (no anchoring rules, no `**` globs, no negation).
  `$SYNAPSE_EXTRA_EXCLUDE_RE` layers one more pattern on top, OR'd with whatever the file holds,
  for a one-off invocation that doesn't want a persistent rule.
- **`synapse-prompt-stopwords.conf`** — no environment-variable override. One English function word
  per line (570 words, from [stopwords-json](https://github.com/6/stopwords-json), MIT), matched
  whole-line with `grep -vxFf`. Filtered out of a raw prompt before `synapse vocab` builds a search
  pattern from it, and shared with `synapse vocab`'s own symbol-vocabulary reduction so the two
  never disagree on what counts as noise.
- **`synapse-tag-vocabulary.conf`** — one allowed Vault-note tag per line. Newly authored v1 notes
  carry a `tags` list (which may be empty); `SchemaValidationStore` checks every present value
  against this file before persistence.
- **`synapse-module-boilerplate.conf`** (`SYNAPSE_MODULE_BOILERPLATE_CONF` overrides the path) —
  hand-curated, not self-populating: one literal path-segment chain per line (e.g. `src/main/java`),
  stripped wholesale when `synapse query`/`write-node`'s `## Sources` mirror aggregates a node's
  sources into module buckets. Anything *not* listed keeps one path segment past `src/` instead of
  collapsing it, since for most non-Java layouts that next segment is the real subsystem, not
  boilerplate.

## Machine-local project registry

- **`synapse-projects.conf`** — `project-name=prefix` pairs (e.g. `my-app=myapp`) resolving a
  repo to its task-note ID prefix for `/synapse-note --task` and friends. Deliberately outside the
  portable `packages/synapse/` package and never copied between machines, so contexts that shouldn't mix
  (personal vs. work projects) never land in the same file. Self-managed by `/synapse-note` — it
  appends a newly resolved pair the first time it has to ask — and safe to hand-edit any time. The
  authoring workflow reads it to resolve IDs and folders; `SchemaValidationStore` reads the values
  on schema-declaring writes to validate `project` frontmatter.

## Every environment variable, by what it touches

Conf-file path overrides (`SYNAPSE_*_CONF`, `SYNAPSE_VAULT_DIR`, `SYNAPSE_VAULT_INTEGRATIONS`) are
listed with their files above, not repeated here.

| Variable | Read by | What it does |
|---|---|---|
| `SYNAPSE_NAMESPACE`, `SYNAPSE_REPO_ROOT`, `SYNAPSE_BRANCH`, `SYNAPSE_REMOTE` | `context.zig`, `common.zig` (hooks) | Identity overrides, normally exported together so a compiled command never re-resolves identity independently of what already resolved it. All four are read as a set — if any one is unset, identity is re-resolved from the checkout instead of mixing an exported value with a freshly-derived one. Not meant to be hand-set; setting one without the others risks exactly the disagreement this exists to prevent. |
| `SYNAPSE_WORK_DIR` | `context.zig` | Overrides `~/.cache/synapse/work/{namespace}`, the derived cache location for `_tags_cache.bin`/`_refs.tsv`/vocabulary artifacts. Lets `enumerate`/`build-lists`/`build-refs`/`callers` run with no vault at all. |
| `SYNAPSE_DISABLE_SYMBOL_CACHE` | `query_cmd.zig` | Any value disables `synapse query symbol`'s cache entirely — no cache I/O, no tagging. A debugging knob rather than a standing preference, which is why it stays environment-only. |
| `SYNAPSE_EXTRA_EXCLUDE_RE` | `enumerate_cmd.zig` | One extra ERE, OR'd with `synapse-ignore-files.conf`'s patterns; see the plain-conf-files section above. |
| `SYNAPSE_MAX_FILE_BYTES` | `enumerate_cmd.zig` | Per-file size cap during enumeration, default 1,048,576 (1 MiB). A file over this is skipped and the skip is reported, never silent — a silent skip would make `enumerated` disagree with the repo. |
| `SYNAPSE_MAX_LISTING_BYTES` | `context.zig` (`build_lists_cmd.zig`, `enumerate_cmd.zig`, `project_index_cmd.zig`, `tags_cache_cmd.zig`) | Overrides the read cap on every listing that scales with the repo's file count — `manifest.tsv` (default 16 MiB), `all.txt` (default 256 MiB), tags-cache's `--paths` (default 64 MiB) — with one number. One knob, not one per file, since a repo large enough to outgrow one of these defaults usually outgrows more than one. Deliberately environment-only: raising it is a per-invocation act, not a `synapse.conf` value every future clone would inherit. |
| `SYNAPSE_TEST_PATH_RE` | `rank_cmd.zig` | Overrides `core.rank.isTest`'s built-in test-file heuristic with `grep -vE <re>` over the path list, for a repo whose test-path convention the built-in rule doesn't recognize. |
| `SYNAPSE_VAULT_PUSH_EVERY` | `git/store.zig` (`GitStore`) | See the `synapse.conf` table above. |
| `SYNAPSE_CONTENT_ROOT` | npm shims, config resolution, `SchemaValidationStore` | Root of the installed `@imunitic/synapse` content package. Schema identifiers resolve directly beneath its `schema/` directory. The npm shims set it automatically when the caller has not supplied an override. |
| `SYNAPSE_AUTHOR_POOL` | orchestrating agent, `/synapse-init` | See the `synapse.conf` table above. |
| `SYNAPSE_BIN`, `SYNAPSE_HOOK_BIN` | dev/CI tooling only (`tests/test_helper.bash`, `docs/generate-cli-reference.sh`) | Point the tests or the doc generator at a specific binary (e.g. a cross-compiled one for `just test-linux`) instead of `zig-out/bin/`. Not read by the running binaries themselves, and not part of the plugin install path at all -- that fetches from the `dist` branch into `~/.cache/synapse/bin/` directly. |
