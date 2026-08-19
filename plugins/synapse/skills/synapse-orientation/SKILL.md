---
name: synapse-orientation
description: How to work out where meaning lives in a codebase you have not seen before — first mechanically, from the repo's own symbol vocabulary, and where no grammar exists, by four questions in order with the cheap commands that answer each. Includes tree-sitter grammar discovery. Use when clustering a repo into Synapse graph nodes for the first time, when re-deriving a node's premises in /synapse-rebuild's re-orient class, or any time you need to orient in an unfamiliar tree before making claims about it.
---

# Orienting in an unfamiliar repo

Loaded by `/synapse-init` at its orientation step, and by `/synapse-rebuild` when a node lands in
the *re-orient* class and its premises have to be re-derived rather than patched. Useful on its own
terms too: nothing here is Synapse-specific except what you do with the answers.

It is a skill rather than a section inside either caller because it is technique, not procedure —
how to find where meaning lives in a tree you have never seen. Both callers need exactly the same
technique, and a copy in each is how the two start giving different advice.

The goal is not a summary of every file; it is learning *where meaning lives in this particular
tree* well enough to cluster it and then write about it.

## Start with the vocabulary — it is mechanical, and it is most of the answer

```
synapse vocab                    # writes six tables into $SYNAPSE_WORK_DIR
```

One command derives what used to be an exploration. It tags every file that has a grammar, splits
symbol names on CamelCase and snake_case, drops stopwords, and aggregates per directory group:

- `counts.tsv` — `group ⇥ file count`, biggest first. **This is question 1, already answered.**
- `groupwords.tsv` — `group ⇥ word ⇥ count`. **This is question 4, for the whole repo, unsampled.**
- `groupexts.tsv` — `group ⇥ artifact kind ⇥ count`. What an area is *made of*, over every kept
  path rather than the code subset — the interesting files here are usually the ones no grammar
  can read.
- `namespaces.tsv` — `group ⇥ namespace ⇥ agree ⇥ total`, where a rule is configured (question 3,
  below, for whichever extensions `~/.claude/synapse-namespace-rules.conf` knows about).
- `parseable.tsv` and `distinctive.tsv` feed `synapse gate` and this section's own distinctiveness
  question respectively — see immediately below.

Measured: the whole of a large repo (125,351 files, 98k of them code) takes ~51 seconds, and clusters
derived from the result expanded to 99.91% coverage. Read these files and cluster from them.
Reading is free; only what you print costs, so collapse to a few dozen lines before reading any
source at all.

**Which words are *distinctive* rather than merely frequent has a first answer in `distinctive.tsv`
now** (`group ⇥ distinctive ⇥ considered`) — how many of a group's top terms score above 0.5 on the
saturation curve `distinctiveness = D / (D + df)`, `D = max(2, N/K)`, rather than the binary "appears
in every group" cliff. Read it alongside `groupwords.tsv`, not instead of it: the table says *how
many* of a group's top terms are shared background versus real signal, not *which* ones or *why* —
a word appearing in every group is background, a word appearing in two is a concept, and seeing that
distinction by eye across groups, not down one, is still the part that turns a count into a cluster.

**An empty `groupwords.tsv` is a legitimate answer**, not a failure: no file in this tree had a
usable grammar. `synapse vocab` says so on stderr and exits 0. That is the case the four
questions below exist for.

## When there is no usable grammar — and as a complement when there is

Four questions, in order. They are language-agnostic; how you answer each one is not, and deducing
that on the spot is the work. With a vocabulary table in hand, 1 and 4 are already answered and 2
and 3 are still worth asking — question 3 in particular is invisible to the vocabulary, because it
is about the gap between what the code calls itself and what the *directory* calls it:

1. **Where is the weight?** Group paths by module/directory and count. Tells you which
   subsystems are large enough to deserve a node and which must be grouped with a neighbour.
2. **What kind of artifact dominates?** Group by extension and count, per candidate cluster.
   This is the cheapest source of genuine surprise — a cluster that is 60% JSON or `.bpmn` or
   `.sql` is telling you something no module name will.
3. **What does the code call itself, versus what the directory calls it?** Derive the code's own
   namespace roots (Java/Kotlin packages, Rust `mod`/crate paths, Go packages, Python modules,
   OCaml library names, TS path aliases) and compare them with the directory names. **Divergences
   here are the highest-value findings in the whole build** and they are invisible from the
   filesystem: a module named one thing whose code is uniformly named another means every later
   search for the wrong term returns nothing.
4. **What are the domain's verbs?** The exported/public symbol names — they read as the
   vocabulary of the domain, and clusters of related names (a state machine, a configuration
   family) are what a node's prose should be about.

**Namespace rules are self-populating too, the same way grammar discovery below is — write one
back when question 3 turns up a well-known ecosystem.** `~/.claude/synapse-namespace-rules.conf`
starts empty and nothing seeds it, so `namespaces.tsv` stays empty forever unless something
writes a rule into it. If you just hand-derived a namespace root for an ecosystem this repo uses
and `synapse-namespace-rules.conf` has no entry for its extension yet, the derivation you just
did *is* the rule — write it back (create the file as `{}` first if it doesn't exist) so the next
repo in this ecosystem gets `namespaces.tsv` for free instead of a repeat of this same
by-hand analysis. Known shapes, verified against one real file in *this* repo before writing --
a wrong guess caches a bad rule for every future project in the ecosystem, not just this one:

| ecosystem | kind | file | prefix | terminator |
|---|---|---|---|---|
| Java | in-file | — | `package ` | `;` |
| Kotlin | in-file | — | `package ` | (none — end of line) |
| Go | build-file | `go.mod` | `module ` | (none — end of line) |
| Rust | build-file | `Cargo.toml` | `name = "` | `"` |
| OCaml (dune) | build-file | `dune` | `(name ` | `)` |

An ecosystem not on this list is real research, not a lookup — same as an unrecognised grammar
below: find the declaration convention, verify it against a real file, then write the rule.

**Answer these with aggregate shell over the path lists, not by reading files.** Reading is
internal and free; only what you print costs tokens, so a 15,000-file cluster should collapse to
a few dozen lines before you read anything. Then let `synapse rank` pick which 2–4 files per
node are worth actually reading — see "Choosing what to read" below.

**Do not sample, and do not invent a sampling rule.** An earlier version of this skill said
`synapse tags` took one file per invocation and so could not be run over a whole cluster,
and told you to pick a sampling rule and defend it. That is obsolete: `synapse tags --paths`
tags a whole list in one invocation, which measured 33× on 200 files, and `synapse vocab`
above uses it to cover an entire repository in under a minute. Sampling existed only to bound a
cost that no longer exists, and every fixed rule was biased in a way that had to be chosen
deliberately — alphabetical is an accident, largest-file favours generated code and god-classes,
most-referenced needs the full scan you were avoiding. If you find yourself reaching for a
sample, run the full pass instead.

**When an aggregation is worth repeating, write it down rather than retyping it.** Once you have
run the same one-liner for the third cluster, record it in `synapse/{repo}@{branch}/_profile.txt` — a
machine-only sibling of `_manifest.tsv`, never a node — as a fenced command plus one line on what
it revealed about *this* repo. **Read it, don't execute it:** it is a record of the aggregations
that earned their keep, so a later run applies the commands itself rather than shelling out to a
script fetched from a notes vault. Begin any re-run by reading it, and improve it rather than
re-deriving from scratch. Nothing like it ships, because which aggregations carry signal depends
on the codebase — a distributed one would encode the wrong ecosystem's conventions.

`.txt`, with markdown formatting inside, for a measured reason: Obsidian indexes `.md` files as
notes, so a `_profile.md` turns up in search, Quick Switcher and the graph, where it is pure noise
to a human reading notes. A non-`.md` extension is invisible to all of those and still perfectly
readable. Note the `_` prefix does *nothing* mechanically — it is only a hint to a human who sees
the file, matching `_manifest.tsv`. Record **negative results** here too ("this abbreviation has no
expansion anywhere in the repo"); a saved shell script cannot hold a search that came back empty,
which is the main reason this is prose rather than an executable.

## Choosing what to read

Once clusters exist, `synapse rank --sources lists/NN.txt` decides reading order — it does not
decide coverage, which stays exhaustive. Two pools, because the two halves of authoring want
different files:

```
synapse rank --sources lists/NN.txt --pool summary   # names: code, tests, DSL consumers
synapse rank --sources lists/NN.txt --pool crux      # implementation only, tests excluded
```

A summary is made of *names*, so test class names and the names of the code consuming a DSL file
both count as evidence at zero read cost. A crux is concentrated logic, so tests are excluded from
that half — density ranks them high for a structural reason (many small test methods, each a
definition, in a small file), and none of the recorded `crux_path` values on a real namespace is a
test.

**Read the top few, not the list.** The ranking exists so that reading 3 files out of 809 produces
the same summary as reading all of them, which is the measured result this whole approach rests on.

**Tree-sitter acceleration — handling `synapse tags`'s exit codes.** These are the *single-file*
form's codes. In `--paths` batch form an extension with no grammar produces one warning line on
stderr and the batch still succeeds, because a mixed repo nearly always has some language that
works and failing the whole batch for one would throw away every language that did.

**A missing grammar gets one line and nothing more.** No coverage report, no per-language
accounting: a file tree-sitter cannot parse is not source, and a non-source file has nothing to
contribute to a node's prose. Do not build a tally out of those warnings.

- **Exit 0:** use the printed tags directly as clustering signal for this file.
- **Exit 1:** this language is a known dead end (or tree-sitter/a C compiler isn't available at
  all) — fall back to a full read for this file, silently, no need to re-announce something
  already covered by the up-front C-compiler check.
- **Exit 2 ("needs discovery" — this extension has never been seen before):** run this discovery
  procedure once, then retry the script:
  1. Try the naming convention first: `https://github.com/tree-sitter/tree-sitter-{lang}` (covers
     most official grammars, e.g. OCaml) — a quick existence check, no reasoning needed if it
     just resolves.
  2. If that doesn't resolve, fall back to a web search for a community-maintained grammar for
     the language.
  3. **Verify before trusting — three tiers, tried in order, and a repo existing is never
     sufficient on its own for any of them** (sb-012). Stop at the first one that verifies; the
     registry records which tier actually won, per step 4 below.

     **Tier 1 — `queries/tags.scm`.** Check **both** the repo root and any sub-grammar subpath,
     in that order — multi-grammar repos split either way and neither is the rule:
     `tree-sitter-ocaml` puts a query under each of its three sub-grammars in `grammars/`, while
     `tree-sitter-typescript` keeps a single shared `queries/tags.scm` at the root serving both
     its `typescript/` and `tsx/` sub-grammars. Plenty of grammars ship only
     `queries/highlights.scm` and no tags query at all — a repo existing there proves nothing by
     itself, only reading the file does.

     **Tier 2 — `queries/locals.scm`, when tier 1 is absent.** Read it and judge whether its
     `@local.definition.*` captures are well-formed or noise, the same "verify before trusting"
     standard as tier 1, not a weaker one just because there is less to work with:
     `tree-sitter-grammars/tree-sitter-zig`'s locals.scm is well-formed, per-kind captures
     (`function`, `method`, `type`, `field`, `var`, `parameter`); `GrayJack/tree-sitter-zig`'s
     captures a bare `@reference` on *every identifier in the file*, which would flood `_refs.tsv`
     with noise rather than add signal — reject that one, even though the file exists and parses.
     A capture with **no** kind suffix at all — bare `@local.definition`, not
     `@local.definition.<kind>` — is not a defect to reject on sight: it is a real, common
     nvim-treesitter shape (`tree-sitter-ocaml`'s own `locals.scm` does exactly this,
     `(value_pattern) @local.definition`, confirmed directly), and it maps through the
     kind-synonym rule list the same as any suffixed one, keyed by the empty string. That rule
     list is `~/.claude/synapse-kind-synonyms.conf` (`SYNAPSE_KIND_SYNONYMS_CONF` overrides the
     path), the same shape and precedence as `synapse-grammars.conf`/`synapse-namespace-rules.conf`
     — ordered rules, first match wins, absent means no mapping rather than a guessed one.

     Then **run it**, against a real sample file from the repo being oriented in, not just read the
     `.scm` text — a query whose every pattern leans on a predicate the evaluator can't answer
     (`#match?`, or any unrecognised predicate name) fails to *load* at all rather than matching
     zero, a distinct outcome (`Error.PredicateUnsupported`) that is an outright reject exactly
     like a candidate that matched nothing, not a puzzle to work around.

     **Tier 3 — a query/walk generated from `node-types.json`, when neither tier above is
     usable.** `node-types.json` is a build artifact `tree-sitter generate` always produces, so
     this tier is available for nearly every grammar — which makes verification about *quality*,
     not presence: run it against a real sample file the same way as tier 2, and judge whether
     what it caught is useful signal. The zero-cost floor (a candidate matching literally nothing
     is auto-rejected, no judgement needed) is the only mechanical check; everything else is read
     and decided by eye. Expect this tier to be weaker than tier 1/2, not absent-minded about it.
     The classifier's suffix/prefix matching and the walk's identifier search are both
     case-insensitive and PascalCase-boundary-aware (`maxxnino/tree-sitter-zig`'s `VarDecl`/
     `TestDecl` and its all-caps `IDENTIFIER` leaf are both caught now, confirmed live — 0 tags to
     46 on a real file). What still doesn't match is a genuinely *different word*, not just
     different casing: `FnProto` has no suffix this tier recognizes at all, and
     `tree-sitter-ocaml`'s `value_name`/`value_pattern` leaf types aren't `identifier`/`name`
     under any casing, confirmed directly. That's still not a reason to hardcode one grammar's
     exact spelling into the classifier — the generic case/boundary handling covers a real,
     cross-language class of grammars (PascalCase/ALL-CAPS naming conventions), a per-grammar word
     substitution would not. `~/.claude/synapse-kind-synonyms.conf` — the same rule list tier 2
     reads above — reaches into tier 3 too, keyed on the grammar's raw node type name (e.g.
     `ContainerDecl`, `subprogram_body`) instead of a locals.scm suffix, and it can do two things:
     relabel a kind the heuristic already guessed, or **force-classify a type the heuristic missed
     outright** — confirmed needed against `tree-sitter-ada`'s `subprogram_body` (a full
     function-with-implementation, no `_declaration`/`_definition`/`decl`/`def` suffix at all, so
     it never became a candidate on its own). Absent/empty is a no-op either way, so this never
     needs touching unless a specific grammar needs it.

     **Before falling through to the escape hatch, try inference once — verified, not left as a
     guess.** When tier 3 runs but is visibly weak (real declarations missing entirely, or caught
     with an unhelpfully generic kind), read `node-types.json` for the pattern the heuristic
     missed. Two confirmed shapes to recognize: a *prefix*-marked defining keyword instead of a
     suffix-marked one (Common Lisp's `defun` is `def-un`, invisible to a suffix scan built for the
     C-family `noun_declaration` convention), and a body/declaration split the classifier has no
     word for (`tree-sitter-ada`'s `subprogram_body` names a full function-with-implementation but
     carries none of the recognized suffixes). Propose `synapse-kind-synonyms.conf` rules scoped to
     this grammar's `source.<lang>` for what's missing or mislabeled, then **re-run `synapse tags`
     against the same real sample and confirm the result actually improved** — not just that the
     rule looks reasonable on paper. Text quality is not a proxy for this: `tree-sitter-ada`'s
     `locals.scm` reads as well-formed and produces zero tags when actually run against a real
     sample, confirmed directly — exactly the gap this verification step exists to catch. Only
     write to the conf file once the improvement is confirmed live, and only there — never
     `$SYNAPSE_WORK_DIR`. These are facts about a *language*, not this repo, and the whole reason
     these conf files are global and permanent (see step 4 below) is so the next project in the
     same language skips rediscovering it; a repo-scoped copy would throw that away for exactly the
     kind of finding worth keeping. This step is additive only and has a real ceiling: it can fix a
     wrong kind or catch a type that exists as its own grammar node but was missed, never conjure
     structure a grammar doesn't have. Clojure's and Scheme's `defn`/`define` aren't distinct node
     types in their own grammars at all, just a generic list form, confirmed directly — no rule
     fixes an absence of structure to key one on.

     **When none of the three verify, tier 3 verifies but stays too weak even after an inference
     attempt, or the language's grammar has no distinct node types worth keying rules on at all:**
     `$SYNAPSE_GRAMMARS_QUERY_PATH/{ext}.scm` is the sanctioned escape hatch — a human-authored
     query file that preempts the whole cascade, not a fourth tier to discover automatically. Name
     it as an option when reporting the outcome (step 5) rather than silently accepting a weak
     tier 3 or a bare `unsupported`.
  4. Write the result back to `~/.claude/synapse-grammars.conf` (create it as `{}` first if it
     doesn't exist) — a positive entry (`{"repo": "...", "scope": "..."}`) for whichever tier
     verified, `{"unsupported": true}` only when all three came up empty or unusable. Record which
     tier with `"queries"`: omit it (or write `"tags"`) for tier 1, `"locals"` or `"generated"` for
     the other two — omitted defaults to `"tags"`, so every entry written before this addition
     stays valid with no migration. This is a permanent, cross-project cache keyed by extension —
     every future project skips rediscovery for this language entirely, tier decision included.

     **The key is the bare extension with no leading dot** — `"rs"`, never `".rs"`, because
     `synapse tags` derives it from the path suffix. Getting this wrong fails *silently*
     and expensively: the lookup misses, the script keeps returning exit 2, and discovery
     re-runs for that language on every file in every project forever, caching nothing. So the
     file should end up shaped like this:

     ```json
     {
       "rs": { "repo": "https://github.com/tree-sitter/tree-sitter-rust", "scope": "source.rust" },
       "ml": { "repo": "https://github.com/tree-sitter/tree-sitter-ocaml", "scope": "source.ocaml",
                "path": "grammars/ocaml", "queries": "locals" },
       "sh": { "unsupported": true }
     }
     ```
  5. Announce the outcome either way — name which tier, when one verified ("found/verified a
     `locals.scm`-based fallback for `.rs`, cached" or "no usable tree-sitter grammar for `.rs`,
     falling back to full reads") — then retry `synapse tags {path}` now that the registry has an
     entry (falls back to a full read for this file per the Exit 1 case above if discovery came up
     empty).
