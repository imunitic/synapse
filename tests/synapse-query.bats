#!/usr/bin/env bats
# Tests `synapse query`'s remaining process-level concerns. The Obsidian
# Local REST API is stubbed by tests/fixtures/fake-bin/curl, which serves
# and writes real files under $FAKE_CURL_VAULT_DIR -- so these tests
# exercise real digest arithmetic against real git objects, not a mock of
# it.
#
# The expected digest is computed independently in python rather than by
# reusing the binary's own formula, so a change to either implementation
# fails the test instead of silently agreeing with itself.
#
# `stale`'s own detection logic (unchanged/changed/deleted/missing-digest/
# node-missing) moved to native coverage -- `src/apps/synapse/query_cmd.zig`'s
# own `test` blocks, calling `cmdStale` directly against a fixture vault and
# a real `_index.bin` built through `core.index_map.build`. What's left here
# is the shared remote-mismatch/no-namespace preamble every `query`
# subcommand gates on (kept once here as the canonical version -- the same
# check is exercised again, for a different subcommand, in
# synapse-drift.bats's branch-switch scenario), the top-level dispatcher's
# own unknown-subcommand handling, and a static audit unrelated to `query`
# itself but with no better home.

load 'test_helper'


setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
}

teardown() {
  common_teardown
}

# The script resolves the repo from $PWD, so run it from inside $REPO.
run_query() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" query "$@"
}

run_stale() { run_query stale; }

# sha256 over the LC_ALL=C sorted "path:hash" lines, newline-joined, no
# trailing newline -- computed independently of the binary under test.
expected_digest() {
  python3 - "$REPO" "$@" <<'PY'
import hashlib, subprocess, sys
repo, paths = sys.argv[1], sys.argv[2:]
hs = subprocess.run(["git", "-C", repo, "hash-object"] + paths,
                    capture_output=True, text=True).stdout.split()
lines = sorted(f"{p}:{h}" for p, h in zip(paths, hs))
print(hashlib.sha256("\n".join(lines).encode()).hexdigest())
PY
}

# The index the query reads, built through the shipped writer. Every path here
# maps to one node, which is what these tests need.
write_node_index() { # write_node_index <node.md> <path>...
  local node="$1" p; shift
  for p in "$@"; do printf '%s\t%s\n' "$p" "$node"; done \
    | write_index_bin "$(default_work_dir)"
}

@test "stale: namespace belongs to a different remote: exits 1, reports nothing" {
  make_repo "ssh://git@example.com/mine.git"
  write_synapse_index "$(repo_name)" "ssh://git@example.com/SOMEONE-ELSE.git"
  write_node_index 'Foo Node.md' src/foo.aa

  run run_stale
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "stale: no namespace for this repo: exits 1, and says why" {
  make_repo
  run run_stale
  [ "$status" -eq 1 ]
  # Exit 1 already means "could not run", but a mute exit 1 is indistinguishable
  # from a broken install; naming the branch that has no graph is the difference.
  [[ "$output" == *"no namespace covers"* ]]
}

# --- body / sources / field ------------------------------------------------
# `body`/`sources`/`field`'s own logic moved to native coverage --
# `src/apps/synapse/query_cmd.zig`'s own `test` blocks, calling `cmdBody`/
# `cmdSources`/`cmdField`/`writeField`/`cmdFieldFile` directly against a
# fixture vault. `write_fenced_node` stays -- the two `config:` tests below
# still need a real fenced node to read back through the actual CLI.

# A node with a generated fence, real hashes, and Notes content that must never
# leak into `body`.
write_fenced_node() {
  local node="$1"; shift
  mkdir -p "$VAULT/synapse/$(repo_name)"
  {
    echo "---"
    echo "title: \"${node%.md}\""
    echo "node_type: synapse-node"
    echo "project: $(repo_name)"
    echo "sources:"
    local p
    for p in "$@"; do
      echo "  - path: $p"
      echo "    hash: $(git -C "$REPO" hash-object "$p")"
    done
    echo "sources_digest: \"$(expected_digest "$@")\""
    echo "stale: false"
    echo "built_at: \"2026-08-03 16:15\""
    echo "---"
    echo
    echo "# ${node%.md}"
    echo "<!-- synapse:generated:start -->"
    echo
    echo "## Summary"
    echo "Prose that should be printed."
    echo
    echo "## Sources"
    echo "- \`src\` (${#@})"
    echo "<!-- synapse:generated:end -->"
    echo
    echo "## Notes"
    echo "HUMAN NOTES must never appear in body output."
  } > "$VAULT/synapse/$(repo_name)/$node"
}

@test "unknown subcommand and no subcommand both exit 2" {
  make_repo
  run run_query bogus
  [ "$status" -eq 2 ]
  run run_query
  [ "$status" -eq 2 ]
}

# --- static audits ----------------------------------------------------------

@test "every mktemp in the shipped hooks passes an explicit template" {
  # macOS `mktemp`/`mktemp -d` ignore TMPDIR unless given a template, so a bare
  # call writes to the system temp dir whatever the caller asked for. Checked
  # statically because the resulting failure is environment-dependent: it
  # passes on Linux and on any macOS where the system temp dir happens to be
  # writable.
  #
  # npm-pkg/lib/*.sh is empty -- every shipped hook is .cjs (Node's own
  # mktemp equivalents already respect TMPDIR), but the check stays
  # glob-safe rather than being deleted: an unmatched glob left bare would
  # pass its literal, unexpanded pattern to grep, which exits 2 (error)
  # rather than 0 or 1 -- silently defeating the check the moment the
  # directory it globs has nothing matching, exactly the failure mode this
  # test exists to catch in the shipped hooks themselves. `nullglob` makes
  # an empty match an empty array instead, so this test skips cleanly today
  # and starts checking again the moment a `.sh` hook reappears.
  shopt -s nullglob
  local files=("$REPO_ROOT"/npm-pkg/lib/*.sh)
  shopt -u nullglob
  [ "${#files[@]}" -eq 0 ] && skip "no .sh hooks currently shipped"

  run grep -nE 'mktemp( -d)?[[:space:]]*(\)|\||$)' "${files[@]}"
  if [ "$status" -ne 1 ]; then
    echo "bare mktemp (no template), or the audit itself is broken -- grep exit $status:"
    echo "$output"
    false
  fi
}

# `core.conf.vaultDir`'s own synapse.conf/second-brain.conf precedence
# ("vaultDir: synapse.conf wins when both exist", "vaultDir: reads the
# pre-rename second-brain.conf when synapse.conf is absent") moved to native
# coverage in src/core/conf.zig -- a pure function of the two file paths, no
# CLI needed. What stayed there over here previously was only a second proof
# that the value actually reaches this far; the underlying precedence is now
# covered where it lives.
