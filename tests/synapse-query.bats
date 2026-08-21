#!/usr/bin/env bats
# Tests claude/lib/synapse/synapse-query.sh. The `stale` subcommand is the Tier 2 batch
# staleness verification that used to live in synapse-verify.sh.
# The Obsidian Local REST API is stubbed by tests/fixtures/fake-bin/curl,
# which serves and writes real files under $FAKE_CURL_VAULT_DIR -- so these
# tests exercise the script's actual digest arithmetic against real git
# objects, not a mock of it.
#
# The expected digest is computed independently in python rather than by
# reusing the script's own formula, so a change to either implementation
# fails the test instead of silently agreeing with itself.
#
# `stale`'s own detection logic (unchanged/changed/deleted/missing-digest/
# node-missing) moved to native coverage -- `src/apps/synapse/query_cmd.zig`'s
# own `test` blocks, calling `cmdStale` directly against a fixture vault and
# a real `_index.bin` built through `core.index_map.build`. What's left here
# are the three genuinely process-level cases: the shared remote-mismatch/
# no-namespace preamble every `query` subcommand gates on, and running
# outside a git repo entirely.

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
# trailing newline -- computed independently of the script under test.
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
# maps to one node, which is what these tests need; a path with two claimants is
# synapse-build-index.bats's case.
write_node_index() { # write_node_index <node.md> <path>...
  local node="$1" p; shift
  for p in "$@"; do printf '%s\t%s\n' "$p" "$node"; done \
    | write_index_bin "$(default_work_dir)"
}

@test "stale: namespace belongs to a different remote: exits 1, reports nothing" {
  make_repo "ssh://git@example.com/mine.git"
  write_synapse_index "$(repo_name)" "ssh://git@example.com/SOMEONE-ELSE.git"
  write_node_index 'Foo Node.md' src/foo.ml

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

@test "stale: not inside a git repo: exits 1" {
  mkdir -p "$TEST_HOME/plain"
  run bash -c 'cd "$1" && PATH="$2:$PATH" FAKE_CURL_LOG="$3" FAKE_CURL_VAULT_DIR="$4" exec "$5" "$6" stale' \
    _ "$TEST_HOME/plain" "$FAKE_BIN" "$CURL_LOG" "$VAULT" "$SYNAPSE_BIN" query
  [ "$status" -eq 1 ]
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

@test "field --file: a missing path or key is a usage error" {
  mkdir -p "$REPO"
  printf -- '---\nsummary: "x"\n---\n' > "$REPO/b-01.md"

  run run_query field --file
  [ "$status" -eq 2 ]
  run run_query field --file b-01.md
  [ "$status" -eq 2 ]
}

@test "unknown subcommand and no subcommand both exit 2" {
  make_repo
  run run_query bogus
  [ "$status" -eq 2 ]
  run run_query
  [ "$status" -eq 2 ]
}

# --- temp-dir handling -----------------------------------------------------

@test "an unusable TMPDIR is not fatal, because nothing needs a temp dir" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_fenced_node "Foo Node.md" "src/foo.ml"
  printf 'src/foo.ml\tFoo Node.md\n' | write_index_bin "$(default_work_dir)"

  # This used to assert the opposite, and the inversion is the point. The script
  # ran without `set -e` -- its exit codes are answers, not failures -- so a
  # failed `mktemp -d` left $WORK empty and every path under it resolving against
  # `/`; the guarantee then was that it died instead. `synapse query` writes no
  # intermediate files at all, so there is no temp dir to fail and the whole class
  # of failure is gone rather than handled.
  run env TMPDIR="$TEST_HOME/definitely-not-here" \
    PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" query stale
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every mktemp in the shipped scripts passes an explicit template" {
  # macOS `mktemp`/`mktemp -d` ignore TMPDIR unless given a template, so a bare
  # call writes to the system temp dir whatever the caller asked for. Checked
  # statically because the resulting failure is environment-dependent: it passes
  # on Linux and on any macOS where the system temp dir happens to be writable.
  # Hooks and lib/synapse as well as bin: the first version of this check
  # globbed only claude/bin and missed a bare mktemp in synapse-staleness.sh
  # for exactly that reason -- the plumbing scripts live in claude/lib/synapse/
  # now, and claude/bin/ holds only the synapse.sh porcelain, so both need
  # covering for the same reason the hooks did.
  run grep -nE 'mktemp( -d)?[[:space:]]*(\)|\||$)' \
    "$REPO_ROOT"/plugins/synapse/bin/*.sh "$REPO_ROOT"/plugins/synapse/lib/synapse/*.sh "$REPO_ROOT"/plugins/synapse/hooks/*.sh
  if [ "$status" -eq 0 ]; then
    echo "bare mktemp (no template) found:"
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
