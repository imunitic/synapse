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
   namespace/package/module declaration, however this ecosystem spells it, and compare it with
   the directory names. **Divergences
   here are the highest-value findings in the whole build** and they are invisible from the
   filesystem: a module named one thing whose code is uniformly named another means every later
   search for the wrong term returns nothing.
4. **What are the domain's verbs?** The exported/public symbol names — they read as the
   vocabulary of the domain, and clusters of related names (a state machine, a configuration
   family) are what a node's prose should be about.

**Namespace rules are self-populating too, the same way grammar discovery below is — write one
back when question 3 turns up a real declaration convention.** `~/.claude/synapse-namespace-rules.conf`
starts empty and nothing seeds it, so `namespaces.tsv` stays empty forever unless something
writes a rule into it. If you just hand-derived a namespace root for an ecosystem this repo uses
and `synapse-namespace-rules.conf` has no entry for its extension yet, the derivation you just
did *is* the rule — write it back (create the file as `{}` first if it doesn't exist) so the next
repo in this ecosystem gets `namespaces.tsv` for free instead of a repeat of this same
by-hand analysis. A rule is a `kind` (`in-file`, or `build-file` plus a `file` name to search
ancestor directories for) and a `prefix`/`terminator` pair bracketing the declared value on its
own line — verified against one real file in *this* repo before writing, never guessed from
general knowledge of the ecosystem: a wrong guess caches a bad rule for every future project in
that ecosystem, not just this one.

Every ecosystem is real research the first time it is encountered, not a lookup against a
pre-built list — same as an unrecognised grammar below: find the file (or the in-file line) that
declares the namespace, confirm it against the repo's own real source, then write the rule.

**Answer these with aggregate shell over the path lists, not by reading files.** Reading is
internal and free; only what you print costs tokens, so a 15,000-file cluster should collapse to
a few dozen lines before you read anything. Then let `synapse rank` pick which 2–4 files per
node are worth actually reading — see "Choosing what to read" below.

**Do not sample, and do not invent a sampling rule.** `synapse tags --paths` tags a whole list in
one invocation (measured 33× faster on 200 files than one-file-at-a-time), and `synapse vocab`
above uses it to cover an entire repository in under a minute — there's no cost left to bound with
a sampling rule. Every fixed rule is biased anyway: alphabetical is an accident, largest-file
favours generated code and god-classes, most-referenced needs the full scan you were avoiding. If
you find yourself reaching for a sample, run the full pass instead.

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
     most official grammars) — a quick existence check, no reasoning needed if it just resolves.
  2. If that doesn't resolve, fall back to a web search for a community-maintained grammar for
     the language.
  3. **Verify before trusting — two tiers, tried in order, and a repo existing is never
     sufficient on its own for either.** Stop at tier 1 if it verifies; otherwise tier 2
     always runs. The registry records which tier actually won, per step 4 below.

     **Tier 1 — `queries/tags.scm`.** Check **both** the repo root and any sub-grammar subpath,
     in that order — multi-grammar repos split either way and neither is the rule: some put a
     query under each sub-grammar's own subdirectory, others keep a single shared query at the
     root serving every sub-grammar. Plenty of grammars ship only `queries/highlights.scm` and no
     tags query at all — a repo existing there proves nothing by itself, only reading the file
     does.

     **Tier 2 — generate a tags.scm, when tier 1 is absent.** No `queries/tags.scm` means no
     reference data at all: a `.ref` role is only ever assigned by `tagFileTags`, tier 1's own
     function — neither reading a grammar's `locals.scm` captures nor classifying its
     `node-types.json` node types can produce one. So this tier's job is not to accept whatever
     definitions those two files hand it and stop; it is to generate a real, tags.scm-shaped
     query file, drawing on whichever of `locals.scm` and `node-types.json` actually exist, and
     reference-pattern generation (`@reference.call`, or the grammar's own call-expression
     equivalent) is **unconditional in every case below** — the one thing neither file's raw
     content can ever supply on its own, so it is never optional, never gated on which source
     material happens to be present.

     Gather what real source material exists first, then generate from it:

     - **`locals.scm`, if present, is ground truth for kind labels** — real, grammar-author-chosen
       names (`function`, `method`, `type`, `field`, `var`, `parameter`, ...), strictly better than
       any guessed suffix/prefix heuristic wherever it overlaps one. Read it and judge whether its
       `@local.definition.*` captures are well-formed or noise — the same "verify before trusting"
       standard as tier 1, not a weaker one just because there is less to work with: one grammar's
       `locals.scm` might have well-formed, per-kind captures; another's might produce nothing
       usable — not necessarily because of a blanket `@reference` capture on every identifier
       (confirmed inert: a capture without the `local.definition` prefix never reaches output
       regardless of how broad or noisy it is), but because its own `@definition.*` captures are
       themselves missing the `local.` prefix this convention requires (the same structural gap
       case 1 below describes). A capture with **no** kind suffix at all — bare
       `@local.definition`, not `@local.definition.<kind>` — is not a defect either: it is a real,
       common nvim-treesitter shape, and it maps through the kind-synonym rule list below the same
       as any suffixed one, keyed by the empty string. Then **run it**, against a real sample file
       from the repo being oriented in, not just read the `.scm` text — a query whose every
       pattern leans on a predicate the evaluator can't answer (`#match?`, or any unrecognised
       predicate name) fails to *load* at all rather than matching zero, a distinct outcome
       (`Error.PredicateUnsupported`) that is an outright reject exactly like a candidate that
       matched nothing, not a puzzle to work around.
     - **`node-types.json`, if present, fills whatever `locals.scm` doesn't cover and supplies the
       raw node-type list a reference pattern builds from.** It is a build artifact
       `tree-sitter generate` always produces, so it is available for nearly every grammar — which
       makes it about *quality*, not presence: judge it by running a classification against a real
       sample the same way as `locals.scm`, not by reading the JSON. The zero-cost floor (a
       candidate matching literally nothing is auto-rejected, no judgement needed) is the only
       mechanical check; everything else is read and decided by eye. The classifier's suffix/prefix
       matching and the walk's identifier search are both case-insensitive and
       PascalCase-boundary-aware (a PascalCase node-type name and an all-caps leaf type are both
       caught, confirmed live on a real grammar — 0 tags to 46 on a real file). What still doesn't
       match is a genuinely *different word*, not just different casing: a node-type name carrying
       no suffix this convention recognizes at all, or a leaf type that isn't `identifier`/`name`
       under any casing, both stay unmatched, confirmed directly. That's still not a reason to
       hardcode one grammar's exact spelling into the classifier — the generic case/boundary
       handling covers a real, cross-grammar class, a per-grammar word substitution would not.

     The kind-synonym rule list both bullets above lean on is
     `~/.claude/synapse-kind-synonyms.conf` (`SYNAPSE_KIND_SYNONYMS_CONF` overrides the path), the
     same shape and precedence as `synapse-grammars.conf`/`synapse-namespace-rules.conf` — ordered
     rules, first match wins, absent means no mapping rather than a guessed one. Keyed by a
     `locals.scm` capture's kind suffix (or the empty string for an unsuffixed capture) or by a
     `node-types.json` node's raw type name, it can either relabel a kind already guessed or
     **force-classify a type the heuristic missed outright** — confirmed needed against a real
     grammar whose full function-with-implementation node type carried no
     `_declaration`/`_definition`/`decl`/`def` suffix at all, so it never became a candidate on its
     own. Absent/empty is a no-op either way, so this never needs touching unless a specific
     grammar needs it.

     Five source-material cases, tried in this order — every one ends the same way, generating a
     real query with unconditional reference patterns, never accepting definitions alone as good
     enough:

     1. **`locals.scm` exists.** Its per-node-type capture pattern is usually close to
        tags.scm-shaped already. If its captures already carry the `local.definition.<kind>`
        prefix, translate them directly. If they don't (the structural gap above, not a content
        one), translate by field rename — confirmed on a real grammar's own `locals.scm`: a
        capture like `(some_declaration (identifier) @definition.namespace)` becomes
        `(some_declaration name: (identifier) @name) @definition.namespace`, one field-name away
        from the real thing. Either way, add reference patterns for the grammar's
        call-expression-shaped node(s) — `locals.scm` never carries these, so this step is never
        satisfied by translation alone.
     2. **Both `locals.scm` and `node-types.json` exist.** Compose rather than pick one:
        `locals.scm`'s captures win for kind labels wherever they cover a node type: real,
        grammar-author-chosen ground truth beats a guessed suffix/prefix match every time they
        overlap. `node-types.json` fills whatever `locals.scm` doesn't cover (nvim-treesitter's own
        convention is scope-tracking, not exhaustive definition coverage) and supplies the raw
        node-type list to generate reference patterns from — required here the same as every other
        case, since neither source file contributes one on its own.
     3. **No `locals.scm`; `node-types.json` exists with real declaration-shaped structure.**
        Classify its node types the same way case 2's fill-in step does — suffix/prefix matching,
        case-insensitive and PascalCase-boundary-aware, `synapse-kind-synonyms.conf` filling or
        relabeling what the heuristic misses — and generate reference patterns from its
        call-expression-shaped types.

        **Before accepting a weak result here, try inference once — verified, not left as a
        guess.** When classification runs but is visibly weak (real declarations missing entirely,
        or caught with an unhelpfully generic kind), read `node-types.json` for the pattern the
        heuristic missed. Two confirmed shapes to recognize: a *prefix*-marked defining keyword
        instead of a suffix-marked one (invisible to a suffix scan built for a
        `noun_declaration`-style convention), and a body/declaration split the classifier has no
        word for (a node type that names a full function-with-implementation but carries none of
        the recognized suffixes). Propose `synapse-kind-synonyms.conf` rules scoped to this
        grammar's own scope for what's missing or mislabeled, then **re-run `synapse tags` against
        the same real sample and confirm the result actually improved** — not just that the rule
        looks reasonable on paper. Text quality is not a proxy for this: a `locals.scm` can read
        as well-formed and still produce zero tags when actually run against a real sample,
        confirmed directly — exactly the gap this verification step exists to catch. Only write to
        the conf file once the improvement is confirmed live, and only there — never
        `$SYNAPSE_WORK_DIR`. These are facts about a *language*, not this repo, and the whole
        reason these conf files are global and permanent (see step 4 below) is so the next project
        in the same language skips rediscovering it; a repo-scoped copy would throw that away for
        exactly the kind of finding worth keeping. This step is additive only and has a real
        ceiling: it can fix a wrong kind or catch a type that exists as its own grammar node but
        was missed, never conjure structure a grammar doesn't have. Some languages' own defining
        forms aren't distinct node types in their grammar at all, just a generic list/call form,
        confirmed directly — no rule fixes an absence of structure to key one on.
     4. **No `locals.scm`; `node-types.json` exists but is nearly featureless** (a real, confirmed
        shape: some grammars' own `node-types.json` files carry only a few dozen named types
        total, almost none declaration-shaped). Generate from the model's own knowledge of the
        language's defining forms instead of the grammar's files, reference patterns included.
        Route around this tagger's missing `#match?` support explicitly — prefer `#eq?`/`#any-of?`
        (e.g. `(#any-of? @ignore "variant-a" "variant-b")`, not a regex) from the start, rather than
        porting a pattern written for an evaluator with a richer predicate set.
     5. **`node-types.json` itself is absent.** Probe for the `tree-sitter` CLI the same
        opportunistic way step 3 above probes for a C compiler — used if present, silently skipped
        if not, never installed. If both the CLI and the grammar's own `grammar.js` are present,
        `tree-sitter generate` regenerates `node-types.json` (confirmed live: byte-identical to
        what was already committed), landing back in case 3 or 4, whichever the grammar's real
        design implies — regeneration recovers a missing artifact, it never manufactures structure
        the grammar doesn't have. If either is missing, this collapses straight into case 4 with
        even less grounding.

     **Every case resolves the same way:** write the candidate query, run `synapse tags` against
     the same real sample, and judge the result by its actual tag output — real names, kinds, and
     spans on real code — never by reading the raw query syntax, which most users have no reason to
     know and can't meaningfully evaluate. If it looks right, write it to
     `$SYNAPSE_GRAMMARS_QUERY_PATH/{ext}.scm`, the same escape-hatch path a human-authored file
     would use — check first that a human hasn't already placed one there, and never overwrite it.
     If it doesn't look right, write nothing; the outcome is an `"unsupported"` registry entry
     (step 4) rather than a silently accepted weak result. No case needs a different rule, and no
     separate approval gate is needed beyond this — a malformed query fails to load outright
     (`Error.QueryInvalid`), one matching nothing is the existing zero-cost floor, one matching the
     wrong things is caught by eye, the same standard every case's output already has to clear.

     Two harmless quirks to expect while judging output, confirmed live against real grammars with
     no distinct declaration node types of their own — neither is a reason to reject an
     otherwise-working query: `#any-of?` needs every case variant spelled out as a literal (no
     `(?i)` equivalent), so an odd casing can slip through uncaught where a regex-based `#match?`
     wouldn't — acceptable, since the common real-world spelling is what matters, not every deliberately
     mixed-case adversarial input. And this tagger doesn't implement the classic tags.scm
     convention where an early `@ignore` capture suppresses a later pattern from also matching the
     same node — a defining form's own name can end up tagged twice, once as the intended
     definition and once more as a generic call from the catch-all pattern; noise, not a wrong
     answer, and it happens identically with human-authored upstream queries loaded by this same
     tagger, not something specific to a generated one.

     **When generation was attempted and its real output still doesn't verify** — every case above
     tried and none produced usable, judged-by-eye-correct output, or the language's grammar has no
     distinct node types worth keying anything on at all:
     `$SYNAPSE_GRAMMARS_QUERY_PATH/{ext}.scm` is the sanctioned escape hatch — a human-authored
     query file that preempts the whole cascade, not a tier to reach automatically. Name it as an
     option when reporting the outcome (step 5) rather than silently accepting a weak result or a
     bare `unsupported`.
  4. Write the result back to `~/.claude/synapse-grammars.conf` (create it as `{}` first if it
     doesn't exist) — a positive entry (`{"repo": "...", "scope": "..."}`) for whichever tier
     verified, `{"unsupported": true}` only when both came up empty or unusable. Record which
     tier with `"queries"`: omit it (or write `"tags"`) for a real `queries/tags.scm` found in the
     grammar's own repo (tier 1). `"locals"` or `"generated"` mean generation was attempted from
     that source material and its real output didn't verify well enough to write — not that the
     tier won outright without an attempt, which is no longer possible once tier 1 is absent.
     Omitted defaults to `"tags"`, so every entry written before this addition stays valid with no
     migration. This is a permanent, cross-project cache keyed by extension — every future project
     skips rediscovery for this language entirely, tier decision included.

     **The key is the bare extension with no leading dot** — `"rs"`, never `".rs"`, because
     `synapse tags` derives it from the path suffix. Getting this wrong fails *silently*
     and expensively: the lookup misses, the script keeps returning exit 2, and discovery
     re-runs for that language on every file in every project forever, caching nothing. So the
     file should end up shaped like this:

     ```json
     {
       "xx": { "repo": "https://github.com/tree-sitter/tree-sitter-xx", "scope": "source.xx" },
       "yy": { "repo": "https://github.com/some-org/tree-sitter-yy", "scope": "source.yy",
                "path": "grammars/yy", "queries": "locals" },
       "zz": { "unsupported": true }
     }
     ```
  5. **Announce the outcome as a hard requirement, not a recommendation — state whether generation
     was attempted and what its real output looked like, every time tier 1 is absent.** A confident
     read of `locals.scm`/`node-types.json` that predicts generation "wouldn't help" is not a
     substitute for running it, the same reason `synapse-rebuild-diff`'s re-orient gate can't be
     skipped by a correct-looking source reading: only an executed check surfaces whether a real
     reference pattern actually matches on this grammar, not what the source implies it should do.
     Say plainly what happened ("generated a tags.scm from `locals.scm` for `.xx`, cached",
     "generation attempted from `node-types.json`, output didn't verify, falling back to `locals`
     classification", or "no usable tree-sitter grammar for `.xx`, falling back to full reads") —
     then retry `synapse tags {path}` now that the registry has an entry (falls back to a full read
     for this file per the Exit 1 case above if discovery came up empty).

## Fixing a `locals.scm` coverage gap: the zero-candidate `.ref` signature

A third discovery-procedure step, distinct in trigger shape from the tags.scm-generation one
above: that one fires on a grammar missing tier 1 entirely, a per-grammar-discovery event. This
one fires on a specific finding encountered while working with the link graph, not on discovering
a new extension — **a `.ref` whose name has zero `def` rows anywhere in `_refs.tsv`** (grep the
whole file, not just the node under review — the join is repo-wide), **in a grammar that already
has some `locals.scm`** (partial coverage, not missing entirely — a grammar with no `locals.scm`
at all just keeps today's unfiltered behavior for local refs, nothing to fix here).

That signature means the name is very likely a local binding this grammar's shipped `locals.scm`
doesn't capture — a function parameter, `let`-binding, or module/functor argument whose binder is
a node type the query never queries for — not a genuine cross-file reference with a missing
definition. This is a real, confirmed shape: a grammar's shipped `locals.scm` can capture one
binder construct (say, a plain value or function-parameter binding) while missing another real
binder construct in the same language entirely, because that construct parses as a distinct node
type the query was simply never written to cover — so a reference to that binder's name leaks
through unfiltered.

Same hard-requirement enforcement as the tags.scm-generation step, and the same verify-before-write
discipline — never assume a patch worked from reading it:

1. Read the grammar's own `locals.scm` and the real AST shape of the binder (`tree-sitter parse`
   against the actual file, or equivalent) to find which node type covers this name and is
   currently uncaptured.
2. Write an override at `$SYNAPSE_GRAMMARS_QUERY_PATH/{ext}.locals.scm`, adding a capture for that
   node type in the grammar's own `@local.definition[.kind]` convention — check first that a human
   hasn't already placed one there, and never overwrite it.
3. Re-run `synapse tags` against the real file that surfaced the finding, override active, and
   confirm the name's `.ref` row is actually gone — not just that the query text reads right.
4. **Announce the outcome as a hard requirement, not a recommendation**, the same as the
   tags.scm-generation step: an override was written and verified against the real file, or a
   genuine attempt didn't resolve the finding (state what was tried) — never silently drop a
   confirmed zero-candidate signature.

## Dependency-edge rules: which languages qualify, and writing one back

A per-file "this file depends on library L" edge narrows an ambiguous reference (a name defined in
more than one node) to the candidate the referencing file actually declares a dependency on —
`core/links.zig`'s own real signal for that case, read from `synapse-dependency-rules.conf`
(`SYNAPSE_DEPENDENCY_RULES_CONF` overrides the path), a second registry alongside
`synapse-namespace-rules.conf` and reusing the exact same `core/namespace.Rule`/`Registry` shape
unchanged — a rule per extension, `kind` `in-file` or `build-file`, ordered `prefix`/`terminator`,
first match wins, no per-language branching in code. A separate file, not a second key on the same
one: an extension can need both a namespace rule (what a file *is*) and a dependency rule (what a
file *depends on*) at once, and a rule-per-extension registry has no room for two different facts
on the same key — so the dependency rule is extracted by the same mechanism into its own
`_deps.tsv` artifact instead, one row per file, not a new column on `_refs.tsv`'s
one-row-per-reference grain.

**A language qualifies for a dependency-edge rule at all only if its import/dependency mechanism is
a reserved, syntactically-distinct construct — confirmed against the language's own spec, never
assumed from its paradigm or family.** A reserved keyword or a call with a fixed, unambiguous
textual shape, syntactically separable from ordinary code, qualifies. Family predicts nothing: two
languages sharing a paradigm can resolve oppositely — one's own file-loading mechanism might be an
ordinary function/word call with no fixed reserved construct across implementations
(disqualifying), while a close relative in the very same paradigm might have a real, fixed parsing
construct for declaring what it imports (qualifying) — checking the language's own actual spec is
the only test that tells the two apart. A language that fails this test gets no rule at all,
documented or committed — not a lighter-touch version of the same treatment, because the syntactic
distinction the rule shape depends on doesn't exist in the language, and no amount of real-file
verification fixes that.

Only a rule or rules already dogfooded against a real ambiguous-reference finding in this project
ship as real, committed data. Every other qualifying language is real research the first time it
is encountered, never a lookup against a pre-built list: find the reserved import/dependency
construct in the language's own spec, verify the exact `prefix`/`terminator` shape against one
real file in the repo being oriented in, then write the rule back — same precedent
`synapse-namespace-rules.conf` itself already sets. Never write a rule from general knowledge of
an ecosystem alone, and never treat a rule confirmed for one language as a template to copy for
another just because they look similar from the outside.

**Known gap in the rule shape itself:** this is a single-line, single-`prefix`/`terminator` rule.
A multi-line or grouped import/dependency form (several names bracketed across more than one line,
or wrapped in an outer grouping construct) isn't expressible this way and produces no edge, not a
wrong one; that is the correct outcome for a form this rule shape can't cover, not a defect needing
a workaround here.

**A file can have more than one valid identity, and the two sides of a match must agree on which
one.** A namespace rule's own primary `prefix`/`terminator` answers "what does this file call
itself" — the question `synapse vocab`'s divergence table asks. But the value another file's own
dependency declaration actually names it by can be a *different* string on the same nearest-ancestor
file — a build system's internal name versus the name it publishes for dependents to reference, for
instance. If a real ambiguous-reference finding traces to exactly this mismatch (the candidate's
declared library never matches, confirmed by checking the real file both values come from, not
assumed), the namespace rule's `"aliases"` array (each entry its own `prefix`/`terminator` against
the same file, unbounded) is the fix — verify the new value against the same real file before
writing it back, same discipline as everything else here.

**Self-population needs the same hard-requirement trigger the tags.scm-generation step already
uses — announced every time an ambiguous reference is met in a language with no existing rule yet,
not a silently-skippable mention.** State plainly which of four outcomes happened:

1. A rule already existed for this extension — used as-is.
2. No rule existed, one was written and verified against a real file in this repo (paste the
   confirmed prefix/terminator match) — then committed to `synapse-dependency-rules.conf`.
3. No rule existed, writing one was attempted and skipped because verification failed against a
   real file — state what was tried and why it didn't hold.
4. The language doesn't qualify at all per the spec-check test above — say so explicitly, don't
   silently produce nothing and move on.

A confident read of a language's import syntax that predicts a rule "would obviously work" is not a
substitute for verifying it against one real file in the repo being oriented in, the same reason the
tags.scm-generation step's own announcement can't be skipped by a correct-looking source reading.
