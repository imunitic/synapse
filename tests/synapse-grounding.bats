#!/usr/bin/env bats
# Tests `synapse-query.sh grounding`'s two genuinely process-level concerns:
# the shared namespace-remote-mismatch preamble every `query` subcommand
# gates on (`run()`'s own check, not `cmdGrounding`'s), and a real
# write-node -> query round trip. The verification logic itself (moved
# vs. changed vs. gone, --list, argument handling) moved to native
# coverage -- `src/apps/synapse/query_cmd.zig`'s own `test` blocks, calling
# `cmdGrounding` directly against a node file written straight into a
# fixture vault rather than through `write-node`'s own pipeline, since
# `cmdGrounding` only cares what's on disk, not how it got there.

load 'test_helper'


setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  BODY="$TEST_HOME/body.md"
  PATHS="$TEST_HOME/paths.txt"
}

teardown() { common_teardown; }

in_repo() {
  PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$@"
}

ns() { echo "$VAULT/synapse/$(repo_name)"; }

# A node grounded in a two-line doc comment at the top of calc.ml.
build_grounded_node() {
  make_repo
  mkdir -p "$REPO/lib"
  { printf '(* Computes the premium for a contract.\n'
    printf '   Rounds half-up at two decimals. *)\n'
    for i in $(seq 3 12); do printf 'let line%02d = %d\n' "$i" "$i"; done; } > "$REPO/lib/calc.ml"
  git -C "$REPO" add lib/calc.ml
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m calc
  printf 'src/foo.ml\nlib/calc.ml\n' > "$PATHS"
  printf '## Summary\nRounds half-up at two decimals.\n<!-- grounded_in: lib/calc.ml 1-2 -->\n' > "$BODY"

  in_repo "$SYNAPSE_BIN" write-node --title "Premium" --summary "Premium calc." \
    --paths "$PATHS" --body "$BODY" >/dev/null
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  printf 'lib/calc.ml\tPremium.md\nsrc/foo.ml\tPremium.md\n' | write_index_bin "$(default_work_dir)"
}

@test "grounding: refuses on a remote mismatch rather than reporting clean" {
  build_grounded_node
  write_synapse_index "$(repo_name)" "ssh://git@example.com/SOMEONE-ELSE.git"
  run in_repo "$SYNAPSE_BIN" query grounding
  [ "$status" -eq 1 ]
  [ -z "$output" ]
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
  done < <(printf 'lib/calc.ml\t1-2\n')

  in_repo "$SYNAPSE_BIN" write-node --title "Premium" --summary "Premium calc." \
    --paths "$PATHS" --body "$TEST_HOME/reemit.md" >/dev/null
  grep -qxF '  - path: lib/calc.ml' "$(ns)/Premium.md"
  grep -qxF '    lines: "1-2"' "$(ns)/Premium.md"
  run in_repo "$SYNAPSE_BIN" query grounding
  [ -z "$output" ]
}
