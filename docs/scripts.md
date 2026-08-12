# Synapse Tools: script reference

Generated from the header block of each script by `docs/generate-scripts-reference.sh`
— the same text the script prints for `--help`. Do not edit by hand; run the
generator, or `--check` it, which the test suite does.

Design rationale is not here: see [synapse-graph.md](synapse-graph.md) for the Graph these
scripts build and why they exist at all, and [synapse-vault.md](synapse-vault.md) for
the Vault that hosts it.

## `synapse-build-index.sh`

Builds $SYNAPSE_WORK_DIR/_index.bin -- the machine-only reverse index from
every source path to the node filenames that claim it, plus the unassigned
list. Step 3 of a scripted /synapse-init.

```
Usage: synapse-build-index.sh
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.

Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title, unassigned.txt
Writes $SYNAPSE_WORK_DIR/_index.bin

Read by the PostToolUse staleness hook, so it must cover every enumerated file:
an edit to an unlisted path flags nothing stale.

This script authors the (path, node) pairs and `synapse index build` encodes
them. Two things changed with that split, both deliberate. The index no longer
lives in the vault: it is derived, gitignored there and never travelled, so
PUT-ing 26 MB over the REST API bought nothing -- which is also why this script
no longer needs the sandbox disabled, and no longer reads the plugin's API key
or certificate. And `jq` is gone: authoring tens of megabytes of JSON was the
only reason it was here.
```

## `synapse-build-lists.sh`

Expands a node manifest into one path list per node, then reports coverage.
Step 1 of a scripted /synapse-init.

```
Usage: synapse-build-lists.sh [--reenumerate]
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
  Never the script's own location, and never the repo -- see below.

Reads   $SYNAPSE_WORK_DIR/manifest.tsv   title <TAB> include-ERE <TAB> exclude-ERE
Calls   claude/lib/synapse/synapse-enumerate.sh  for $SYNAPSE_WORK_DIR/all.txt -- see its
        own header for the exclusion rules, the size cap and --reenumerate.
Writes  $SYNAPSE_WORK_DIR/lists/NN.txt   one path list per manifest line
        $SYNAPSE_WORK_DIR/lists/NN.title the node title for that list
        $SYNAPSE_WORK_DIR/unassigned.txt files no node claimed

Prints enumerated/covered/unassigned counts, so a bad pattern shows up as a
number rather than a silent gap.

Exit codes: 0 ok, 1 could not run, 2 usage error
```

## `synapse-build-project-index.sh`

Builds and uploads synapse/{repo}/Index.md -- the per-project node map, carrying
the `remote` field the SessionStart hook verifies before injecting a pointer.
Step 4 (last) of a scripted /synapse-init.

```
Usage: synapse-build-project-index.sh
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.

Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title   (for titles and file counts)
       each node's `summary` frontmatter field, fetched from the vault

Run after the nodes exist: summaries are read back off the nodes, and a node that
is missing or has no `summary` is a hard error. Emits no repo-specific prose of
its own -- see docs/synapse-graph.md for why.

Note for agent callers: needs the sandbox disabled (localhost REST API).
```

## `synapse-build-refs.sh`

Projects a project's tags cache into a flat, sorted reference index -- the
artifact `synapse-query.sh callers` reads. One line per tag, so "who calls X"
is a text lookup rather than a JSON traversal.

```
Usage: synapse-build-refs.sh [--cache <path>] [--out <path>] [--repo <path>]
       synapse-build-refs.sh --help

  --cache  the tags cache to project. Default $SYNAPSE_WORK_DIR/_tags_cache.bin,
           i.e. ~/.claude/synapse-work/{repo}@{branch}/_tags_cache.bin.
  --out    where to write the index. Default $SYNAPSE_WORK_DIR/_refs.tsv.
  --repo   the repo whose work dir supplies those defaults. Default: the git
           toplevel containing $PWD. Only used to resolve defaults; nothing
           here reads the working tree.

Output, LC_ALL=C sorted, one tag per line:

  name <TAB> def|ref <TAB> kind <TAB> path:line <TAB> expression

`def|ref` is what tree-sitter calls the tag; `kind` is its syntactic category
(`class`, `method`, `call`, `implementation`, ...). Both are kept because they
answer different questions: a `ref` is not necessarily a call -- an
`implements Foo` clause is `ref | implementation` -- so a callers query that
filtered on `ref` alone would over-report.

WHY A SEPARATE FILE RATHER THAN QUERYING THE CACHE. The constraint is format,
not size. Disk is cheap and the cache already lives in the work dir rather
than the version-controlled vault. What bites is querying JSON at scale: one
`jq` pass over a 4.6 MB cache measured 0.064s, which extrapolates to ~13s per
query at a large repo's 942 MB -- for something meant to feel interactive. The same
data as flat sorted lines is a different regime: measured against a 560 MB
index, `grep` answered in 0.092s.

THE NAME COLUMN IS SPACE-PADDED IN tree-sitter's OUTPUT and is trimmed here.
`execute` is emitted as `execute   `, so an exact-match lookup against the raw
text silently finds nothing -- the failure returns success and no rows, which
is indistinguishable from "not called anywhere". synapse-query.sh's `symbol`
already trims for the same reason.

Rebuilt, never appended to: it is derived from the cache and cheap to redo, so
a partial write from an interrupted run is replaced rather than merged. Files
the cache marks `unsupported` (no grammar) contribute nothing and are counted
separately, so "no hits" can be told apart from "never parsed".

Exit codes:
  0 - index written; prints tags/files/unsupported counts on stderr
  1 - could not run (no cache, unreadable cache, missing dependency)
  2 - usage error
```

## `synapse-callers.sh`

Repo-wide call sites of an exact name, over the flat reference index
synapse-build-refs.sh projects from the tags cache.

```
Usage: synapse-callers.sh <name> [--all]   (operates on the repo containing $PWD)

  <name>          exact symbol name (not a prefix, not a regex)
  (default)        calls only, as path:line<TAB>calling expression
  --all            every def and ref, not only calls, as
                   def|ref<TAB>kind<TAB>path:line<TAB>expression

Needs NO graph -- no nodes, no reverse index, no clustering, no vault. It reads
$SYNAPSE_WORK_DIR/_refs.tsv and nothing else, which is why `synapse-query.sh
callers` dispatches straight into this script ahead of that file's
vault/namespace preamble: the property is structural, so it keeps answering
in a repo where /synapse-init has never clustered anything. Build the index
with:

  synapse tags-cache --repo-root . --cache <cache> --paths <path:hash tsv>
  synapse-build-refs.sh

It is name-based like `symbol`, so hits are candidates with evidence rather
than resolved callers -- the calling expression is on the line, which usually
settles the receiver without opening the file. Out of reach, and not worked
around: reflective invocation, and a call whose receiver sits on another line
(a fluent chain split across lines). Interface dispatch appears as the
interface method, which is normally the answer wanted rather than a loss.

`symbol` and `callers` differ in scope, not technique. `symbol` is scoped to
one node's sources and re-hashes them on every call, so it answers "within this
subsystem" and costs O(node sources); `callers` is repo-wide over a precomputed
index, so it answers "anywhere" and costs one pass over a text file.

Exit codes:
  0 - ran successfully. Empty output means "checked, never called" -- a real
      answer, not an error.
  1 - could not run (not a git repo, synapse-identity.sh missing, no
      reference index built yet)
  2 - usage error
```

## `synapse-enumerate.sh`

Enumerates a repo's tracked files, dropping binaries, generated/lockfile
noise, submodule gitlinks and oversized files. Standalone and vault-free --
no manifest.tsv, no clustering, nothing beyond git and the repo itself.

```
Usage: synapse-enumerate.sh [--reenumerate]
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
  Never the script's own location, and never the repo -- see below.

Writes  $SYNAPSE_WORK_DIR/all.txt        enumerated tracked files (kept if present)
        $SYNAPSE_WORK_DIR/oversize.txt   size<TAB>path for files over the cap

An existing all.txt is reused as-is unless --reenumerate forces a rebuild --
a caller that only needs the file list, not a fresh one, pays nothing extra.

Two ways to drop more than the built-in exclusions, both OR'd together:
  ~/.claude/synapse-ignore-files.conf   one ERE per line, comments allowed
  $SYNAPSE_EXTRA_EXCLUDE_RE             a single ERE, for one-off invocations
Excluding a path removes it from the graph entirely -- no owning node, no
vault search hit, no staleness flag when it changes. Right for build output
and vendored code; wrong for anything whose edits still matter.

Files over $SYNAPSE_MAX_FILE_BYTES (default 1048576, 1 MB) are skipped and
reported, not dropped silently: no extension or name rule anticipates a
generated monster, and a silent skip makes `enumerated` disagree with the repo.

Exit codes: 0 ok, 1 could not run, 2 usage error

WHAT IS LEFT HERE. The work moved into `synapse enumerate`; this resolves the
namespace and dispatches. That split is not tidiness -- synapse-identity.sh is
sourced, not executed, and stays bash until every one of its twelve sourcers is
ported, so the namespace has exactly one implementation for as long as any of
them remain. The binary is told the work dir and never derives it.

Measured on syrius3 (125,351 tracked files, 124,817 enumerated): 15.9s and 65
process spawns before, 0.59s and one spawn after -- byte-identical all.txt and
oversize.txt. 45 of those 65 spawns were one `sed` per line of
synapse-ignore-files.conf, comment lines included.
```

## `synapse-gate.sh`

Flags candidate clusters that own no vocabulary of their own, before anyone
pays to author their prose. The one quality check /synapse-init never had:
coverage was already provable by regex expansion plus `comm`, but whether a
cluster corresponds to a *concept* was judgment, discovered only when someone
tried to write its summary and found there was nothing to say.

```
Usage: synapse-gate.sh --vocab <groupwords.tsv> [--all] [--top N]
  --vocab  cluster-keyed vocabulary: `cluster <TAB> word <TAB> count`, i.e.
           synapse-vocab.sh run with --lists. NOT the directory-keyed table --
           see "RUN IT ON CLUSTERS" below, which is the whole reason the
           threshold ever looked unstable.
  --all    print every cluster with its score, not only the flagged ones.
  --top    terms per cluster the rule looks at, default 8.

Prints `cluster <TAB> rare-count <TAB> flagged|ok <TAB> top terms`, one line
per flagged cluster -- so empty output means every cluster is differentiated,
matching the reporting convention of `synapse-query.sh stale`/`drift`/
`grounding`. `--all` adds the `ok` rows in the same shape rather than a
second one, so the same field positions parse either way.

THE RULE, and why it is this and not something more obvious:

  rare  := df <= max(2, N/20)      # N = number of clusters, df over clusters
  flag  := count of rare terms among the cluster's top TOP <= 1

Terms rank within a cluster by raw count. Ranking by tf-idf *sum* is what
fails: a sum follows frequency rather than rarity, and it put two known-bad
clusters near the TOP of the list. What separates a real concept from a
generic one is not how much distinctive vocabulary it has in total, it is
whether it has any at all -- so the rule counts near-unique terms rather than
weighing them.

Measured against the four known-undifferentiated clusters in a large repo
(46 nodes): tolerance 0 catches three with no false positives, tolerance 1
catches all four with no false positives, tolerance 2 catches four but flags
five good clusters as well. The `max(2, N/20)` form reduces to the constant
that worked at that corpus size and scales with cluster count instead of
needing recalibration per repo.

RUN IT ON CLUSTERS, NOT ON MODULE GROUPS. A few dozen candidate clusters, not
the several hundred directory groups that form the orientation evidence.
Document frequency across 500 groups means something entirely different from
document frequency across 46 clusters, and feeding the wrong table in is what
made the threshold look like it needed tuning.

KNOWN LIMIT, deliberately unfixed: the rule cannot distinguish "owns no
distinctive vocabulary" from "produced no vocabulary". Both present as zero
rare terms. In a single-language repo the ambiguity cannot arise. In a mixed
repo, a cluster whose code is in a language with no grammar is flagged as
undifferentiated when it should be left alone -- so treat a flag on such a
cluster as "look at it", which is all a flag ever means here. Whatever
eventually addresses mixed repos has to give this rule a parseable-fraction
signal to tell the two cases apart.

Exit codes:
  0 - ran. Flagged clusters, if any, are on stdout; a flag is advice to
      re-cluster or disperse, never a hard stop, so this is 0 either way.
  1 - could not run (unreadable or empty vocabulary file)
  2 - usage error
```

## `synapse-graph-clean.sh`

Removes Synapse namespaces whose branch was deleted upstream, and reports the
ones it cannot decide about. The only destructive tool in Synapse, which is why
it is a command you run rather than a hook that fires: these are notes in a
permanent vault, and the system should not delete them on inference.

```
Usage: synapse-graph-clean.sh [--dry-run]
       synapse-graph-clean.sh --help

  --dry-run  report what would be removed, delete nothing.

Operates on the repo containing $PWD, across every branch's namespace for it --
not just the branch checked out now.

What it does with each `synapse/{repo}@{branch}/` namespace:

  remove  the branch had an upstream and it is gone -- merged and deleted, the
          case this exists for. `git branch -vv` shows it as `[origin/x: gone]`.
  report  the branch is absent locally and no upstream can be confirmed. That
          covers a never-pushed branch deleted by hand, and a branch whose
          config went with it, which are indistinguishable after the fact.
          Reported for a human to remove, never deleted here.
  keep    anything else, including a branch that was never pushed and still
          exists -- work in progress, whose namespace is in active use.

A `git fetch --prune` runs first unless --dry-run: without it a deleted branch
still has a local remote-tracking ref, every namespace looks alive, and the
command silently does nothing.

In a repo with no remote there is no upstream to consult at all, so the test
falls back to whether the local branch still exists. Without that fallback the
first run in a remoteless repo would classify every namespace as deleted
upstream and wipe the lot.

Deletion is on-disk rather than over the REST API, which would need one call
per note. The vault's own git history (see synapse-db-sync.sh) is the undo.

Exit codes:
  0 - ran (removed something, or found nothing to remove)
  1 - could not run (no vault, not in a git repo, missing dependency)
  2 - usage error
```

## `synapse-graph-wipe.sh`

Wipes the current checkout's Synapse namespace, preserving any hand-written
`## Notes` content first, ahead of a full /synapse-rebuild-full rebuild. The
second destructive tool in Synapse (after synapse-graph-clean.sh), so it follows
the same discipline: --dry-run support, and rm -rf gated behind a belt-and-braces
path check that only ever removes a directory whose name was just matched inside
the vault's own synapse/ directory.

```
Usage: synapse-graph-wipe.sh [--dry-run]
       synapse-graph-wipe.sh --help

  --dry-run  report node count and which nodes have `## Notes` content at risk,
             delete nothing, preserve nothing.

Operates on {repo}@{branch} resolved from $PWD via synapse-identity.sh -- the
same resolution /synapse-init and /synapse-rebuild-diff use. Never takes a
namespace on the command line: this wipes the current checkout's own namespace,
nothing else's.

`## Notes` is the one thing in a node file that is human-authored and lives
outside every generated fence -- no script regenerates it. Before deleting
anything, every node's `## Notes` section is scanned; non-empty ones are dumped
into a staging note at scratchpad/{repo}@{branch} -- preserved notes before full
rebuild.md, so nothing is silently lost even though the namespace directory that
held them is about to be removed. /synapse-rebuild-full reads that staging note
back after rebuilding and merges what it can into the new nodes.

Exit codes:
  0 - ran (removed the namespace, or --dry-run reported cleanly)
  1 - could not run (no vault, not in a git repo, missing dependency, namespace absent)
  2 - usage error
```

## `synapse-identity.sh`

Sourced by every component that has to name a Synapse namespace. One copy on
purpose: synapse-staleness.sh already carried a comment warning that a
divergent resolution chain makes one component refuse where another proceeds,
and that warning applied to five inline copies of the same logic. This is that
chain, once.
A namespace is keyed by repo AND branch -- `synapse/{repo}@{branch}/` -- so the
graph describes one tree rather than every branch at once. Worktrees need no
handling of their own: git refuses to check out one branch in two worktrees of
a repository (the main checkout included), so a branch already names at most
one checkout. That is why there is no `.git`-file parsing here, no `gitdir:` or
`commondir` walking, and no worktree-versus-submodule discrimination -- the
whole question reduces to which branch is checked out.

```
Usage (sourced, never executed):
  . "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh"
  REMOTE="$(synapse_remote "$REPO_ROOT")"           # identity, unchanged chain
  NS="$(synapse_namespace "$REPO_ROOT")" || ...     # "{repo}@{branch}"

Deliberately does NOT `set -euo pipefail`: a sourced file that sets shell
options silently rewrites its caller's error handling. Every git call below is
guarded instead, so these stay safe under a caller that does set them -- which
all the hooks do.
```

## `synapse-push-nodes.sh`

Writes every node that has both a path list and an authored body. Step 2 of a
scripted /synapse-init.

```
Usage: synapse-push-nodes.sh [NN ...]      (default: every staged or authored node)
  Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.

Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title   (from synapse-build-lists.sh)
       $SYNAPSE_WORK_DIR/b-NN.md                   (authored per node, see below)
Calls  synapse-write-node.sh once per node.

Each b-NN.md carries its own one-line summary in frontmatter, so everything
authored about a node lives in one file:

    ---
    summary: One line differentiating this node from its siblings.
    ---

    ## Summary
    ...

The frontmatter is stripped before the rest is passed on as the node body, and the
summary becomes the node's `summary` field. A node without one is an error rather
than a default, because the index bullet has nothing to say without it.

Note for agent callers: needs the sandbox disabled (localhost REST API).
```

## `synapse-query.sh`

Read-only queries against a repo's Synapse graph. Reads the expensive parts
internally and prints only what was asked for.

```
Usage: synapse-query.sh <subcommand> [args]   (operates on the repo containing $PWD)

  body    <node>                     fenced prose only, no frontmatter
  sources <node>                     every path the node covers
  sources <node> --count             just the number
  sources <node> --modules           module<TAB>count, LC_ALL=C sorted
  sources <node> --filter <pattern>  matching paths only (substring)
  field   <node> <key>               one top-level frontmatter scalar
  stale                              nodes whose files no longer match, with a reason
  drift                              what changed since each node's recorded commit
  grounding                          nodes whose recorded evidence no longer matches
  grounding <node> --list            that node's groundings, as path<TAB>lines
  links   <node>                     outbound relations, as relation<TAB>target
  links   <node> --inbound           what points here, as relation<TAB>source
  links   <node> --closure           every node reachable outbound, depth<TAB>node
  links   --check                    link targets that resolve to no node
  symbol  <name> <node>              exact-name def/ref hits across the node's
                                     sources, as path<TAB>tag-line
  callers <name>                     repo-wide call sites of an exact name, as
                                     path:line<TAB>calling expression
  callers <name> --all               every def and ref, not only calls, as
                                     def|ref<TAB>kind<TAB>path:line<TAB>expression

<node> may be given with or without the trailing `.md`.

`callers` is a one-line dispatch into claude/lib/synapse/synapse-callers.sh, ahead of
this script's namespace preamble -- see that file's header for why, and for the
rest of its usage and rationale.

`symbol` and `callers` differ in scope, not technique. `symbol` is scoped to
one node's sources and re-hashes them on every call, so it answers "within this
subsystem" and costs O(node sources); `callers` is repo-wide over a precomputed
index, so it answers "anywhere" and costs one pass over a text file.

`symbol` is a name-based, not type-resolved, lookup backed by a per-project
tags cache ($SYNAPSE_WORK_DIR/_tags_cache.bin, default
~/.claude/synapse-work/{repo}@{branch}/) kept current as a byproduct of node
build/regeneration, with any file the cache is missing tagged lazily on the
spot. Set SYNAPSE_DISABLE_SYMBOL_CACHE (any value) to disable entirely --
see docs/synapse-graph.md's "Exact-symbol lookup" section for the full design.

`stale` re-hashes what a node claims; `drift` diffs its recorded `commit` against
HEAD, so only `drift` sees added, deleted and renamed paths. Neither pulls.
When to use which, and why any of this is a script: docs/synapse-graph.md.

Exit codes:
  0 - ran successfully. Empty output means clean for every reporting subcommand:
      `stale`, `drift`, `grounding` and `links --check`. `drift` prints context
      (commits behind, commits since baseline) only alongside a finding, so its
      silence means the graph matches the worktree rather than that it gave up.
  1 - could not run (missing dependency, no vault, no namespace, remote
      mismatch, unknown node). Treat as "no information", never as "clean".
  2 - usage error (unknown subcommand, bad flag, unsupported field)

WHAT IS LEFT HERE. Namespace resolution and dispatch, and nothing else. Every
subcommand moved into `synapse query`, which is where the vault reads, the
frontmatter parsing, the digest arithmetic, the link graph and the tags-cache
lookup now live -- and where `jq`, `sed`, `awk`, `comm`, `paste`, `wc` and every
`curl` on the read path went with them. What the binary still spawns is `git`
and, for a user-authored ERE out of `_manifest.tsv`, `grep -E`.

Identity stays here because `synapse-identity.sh` is still bash and is sourced
by hooks this rewrite has not reached yet. It is resolved once and exported, so
the binary cannot disagree with the hooks about which namespace a checkout
belongs to -- the same arrangement synapse-enumerate.sh already uses for
$SYNAPSE_WORK_DIR.
```

## `synapse-rank.sh`

Ranks a node's sources by how much they are worth READING when authoring its
prose. Decides reading order only: `sources` stays exhaustive, so coverage,
staleness and vault search are all unaffected by anything here. See
docs/synapse-graph.md's "Orientation from vocabulary" section.

```
Usage: synapse-rank.sh --sources <file> [--repo <path>] [--top N] [--tier T]
                       [--pool summary|crux]
  --sources  file of repo-relative paths, one per line -- a node's `sources`,
             or synapse-build-lists.sh's lists/NN.txt.
  --repo     default: the git toplevel containing $PWD.
  --top      lines per tier, default 10. `--top 0` prints every ranked file.
  --tier     restrict output to `code` or `dsl`. Default: both.
  --pool     which half of the authoring job this is for, default `summary`
             (which is the unrestricted behaviour). See below.

THE TWO POOLS ARE NOT THE SAME SET OF FILES, and that is a measured result
rather than tidiness.

  summary   everything. A summary is made of NAMES, so it draws on test class
            names and DSL consumer names as well as implementation -- both at
            zero read cost, and both carrying domain concepts nothing else
            surfaces. On a real node `Gegenpartei` and `Frist` came only from
            test class names.

  crux      implementation only, tests excluded, code tier only. A crux is
            concentrated logic, and none of the seven `crux_path` values
            recorded in a real namespace is a test. Density ranks tests high
            for a structural reason -- many small `@Test` methods, each a
            definition, in a small file -- so without this they would crowd
            out the thing a crux is supposed to point at.

What counts as a test is a path/filename heuristic, not a parse, and it is
deliberately conservative about the boundary: `FooTest.java` is a test,
`Latest.java` is not. Override the whole rule with $SYNAPSE_TEST_PATH_RE (one
ERE) for a project that names tests some other way.

Prints `tier <TAB> score <TAB> path`, ranked within each tier, code first.
Counts per tier go to stderr, so a node whose files all scored zero is a
number rather than an empty answer.

THREE TIERS, because "relevant" means different things per kind of file.

  code    definitions per KB. NOT raw definition counts: those rank generated
          constant tables first, which is the opposite of useful. Normalising
          by size moved a known crux from rank 17 to rank 7 of 574 on a real
          node. Definitions specifically, not all tags -- a reference says the
          file USES something, a definition says it DECLARES it, and a summary
          is made of what a subsystem declares.

  dsl     a declarative file carries little meaning on its own; the code that
          consumes it carries the domain verbs. So the CONSUMER is what gets
          ranked, scored by how many declarations it serves. Resolved by stem
          plus module prefix, never by parsing.

  ignore  everything else -- config, data, docs, generated output. Scored
          zero and omitted from the ranking, still fully covered by `sources`.

WHAT COUNTS AS DSL IS DERIVED, NOT LISTED. A non-code file is a declaration
exactly when some code file in the same module has a stem starting with its
own -- `Adresse.domvo` resolving to `Adresse.java`, `Kunde.gui` to
`KundeController.java`. Shipping a list of extensions instead would have meant
shipping one project's vocabulary (`.gui`, `.domvo`, `.bo`, `.paramvo`) as if
it were universal, and this toolkit is meant to be language-agnostic with no
per-repo curation.

THE MODULE PREFIX IS LOAD-BEARING, not a tie-breaker. Generic stems -- the
measured examples were `Adresse` and `NatPerson` -- match dozens of unrelated
classes across a large repo, so a stem-only hop resolves to whichever one
sorts first and is worse than no answer. Constraining to the declaration's own
module is what makes the hop mean anything.

Consumers are searched repo-wide rather than within `sources`: the code that
uses a node's declarations is frequently the reason to read it, and is not
always a file the node itself owns.

Exit codes:
  0 - ran. Empty output means nothing scored above zero, which for a node made
      entirely of config is the correct answer, not a failure.
  1 - could not run (not a git repo, unreadable sources, no synapse binary)
  2 - usage error
```

## `synapse-vocab.sh`

Reduces a whole repository to its symbol vocabulary, grouped by directory:
`group <TAB> word <TAB> count`. Evidence for the clustering step of
/synapse-init, so that deciding what a subsystem is about costs symbol names
rather than source lines. See docs/synapse-graph.md's "Orientation from
vocabulary" section.

```
Usage: synapse-vocab.sh [--repo <path>] [--depth N] [--chunk N] [--out <dir>]
                        [--lists <dir>]
  --repo   default: the git toplevel containing $PWD.
  --depth  directory levels that make a group, default 2 (`src/main` from
           `src/main/java/Foo.java`). A path shallower than that groups by
           whatever prefix it has; a repo-root file groups as `(repo root)`.
  --chunk  files per tree-sitter invocation, default: one chunk per core,
           floor 500. Only a parallelism knob -- see below.
  --out    default: $SYNAPSE_WORK_DIR, i.e. ~/.claude/synapse-work/{repo}@{branch}/.
  --lists  key by CLUSTER instead of by directory: a synapse-build-lists.sh
           lists/ dir, where each NN.txt is a node's paths and NN.title its
           name. Files no list claims are skipped. --depth is then unused.

Writes  <out>/groupwords.tsv   group <TAB> word <TAB> count, group then count desc
        <out>/counts.tsv       group <TAB> file count, count desc

TWO GROUPINGS, ONE SCRIPT, AND WHY BOTH ARE NEEDED. Directory grouping is the
orientation evidence -- it exists before anyone has decided what the nodes
are, which is the whole point of it. Cluster grouping is what the quality gate
scores, and a cluster is not generally a union of directories, so it cannot be
derived from the directory-keyed table after the fact. The second run costs
another tagging pass (~51s on a large repo) against a build that was measured in
hours, so exactness was the cheaper side of that trade.

Prints groups / files / code files / pairs on stderr, so a repo that yielded
no vocabulary is a number rather than an empty file nobody looked at.

WHY THIS IS AFFORDABLE. Tagging is one in-process pass per worker thread, so
there is no CLI startup to amortise and a grammar loads once per extension per
thread. Chunking exists only to use more than one core; it is not what makes
this cheap.

THE PARALLELISM IS LOAD-BEARING, unlike the equivalent apparatus stage 1 dropped
from the tags cache. Measured on syrius-querschnitt-basis (3,642 code files):
1987ms for the twelve-process bash, 4453ms for a sequential in-process pass, and
1142ms threaded -- byte-identical output in all three. Tree-sitter parsing
thousands of files is real CPU work, so cores win even against process overhead.

RAW TAGS ARE NEVER STORED. Each worker pipes `synapse tags` straight into
the word reduction and keeps only `group <TAB> word`. The tags themselves are
~942 MB on a large repo against 6.9 MB of vocabulary, so writing them out first
would cost more disk than the entire graph.

EVERY TRANSFORM IS awk, NOT sed. `sed` works on whole lines, so a character
class meant for the symbol field also mangles the group key and the tab
between them -- and BSD `sed` reads `\t` inside a bracket expression as a
literal `t`, which silently destroys the field separator rather than erroring.
Everything runs under LC_ALL=C for the same class of reason: macOS `awk`
aborts mid-stream on Latin-1 bytes, which real repos contain.

Word splitting matches the identifier conventions, not English: `getUserName`
gives get/user/name, `user_name` gives user/name, and a run of capitals stays
with what follows it (`HTTPServer` is one word). Words shorter than 4
characters, pure digits, and anything in ~/.claude/synapse-prompt-stopwords.conf
are dropped -- the same list the prompt tokenizer uses, deliberately, because
two stopword lists that disagree is how two mechanisms start giving different
answers.

Exit codes:
  0 - ran. An EMPTY groupwords.tsv is a legitimate outcome (no file had a
      usable grammar) and the caller must test for it: that is the signal to
      fall back to `synapse-orientation`, not an error to report.
  1 - could not run (not a git repo, no synapse binary, no work dir)
  2 - usage error
```

## `synapse-write-node.sh`

Writes one Synapse node into the vault: hashes every source path, computes
sources_digest, records the baseline `commit`, builds the aggregated `## Sources`
mirror, and PUTs the note via the Obsidian Local REST API.

```
Usage: synapse-write-node.sh --title <t> --summary <s> --paths <file> --body <file>
       synapse-write-node.sh --help

  --title    node title. Used verbatim as the H1, and sanitized for the filename.
  --summary  one line for the index bullet, stored as the `summary` frontmatter
             field. Written for the index, not as the node's opening sentence.
  --paths    file of repo-relative paths, one per line: every file the node covers.
  --body     file holding the authored prose (## Summary / ## Crux / ## Links).
             `## Sources` and the generated fences are added by the writer.

The body must not contain crux code. It points instead:

  <!-- crux: crates/matcher/src/lib.rs 412-419 -->     slice these lines
  <!-- crux: none -->                                  no single span carries it

The writer cuts the text out of the file, fences it with a language guessed
from the extension, appends a `path:start-end` provenance line, and records
`crux_path`/`crux_lines` in frontmatter. The path must be one the node claims
and the range must be under 20 lines, or the write is refused.

The body may also carry any number of grounding pointers — the evidence a
summary rests on, typically a doc comment or a test:

  <!-- grounded_in: src/main/java/Foo.java 10-14 -->

These are recorded in the `grounded_in` frontmatter list as path + lines +
sha256 of the sliced text, then stripped from the body: provenance, not
display. Same path and range checks as the crux, with a 40-line cap.

Writes to the vault over the Obsidian Local REST API on 127.0.0.1. Agent callers
need the network sandbox disabled, or curl fails with exit 7 and no message.

As a byproduct it refreshes $SYNAPSE_WORK_DIR/_tags_cache.bin (default
~/.claude/synapse-work/{repo}@{branch}/) for the node's sources, so
`synapse-query.sh symbol` is a cache read. That file is derived and
disposable, which is why it lives beside the work dir rather than in the
version-controlled vault. Never fatal; SYNAPSE_DISABLE_SYMBOL_CACHE skips it.

Exit codes:
  0 - node written; prints "<file>\t<n> files\t<digest>"
  1 - could not run (missing dependency, no vault, remote mismatch, PUT failed)
  2 - usage error

Design rationale lives in docs/synapse-graph.md, not here.

WHAT IS LEFT HERE. Namespace resolution and dispatch. The writer moved into
`synapse write-node`: the path hashing (in process now -- a git blob hash is
sha1 over an object header git has not changed since 2005, so `git hash-object
--stdin-paths` is gone), the digest, the crux slicing, the grounding digests,
the `## Sources` mirror, the frontmatter and the PUT. With them went `jq`, the
four `awk` programs, `paste`, `sed`, `wc` and both API *reads* -- the namespace
index and the existing node are read from disk, which is where they are. The PUT
still goes through the API, because that is what keeps Obsidian's own view and
the vault's git history correct.

Identity stays here because `synapse-identity.sh` is still bash and is sourced
by hooks this rewrite has not reached yet. It is resolved once and exported so
the binary cannot disagree with the hooks about which namespace a checkout
belongs to.
```

