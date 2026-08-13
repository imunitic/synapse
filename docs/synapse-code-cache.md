# Synapse Code Cache: the vault-free acceleration layer

A layer underneath the Graph, not a fourth component beside the Vault, the Graph and the Tools. The
work directory has always accumulated it quietly — `_tags_cache.bin`, `_refs.tsv`, plus the
vocabulary/list artifacts clustering uses — but it was previously documented only as a footnote inside
[synapse-graph.md](synapse-graph.md). Naming it here states plainly what was already true: nothing in
this chain needs Obsidian, a vault, the REST API, a cert, or an API key.

That independence is worth being precise about, because it is a fact about *dependencies* rather than
about structure. The binary on its own is enough to build and query this cache — `synapse callers`
answers with no graph, no vault and no nodes — and it is still a layer of the Graph in the sense that
matters for how the project is described: it exists to make the Graph's per-symbol questions cheap,
and the Graph is what gives its answers somewhere to live.

![Build path (tags → tags-cache → build-refs) and query path (symbol, callers) over the Code Cache](diagrams/synapse-code-cache.png)

## Build path

`git ls-files` (so `.gitignore` exclusion is free) feeds `synapse tags`, a tree-sitter
acceleration layer: given a file, it prints real definitions and name-based call references, extracted
by parsing rather than text guessing. It fails soft — no C compiler, an unsupported
language — and every caller falls back to reading the file directly, exactly as if the script did not
exist.

`synapse tags-cache` keeps `_tags_cache.bin` (`path → {hash, tags}`) current for a set of files,
piggybacked on the same per-file hash comparison node regeneration already performs: unchanged paths
are skipped, changed-or-missing ones are (re-)tagged in one extraction over every path that needs one.

There is no chunking and no worker pool any more, and that is a deletion rather than a regression. The
shell version split the work across `xargs -P` workers, with each worker writing a private temp file
and one sequential merge afterwards, because CLI startup and grammar load dominated the per-file cost
— chunking was how it stopped paying that per file, and it bought a real 10.26s → 1.39s on 400 Java
files. In process there is nothing to amortise: a grammar is loaded once per extension for the life of
the run, so the whole apparatus collapses into a single pass. What that trades away is CPU
parallelism, and whether *that* costs anything on a cold repository has not been measured — it is an
open question, not a settled one.

`synapse build-refs` projects that cache into `_refs.tsv`, a flat, byte-sorted index —
`name ⇥ def|ref ⇥ kind ⇥ path:line ⇥ expression`. A separate artifact because the constraint is
*format*, not size. That was measured back when the cache was JSON: one `jq` pass over a 4.6 MB cache
took 0.064s, which extrapolates to ~13s per query at a large repo's 942 MB, for something meant to
feel interactive — while the same data as flat sorted lines was a different regime entirely, 0.092s
against a 560 MB index. The cache is a binary format now rather than JSON, so the `jq` half of that
comparison is history; the conclusion it produced is why this file exists, and a sorted line index is
still what a binary search wants.

## Query path

Two commands read the cache, at different scopes:

- **`synapse query symbol <name> "{Node}"`** — node-scoped: exact-name definition/reference lookup
  within a node's already-known `sources`, closing the last-mile gap from "a node named the file" to a
  real `file:line`. A cache miss triggers the same lazy, parallel backfill the build path uses. Set
  `SYNAPSE_DISABLE_SYMBOL_CACHE` to turn the whole cache off.
- **`synapse callers <name>`** (a top-level subcommand, not one of `query`'s) — repo-wide:
  every call site of an exact name, anywhere, as `path:line ⇥ calling expression`, reading `_refs.tsv`
  directly. The lookup is an in-process binary search over the index, which is mapped rather than read
  — a query touches the pages its handful of lines sit on, where reading the file first meant paying
  1.4 GB of I/O and resident memory to reach roughly twenty pages of it. Defaults to `ref | call`
  matches; `--all` widens to every def and ref.

  The binary search is the part worth keeping from the shell version, which reached it with `look`
  plus an exact `awk` filter: on a 1.4 GB index (5.56M tags, 96,513 files) that answered in 0.235s
  where `awk` alone — a full scan — took 26s, and where the answer's speed depended on *which* `grep`
  was on `PATH`, a 50× spread. In process there is one implementation, `look`'s prefix-matching quirk
  is gone (asking for `bet` no longer returns every `beta`), and the byte-order agreement that the
  writer and the reader each had a shouting comment about is arithmetic in one program rather than a
  contract between two scripts.

**`callers` needs no graph at all** — no nodes, no reverse index, no vault — and is dispatched *ahead*
of `synapse query`'s vault/namespace preamble, so that stays a structural fact rather than a merely
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

Counting vault references (`OBSIDIAN_VAULT_DIR`, the Local REST API, its cert/key) across the
subcommands of `synapse`: 12 of 18 are vault-free outright — `namespace`, `build-index`,
`build-lists`, `build-refs`, `callers`, `enumerate`, `gate`, `push-nodes`, `rank`, `vocab`, `tags`
and `tags-cache`. The remaining six (`write-node`, `query`, `build-project-index`, `graph-clean`,
`graph-wipe`, `index`) are mostly *path*-bound rather than *API*-bound: every write is a `PUT` of a
file, replaceable by writing to disk, and `links` parses a node's own `## Links` section directly
rather than asking Obsidian.

The counting is easier than it was, and that is the point of the port rather than a side effect:
this was fifteen shell scripts plus a compiled binary, so "is this piece vault-free" meant reading
each script's preamble. It is now one binary whose vault access is a single function
(`core.conf.vaultDir`) with a countable set of callers.

`build-index` moved from the second list to the first during the Zig port, which is what that
distinction predicted: the index it writes was derived, gitignored in the vault and never travelled,
so the vault reference was a `PUT` with nothing behind it. `query` moved most of the way for the same
reason — every read is a disk read now, and only `write-node` and `build-project-index` still speak
to the API at all.

The genuine Obsidian dependency in the whole system is two things, not five scripts: full-text search
(the "where does X live" entry point) and `api_search_frontmatter`'s JsonLogic evaluation over the
vault. Not yet decided: whether the Code Cache ships as a separate repo, given it needs only `git` and
a C compiler to stand alone as `git ls-files → tags-cache → build-refs → callers`. That list used to
name `jq` and the `tree-sitter` CLI as well, and both are gone — libtree-sitter is linked into the
binary and the grammar's own `queries/tags.scm` runs in-process.
