# Shared setup for bats tests in this directory. Loaded with:
#   load 'test_helper'
#
# Every test gets an isolated $HOME (so hooks/setup.sh never touch the
# real ~/.claude) plus a scratch git repo and a scratch "vault" directory
# standing in for the Obsidian vault. Nothing here touches real Obsidian,
# real git remotes, or the network.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_BIN="$REPO_ROOT/tests/fixtures/fake-bin"

# The binary every test invokes. `synapse-fake` rather
# than `synapse`: the suite has to run without a network, a C toolchain or a
# real grammar repository, and `synapse-fake` is the same app with only the
# grammar compile-and-load step stubbed -- see src/apps/synapse/main_fake.zig.
#
# Overridable because `just test-linux` runs the suite inside a container with
# no Zig in it, so the binary is cross-compiled on the host into a separate
# prefix and named through this variable rather than found by convention.
SYNAPSE_FAKE_BIN="${SYNAPSE_FAKE_BIN:-$REPO_ROOT/zig-out/bin/synapse-fake}"

common_setup() {
  # Checked here rather than left to fail inside a test, because the failure
  # otherwise arrives as an unexplained exit 127 from a shim, in whichever
  # test happened to run first.
  if [ ! -x "$SYNAPSE_FAKE_BIN" ]; then
    echo "missing $SYNAPSE_FAKE_BIN -- run 'zig build fake' (or 'just test', which does)" >&2
    return 1
  fi
  export SYNAPSE_BIN="$SYNAPSE_FAKE_BIN"

  # The hooks are a second binary, and it needs no stub: it links no grammar, so
  # the real one is what a test should exercise. Defaults to the native build for
  # `just test`; `just test-linux` passes a cross-compiled path in.
  SYNAPSE_HOOK_BIN="${SYNAPSE_HOOK_BIN:-$REPO_ROOT/zig-out/bin/synapse-hook}"
  if [ ! -x "$SYNAPSE_HOOK_BIN" ]; then
    echo "missing $SYNAPSE_HOOK_BIN -- run 'zig build' (or 'just test', which does)" >&2
    return 1
  fi
  export SYNAPSE_HOOK_BIN

  # Neutralise an inherited TMPDIR before anything uses it. Whatever launched the
  # suite decides this, and an editor-hosted terminal routinely points it
  # somewhere surprising -- Emacs sets it to ~/.emacs.d/var/tmp, which is *inside
  # a git repo*, so every scratch directory resolved to that repo and any test
  # asserting "this is not a git repo" passed for the wrong reason. Fixing the
  # source beats defending against it in each test.
  #
  # /tmp preferred, the inherited value kept only if /tmp is unusable -- which is
  # the case the original explicit-template comment was protecting, and is why
  # this is a preference rather than a hardcoding.
  if [ -d /tmp ] && [ -w /tmp ]; then
    export TMPDIR=/tmp
  fi

  # Explicit template for the same reason the shipped scripts use one: macOS
  # `mktemp -d` with no template ignores TMPDIR entirely.
  TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/synapse-test.XXXXXX")"
  VAULT="$TEST_HOME/vault"
  REPO="$TEST_HOME/repo"
  # One mkdir -p for every directory this function needs -- `mkdir -p` creates
  # missing parents on its own.
  mkdir -p "$TEST_HOME/.claude" "$VAULT"

  # Captured before the swap. Only for tests that must reach a real, machine-wide
  # cache they cannot reasonably fake -- currently just puppeteer's Chromium, which
  # mermaid-cli needs and which lives under the real $HOME. Never a general escape
  # hatch: everything else belongs inside $TEST_HOME.
  export REAL_HOME="$HOME"

  export HOME="$TEST_HOME"
  export ORIGINAL_HOME_UNUSED=1 # documents that $HOME is intentionally swapped for the test

  # Stop git's repo discovery from ascending out of the scratch dir. Needed
  # because $TMPDIR is honoured above, and a TMPDIR that happens to live inside
  # a git repo (e.g. ~/.emacs.d/var/tmp) makes every scratch directory look like
  # part of that repo -- so a test asserting "this is not a git repo" passes or
  # fails depending on the machine.
  #
  # The ceiling is $TEST_HOME's *parent*, not $TEST_HOME. Git stops before
  # *entering* a directory on this list, so listing $TEST_HOME does not stop a
  # walk that starts at $TEST_HOME: it examines $TEST_HOME, then ascends to an
  # unlisted parent and keeps going. Listing the parent is what actually halts
  # it. Discovery from inside $REPO still finds $REPO/.git first, so the scratch
  # repo is unaffected either way.
  export GIT_CEILING_DIRECTORIES="$(dirname "$TEST_HOME")"

  # Bash builtins (read, printf), not a `cat > file <<EOF` -- a heredoc piped
  # into cat is one more fork this function does not need for two lines of
  # static-shaped text.
  read -r -d '' _synapse_conf <<EOF || true
SYNAPSE_VAULT_DIR="$VAULT"
EOF
  printf '%s\n' "$_synapse_conf" > "$HOME/.claude/synapse.conf"

  # Seeded from the shipped template so tests exercise the real default
  # boilerplate list, not a hand-copied duplicate that could drift from it.
  cp "$REPO_ROOT/packages/synapse/synapse-module-boilerplate.conf.template" \
    "$HOME/.claude/synapse-module-boilerplate.conf"

  # Nothing to install here any more. Every test invokes `$SYNAPSE_BIN` or
  # `$SYNAPSE_HOOK_BIN` directly, so there is no shell library to place at
  # $HOME/.claude/lib/synapse/ and no dispatcher to find -- which also removes the
  # class of failure this block existed to prevent, where a test failed on a
  # missing callee rather than on anything it was about.
}

# In-place sed that works on both BSD and GNU. `sed -i ''` is BSD-only (GNU reads
# the empty string as a filename) and `sed -i` with no arg is GNU-only, so the
# suite avoids -i altogether: edit to a temp file, then move it back.
sed_i() { # sed_i <expression> <file>
  local expr="$1" file="$2"
  sed -e "$expr" "$file" > "$file.sed_i" && mv "$file.sed_i" "$file"
}

# sha256 of stdin, portable across macOS (shasum) and Linux (sha256sum). The
# tests compute expected digests independently of the scripts under test, so they
# need their own copy of this rather than sourcing one -- a shared implementation
# would let a wrong formula agree with itself.
sha256_stdin() {
  if command -v shasum >/dev/null; then shasum -a 256 | cut -d' ' -f1
  else sha256sum | cut -d' ' -f1; fi
}

common_teardown() {
  [ -n "${TEST_HOME:-}" ] && [ -d "$TEST_HOME" ] && rm -rf "$TEST_HOME"
}

# Writes a minimal vault Index.md (the Synapse Vault index note itself, not
# a Synapse per-project index) -- just enough for the SessionStart hook to
# have something to inject.
write_vault_index() {
  cat > "$VAULT/Index.md" <<'EOF'
---
title: "Index"
---
# Index
Test index content.
EOF
}

# Builds the one-tracked-file template make_repo() copies from, if no other
# test process has already published one. `git init`+`add`+`commit` measured
# 2.4x the cost of copying a prebuilt template (54ms vs 22ms/call) -- most of
# it fork overhead, not git's own work, so every caller of make_repo() pays it
# once here instead of once per test.
#
# Built in a scratch dir and published with a plain `mv`, not written directly
# at the template path: under `bats --jobs`, many test processes race to be
# the first to want it, and `mv` between two dirs on the same filesystem is a
# single rename -- either this process's build wins and lands whole, or it
# loses to one that got there first and is discarded, but no reader ever sees
# a half-built template.
# The trailing -v1 is a manual cache-buster: bump it if this function's
# tracked file, its content, or the commit message ever change, so a stale
# /tmp survivor from a previous session can never silently diverge from what
# make_repo()'s callers assert against.
_repo_template_dir() { echo "${TMPDIR:-/tmp}/synapse-test-repo-template-v2"; }

_ensure_repo_template() {
  local tmpl; tmpl="$(_repo_template_dir)"
  [ -d "$tmpl/.git" ] && return 0
  local build; build="$(mktemp -d "${TMPDIR:-/tmp}/synapse-repo-template-build.XXXXXX")"
  mkdir -p "$build/src"
  git init -q "$build"
  printf 'let x = 1\n' > "$build/src/foo.aa"
  git -C "$build" add src/foo.aa
  git -C "$build" -c user.email=test@test -c user.name=test commit -q -m init
  mv -n "$build" "$tmpl" 2>/dev/null || rm -rf "$build"
}

# Creates a throwaway git repo at $REPO with one tracked file, and
# optionally a remote (local git config only -- never actually fetched
# from or pushed to). The tracked file, its content and the init commit
# message must stay byte-identical to what this used to build inline --
# some tests assert against them directly.
make_repo() {
  local remote="${1:-}"
  _ensure_repo_template
  cp -R "$(_repo_template_dir)" "$REPO"
  if [ -n "$remote" ]; then
    git -C "$REPO" remote add origin "$remote"
  fi
}

# The namespace directory name for $REPO -- "{repo}@{branch}", not a bare repo
# name. Kept under the old name because fourteen test files build vault and
# work-dir paths through it, and the point is that they keep doing so: a test
# that hardcoded the key instead would pass while the components disagreed.
#
# Deliberately delegates to the shipped resolver rather than reimplementing the
# derivation. A test helper with its own copy of the rule could agree with a
# wrong implementation -- the same reasoning that keeps `sources_digest` out of
# the helpers and recomputed in Python instead. The resolver used to be a sourced
# shell library; it is `synapse namespace` now, which exists for this and for a
# person debugging an install.
repo_name() {
  "$SYNAPSE_BIN" namespace --repo "$REPO"
}

# The two halves of the namespace key, for assertions against the `project:` and
# `branch:` fields the writers record separately. Derived from repo_name() rather
# than recomputed, so all three answers come from the one shipped resolver.
ns_repo() {
  local ns; ns="$(repo_name)"
  printf '%s' "${ns%@*}"
}

ns_branch() {
  local ns; ns="$(repo_name)"
  printf '%s' "${ns##*@}"
}

repo_remote_or_path() {
  # Falls back to the git-resolved repo root, not the raw $REPO variable --
  # git rev-parse --show-toplevel resolves symlinks (e.g. macOS /tmp ->
  # /private/tmp), and that's what both the hook and /synapse-init actually
  # compare against.
  git -C "$REPO" remote get-url origin 2>/dev/null || git -C "$REPO" rev-parse --show-toplevel
}

# Fakes just enough of the Obsidian Local REST API plugin's on-disk state
# for synapse-staleness.sh to get past its own existence checks: the
# plugin's data.json (apiKey + port) and a stand-in cert file. Actual HTTP
# calls are intercepted by tests/fixtures/fake-bin/curl (prepended onto
# PATH by run_staleness_hook below), so the port/key values themselves are
# never really dialed.
setup_fake_obsidian_plugin() {
  mkdir -p "$VAULT/.obsidian/plugins/obsidian-local-rest-api"
  cat > "$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json" <<'EOF'
{"apiKey": "test-api-key", "port": 27124}
EOF
  : > "$HOME/.claude/obsidian-local-rest-api-ca.pem"
}

# Writes a work dir's `_index.bin` from `path<TAB>node` lines on stdin, with any
# remaining arguments as the unassigned list.
#
# Delegates to the shipped `synapse index build` rather than authoring the bytes,
# for the reason repo_name() delegates to the shipped resolver: a helper with its
# own encoder could agree with a wrong one. It also means every test that stages
# an index exercises the same writer the pipeline uses.
#
# This replaced hand-authored `_index.json` fixtures in eight test files. Those
# could be written with printf because the format was text; a binary index cannot
# be, and pretending otherwise by committing fixture bytes would pin the format
# in places that are not about the format.
write_index_bin() { # write_index_bin <work-dir> [unassigned-path...] < pairs
  local work="$1"; shift
  mkdir -p "$work"
  local un="$work/.unassigned-fixture"
  if [ "$#" -gt 0 ]; then printf '%s\n' "$@" > "$un"; else : > "$un"; fi
  # Stdout silenced: the writer reports keys/unassigned/bytes for
  # synapse-build-index.sh to pass through, and a fixture helper that printed it
  # would land those numbers inside any `run` capture around the caller -- in
  # front of the output the test is actually asserting on.
  "$SYNAPSE_BIN" index build --unassigned "$un" --out "$work/_index.bin" >/dev/null || return 1
  rm -f "$un"
}

# The work dir every component defaults to for $REPO's namespace, so a test can
# stage an index where the scripts will look for it without exporting anything.
default_work_dir() {
  printf '%s' "$HOME/.cache/synapse/work/$(repo_name)"
}

# Writes a Synapse per-project Index.md with the given `remote` frontmatter
# value, matching the shape /synapse-init produces. The first argument is the
# namespace directory name ("{repo}@{branch}"); `project` and `branch` inside are
# the two halves separately, which is how the real builder writes them.
#
# `branch` is not optional decoration: every component treats an index with no
# branch field as a mismatch, so a fixture without one would make each of them
# refuse and the test would pass or fail for the wrong reason.
write_synapse_index() {
  local project="$1" remote="$2"
  local branch; branch="$("$SYNAPSE_BIN" namespace --repo "$REPO" --branch)"
  mkdir -p "$VAULT/synapse/$project"
  cat > "$VAULT/synapse/$project/Index.md" <<EOF
---
title: "$project — Synapse index"
node_type: synapse-index
project: ${project%@*}
branch: $branch
remote: "$remote"
built_at: "test"
---
# $project — Synapse index
EOF
}
