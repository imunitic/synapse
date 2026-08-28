#!/usr/bin/env bats
# Tests `synapse query grounding`'s one genuinely process-level concern: a
# real write-node -> query round trip proving `grounded_in` provenance
# survives a realistic edit-regenerate-rewrite cycle. The remote-mismatch
# preamble this subcommand shares with every other `query` subcommand has
# its canonical test in synapse-query.bats, not duplicated here. The
# verification logic itself (moved vs. changed vs. gone, --list, argument
# handling) moved to native coverage -- `src/apps/synapse/query_cmd.zig`'s
# own `test` blocks, calling `cmdGrounding` directly against a node file
# written straight into a fixture vault rather than through `write-node`'s
# own pipeline, since `cmdGrounding` only cares what's on disk, not how it
# got there.

load 'test_helper'


setup() {
  common_setup
  BODY="$TEST_HOME/body.md"
  PATHS="$TEST_HOME/paths.txt"
}

teardown() { common_teardown; }

in_repo() {
  PATH="$FAKE_BIN:$PATH" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$@"
}

ns() { echo "$VAULT/synapse/$(repo_name)"; }

# A node grounded in a two-line doc comment at the top of calc.aa.
build_grounded_node() {
  make_repo
  mkdir -p "$REPO/lib"
  { printf '(* Computes the premium for a contract.\n'
    printf '   Rounds half-up at two decimals. *)\n'
    for i in $(seq 3 12); do printf 'let line%02d = %d\n' "$i" "$i"; done; } > "$REPO/lib/calc.aa"
  git -C "$REPO" add lib/calc.aa
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m calc
  printf 'src/foo.aa\nlib/calc.aa\n' > "$PATHS"
  printf '## Summary\nRounds half-up at two decimals.\n<!-- grounded_in: lib/calc.aa 1-2 -->\n' > "$BODY"

  in_repo "$SYNAPSE_BIN" write-node --title "Premium" --summary "Premium calc." \
    --paths "$PATHS" --body "$BODY" >/dev/null
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  printf 'lib/calc.aa\tPremium.md\nsrc/foo.aa\tPremium.md\n' | write_index_bin "$(default_work_dir)"
}

@test "round trip: --list plus re-emit preserves groundings; omitting them loses all" {
  build_grounded_node
  # What a regeneration actually has in hand: the prose, with no directives in it.
  in_repo "$SYNAPSE_BIN" query body "Premium" | awk '/^## Sources$/ { exit } { print }' > "$TEST_HOME/recovered.md"
  ! grep -q 'grounded_in' "$TEST_HOME/recovered.md"

  # (a) writing the recovered body back as-is drops the provenance, silently
  in_repo "$SYNAPSE_BIN" write-node --title "Premium" --summary "Premium calc." \
    --paths "$PATHS" --body "$TEST_HOME/recovered.md" >/dev/null
  ! grep -q '^grounded_in:' "$(ns)/Premium.md"

  # (b) re-emitting from --list restores it exactly -- which is why --list exists
  cp "$TEST_HOME/recovered.md" "$TEST_HOME/reemit.md"
  while IFS="$(printf '\t')" read -r p l; do
    printf '<!-- grounded_in: %s %s -->\n' "$p" "$l" >> "$TEST_HOME/reemit.md"
  done < <(printf 'lib/calc.aa\t1-2\n')

  in_repo "$SYNAPSE_BIN" write-node --title "Premium" --summary "Premium calc." \
    --paths "$PATHS" --body "$TEST_HOME/reemit.md" >/dev/null
  grep -qxF '  - path: lib/calc.aa' "$(ns)/Premium.md"
  grep -qxF '    lines: "1-2"' "$(ns)/Premium.md"
  run in_repo "$SYNAPSE_BIN" query grounding
  [ -z "$output" ]
}
