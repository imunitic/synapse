# Synapse Code Cache: the vault-free acceleration layer

A fourth named component, alongside the Vault, the Graph and the Tools. The work directory has always
accumulated it quietly — `_tags_cache.json`, `_refs.tsv`, plus the vocabulary/list artifacts clustering
uses — but it was previously documented only as a footnote inside [synapse-graph.md](synapse-graph.md).
Naming it here makes the vault/graph/tools trilogy a quartet, and states plainly what was already true:
nothing in this chain needs Obsidian, a vault, the REST API, a cert, or an API key.

![Build path (tags → tags-cache → build-refs) and query path (symbol, callers) over the Code Cache](diagrams/synapse-code-cache.png)

## Build path

`git ls-files` (so `.gitignore` exclusion is free) feeds `synapse-tags.sh`, an optional tree-sitter
acceleration layer: given a file, it prints real definitions and name-based call references, extracted
by parsing rather than text guessing. It fails soft — no tree-sitter, no C compiler, an unsupported
language — and every caller falls back to reading the file directly, exactly as if the script did not
exist.

`synapse-tags-cache.sh` keeps `_tags_cache.json` (`path → {hash, tags}`) current for a set of files,
piggybacked on the same per-file hash comparison node regeneration already performs: unchanged paths
are skipped, changed-or-missing ones are (re-)tagged one `synapse-tags.sh --paths` invocation per
*chunk* rather than per file, parallelized via `xargs -P` (capped at the machine's core count). Each
worker writes its own result to a private temp file; one sequential merge afterward writes the shared
cache — never a worker writing it directly. Measured: 400 real Java files went from 10.26s to 1.39s,
byte-for-byte the same cache as the serial version.

`synapse-build-refs.sh` projects that cache into `_refs.tsv`, a flat, `LC_ALL=C`-sorted index —
`name ⇥ def|ref ⇥ kind ⇥ path:line ⇥ expression`. A separate artifact because the constraint is
*format*, not size: querying the JSON cache directly does not scale (one `jq` pass over a 4.6 MB cache
measured 0.064s, extrapolating to ~13s per query at a 942 MB cache), while the same data as sorted
lines answers in 0.36s.

## Query path

Two commands read the cache, at different scopes:

- **`synapse-query.sh symbol <name> "{Node}"`** — node-scoped: exact-name definition/reference lookup
  within a node's already-known `sources`, closing the last-mile gap from "a node named the file" to a
  real `file:line`. A cache miss triggers the same lazy, parallel backfill the build path uses. Set
  `SYNAPSE_DISABLE_SYMBOL_CACHE` to turn the whole cache off.
- **`claude/lib/synapse/synapse-callers.sh`** (dispatched as `synapse-query.sh callers <name>`) — repo-wide:
  every call site of an exact name, anywhere, as `path:line ⇥ calling expression`, reading `_refs.tsv`
  directly. The lookup is `look` (binary search) plus an exact `awk` filter — `look` alone
  prefix-matches (`bet` → `beta`), `awk` alone is a full scan (26s on a 1.4 GB index). Not `grep`,
  because *which* `grep` is on `PATH` changes the answer's speed by 50×. Measured on a 1.4 GB index
  (5.56M tags, 96,513 files): 0.36s for a name with 3,239 call sites. Defaults to `ref | call` matches;
  `--all` widens to every def and ref.

**`callers` needs no graph at all** — no nodes, no `_index.json`, no vault — and is dispatched *ahead*
of `synapse-query.sh`'s vault/namespace preamble, so that stays a structural fact rather than a merely
intended one. Filling the cache is worth doing on its own, independently of ever building a graph.

## What this buys, priced against the alternative

Precision measured on a real repo: for one common method name, 38% of raw `grep` hits were noise; for
another, 61%. That is the real saving — not smaller output, but skipping the file-opening needed to
tell a call from a definition, a comment, or an unrelated same-named method. Priced against "`grep`,
then open ~5 files to disambiguate" (the realistic baseline), a `callers` query runs 3–14× cheaper.

What it honestly does not have: no summaries, no typed relations, no staleness tracking, no "explain
this subsystem." A fast exact-name index — `grep` with the noise removed, no tree walk — narrower than
the Graph, but real, with no Obsidian install as its price of entry.

## Vault-freedom, measured

Counting vault references (`OBSIDIAN_VAULT_DIR`, `$VAULT`, the Local REST API, its cert/key) across
every script in `claude/bin/`: 10 of 15 are vault-free outright (`synapse-identity.sh`,
`synapse-tags.sh`, `synapse-tags-cache.sh`, `synapse-build-refs.sh`, `synapse-callers.sh`,
`synapse-enumerate.sh`, `synapse-build-lists.sh`, `synapse-vocab.sh`, `synapse-gate.sh`,
`synapse-rank.sh`, `synapse-tokenizer.sh`, `synapse-push-nodes.sh`). The remaining five
(`synapse-write-node.sh`, `synapse-query.sh`, `synapse-build-index.sh`,
`synapse-build-project-index.sh`, `synapse-graph-clean.sh`) are mostly *path*-bound rather than
*API*-bound: every write is a `PUT` of a file, replaceable by writing to disk, and `links` parses a
node's own `## Links` section directly rather than asking Obsidian.

The genuine Obsidian dependency in the whole system is two things, not five scripts: full-text search
(the "where does X live" entry point) and `api_search_frontmatter`'s JsonLogic evaluation over the
vault. Not yet decided: whether the Code Cache ships as a separate repo, given it needs only `git`,
`jq`, `tree-sitter` and a C compiler to stand alone as `git ls-files → tags-cache → build-refs →
callers`.
