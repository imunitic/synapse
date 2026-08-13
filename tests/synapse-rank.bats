#!/usr/bin/env bats
# Tests claude/lib/synapse/synapse-rank.sh -- the tiered ranking that decides what is
# worth READING when authoring a node's prose. Coverage is not at stake here:
# `sources` stays exhaustive, and nothing this script does can remove a file
# from the graph. Only reading order changes.
#
# tree-sitter is the fake in tests/fixtures/fake-bin, which emits one tag per
# `symbol:` line (a definition) and per `ref:` line (a reference) in the file.
# File SIZE is real, so a fixture controls density by how much filler it
# carries -- which is the whole point of the code tier.

load 'test_helper'

setup() {
  common_setup
  # java/py/ts: CODE_RE is now built from this registry (via
  # `synapse tags --list-extensions`) rather than hardcoded, so any
  # extension a test's fixture uses as "code" must be registered here or it
  # silently falls out of the code tier entirely.
  printf '%s' '{"java": {"repo": "https://example.invalid/tree-sitter-java", "scope": "source.java"},
                "py": {"repo": "https://example.invalid/tree-sitter-python", "scope": "source.python"},
                "ts": {"repo": "https://example.invalid/tree-sitter-typescript", "scope": "source.tsx"}}' \
    > "$HOME/.claude/synapse-grammars.conf"
  SRC="$TEST_HOME/sources.txt"
  : > "$SRC"
  OUT="$TEST_HOME/out"
}

teardown() {
  common_teardown
}

# A file with the given definitions, plus `pad` filler bytes. Filler is what
# separates "declares a lot" from "is merely large".
src() { # src <path> <pad-bytes> <symbol>...
  local path="$REPO/$1" pad="$2"; shift 2
  mkdir -p "$(dirname "$path")"
  : > "$path"
  local s
  for s in "$@"; do printf 'symbol:%s\n' "$s" >> "$path"; done
  [ "$pad" -eq 0 ] || head -c "$pad" /dev/zero | tr '\0' 'x' >> "$path"
}

# Registers a path in the sources list under test.
want() { printf '%s\n' "$@" >> "$SRC"; }

commit_repo() {
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init
}

run_rank() {
  # synapse-001, step 4: the code tier reads `_tags_cache.bin`, it no longer
  # tags anything itself. Warming it via `vocab` first is not a test
  # convenience -- it is the real precondition /synapse-init's own procedure
  # establishes by running `vocab` before ever calling `rank`.
  PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --repo "$REPO" --out "$OUT" >/dev/null 2>&1
  PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$SRC" --repo "$REPO" --out "$OUT" "$@"
}

# sb-011, stage 1: writes `NN.txt` under `$OUT/lists` -- rank's --lists mode
# needs nothing else, deliberately not even a `.title` (nothing in the
# ranking path reads one).
node_list() { # node_list <NN> <path>...
  local nn="$1"; shift
  mkdir -p "$OUT/lists"
  printf '%s\n' "$@" > "$OUT/lists/$nn.txt"
}

run_rank_lists() {
  PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --repo "$REPO" --out "$OUT" >/dev/null 2>&1
  PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --lists "$OUT/lists" --repo "$REPO" --out "$OUT" "$@"
}

# bats merges stderr into $output, and this script reports its per-tier counts
# there. Every assertion about the RANKING therefore has to filter to the data
# lines first, or the summary line counts as a result.
data() { # data <output>
  grep -E '^(code|dsl)	' <<< "$1" || true
}

# The rank (1-based) of a path within its tier, or empty when absent.
rank_of() { # rank_of <path> <output>
  data "$2" | awk -F'\t' -v p="$1" '$3 == p { print NR }'
}

@test "an oversized file does not outrank a small one with the same definitions" {
  # The finding the code tier exists for: raw definition counts rank generated
  # constant tables and wide accessor classes first, which is the opposite of
  # useful. Both files here declare exactly the same symbols; only size differs.
  git init -q "$REPO"
  src core/src/Service.java   0     Alpha Beta Gamma
  src core/src/Generated.java 40000 Alpha Beta Gamma
  commit_repo
  want core/src/Service.java core/src/Generated.java

  run run_rank
  [ "$status" -eq 0 ]
  [ "$(rank_of core/src/Service.java "$output")" -lt "$(rank_of core/src/Generated.java "$output")" ]
}

@test "raw counts alone would give the opposite answer" {
  # Pins that normalising is what decides it, rather than the small file
  # happening to win for some other reason: here the big file declares strictly
  # MORE symbols and must still rank below.
  git init -q "$REPO"
  src core/src/Service.java   0     Alpha Beta
  src core/src/Generated.java 40000 One Two Three Four Five Six Seven Eight
  commit_repo
  want core/src/Service.java core/src/Generated.java

  run run_rank
  [ "$status" -eq 0 ]
  [ "$(rank_of core/src/Service.java "$output")" -lt "$(rank_of core/src/Generated.java "$output")" ]
}

@test "references do not count as definitions" {
  # A summary is made of what a subsystem DECLARES. A file that merely calls a
  # lot of things is not thereby a good thing to read first.
  git init -q "$REPO"
  src core/src/Declarer.java 0 Alpha Beta Gamma Delta
  mkdir -p "$REPO/core/src"
  : > "$REPO/core/src/Caller.java"
  for i in 1 2 3 4 5 6 7 8 9; do printf 'ref:Thing%s\n' "$i" >> "$REPO/core/src/Caller.java"; done
  commit_repo
  want core/src/Declarer.java core/src/Caller.java

  run run_rank
  [ "$status" -eq 0 ]
  [ "$(rank_of core/src/Declarer.java "$output")" -lt "$(rank_of core/src/Caller.java "$output")" ]
}

@test "a file that parsed to no definitions is ranked last, not dropped" {
  git init -q "$REPO"
  src core/src/Real.java 0 Alpha Beta
  printf 'notags\n' > "$REPO/core/src/Empty.java"
  commit_repo
  want core/src/Real.java core/src/Empty.java

  run run_rank
  [ "$status" -eq 0 ]
  [ -n "$(rank_of core/src/Empty.java "$output")" ]
  [ "$(rank_of core/src/Real.java "$output")" -lt "$(rank_of core/src/Empty.java "$output")" ]
}

# --- dsl tier --------------------------------------------------------------

@test "a declaration ranks its consumer, resolved by stem prefix" {
  # `Kunde.gui` is a declaration; `KundeController.java` is the code that binds
  # it and carries the domain verbs. The declaration itself is never ranked.
  git init -q "$REPO"
  src core/src/KundeController.java 0 Alpha
  printf 'declaration\n' > "$REPO/core/src/Kunde.gui"
  commit_repo
  want core/src/Kunde.gui core/src/KundeController.java

  run run_rank
  [ "$status" -eq 0 ]
  [ -n "$(data "$output" | awk -F'\t' '$1 == "dsl" && $3 == "core/src/KundeController.java"')" ]
  # The .gui file is evidence, not a reading target.
  [ -z "$(data "$output" | awk -F'\t' '$3 == "core/src/Kunde.gui"')" ]
}

@test "the consumer hop is constrained to the declaration's own module" {
  # THE finding that makes the hop worth anything: generic stems match dozens
  # of unrelated classes across a large repo, so a stem-only match resolves to
  # whichever sorts first and is worse than no answer at all.
  git init -q "$REPO"
  src billing/src/AdresseHandler.java  0 Alpha
  src shipping/src/AdresseHandler.java 0 Beta
  printf 'declaration\n' > "$REPO/billing/src/Adresse.domvo"
  commit_repo
  want billing/src/Adresse.domvo billing/src/AdresseHandler.java shipping/src/AdresseHandler.java

  run run_rank
  [ "$status" -eq 0 ]
  [ -n "$(data "$output" | awk -F'\t' '$1 == "dsl" && $3 == "billing/src/AdresseHandler.java"')" ]
  [ -z "$(data "$output" | awk -F'\t' '$1 == "dsl" && $3 == "shipping/src/AdresseHandler.java"')" ]
}

@test "consumers rank by how many declarations they serve" {
  git init -q "$REPO"
  src core/src/BusyHandler.java 0 Alpha
  src core/src/IdleHandler.java 0 Beta
  # Both stems prefix `BusyHandler`, so both resolve to the same consumer.
  printf 'x\n' > "$REPO/core/src/Busy.domvo"
  printf 'x\n' > "$REPO/core/src/BusyHandler.domvo"
  printf 'x\n' > "$REPO/core/src/Idle.domvo"
  commit_repo
  want core/src/Busy.domvo core/src/BusyHandler.domvo core/src/Idle.domvo

  run run_rank --tier dsl
  [ "$status" -eq 0 ]
  [ "$(rank_of core/src/BusyHandler.java "$output")" -lt "$(rank_of core/src/IdleHandler.java "$output")" ]
  [ "$(data "$output" | awk -F'\t' '$3 ~ /BusyHandler/ { print $2 }')" = "2" ]
}

@test "a consumer outside the node's own sources is still found" {
  # The code that uses a node's declarations is frequently the reason to read
  # it, and is not always a file the node itself owns.
  git init -q "$REPO"
  src core/src/KundeController.java 0 Alpha
  printf 'x\n' > "$REPO/core/src/Kunde.gui"
  commit_repo
  want core/src/Kunde.gui          # the controller is deliberately NOT listed

  run run_rank --tier dsl
  [ "$status" -eq 0 ]
  [ -n "$(data "$output" | awk -F'\t' '$3 == "core/src/KundeController.java"')" ]
}

@test "config and data with no consumer are unranked but counted" {
  # Scored zero and omitted from the ranking, still fully covered by `sources`
  # -- coverage and relevance are separate axes.
  git init -q "$REPO"
  src core/src/Real.java 0 Alpha
  printf 'a=1\n' > "$REPO/core/src/settings.properties"
  printf '{}\n'  > "$REPO/core/src/data.json"
  commit_repo
  want core/src/Real.java core/src/settings.properties core/src/data.json

  run run_rank
  [ "$status" -eq 0 ]
  [ -z "$(data "$output" | awk -F'\t' '$3 ~ /settings.properties|data.json/')" ]
  [[ "$output" == *"unranked 2"* ]]
}

@test "a stem under three characters makes no hop" {
  # Such a stem prefixes half the repo and tells you nothing.
  git init -q "$REPO"
  src core/src/AbcHandler.java 0 Alpha
  printf 'x\n' > "$REPO/core/src/Ab.domvo"
  commit_repo
  want core/src/Ab.domvo

  run run_rank --tier dsl
  [ "$status" -eq 0 ]
  [ -z "$(data "$output")" ]
}

# --- the two pools ---------------------------------------------------------

@test "the crux pool excludes tests even when density ranks them first" {
  # Density ranks tests high for a structural reason -- many small @Test
  # methods, each a definition, in a small file -- so this is not a rare
  # collision, it is the normal outcome. Without the split, the crux pointer
  # would routinely land on a test.
  git init -q "$REPO"
  src src/main/java/Service.java 3000 Alpha Beta
  src src/test/java/ServiceTest.java 0 T1 T2 T3 T4 T5 T6
  commit_repo
  want src/main/java/Service.java src/test/java/ServiceTest.java

  # It really would have won on density alone.
  run run_rank --pool summary --tier code
  [ "$status" -eq 0 ]
  [ "$(rank_of src/test/java/ServiceTest.java "$output")" -eq 1 ]

  run run_rank --pool crux
  [ "$status" -eq 0 ]
  [ -z "$(rank_of src/test/java/ServiceTest.java "$output")" ]
  [ -n "$(rank_of src/main/java/Service.java "$output")" ]
  [[ "$output" == *"tests-excluded 1"* ]]
}

@test "the summary pool keeps tests, because a summary is made of names" {
  # `Gegenpartei` and `Frist` came only from test class names on a real node.
  # Excluding tests from both halves would have cost those concepts entirely.
  git init -q "$REPO"
  src src/main/java/Service.java 0 Alpha
  src src/test/java/GegenparteiTest.java 0 Frist
  commit_repo
  want src/main/java/Service.java src/test/java/GegenparteiTest.java

  run run_rank --pool summary
  [ "$status" -eq 0 ]
  [ -n "$(rank_of src/test/java/GegenparteiTest.java "$output")" ]
  [[ "$output" == *"tests-excluded 0"* ]]
}

@test "the crux pool emits no dsl tier: a crux is code" {
  git init -q "$REPO"
  src core/src/KundeController.java 0 Alpha
  printf 'x\n' > "$REPO/core/src/Kunde.gui"
  commit_repo
  want core/src/Kunde.gui core/src/KundeController.java

  run run_rank --pool crux
  [ "$status" -eq 0 ]
  [ "$(data "$output" | awk -F'\t' '$1 == "dsl"' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "test detection does not swallow implementation files that merely end in -test" {
  # `Latest.java` ends in the letters "test". Silently dropping a real
  # implementation file from the crux pool is precisely the kind of wrong
  # answer that never announces itself, so the boundary is asserted directly.
  git init -q "$REPO"
  src core/src/Latest.java 0 Alpha
  src core/src/Contest.java 0 Beta
  src core/src/RealTest.java 0 Gamma
  commit_repo
  want core/src/Latest.java core/src/Contest.java core/src/RealTest.java

  run run_rank --pool crux
  [ "$status" -eq 0 ]
  [ -n "$(rank_of core/src/Latest.java "$output")" ]
  [ -n "$(rank_of core/src/Contest.java "$output")" ]
  [ -z "$(rank_of core/src/RealTest.java "$output")" ]
}

@test "test detection covers the conventions that recur across languages" {
  git init -q "$REPO"
  src core/src/Keep.java 0 Alpha
  src core/src/FooTest.java 0 A
  src core/src/FooSpec.java 0 B
  src core/src/thing_test.py 0 C
  src core/src/test_thing.py 0 D
  src core/src/widget.test.ts 0 E
  src core/spec/Helper.java 0 F
  commit_repo
  want core/src/Keep.java core/src/FooTest.java core/src/FooSpec.java \
       core/src/thing_test.py core/src/test_thing.py core/src/widget.test.ts \
       core/spec/Helper.java

  run run_rank --pool crux --top 0
  [ "$status" -eq 0 ]
  [ "$(data "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ -n "$(rank_of core/src/Keep.java "$output")" ]
  [[ "$output" == *"tests-excluded 6"* ]]
}

@test "SYNAPSE_TEST_PATH_RE replaces the built-in rule" {
  # A project that names tests some other way needs one knob, not a patch.
  git init -q "$REPO"
  src core/src/FooTest.java 0 Alpha
  src core/src/Probe.java 0 Beta
  commit_repo
  want core/src/FooTest.java core/src/Probe.java

  run env PATH="$FAKE_BIN:$PATH" SYNAPSE_TEST_PATH_RE='Probe' \
    "$SYNAPSE_BIN" rank --sources "$SRC" --repo "$REPO" --pool crux
  [ "$status" -eq 0 ]
  [ -n "$(rank_of core/src/FooTest.java "$output")" ]
  [ -z "$(rank_of core/src/Probe.java "$output")" ]
}

# --- output shape ----------------------------------------------------------

@test "--top limits each tier, and --top 0 prints everything" {
  git init -q "$REPO"
  local i
  for i in $(seq 1 8); do src "core/src/F$i.java" 0 "Sym$i"; done
  commit_repo
  for i in $(seq 1 8); do want "core/src/F$i.java"; done

  run run_rank --top 3
  [ "$status" -eq 0 ]
  [ "$(data "$output" | wc -l | tr -d ' ')" -eq 3 ]

  run run_rank --top 0
  [ "$status" -eq 0 ]
  [ "$(data "$output" | wc -l | tr -d ' ')" -eq 8 ]
}

@test "--tier restricts the output to one tier" {
  git init -q "$REPO"
  src core/src/KundeController.java 0 Alpha
  printf 'x\n' > "$REPO/core/src/Kunde.gui"
  commit_repo
  want core/src/Kunde.gui core/src/KundeController.java

  run run_rank --tier code
  [ "$status" -eq 0 ]
  [ "$(data "$output" | awk -F'\t' '$1 != "code"' | wc -l | tr -d ' ')" -eq 0 ]

  run run_rank --tier dsl
  [ "$status" -eq 0 ]
  [ "$(data "$output" | awk -F'\t' '$1 != "dsl"' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "a node made entirely of config ranks nothing, and that is not a failure" {
  git init -q "$REPO"
  mkdir -p "$REPO/core/src"
  printf 'a=1\n' > "$REPO/core/src/settings.properties"
  commit_repo
  want core/src/settings.properties

  run run_rank
  [ "$status" -eq 0 ]
  [ -z "$(data "$output")" ]
}

@test "an empty tags cache is not an error: it warns once, and every file scores zero" {
  # synapse-001, step 4: rank is read-only against the cache. Without a prior
  # `vocab` call there is nothing to read, and it must not tag anything to
  # compensate -- the whole point is that authoring stays a reader.
  git init -q "$REPO"
  src core/src/Real.java 0 Alpha Beta Gamma
  commit_repo
  want core/src/Real.java

  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$SRC" --repo "$REPO" --out "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tags cache is empty"* ]]
  # Present with a score of zero, not dropped from its tier -- the same
  # outcome an unsupported or untagged file always got.
  [ "$(data "$output" | awk -F'\t' '$3 == "core/src/Real.java" { print $2 }')" = "0.000" ]
}

@test "a file the cache never held scores zero without a warning once the cache itself is non-empty" {
  # The narrower case within a warm cache: this specific source was added to
  # --sources after the cache was built (or never claimed by anything vocab
  # tagged), so it is an ordinary per-file miss rather than a cold cache.
  git init -q "$REPO"
  src core/src/Known.java   0 Alpha Beta
  src core/src/Unknown.java 0 Gamma Delta
  commit_repo
  # Warm the cache for Known.java only, via a --lists dir naming just that one
  # file -- vocab --lists tags exactly what the list claims.
  mkdir -p "$TEST_HOME/lists"
  printf 'Known\n' > "$TEST_HOME/lists/01.title"
  printf 'core/src/Known.java\n' > "$TEST_HOME/lists/01.txt"
  PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --repo "$REPO" --out "$OUT" --lists "$TEST_HOME/lists" >/dev/null 2>&1

  want core/src/Known.java core/src/Unknown.java
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$SRC" --repo "$REPO" --out "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"tags cache is empty"* ]]
  [ "$(data "$output" | awk -F'\t' '$3 == "core/src/Unknown.java" { print $2 }')" = "0.000" ]
  [ "$(data "$output" | awk -F'\t' '$3 == "core/src/Known.java" { print $2 }')" != "0.000" ]
}

# --- --lists: both pools for every node, one repo pass (sb-011, stage 1) ---

@test "--lists writes both pools per node, matching what --sources produces for the same list" {
  git init -q "$REPO"
  src core/src/Service.java 0 Alpha Beta
  src core/src/ServiceTest.java 0 T1 T2 T3
  commit_repo
  node_list 01 core/src/Service.java core/src/ServiceTest.java

  run run_rank_lists
  [ "$status" -eq 0 ]
  [ -f "$OUT/rank/01.summary.tsv" ]
  [ -f "$OUT/rank/01.crux.tsv" ]

  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$OUT/lists/01.txt" --repo "$REPO" --out "$OUT" --pool summary
  local want_summary; want_summary="$(data "$output" | sort)"
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$OUT/lists/01.txt" --repo "$REPO" --out "$OUT" --pool crux
  local want_crux; want_crux="$(data "$output" | sort)"

  [ "$(sort "$OUT/rank/01.summary.tsv")" = "$want_summary" ]
  [ "$(sort "$OUT/rank/01.crux.tsv")" = "$want_crux" ]
  # And the actual behavioural claim, not just "matches itself": the test is
  # in summary, excluded from crux.
  [ -n "$(grep -F 'core/src/ServiceTest.java' "$OUT/rank/01.summary.tsv")" ]
  [ -z "$(grep -F 'core/src/ServiceTest.java' "$OUT/rank/01.crux.tsv")" ]
}

@test "--lists: the DSL index is shared across nodes without cross-contaminating them" {
  # Two unrelated module pairs, one node each. Each node's DSL rows must come
  # only from its own node's declarations, even though both are matched
  # against one repo-wide index built before either node is ranked.
  git init -q "$REPO"
  src billing/src/AdresseHandler.java 0 Alpha
  printf 'declaration\n' > "$REPO/billing/src/Adresse.domvo"
  src shipping/src/BestellungHandler.java 0 Beta
  printf 'declaration\n' > "$REPO/shipping/src/Bestellung.domvo"
  commit_repo
  node_list 01 billing/src/Adresse.domvo billing/src/AdresseHandler.java
  node_list 02 shipping/src/Bestellung.domvo shipping/src/BestellungHandler.java

  run run_rank_lists
  [ "$status" -eq 0 ]
  [ -n "$(grep -F 'billing/src/AdresseHandler.java' "$OUT/rank/01.summary.tsv")" ]
  [ -z "$(grep -F 'shipping/src/BestellungHandler.java' "$OUT/rank/01.summary.tsv")" ]
  [ -n "$(grep -F 'shipping/src/BestellungHandler.java' "$OUT/rank/02.summary.tsv")" ]
  [ -z "$(grep -F 'billing/src/AdresseHandler.java' "$OUT/rank/02.summary.tsv")" ]
}

@test "--lists writes an empty pool file for a node with nothing to rank, rather than skipping it" {
  git init -q "$REPO"
  printf 'x\n' > "$REPO/config.json"
  commit_repo
  node_list 01 config.json

  run run_rank_lists
  [ "$status" -eq 0 ]
  [ -f "$OUT/rank/01.summary.tsv" ]
  [ -f "$OUT/rank/01.crux.tsv" ]
  [ ! -s "$OUT/rank/01.summary.tsv" ]
  [ ! -s "$OUT/rank/01.crux.tsv" ]
}

@test "--lists honours --top per file" {
  git init -q "$REPO"
  src core/src/A.java 0 A1 A2 A3
  src core/src/B.java 0 B1
  commit_repo
  node_list 01 core/src/A.java core/src/B.java

  run run_rank_lists --top 1
  [ "$status" -eq 0 ]
  [ "$(grep -cE '^code	' "$OUT/rank/01.summary.tsv")" -eq 1 ]
}

@test "--lists needs no .title file -- nothing in the ranking path reads one" {
  git init -q "$REPO"
  src core/src/Service.java 0 Alpha
  commit_repo
  node_list 01 core/src/Service.java
  [ ! -f "$OUT/lists/01.title" ]

  run run_rank_lists
  [ "$status" -eq 0 ]
  [ -n "$(grep -F 'core/src/Service.java' "$OUT/rank/01.summary.tsv")" ]
}

@test "usage and environment errors" {
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$SRC" --tier bogus
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$TEST_HOME/nope.txt"
  [ "$status" -eq 1 ]
  # --lists and --sources pick two different input modes; giving both is a
  # usage error, not a silent pick of one.
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$SRC" --lists "$OUT/lists" --repo "$REPO" --out "$OUT"
  [ "$status" -eq 2 ]
  # --pool and --tier select one pool/tier for a single stream; --lists always
  # writes both pools per node, so combining them is a usage error too.
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --lists "$OUT/lists" --repo "$REPO" --out "$OUT" --pool crux
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --lists "$OUT/lists" --repo "$REPO" --out "$OUT" --tier code
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --lists "$TEST_HOME/no-such-lists-dir" --repo "$REPO" --out "$OUT"
  [ "$status" -eq 1 ]
  git init -q "$REPO"
  mkdir -p "$OUT/lists-empty"
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --lists "$OUT/lists-empty" --repo "$REPO" --out "$OUT"
  [ "$status" -eq 1 ]
}
