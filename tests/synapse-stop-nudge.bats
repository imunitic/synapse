#!/usr/bin/env bats
# Tests `synapse-hook stop-nudge`'s vault-push half. It used
# to read $SYNAPSE_HOOK_BIN to find its own path for the detached vault-push
# re-invocation, but settings.json's hook entry never actually sets that
# variable at runtime -- the push was silently a no-op on every real install.
# The fix threads argv[0] down from `main` instead; these tests exercise the
# real spawn and a real (local, no-network) git push to prove it actually
# fires.
#
# Everything else -- push()'s own logic (nothing-to-push, no vault, no .git,
# no upstream, an existing lock, a failed push getting logged) and the
# check-in nudge's turn-counting/re-arming -- moved to native coverage,
# src/apps/hook/stop_nudge.zig's own `test` blocks, called directly rather
# than through a detached self-respawn. These two tests are what remains
# because they are the one thing that can't be: the spawn itself, which only
# a real compiled binary re-invoking itself can prove still works.

load 'test_helper'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# A bare "remote" and a vault repo tracking it, both local paths -- so a push
# here is real git plumbing with no network involved.
seed_vault_with_remote() {
  local remote="$TEST_HOME/vault-remote.git"
  git init -q --bare -b main "$remote"
  git init -q -b main "$VAULT"
  printf 'seed\n' > "$VAULT/seed.md"
  git -C "$VAULT" add seed.md
  git -C "$VAULT" -c user.email=t@e -c user.name=t commit -q -m seed
  git -C "$VAULT" remote add origin "$remote"
  git -C "$VAULT" push -q -u origin main
  echo "$remote"
}

@test "stop-nudge spawns a real vault-push that pushes to a local remote" {
  local remote; remote="$(seed_vault_with_remote)"

  # One more commit the remote does not have yet, so push() finds ahead > 0
  # and actually pushes rather than early-returning "nothing to send".
  printf 'more\n' > "$VAULT/more.md"
  git -C "$VAULT" add more.md
  git -C "$VAULT" -c user.email=t@e -c user.name=t commit -q -m more

  SYNAPSE_VAULT_PUSH_EVERY=1 run bash -c \
    'printf "{\"session_id\":\"s1\"}" | "$1" stop-nudge' _ "$SYNAPSE_HOOK_BIN"
  [ "$status" -eq 0 ]

  # The spawn is detached and stop-nudge does not wait on it, so give the
  # child a bounded window to finish the local push rather than asserting
  # immediately.
  local got=""
  for i in $(seq 1 50); do
    got="$(git -C "$remote" log -1 --format=%s main 2>/dev/null || true)"
    [ "$got" = "more" ] && break
    sleep 0.1
  done
  [ "$got" = "more" ]
}

@test "stop-nudge pushes nothing when the vault is already up to date with its remote" {
  local remote; remote="$(seed_vault_with_remote)"

  SYNAPSE_VAULT_PUSH_EVERY=1 run bash -c \
    'printf "{\"session_id\":\"s2\"}" | "$1" stop-nudge' _ "$SYNAPSE_HOOK_BIN"
  [ "$status" -eq 0 ]

  sleep 0.3
  [ "$(git -C "$remote" log -1 --format=%s main)" = "seed" ]
}
