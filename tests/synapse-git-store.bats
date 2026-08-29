#!/usr/bin/env bats
# Tests GitStore's own detached Pusher spawn (SYNAPSE_VAULT_INTEGRATIONS=git) -- the
# one thing that can't move to native coverage: src/adapters/git/store.zig's
# own `test` blocks call `runPusher` directly, never through a real
# self-respawn, so nothing there proves `vault-write` actually spawns
# `synapse vault-git-pusher` as a detached child and that it fires a real
# push. These two tests are what a real compiled binary re-invoking itself
# is needed for.
#
# Everything else -- write()'s commit-or-skip under lock contention, the
# lock's own staleness recovery, a repo with no upstream never spawning --
# is native coverage already, src/adapters/git_sync.zig's and
# src/adapters/git/store.zig's own `test` blocks.

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
  git -C "$VAULT" remote add origin "$remote"
  printf 'seed\n' > "$VAULT/seed.md"
  git -C "$VAULT" add seed.md
  git -C "$VAULT" -c user.email=t@e -c user.name=t commit -q -m seed
  git -C "$VAULT" push -q -u origin main
  echo "$remote"
}

@test "vault-write under SYNAPSE_VAULT_INTEGRATIONS=git spawns a real Pusher that pushes to a local remote" {
  local remote; remote="$(seed_vault_with_remote)"

  SYNAPSE_VAULT_INTEGRATIONS=git SYNAPSE_VAULT_PUSH_EVERY=1 run bash -c \
    'printf "more\n" | "$1" vault-write more.md' _ "$SYNAPSE_BIN"
  [ "$status" -eq 0 ]

  # The Pusher is detached and write() does not wait on it, so give the
  # child a bounded window to finish the local push rather than asserting
  # immediately.
  local got=""
  for i in $(seq 1 50); do
    got="$(git -C "$remote" log -1 --format=%s main 2>/dev/null || true)"
    [ "$got" = "vault: more.md" ] && break
    sleep 0.1
  done
  [ "$got" = "vault: more.md" ]
}

@test "vault-write under SYNAPSE_VAULT_INTEGRATIONS=git commits but spawns no Pusher below the push-every threshold" {
  local remote; remote="$(seed_vault_with_remote)"

  SYNAPSE_VAULT_INTEGRATIONS=git SYNAPSE_VAULT_PUSH_EVERY=5 run bash -c \
    'printf "more\n" | "$1" vault-write more.md' _ "$SYNAPSE_BIN"
  [ "$status" -eq 0 ]

  # The commit lands locally either way; only the push is threshold-gated.
  [ "$(git -C "$VAULT" log -1 --format=%s)" = "vault: more.md" ]

  sleep 0.3
  [ "$(git -C "$remote" log -1 --format=%s main)" = "seed" ]
}
