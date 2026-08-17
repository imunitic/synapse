#!/usr/bin/env bats
# Tests claude/lib/synapse/synapse-vocab.sh -- the pass that reduces a whole repo to
# `group <TAB> word <TAB> count` so the clustering step of /synapse-init can
# decide what a subsystem is about from symbol names instead of source lines.
#
# tree-sitter is the fake in tests/fixtures/fake-bin: it emits FAKE_NAME for
# every .ml/.java/.py file plus one tag per `symbol:<Name>` line in the file, so
# a fixture's vocabulary is authored as ordinary file content. Everything about
# the reduction -- CamelCase and snake_case splitting, stopwording, the group
# key, the counts -- is therefore asserted against symbols the test chose.

load 'test_helper'

setup() {
  common_setup
  # Every extension the fake knows about, so the script's own registry gate is
  # not what a vocabulary assertion is really testing.
  printf '%s' '{"java": {"repo": "https://example.invalid/tree-sitter-java", "scope": "source.java"},
                "py": {"repo": "https://example.invalid/tree-sitter-python", "scope": "source.python"},
                "ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}' \
    > "$HOME/.claude/synapse-grammars.conf"
  OUT="$TEST_HOME/out"
  FAKE_TS_LOG="$TEST_HOME/ts.log"
  : > "$FAKE_TS_LOG"
}

teardown() {
  common_teardown
}

# A file with the given symbols, one `symbol:` line each. The body is otherwise
# irrelevant: the fake reads only those lines.
src() { # src <repo-relative path> <symbol>...
  local path="$REPO/$1"; shift
  mkdir -p "$(dirname "$path")"
  : > "$path"
  local s
  for s in "$@"; do printf 'symbol:%s\n' "$s" >> "$path"; done
}

# Two modules with deliberately disjoint domain vocabulary, plus one term
# ("Shared") every module uses -- the corpus-common case the quality gate later
# has to be able to see.
make_two_module_repo() {
  git init -q "$REPO"
  src billing/src/InvoiceCalculator.java InvoiceCalculator SharedRegistry
  src billing/src/DunningSchedule.java   DunningSchedule    SharedRegistry
  src shipping/src/ParcelRouter.java     ParcelRouter       SharedRegistry
  src shipping/src/CarrierManifest.java  CarrierManifest    SharedRegistry
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init
}

run_vocab() {
  PATH="$FAKE_BIN:$PATH" FAKE_TS_LOG="$FAKE_TS_LOG" "$SYNAPSE_BIN" vocab --repo "$REPO" --out "$OUT" "$@"
}

# The count for one group/word pair, or empty when the pair is absent.
count_of() { # count_of <group> <word>
  awk -F'\t' -v g="$1" -v w="$2" '$1 == g && $2 == w { print $3 }' "$OUT/groupwords.tsv"
}

@test "two modules with different symbols yield disjoint top terms" {
  make_two_module_repo

  run run_vocab
  [ "$status" -eq 0 ]

  # Each module's own vocabulary, and only its own.
  [ -n "$(count_of billing/src invoice)" ]
  [ -n "$(count_of billing/src dunning)" ]
  [ -z "$(count_of billing/src parcel)" ]
  [ -z "$(count_of billing/src carrier)" ]

  [ -n "$(count_of shipping/src parcel)" ]
  [ -n "$(count_of shipping/src carrier)" ]
  [ -z "$(count_of shipping/src invoice)" ]
}

@test "a term used by every module is present in every group, so its df is visible" {
  # Not scored here: synapse-vocab.sh counts, and the quality gate is what turns
  # a high document frequency into "this cluster owns no vocabulary". The gate
  # can only do that if the term is actually recorded per group rather than
  # filtered out as noise on the way through.
  make_two_module_repo

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(count_of billing/src shared)" = "2" ]
  [ "$(count_of shipping/src shared)" = "2" ]
  [ "$(awk -F'\t' '$2 == "registry"' "$OUT/groupwords.tsv" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "CamelCase and snake_case split into words; a run of capitals stays whole" {
  git init -q "$REPO"
  src core/src/A.java getUserName premium_rate_table HTTPServer
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ -n "$(count_of core/src user)" ]
  [ -n "$(count_of core/src name)" ]
  [ -n "$(count_of core/src premium)" ]
  [ -n "$(count_of core/src rate)" ]
  [ -n "$(count_of core/src table)" ]
  # `get` is under four characters, so it never survives regardless.
  [ -z "$(count_of core/src get)" ]
  # An acronym run absorbs what follows it -- documented behaviour, not a bug to
  # fix silently later: the alternative needs lookahead, which awk has no form of.
  [ -n "$(count_of core/src httpserver)" ]
}

@test "stopwords come from the tokenizer's own list, and short words are dropped" {
  cp "$REPO_ROOT/plugins/synapse/synapse-prompt-stopwords.conf.template" \
    "$HOME/.claude/synapse-prompt-stopwords.conf"
  git init -q "$REPO"
  # `Another` and `Because` are ordinary English function words in that list and
  # would otherwise be perfectly good-looking domain terms.
  src core/src/A.java AnotherThing BecauseInvoice Fee
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ -z "$(count_of core/src another)" ]
  [ -z "$(count_of core/src because)" ]
  [ -z "$(count_of core/src fee)" ]      # three characters
  [ -n "$(count_of core/src thing)" ]
  [ -n "$(count_of core/src invoice)" ]
}

@test "groupexts.tsv names what an area is made of, grammar or not" {
  # The orientation question a module name cannot answer. The files that carry
  # the answer are usually the ones no grammar can read, so this counts every
  # kept path rather than the code subset.
  git init -q "$REPO"
  src core/src/A.java Alpha
  printf 'x\n' > "$REPO/core/src/b.xml"
  printf 'y\n' > "$REPO/core/src/c.xml"
  # No dot at all. Reported by filename, because a group full of `dune` files is
  # a finding and a group full of "none" is not.
  printf 'z\n' > "$REPO/core/src/dune"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]

  [ "$(awk -F'\t' '$1=="core/src" && $2=="xml" { print $3 }' "$OUT/groupexts.tsv")" = "2" ]
  [ "$(awk -F'\t' '$1=="core/src" && $2=="java" { print $3 }' "$OUT/groupexts.tsv")" = "1" ]
  [ "$(awk -F'\t' '$1=="core/src" && $2=="dune" { print $3 }' "$OUT/groupexts.tsv")" = "1" ]

  # Most common first within a group, matching groupwords.tsv, so the two tables
  # can be read side by side.
  [ "$(awk -F'\t' '$1=="core/src" { print $2; exit }' "$OUT/groupexts.tsv")" = "xml" ]
}

@test "groupexts.tsv and counts.tsv agree, group for group" {
  # The invariant that makes the two tables readable together. They are keyed by
  # one shared map rather than two rules, and this is what that buys: a group
  # can never appear to hold more kinds of file than it holds files.
  git init -q "$REPO"
  src core/src/A.java Alpha
  src other/src/B.java Beta
  printf 'x\n' > "$REPO/core/src/b.xml"
  printf 'y\n' > "$REPO/top.md"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]

  awk -F'\t' '{s[$1]+=$3} END{for (g in s) print g"\t"s[g]}' "$OUT/groupexts.tsv" | sort > "$TEST_HOME/sums"
  sort "$OUT/counts.tsv" > "$TEST_HOME/counts"
  diff "$TEST_HOME/counts" "$TEST_HOME/sums"
}

@test "parseable.tsv's total agrees with counts.tsv, group for group" {
  # Same invariant as groupexts.tsv, same reason: one shared map for "which
  # group is this path in" rather than two rules that can silently disagree.
  git init -q "$REPO"
  src core/src/A.java Alpha
  printf 'x\n' > "$REPO/core/src/b.xml"
  printf 'y\n' > "$REPO/core/src/c.xml"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]

  awk -F'\t' '{print $1"\t"$3}' "$OUT/parseable.tsv" | sort > "$TEST_HOME/parseable-totals"
  sort "$OUT/counts.tsv" > "$TEST_HOME/counts"
  diff "$TEST_HOME/counts" "$TEST_HOME/parseable-totals"
}

@test "a group with no parseable files reports zero, not an absent row" {
  # This is the exact row synapse gate --parseable looks for: the gate cannot
  # tell "owns no vocabulary" from "nothing here has a grammar" without it.
  git init -q "$REPO"
  mkdir -p "$REPO/config"
  printf 'a=1\n' > "$REPO/config/settings.properties"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "config" { print $2"\t"$3 }' "$OUT/parseable.tsv")" = "0	1" ]
}

@test "a mixed group reports the real share, not all-or-nothing" {
  git init -q "$REPO"
  src core/src/A.java Alpha
  src core/src/B.java Beta
  printf 'x\n' > "$REPO/core/src/c.xml"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "core/src" { print $2"\t"$3 }' "$OUT/parseable.tsv")" = "2	3" ]
}

@test "distinctive.tsv reports every group, including one scoring entirely zero" {
  # synapse-001, step 8. A word shared by every group is common, not
  # distinctive, and the group still gets a row -- 0 is a computed answer,
  # not the absence of one.
  git init -q "$REPO"
  src core/src/A.java Shared
  src shipping/src/B.java Shared
  src pricing/src/C.java Shared
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$OUT/distinctive.tsv" | tr -d ' ')" -eq 3 ]
  [ "$(awk -F'\t' '$1 == "core/src" { print $2 }' "$OUT/distinctive.tsv")" = "0" ]
}

@test "a word unique to one group is distinctive; a word shared by every group is not" {
  git init -q "$REPO"
  src core/src/A.java Invoice Shared
  src shipping/src/B.java Parcel Shared
  src pricing/src/C.java Tariff Shared
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  # N = 3, D = max(2, 3/20) = 2. df(invoice) = 1: score 2/3 > 0.5, counted.
  # df(shared) = 3: score 2/5 < 0.5, not counted.
  [ "$(awk -F'\t' '$1 == "core/src" { print $2 }' "$OUT/distinctive.tsv")" = "1" ]
}

@test "--distinctive-top limits how many terms are considered per group" {
  git init -q "$REPO"
  src core/src/A.java One Two Three Four
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab --distinctive-top 2
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "core/src" { print $3 }' "$OUT/distinctive.tsv")" = "2" ]

  run run_vocab --distinctive-top 8
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "core/src" { print $3 }' "$OUT/distinctive.tsv")" = "4" ]
}

@test "a bad --distinctive-top or --distinctive-k is a usage error, exit 2" {
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --distinctive-top zero
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --distinctive-top 0
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --distinctive-k zero
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --distinctive-k 0
  [ "$status" -eq 2 ]
}

@test "counts.tsv counts every tracked file, not only the ones with a grammar" {
  # Coverage and vocabulary are separate axes: a group's size is what the model
  # weighs when clustering, and a module that is mostly XML is still that big.
  git init -q "$REPO"
  src core/src/A.java Alpha
  printf 'x\n' > "$REPO/core/src/b.xml"
  printf 'y\n' > "$REPO/core/src/c.xml"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "core/src" { print $2 }' "$OUT/counts.tsv")" = "3" ]
}

@test "a repo-root file groups as (repo root) rather than vanishing" {
  git init -q "$REPO"
  src core/src/A.java Alpha
  printf 'readme\n' > "$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "(repo root)" { print $2 }' "$OUT/counts.tsv")" = "1" ]
}

@test "--depth changes the group key, and counts.tsv keys agree with groupwords.tsv" {
  # The two files keyed differently is the failure that makes a group look like
  # it has vocabulary but no files, or the reverse -- so the grouping rule is
  # shared textually and this pins that it stays shared.
  git init -q "$REPO"
  src alpha/one/deep/A.java Invoice
  src alpha/two/deep/B.java Parcel
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab --depth 1
  [ "$status" -eq 0 ]
  [ -n "$(count_of alpha invoice)" ]
  [ -n "$(count_of alpha parcel)" ]

  run run_vocab --depth 2
  [ "$status" -eq 0 ]
  [ -n "$(count_of alpha/one invoice)" ]
  [ -z "$(count_of alpha/one parcel)" ]

  # Every group named in groupwords.tsv exists in counts.tsv.
  run bash -c "cut -f1 '$OUT/groupwords.tsv' | sort -u > '$TEST_HOME/gw-keys'
               cut -f1 '$OUT/counts.tsv'     | sort -u > '$TEST_HOME/c-keys'
               comm -23 '$TEST_HOME/gw-keys' '$TEST_HOME/c-keys'"
  [ -z "$output" ]
}

@test "an extension with no registry entry is excluded before tagging, not warned about" {
  # CODE_RE is built once, up front, from `synapse tags --list-extensions`
  # -- the registry's own list of usable grammars -- rather than a hardcoded
  # guess at "languages worth having". An extension the registry has never
  # heard of therefore never reaches code.txt, so it never reaches
  # the binary at all: no per-chunk warning to dedup, at any --chunk
  # size, because there is nothing to warn about in the first place.
  git init -q "$REPO"
  src core/src/A.java Alpha
  src core/src/B.java Beta
  printf 'x\n' > "$REPO/core/src/c.zzz"
  printf 'y\n' > "$REPO/core/src/d.zzz"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  # .zzz is not a code extension; .rb looks like one but has no registry
  # entry in this fixture -- exactly the case that used to slip through a
  # hardcoded CODE_RE and produce a warning. It should now be silent.
  mv "$REPO/core/src/c.zzz" "$REPO/core/src/c.rb"
  mv "$REPO/core/src/d.zzz" "$REPO/core/src/d.rb"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m "rb"

  run run_vocab --chunk 1
  [ "$status" -eq 0 ]
  [ "$(grep -c 'no grammar registered for .rb' <<< "$output")" -eq 0 ]
  [ "$(grep -c 'grammar for .rb is not usable' <<< "$output")" -eq 0 ]
  # And the files that did have a registered grammar still produced vocabulary.
  [ -n "$(count_of core/src alpha)" ]
}

@test "nothing with a usable grammar: empty groupwords.tsv and exit 0, not an error" {
  # The signal to fall back to synapse-orientation. An exit 1 here would read as
  # "the script is broken" in a repo that is simply written in a language with
  # no grammar installed, which is a supported state.
  git init -q "$REPO"
  mkdir -p "$REPO/core/src"
  printf 'x\n' > "$REPO/core/src/a.txt"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ -f "$OUT/groupwords.tsv" ]
  [ ! -s "$OUT/groupwords.tsv" ]
  [[ "$output" == *"synapse-orientation"* ]]
}

@test "synapse-ignore-files.conf excludes a path from the evidence as well as the graph" {
  # Vendored and generated trees would otherwise dominate the vocabulary of
  # whatever group they sit in, and a path excluded from the graph has no node
  # for that vocabulary to describe.
  git init -q "$REPO"
  src core/src/A.java Alpha
  src vendor/lib/B.java Vendored
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ -n "$(count_of vendor/lib vendored)" ]

  printf '(^|/)vendor/\n' > "$HOME/.claude/synapse-ignore-files.conf"
  run run_vocab
  [ "$status" -eq 0 ]
  [ -z "$(count_of vendor/lib vendored)" ]
  [ -z "$(awk -F'\t' '$1 == "vendor/lib"' "$OUT/counts.tsv")" ]
  [ -n "$(count_of core/src alpha)" ]
}

# --- --lists: keyed by cluster rather than by directory --------------------
#
# The quality gate scores clusters, and a cluster is not generally a union of
# directories, so its vocabulary cannot be derived from the directory-keyed
# table after the fact.

# A synapse-build-lists.sh-shaped lists/ dir: NN.txt paths, NN.title name.
write_list() { # write_list <NN> <title> <path>...
  local nn="$1" title="$2"; shift 2
  mkdir -p "$TEST_HOME/lists"
  printf '%s\n' "$title" > "$TEST_HOME/lists/$nn.title"
  printf '%s\n' "$@" > "$TEST_HOME/lists/$nn.txt"
}

@test "--lists keys vocabulary by node title, cutting across directories" {
  git init -q "$REPO"
  src alpha/src/InvoiceCalculator.java InvoiceCalculator
  src beta/src/DunningSchedule.java    DunningSchedule
  src beta/src/ParcelRouter.java       ParcelRouter
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init
  # Deliberately not a union of directories: one node takes a file from each.
  write_list 01 "Billing" alpha/src/InvoiceCalculator.java beta/src/DunningSchedule.java
  write_list 02 "Shipping" beta/src/ParcelRouter.java

  run run_vocab --lists "$TEST_HOME/lists"
  [ "$status" -eq 0 ]
  [ -n "$(count_of Billing invoice)" ]
  [ -n "$(count_of Billing dunning)" ]
  [ -z "$(count_of Billing parcel)" ]
  [ -n "$(count_of Shipping parcel)" ]
  [ "$(awk -F'\t' '$1 == "Billing" { print $2 }' "$OUT/counts.tsv")" = "2" ]
}

@test "the --lists run against an already-warm cache tags nothing at all" {
  # synapse-001, step 3: /synapse-init runs plain vocab first (directory-keyed,
  # clustering evidence) and vocab --lists second (cluster-keyed, gate
  # evidence) against the same files. Once step 2 makes the first call warm
  # the cache for the whole code subset, the second call's code subset -- a
  # list-narrowed slice of the same files -- should already be entirely
  # covered by it, so it neither re-tags nor even needs the grammar
  # registry entry it would otherwise have to have.
  git init -q "$REPO"
  src alpha/src/InvoiceCalculator.java InvoiceCalculator
  src beta/src/DunningSchedule.java    DunningSchedule
  src beta/src/ParcelRouter.java       ParcelRouter
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(grep -c '^path ' "$FAKE_TS_LOG")" -eq 3 ]

  write_list 01 "Billing" alpha/src/InvoiceCalculator.java beta/src/DunningSchedule.java
  write_list 02 "Shipping" beta/src/ParcelRouter.java

  : > "$FAKE_TS_LOG"
  run run_vocab --lists "$TEST_HOME/lists"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]

  # And the cluster-keyed vocabulary is still correct, read entirely from
  # what the first call cached.
  [ -n "$(count_of Billing invoice)" ]
  [ -n "$(count_of Billing dunning)" ]
  [ -z "$(count_of Billing parcel)" ]
  [ -n "$(count_of Shipping parcel)" ]
}

@test "--lists: a file claimed by two nodes contributes to both" {
  # Node manifests may legitimately overlap -- synapse-build-lists.sh only
  # `sort -u`s the union for its coverage count, it does not make lists
  # disjoint. Keeping one membership would make the gate's verdict depend on
  # the order the lists happened to be read in.
  git init -q "$REPO"
  src core/src/Shared.java InvoiceCalculator
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init
  write_list 01 "Billing"  core/src/Shared.java
  write_list 02 "Reporting" core/src/Shared.java

  run run_vocab --lists "$TEST_HOME/lists"
  [ "$status" -eq 0 ]
  [ -n "$(count_of Billing invoice)" ]
  [ -n "$(count_of Reporting invoice)" ]
  [ "$(awk -F'\t' '$1 == "Billing" { print $2 }' "$OUT/counts.tsv")" = "1" ]
  [ "$(awk -F'\t' '$1 == "Reporting" { print $2 }' "$OUT/counts.tsv")" = "1" ]
}

@test "--lists: a file no node claims contributes nothing" {
  git init -q "$REPO"
  src core/src/Claimed.java InvoiceCalculator
  src core/src/Orphan.java  OrphanRegistry
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init
  write_list 01 "Billing" core/src/Claimed.java

  run run_vocab --lists "$TEST_HOME/lists"
  [ "$status" -eq 0 ]
  [ -n "$(count_of Billing invoice)" ]
  [ -z "$(awk -F'\t' '$2 == "orphan"' "$OUT/groupwords.tsv")" ]
}

@test "--lists: a missing or empty lists dir is an error, not a silent empty result" {
  make_two_module_repo
  run run_vocab --lists "$TEST_HOME/nope"
  [ "$status" -eq 1 ]

  mkdir -p "$TEST_HOME/lists"
  run run_vocab --lists "$TEST_HOME/lists"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NN.txt/NN.title"* ]]
}

@test "test classes contribute vocabulary, because a summary is made of names" {
  # The other half of the summary/crux pool split (synapse-rank.sh --pool).
  # Tests are excluded from the CRUX pool -- a crux is concentrated logic -- but
  # they must keep feeding the summary: on a real node `Gegenpartei` and `Frist`
  # came only from test class names, at zero read cost. Excluding tests here as
  # well as there would silently cost those concepts.
  git init -q "$REPO"
  # The class declaration is spelled out because the fake only emits `symbol:`
  # lines; real tree-sitter tags the class itself, which is exactly how a test
  # class name reaches the vocabulary in the first place.
  src src/main/java/Service.java Alpha
  src src/test/java/GegenparteiTest.java GegenparteiTest Frist
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab --depth 1
  [ "$status" -eq 0 ]
  [ -n "$(count_of src frist)" ]
  [ -n "$(count_of src gegenpartei)" ]
}

@test "raw tags are never buffered whole, only reduced and cached per file" {
  # 98k code files produce ~942 MB of tags against 6.9 MB of vocabulary, so this
  # process must never hold the whole repo's tags in memory at once. This used to
  # be asserted structurally, against the shell worker's pipe; there is no worker
  # now, so the property is asserted where it is observable: the output
  # directory holds only the four reductions plus the tags cache -- never a
  # flat debug dump of raw tag text.
  #
  # The allowlist is meant to be widened by hand. Adding an output should fail
  # this test once and be added here on purpose, which is what stops a debug
  # dump of raw tags from arriving unnoticed. `_tags_cache.bin` and
  # `namespaces.tsv` are on it deliberately: see "vocab fills the tags cache
  # from the same tagging pass" and the namespace-divergence tests below for
  # why those belong here and a flat dump would not.
  git init -q "$REPO"
  src core/src/A.java getUserName premium_rate_table
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]

  local unexpected
  unexpected="$(ls -A "$OUT" | grep -vE '^(counts|groupwords|groupexts|namespaces|parseable|distinctive)\.tsv$|^_tags_cache\.bin$' || true)"
  [ -z "$unexpected" ]
}

# --- tags cache: filled as a byproduct of the same pass ---------------------
#
# synapse-001 (precompute before inference): the Code Cache must be warm by the
# time orientation ends, not filled later node by node as write-node runs.

dump_cache() { "$SYNAPSE_BIN" tags-cache --dump "$OUT/_tags_cache.bin"; }
cache_entry_count() { dump_cache | grep -c '^H	' || true; }
cache_is_parsed() { dump_cache | grep -qx "P	$1"; }
cache_tags_of() { dump_cache | awk -F'\t' -v p="$1" '$1 == "T" && $2 == p { print substr($0, length($1) + length(p) + 3) }'; }

@test "vocab fills the tags cache from the same tagging pass, not a second one" {
  git init -q "$REPO"
  src core/src/A.java Alpha
  src core/src/B.java Beta
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ -f "$OUT/_tags_cache.bin" ]

  [ "$(cache_entry_count)" -eq 2 ]
  cache_is_parsed core/src/A.java
  cache_is_parsed core/src/B.java
  [[ "$(cache_tags_of core/src/A.java)" == *"FAKE_NAME"* ]]

  # write-node's own backfill (synapse tags-cache --repo-root ... --paths ...)
  # finds both already current and does nothing -- the whole point of filling
  # the cache here.
  printf 'core/src/A.java\t%s\n' "$(git -C "$REPO" hash-object core/src/A.java)" > "$TEST_HOME/paths.tsv"
  printf 'core/src/B.java\t%s\n' "$(git -C "$REPO" hash-object core/src/B.java)" >> "$TEST_HOME/paths.tsv"
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" tags-cache \
    --repo-root "$REPO" --cache "$OUT/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ "$(cache_entry_count)" -eq 2 ]
}

@test "a file outside the code subset is not added to the tags cache" {
  # vocab only ever tags the code subset (a usable grammar); a file counted in
  # groupexts.tsv purely as artifact-mix evidence was never parsed and has
  # nothing to cache.
  git init -q "$REPO"
  src core/src/A.java Alpha
  printf 'x\n' > "$REPO/core/src/b.xml"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(cache_entry_count)" -eq 1 ]
  [ -z "$(dump_cache | grep 'b.xml' || true)" ]
}

@test "a second run against an unchanged repo tags nothing" {
  # synapse-001, step 2: the directory-keyed reduction comes from the cache,
  # not from re-tagging. A repeat run with nothing changed should reach the
  # extractor for zero files.
  git init -q "$REPO"
  src core/src/A.java Alpha
  src core/src/B.java Beta
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(grep -c '^path ' "$FAKE_TS_LOG")" -eq 2 ]

  : > "$FAKE_TS_LOG"
  run run_vocab
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]

  # And the vocabulary is unchanged, read entirely from the cache.
  [ -n "$(count_of core/src alpha)" ]
  [ -n "$(count_of core/src beta)" ]
}

@test "only a changed file is re-tagged on a second run, the rest come from the cache" {
  git init -q "$REPO"
  src core/src/A.java Alpha
  src core/src/B.java Beta
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]

  # A symbol sharing no CamelCase sub-word with "Alpha", so a surviving
  # "alpha" count could only mean a stale read, not a coincidence of the
  # split rule.
  src core/src/A.java GammaRenamed
  : > "$FAKE_TS_LOG"
  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(grep -c '^path ' "$FAKE_TS_LOG")" -eq 1 ]
  grep -qx 'path core/src/A.java' "$FAKE_TS_LOG"

  [ -n "$(count_of core/src gamma)" ]
  [ -z "$(count_of core/src alpha)" ]
  [ -n "$(count_of core/src beta)" ]
}

# --- namespaces.tsv: does the code's own name match the directory holding it ---
#
# synapse-001, step 6. Rules live in $HOME/.claude/synapse-namespace-rules.conf,
# same discovery contract as the grammar registry: absent means nothing
# configured yet, not an error.

write_content() { # write_content <repo-relative path> <line>...
  local path="$REPO/$1"; shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

namespace_row() { # namespace_row <group>
  awk -F'\t' -v g="$1" '$1 == g' "$OUT/namespaces.tsv"
}

@test "namespaces.tsv is empty when no rules are configured, not an error" {
  git init -q "$REPO"
  write_content core/src/A.java 'package com.example.billing;' 'class A {}'
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ -f "$OUT/namespaces.tsv" ]
  [ ! -s "$OUT/namespaces.tsv" ]
}

@test "an in-file rule captures a package declaration, and full agreement shows agree == total" {
  printf '%s' '{"java": {"kind": "in-file", "prefix": "package ", "terminator": ";"}}' \
    > "$HOME/.claude/synapse-namespace-rules.conf"
  git init -q "$REPO"
  write_content core/src/A.java 'package com.example.billing;' 'class A {}'
  write_content core/src/B.java 'package com.example.billing;' 'class B {}'
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(namespace_row core/src)" = "core/src	com.example.billing	2	2" ]
}

@test "a divergence shows the majority namespace, not an average of the two" {
  printf '%s' '{"java": {"kind": "in-file", "prefix": "package ", "terminator": ";"}}' \
    > "$HOME/.claude/synapse-namespace-rules.conf"
  git init -q "$REPO"
  write_content core/src/A.java 'package com.example.billing;'
  write_content core/src/B.java 'package com.example.billing;'
  write_content core/src/C.java 'package com.example.legacy;'
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(namespace_row core/src)" = "core/src	com.example.billing	2	3" ]
}

@test "a build-file rule resolves via the nearest ancestor, not just a same-directory sibling" {
  printf '%s' '{"ml": {"kind": "build-file", "file": "dune", "prefix": "(name ", "terminator": ")"}}' \
    > "$HOME/.claude/synapse-namespace-rules.conf"
  git init -q "$REPO"
  write_content eon_edn/src/dune '(name eon_edn)'
  write_content eon_edn/src/foo.ml 'let x = 1'
  write_content eon_edn/src/nested/bar.ml 'let y = 2'
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab --depth 1
  [ "$status" -eq 0 ]
  # Both foo.ml (same directory as dune) and bar.ml (one level deeper, no dune
  # of its own) resolve to the same declared namespace via the ancestor walk.
  [ "$(namespace_row eon_edn)" = "eon_edn	eon_edn	2	2" ]
}

@test "an extension with no rule contributes nothing, even alongside one that has a rule" {
  printf '%s' '{"java": {"kind": "in-file", "prefix": "package ", "terminator": ";"}}' \
    > "$HOME/.claude/synapse-namespace-rules.conf"
  git init -q "$REPO"
  write_content core/src/A.java 'package com.example.billing;'
  write_content core/src/A.py 'class A: pass'
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run run_vocab
  [ "$status" -eq 0 ]
  [ "$(namespace_row core/src)" = "core/src	com.example.billing	1	1" ]
}

@test "SYNAPSE_NAMESPACE_RULES_CONF overrides the default path" {
  printf '%s' '{"java": {"kind": "in-file", "prefix": "package ", "terminator": ";"}}' \
    > "$TEST_HOME/custom-rules.conf"
  git init -q "$REPO"
  write_content core/src/A.java 'package com.example.billing;'
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init

  run env PATH="$FAKE_BIN:$PATH" SYNAPSE_NAMESPACE_RULES_CONF="$TEST_HOME/custom-rules.conf" \
    "$SYNAPSE_BIN" vocab --repo "$REPO" --out "$OUT"
  [ "$status" -eq 0 ]
  [ "$(namespace_row core/src)" = "core/src	com.example.billing	1	1" ]
}

@test "defaults to the work dir when --out is omitted" {
  make_two_module_repo

  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --repo "$REPO"
  [ "$status" -eq 0 ]
  [ -s "$HOME/.claude/synapse-work/$(repo_name)/groupwords.tsv" ]
  [ -s "$HOME/.claude/synapse-work/$(repo_name)/counts.tsv" ]
}

@test "outside a git repo: exits 1 with a message, writes nothing" {
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --repo "$TEST_HOME" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a git repo"* ]]
  [ ! -f "$OUT/groupwords.tsv" ]
}

@test "a bad flag or a non-numeric depth is a usage error, exit 2" {
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --nope
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --depth two
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --depth 0
  [ "$status" -eq 2 ]
}
