#!/usr/bin/env bats
# Tests claude/hooks/synapse-session-start.sh -- both the pre-existing
# index-injection behavior and the Synapse pointer check.
# Everything but the cross-file consistency guard below moved to native
# coverage -- src/apps/hook/session_start.zig's own `test` blocks, via the
# `build()` entry point `run()` delegates to after reading the stdin
# payload.

load 'test_helper'


setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "the stop-nudge hook cites a CLAUDE.md heading that actually exists" {
  # The nudge text points the reader at a section of the global CLAUDE.md by name.
  # Renaming the heading without the hook (or the reverse) leaves a pointer to a
  # section that is not there, and nothing about reading the nudge would reveal it
  # -- the whole failure is silent. This caught nothing when written; it exists so
  # the next rename cannot break the pair. The heading itself lives in
  # synapse-claude.md, imported into CLAUDE.md rather than shipped inline -- see
  # setup.sh's "CLAUDE.md / synapse-claude.md" section -- but reads as "the global
  # CLAUDE.md" from the hook's and the reader's point of view either way.
  # The text lives in the hook binary now, not in the wrapper -- the check follows
  # it rather than lapsing, because what it protects is the pair (nudge text,
  # heading) and not the file either half happens to sit in. Unrelated to
  # session-start's own logic -- co-located here for lack of a better home,
  # not because it exercises anything this file does.
  local nudge="$REPO_ROOT/src/apps/hook/stop_nudge.zig"
  local cited
  cited="$(grep -o 'CLAUDE.md \\"[^\\]*\\" section' "$nudge" | sed -e 's/.*\\"\(.*\)\\" section/\1/')"
  [ -n "$cited" ]
  grep -qxF "# $cited" "$REPO_ROOT/npm-pkg/synapse-claude.md"
}
