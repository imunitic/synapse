#!/usr/bin/env bats
# Tests claude/hooks/synapse-staleness.sh (Tier 1 PostToolUse staleness
# flagging). The Obsidian Local REST API is stubbed out by
# tests/fixtures/fake-bin/curl -- see that file for exactly what it
# simulates -- so these tests exercise the hook's own logic (repo/path
# resolution, index lookup, decision to PATCH vs. queue-unassigned)
# without a real Obsidian instance.

load 'test_helper'


# Writes a Synapse node whose frontmatter contains every shape the old
# `PATCH -H "Target-Type: frontmatter"` call used to mangle: a title long
# enough to be line-folded, quoted values, and an all-digit `hash` that
# YAML happily coerces to a float.
write_synapse_node() {
  local project="$1" node="$2" stale="${3:-false}"
  mkdir -p "$VAULT/synapse/$project"
  cat > "$VAULT/synapse/$project/$node" <<EOF
---
title: "A deliberately long node title that a re-serialising writer would fold across two lines"
node_type: synapse-node
project: $project
sources:
  - path: src/foo.ml
    hash: 1111111111111111111111111111111111111111
sources_digest: "2222222222222222222222222222222222222222222222222222222222222222"
stale: $stale
built_at: "2026-08-03 16:15"
---

# A node

Body text, including a decoy: stale: false
EOF
}

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  CURL_CAPTURE="$TEST_HOME/curl-capture"
  WORK="$TEST_HOME/work"
  : > "$CURL_LOG"
  mkdir -p "$CURL_CAPTURE" "$WORK"
}

teardown() {
  common_teardown
}

# Runs the hook against $1 (the edited file path) with the fake curl on PATH and
# the index staged from $2 -- `<node.md> <path>...`, or nothing for "no namespace
# exists".
#
# The index is binary and lives in the work dir now, so the fixture is built by
# the shipped writer rather than copied from authored JSON. No arguments beyond
# the file leaves no index at all, which is the case the hook exits on -- and it
# is still exactly a file-existence question, not an HTTP status one.
run_staleness_hook() {
  local file="$1"; shift
  if [ "${1:-}" = "--keep-index" ]; then
    # Use whatever the test already staged, including something deliberately
    # broken that must survive the run untouched.
    shift
  elif [ "$#" -eq 1 ] && [ -f "${1:-}" ]; then
    # A `path<TAB>node` pairs file, for the fixtures that need more than one node
    # or more than one path.
    write_index_bin "$WORK" < "$1"
  elif [ "$#" -gt 0 ]; then
    # <node.md> <path>... -- the common single-node case, spelled inline.
    local node="$1" p; shift
    for p in "$@"; do printf '%s\t%s\n' "$p" "$node"; done | write_index_bin "$WORK"
  else
    rm -f "$WORK/_index.bin"
  fi
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_CAPTURE_DIR="$CURL_CAPTURE" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c "printf '%s' \"\$2\" | jq -Rn '{tool_input:{file_path: input}}' | \"\$0\" \"\$1\"" "$SYNAPSE_HOOK_BIN" staleness "$file"
}

# The paths the index has queued for the _unassigned sweep.
queued_unassigned() {
  "$SYNAPSE_BIN" index unassigned --file "$WORK/_index.bin"
}

@test "file mapped to a node: rewrites that node's stale line, never PATCHes frontmatter" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  run run_staleness_hook "$REPO/src/foo.ml" 'Foo Node.md' src/foo.ml
  [ "$status" -eq 0 ]

  grep -q "synapse/$(repo_name)/Foo Node.md" "$CURL_CAPTURE/node-puts.log"
  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/Foo Node.md"
  # The frontmatter-patch call is the bug being fixed -- it must never reappear.
  [ ! -f "$CURL_CAPTURE/patches.log" ]
  ! grep -q "Target-Type: frontmatter" "$CURL_LOG"
  [ -z "$(queued_unassigned)" ]
}

@test "file mapped to two nodes: flags both" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" false
  write_synapse_node "$(repo_name)" "Bar Node.md" false

  printf 'src/foo.ml\tFoo Node.md\nsrc/foo.ml\tBar Node.md\n' > "$TEST_HOME/index-pairs.tsv"

  run run_staleness_hook "$REPO/src/foo.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]

  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/Foo Node.md"
  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/Bar Node.md"
  [ "$(wc -l < "$CURL_CAPTURE/node-puts.log" | tr -d ' ')" = "2" ]
}

@test "new file not in any node's sources: queued into the unassigned list, no PATCH" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_staleness_hook "$REPO/src/foo.ml" 'Other Node.md' src/other.ml
  [ "$status" -eq 0 ]

  # An in-place re-encode of the index now, not a 27 MB PUT: the claim survives
  # and the new path is appended.
  queued_unassigned | grep -qx 'src/foo.ml'
  [ "$("$SYNAPSE_BIN" index lookup src/other.ml --file "$WORK/_index.bin")" = "Other Node.md" ]
  [ ! -f "$CURL_CAPTURE/patches.log" ]
}

@test "queueing the same new file twice does not grow the list" {
  # The hook fires on every edit, so a non-idempotent append would grow the
  # index without bound for any file that stays unclaimed.
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_staleness_hook "$REPO/src/foo.ml" 'Other Node.md' src/other.ml
  [ "$status" -eq 0 ]
  [ "$(queued_unassigned | wc -l | tr -d ' ')" = "1" ]

  # Second edit, same file, and the index is left as it was rather than restaged.
  run env PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_CAPTURE_DIR="$CURL_CAPTURE" FAKE_CURL_VAULT_DIR="$VAULT" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c "printf '%s' \"\$2\" | jq -Rn '{tool_input:{file_path: input}}' | \"\$0\" \"\$1\"" \
    "$SYNAPSE_HOOK_BIN" staleness "$REPO/src/foo.ml"
  [ "$status" -eq 0 ]
  [ "$(queued_unassigned | wc -l | tr -d ' ')" = "1" ]
}

@test "no Synapse namespace for this repo: no-op, no write or PATCH" {
  # Regression test, kept for what it now guards rather than what it did. The
  # original bug was that the Local REST API answers a missing index with a 404
  # whose body is itself valid JSON (`{"message":"Not Found","errorCode":40400}`),
  # so a hook checking "is this valid JSON" treated it as a real index and PUT a
  # stray `_unassigned` onto it -- which happened in the wild to two repos edited
  # before /synapse-init had ever run. There is no GET to misread any more, so the
  # case reduces to the thing it always should have been: no index file, no work.
  make_repo
  # The namespace Index.md must exist with a matching remote, or the hook's
  # remote guard exits before the GET and this test would pass vacuously --
  # covering the guard rather than the 404 handling it is named for.
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  # No index staged at all.
  run run_staleness_hook "$REPO/src/foo.ml"
  [ "$status" -eq 0 ]
  [ ! -f "$WORK/_index.bin" ]
  [ ! -f "$CURL_CAPTURE/patches.log" ]
}

@test "no OBSIDIAN_VAULT_DIR configured: exits before any curl call at all" {
  cat > "$HOME/.claude/synapse.conf" <<'EOF'
EOF
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"

  run run_staleness_hook "$REPO/src/foo.ml" 'Foo Node.md' src/foo.ml
  [ "$status" -eq 0 ]
  [ ! -s "$CURL_LOG" ]
}

@test "edited file outside any git repo: no-op" {
  local outside="$TEST_HOME/not-a-repo"
  mkdir -p "$outside"
  printf 'stray\n' > "$outside/stray.txt"

  run run_staleness_hook "$outside/stray.txt"
  [ "$status" -eq 0 ]
  [ ! -s "$CURL_LOG" ]
}

@test "node title with special characters is percent-encoded correctly in the request URL" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "World — entity_component_resource core.md" false

  run run_staleness_hook "$REPO/src/foo.ml" 'World — entity_component_resource core.md' src/foo.ml
  [ "$status" -eq 0 ]
  grep -q "World%20%E2%80%94%20entity_component_resource%20core.md" "$CURL_LOG"
  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/World — entity_component_resource core.md"
}

@test "flagging a node leaves every byte outside the stale line untouched" {
  # Regression test for the frontmatter-corruption bug. The old
  # `PATCH -H "Target-Type: frontmatter" -H "Target: stale"` call was not
  # field-local: it re-serialised the whole YAML block, stripping quotes from
  # every value, folding long `title:` lines in two, and YAML-coercing an
  # all-digit `hash` into scientific notation (verified 2026-08-03:
  # 1111111111111111111111111111111111111111 -> 1.1111111111111112e+39).
  # A corrupted hash makes sources_digest disagree with its own sources
  # permanently, so verification would report the node stale forever.
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  local node="$VAULT/synapse/$(repo_name)/Foo Node.md"
  cp "$node" "$TEST_HOME/before.md"

  run run_staleness_hook "$REPO/src/foo.ml" 'Foo Node.md' src/foo.ml
  [ "$status" -eq 0 ]

  # Exactly one line differs, and it is the stale line.
  run diff "$TEST_HOME/before.md" "$node"
  [ "$status" -eq 1 ]
  [ "$(diff "$TEST_HOME/before.md" "$node" | grep -c '^[<>]')" = "2" ]
  diff "$TEST_HOME/before.md" "$node" | grep -q '^< stale: false$'
  diff "$TEST_HOME/before.md" "$node" | grep -q '^> stale: true$'

  # The specific values the old call destroyed.
  grep -q 'hash: 1111111111111111111111111111111111111111' "$node"
  grep -q '^title: "A deliberately long node title' "$node"
  grep -q '^built_at: "2026-08-03 16:15"$' "$node"
  grep -q 'decoy: stale: false' "$node"
}

@test "node already stale: no write at all" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" true

  run run_staleness_hook "$REPO/src/foo.ml" 'Foo Node.md' src/foo.ml
  [ "$status" -eq 0 ]
  # Already true -> the hook must skip the PUT rather than churn the file.
  [ ! -f "$CURL_CAPTURE/node-puts.log" ]
}

@test "node listed in the index but missing from the vault: no-op, no crash" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  # deliberately no write_synapse_node -- fake curl's GET -o exits 22

  run run_staleness_hook "$REPO/src/foo.ml" 'Ghost Node.md' src/foo.ml
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_CAPTURE/node-puts.log" ]
}

@test "namespace belongs to a different remote: no write, and no HTTP at all" {
  # A namespace is keyed by repo and branch, so a collision needs two repos whose
  # remotes differ but whose key matches. This is the write-side half of the check
  # the SessionStart hook and synapse-query.sh already make.
  make_repo "ssh://git@example.com/mine.git"
  write_synapse_index "$(repo_name)" "ssh://git@example.com/SOMEONE-ELSE.git"
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  run run_staleness_hook "$REPO/src/foo.ml" 'Foo Node.md' src/foo.ml
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_CAPTURE/node-puts.log" ]
  [ -z "$(queued_unassigned)" ]
  # The guard is ahead of any HTTP, so nothing should have been dialed at all.
  [ ! -s "$CURL_LOG" ]
  grep -q '^stale: false$' "$VAULT/synapse/$(repo_name)/Foo Node.md"
}

@test "namespace Index.md with no remote line: treated as a mismatch, not a match on empty" {
  make_repo "ssh://git@example.com/mine.git"
  mkdir -p "$VAULT/synapse/$(repo_name)"
  cat > "$VAULT/synapse/$(repo_name)/Index.md" <<'EOF2'
---
title: "no remote here"
---
# index
EOF2
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  run run_staleness_hook "$REPO/src/foo.ml" 'Foo Node.md' src/foo.ml
  [ "$status" -eq 0 ]
  [ ! -f "$CURL_CAPTURE/node-puts.log" ]
  [ ! -s "$CURL_LOG" ]
}

@test "repo with no remote at all: falls back to the repo root and still matches" {
  # A repo without an `origin` must compare equal against its own namespace --
  # this is why the hook has to reuse the exact origin -> first-remote ->
  # repo-root chain the other components use.
  make_repo   # no remote argument
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  run run_staleness_hook "$REPO/src/foo.ml" 'Foo Node.md' src/foo.ml
  [ "$status" -eq 0 ]
  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/Foo Node.md"
}

# --- opportunistic correction ----------------------------------------------
# The hook nudges only when the edit landed on evidence a node explicitly
# cites, and only when that evidence stopped matching. Silence in every other
# case is the design, not an omission: a nudge that fired on ordinary edits
# would be tuned out within a day, and then the rare real one would be missed
# with it.

# A node citing lib/calc.ml both as its crux (lines 5-6, sliced into the body)
# and as a grounding (lines 1-2, recorded as a digest).
write_cited_node() { # write_cited_node <project> <node> <grounding-digest>
  local project="$1" node="$2" gdigest="$3"
  mkdir -p "$VAULT/synapse/$project"
  cat > "$VAULT/synapse/$project/$node" <<EOF
---
title: "Cited"
node_type: synapse-node
project: $project
sources:
  - path: lib/calc.ml
    hash: 1111111111111111111111111111111111111111
sources_digest: "2222222222222222222222222222222222222222222222222222222222222222"
stale: false
built_at: "2026-08-03 16:15"
crux_path: lib/calc.ml
crux_lines: "5-6"
grounded_in:
  - path: lib/calc.ml
    lines: "1-2"
    digest: $gdigest
---

# Cited
<!-- synapse:generated:start -->

## Summary
Rounds half-up at two decimals.

## Crux
\`\`\`ocaml
let line05 = 5
let line06 = 6
\`\`\`
— \`lib/calc.ml\`:5-6
<!-- synapse:generated:end -->

## Notes
EOF
}

# A node whose ## Links section depends_on <target> -- for blast-radius tests,
# where <target> is the node that directly covers the edited file.
write_dependent_node() { # write_dependent_node <project> <node> <target>
  local project="$1" node="$2" target="$3"
  mkdir -p "$VAULT/synapse/$project"
  cat > "$VAULT/synapse/$project/$node" <<EOF
---
title: "Dependent"
node_type: synapse-node
project: $project
sources:
  - path: lib/dependent.ml
    hash: 3333333333333333333333333333333333333333
sources_digest: "4444444444444444444444444444444444444444444444444444444444444444"
stale: false
built_at: "2026-08-03 16:15"
---

# Dependent
<!-- synapse:generated:start -->

## Summary
Depends on $target.

## Links
- depends_on [[$target]]
<!-- synapse:generated:end -->

## Notes
EOF
}

# calc.ml with a stable doc comment on 1-2 and numbered lines below.
make_cited_repo() {
  make_repo
  mkdir -p "$REPO/lib"
  { printf '(* Computes the premium.\n'
    printf '   Rounds half-up. *)\n'
    for i in $(seq 3 12); do printf 'let line%02d = %d\n' "$i" "$i"; done; } > "$REPO/lib/calc.ml"
  git -C "$REPO" add lib/calc.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m calc
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  printf 'lib/calc.ml\tCited.md\n' > "$TEST_HOME/index-pairs.tsv"
  write_cited_node "$(repo_name)" "Cited.md" \
    "$(sed -n '1,2p' "$REPO/lib/calc.ml" | sha256_stdin)"
}

@test "correction: silent when the cited evidence still matches" {
  make_cited_repo
  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"additionalContext"* ]]
  # the staleness flag is still written -- the nudge is additive, not a replacement
  grep -q "synapse/$(repo_name)/Cited.md" "$CURL_CAPTURE/node-puts.log"
}

@test "correction: silent for an edit to a file the node cites nothing from" {
  make_cited_repo
  printf 'let other = 1\n' > "$REPO/lib/elsewhere.ml"
  git -C "$REPO" add lib/elsewhere.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m e
  printf 'lib/elsewhere.ml\tCited.md\n' > "$TEST_HOME/index-pairs.tsv"

  run run_staleness_hook "$REPO/lib/elsewhere.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"additionalContext"* ]]
}

@test "correction: a changed grounding range produces a nudge naming the node" {
  make_cited_repo
  sed_i 's/   Rounds half-up. \*)/   Truncates toward zero. *)/' "$REPO/lib/calc.ml"

  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"additionalContext"* ]]
  [[ "$output" == *"Cited"* ]]
  [[ "$output" == *"grounding (lib/calc.ml:1-2)"* ]]
}

@test "correction: a changed crux range produces a nudge too" {
  make_cited_repo
  sed_i 's/^let line05 = 5$/let line05 = 999/' "$REPO/lib/calc.ml"

  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"crux (lib/calc.ml:5-6)"* ]]
}

@test "correction: the nudge tells the model to stay incidental" {
  make_cited_repo
  sed_i 's/   Rounds half-up. \*)/   Something else entirely. *)/' "$REPO/lib/calc.ml"

  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  # the guardrail is the point: without it this becomes an unbounded sweep
  [[ "$output" == *"Keep it incidental"* ]]
  [[ "$output" == *"do not start a sweep"* ]]
  [[ "$output" == *"synapse-rebuild"* ]]
}

@test "correction: an already-stale node is still checked" {
  make_cited_repo
  # A node flagged stale earlier has had the LONGEST time to go wrong, so
  # skipping it would hide the very case worth catching.
  sed_i 's/^stale: false$/stale: true/' "$VAULT/synapse/$(repo_name)/Cited.md"
  sed_i 's/   Rounds half-up. \*)/   Truncates toward zero. *)/' "$REPO/lib/calc.ml"

  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"grounding (lib/calc.ml:1-2)"* ]]
  # and no redundant PUT, since stale was already true
  [ ! -f "$CURL_CAPTURE/node-puts.log" ] || \
    ! grep -q "Cited.md" "$CURL_CAPTURE/node-puts.log"
}

@test "correction: emits valid JSON, so the harness can parse it" {
  make_cited_repo
  sed_i 's/   Rounds half-up. \*)/   Truncates toward zero. *)/' "$REPO/lib/calc.ml"

  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null
}

@test "blast radius: silent when the owning node has no dependents" {
  make_cited_repo
  # calc.ml is untouched -- no citation break either, so this isolates the
  # "no dependents" case rather than piggybacking on the correction check.
  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"additionalContext"* ]]
}

@test "blast radius: fires once when another node depends on the owning node" {
  make_cited_repo
  write_dependent_node "$(repo_name)" "Dependent.md" "Cited"

  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"additionalContext"* ]]
  [[ "$output" == *"Dependent"* ]]
  [[ "$output" == *"covered by a Synapse node that other nodes depend on"* ]]
}

@test "blast radius: silent on a second edit to the same file in the same session" {
  make_cited_repo
  write_dependent_node "$(repo_name)" "Dependent.md" "Cited"

  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"additionalContext"* ]]

  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" != *"additionalContext"* ]]
}

@test "blast radius: a different file under the same session still gets its own first nudge" {
  make_cited_repo
  write_dependent_node "$(repo_name)" "Dependent.md" "Cited"
  printf '(* second file *)\nlet x = 1\n' > "$REPO/lib/calc2.ml"
  git -C "$REPO" add lib/calc2.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m calc2
  printf 'lib/calc.ml\tCited.md\nlib/calc2.ml\tCited.md\n' > "$TEST_HOME/index-pairs.tsv"

  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"additionalContext"* ]]

  run run_staleness_hook "$REPO/lib/calc2.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"additionalContext"* ]]
}

@test "blast radius and correction merge into one additionalContext, not two" {
  make_cited_repo
  write_dependent_node "$(repo_name)" "Dependent.md" "Cited"
  sed_i 's/   Rounds half-up. \*)/   Truncates toward zero. *)/' "$REPO/lib/calc.ml"

  run run_staleness_hook "$REPO/lib/calc.ml" "$TEST_HOME/index-pairs.tsv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"grounding (lib/calc.ml:1-2)"* ]]
  [[ "$output" == *"Dependent"* ]]
  # One JSON object, one additionalContext string carrying both messages --
  # never two separate hookSpecificOutput emissions.
  printf '%s' "$output" | jq -e 'type == "object"' >/dev/null
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | length > 0' >/dev/null
}

@test "index: a malformed index is left alone, not overwritten with nothing" {
  # The upfront `jq -e .` validation was dropped when the index moved to a disk
  # read (file existence answers "no namespace" exactly, which is what that check
  # was standing in for). This is where a malformed index has to be caught
  # instead: jq prints nothing, and PUTting nothing would replace a 27MB index
  # with an empty body.
  make_repo
  # A real index, then truncated: the magic and version still read, so this is
  # caught by the length and checksum checks rather than by "not ours".
  printf 'src/foo.ml\tFoo Node.md\n' | write_index_bin "$WORK"
  local idx="$WORK/_index.bin"
  head -c 40 "$idx" > "$idx.trunc" && mv "$idx.trunc" "$idx"
  local before; before="$(cksum < "$idx")"

  # No staging argument -- the truncated index is already in place and must be
  # left exactly as it is.
  run run_staleness_hook "$REPO/src/foo.ml" --keep-index
  [ "$status" -eq 0 ]
  [ "$(cksum < "$idx")" = "$before" ]
  [ ! -s "$CURL_LOG" ]
}

@test "index: an absent index is the no-namespace case, and costs nothing" {
  make_repo
  rm -f "$WORK/_index.bin"
  run run_staleness_hook "$REPO/src/foo.ml"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # no HTTP traffic whatsoever for a repo that never opted in
  [ ! -s "$CURL_LOG" ]
}
