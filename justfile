# Task runner for this repo. The recipes here mirror .github/workflows/tests.yml
# deliberately: the point is that "green locally" and "green in CI" cannot mean
# different things. If you change the gate, change it in both places.
#
#   just            list the recipes
#   just check      the full gate -- run this before committing
#   just test       the suite, parallel
#   just fix        regenerate whatever `check` verifies
#   just test-linux the full suite under Linux/Podman -- the default full run
#   just ci-local   what CI actually runs, locally, via act -- before pushing
#
# Note on comments below: `just --list` shows the comment line immediately above a
# recipe, so each one gets a single short line there and any longer explanation
# goes above a blank line, where the listing will not pick it up.

set shell := ["bash", "-uc"]

_default:
    @just --list --unsorted

# --jobs parallelises within each file as well as across them, which is where the
# win is: one file is a quarter of the suite, so across-files-only would leave it
# as the critical path. Measured on 12 cores: 2m37s against roughly 5m serial.
#
# The `parallel` guard is why this is a recipe rather than a README line. `bats
# --jobs` shells out to GNU parallel and, when it is missing, does not fail -- it
# silently runs serially and produces an identical-looking log. A silent 2x is
# exactly what nobody notices, so here it is an error.

# Run the suite in parallel; pass file paths to narrow it.
test *FILES:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v parallel >/dev/null; then
        echo "GNU parallel not on PATH -- 'bats --jobs' would silently run serially." >&2
        echo "  macOS: brew install parallel      Debian/Ubuntu: apt-get install parallel" >&2
        exit 1
    fi
    targets="{{ FILES }}"
    [ -n "$targets" ] || targets="tests/"
    bats --jobs "$(getconf _NPROCESSORS_ONLN)" $targets

# Run the suite serially, for unreadable parallel failures or a missing parallel.
test-serial *FILES:
    bats {{ if FILES == "" { "tests/" } else { FILES } }}

# THIS IS FOR THE INNER LOOP, NOT A SUBSTITUTE FOR `just check`. It runs the tests
# that name the files you give it, and coverage by grep is a lower bound: a test can
# exercise a script without ever spelling its path, through an installed copy that
# another script invokes. So this narrows, it does not verify. Commit behind
# `just check`, always.
#
# `setup.bats` is the one always-run file: it is cheap and it catches the install
# breaking, which nothing else would. `synapse-pipeline` and
# `synapse-rebuild-scenario` were also in this set and have been taken out, on
# measurement -- they are 12 tests but 21% of the suite's CPU, and
# rebuild-scenario's slowest single test is 50s, so together they were 35s of a 42s
# narrowed run. Keeping them made the inner loop 6x slower to re-cover ground
# `check` covers anyway, which is a bad trade for a loop whose whole value is being
# fast enough to actually run.
#
# Groups are derived rather than listed on purpose. A hand-maintained group list is
# one more thing that silently stops matching reality, and the coupling here is dense
# enough to guarantee it: synapse-tags.sh alone is exercised by seven files.

# Run only the tests covering the given source files, plus the integration ones.
test-for +PATHS:
    #!/usr/bin/env bash
    set -euo pipefail
    always="tests/setup.bats"
    picked=""
    for p in {{ PATHS }}; do
        b="$(basename "$p")"
        # A test file given directly is itself the target.
        case "$p" in tests/*.bats) picked="$picked $p"; continue ;; esac
        hits="$(grep -l -- "$b" tests/*.bats 2>/dev/null || true)"
        [ -n "$hits" ] || echo "no test names '$b' -- relying on the integration files" >&2
        picked="$picked $hits"
    done
    files="$(printf '%s %s' "$picked" "$always" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
    echo "running: $(printf '%s' "$files" | wc -w | tr -d ' ') files" >&2
    just test $files

# Same, for whatever you have changed against the upstream branch.
test-changed:
    #!/usr/bin/env bash
    set -euo pipefail
    changed="$(git diff --name-only @{u}.. 2>/dev/null; git diff --name-only; git diff --name-only --cached)"
    changed="$(printf '%s' "$changed" | sort -u | grep -v '^$' || true)"
    if [ -z "$changed" ]; then echo "nothing changed"; exit 0; fi
    echo "changed:"; printf '  %s\n' $changed
    just test-for $changed

# The suite is fork/exec-bound, and macOS pays a real tax on every process
# spawn (Gatekeeper/codesign checks, sandbox policy evaluation) that Linux does
# not -- measured on this machine at 318s of user+sys CPU time running the
# suite natively on macOS against 94s for the identical suite in this
# container, same 8 cores. `test-linux` is the default way to run the full
# suite from here on, not `just test` against the host directly.
#
# ci/Containerfile bakes in this repo's CI dependencies (see
# .github/workflows/tests.yml) once; the worktree itself is bind-mounted, not
# copied in, so code changes need no rebuild -- only a change to the
# Containerfile does, and `podman build` no-ops when it sees none.

# Build/refresh the Linux test image and make sure Podman is up.
_podman-ready:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v podman >/dev/null || { echo "podman not on PATH -- brew install podman" >&2; exit 1; }
    podman machine init --cpus 8 --memory 8192 >/dev/null 2>&1 || true
    podman machine start >/dev/null 2>&1 || true
    podman build -q -t synapse-test -f ci/Containerfile ci >/dev/null

# Full suite under Linux/Podman -- the default full-suite run, not `just test`.
test-linux: _podman-ready
    podman run --rm -v "$(pwd):/repo:Z" -w /repo synapse-test \
      bats --jobs "$(getconf _NPROCESSORS_ONLN)" tests/

# Needs `brew install act` once -- podman-ready's Podman machine is reused.
# Tests committed HEAD, same as a real push would -- see the recipe body for
# why (a worktree's own .git is a pointer act cannot resolve on its own).

# What CI actually runs, locally, via act -- the pre-push check.
ci-local: _podman-ready
    #!/usr/bin/env bash
    set -euo pipefail
    command -v act >/dev/null || { echo "act not on PATH -- brew install act" >&2; exit 1; }
    # A linked worktree's `.git` is a pointer file to the main checkout's
    # `.git/worktrees/...`, a path outside the worktree itself -- act's
    # checkout step (a plain copy of the working directory, not a real clone)
    # carries that dangling pointer in, and every git command then fails with
    # "not a git repository: (null)", even `git config --global`. Cloning
    # into a scratch dir first sidesteps it with a real, standalone .git --
    # and only tests committed HEAD while doing so, which is what a real push
    # would test too.
    clone="$(mktemp -d "${TMPDIR:-/tmp}/synapse-ci-local.XXXXXX")"
    trap 'rm -rf "$clone"' EXIT
    git clone --local --quiet . "$clone"
    # act itself (a macOS binary) needs the host-forwarded socket to talk to
    # Podman at all -- but that same path is not a real path inside the
    # machine's own filesystem, so act bind-mounting it into every job
    # container (its default, for actions that themselves shell out to
    # Docker) fails outright. This workflow never touches Docker from inside
    # a step, so the fix is disabling that bind-mount rather than chasing a
    # path valid on both sides at once: `-` per act's own docs.
    sock="$(podman machine inspect | jq -r '.[0].ConnectionInfo.PodmanSocket.Path')"
    (cd "$clone" && DOCKER_HOST="unix://$sock" act -j bats --container-daemon-socket - \
      -P ubuntu-latest=catthehacker/ubuntu:act-latest)

# Catches the class of typo that only surfaces when a rarely-taken branch runs --
# an unbalanced quote inside an awk program embedded in a heredoc, say.

# Parse-check every shipped script without executing it.
syntax:
    #!/usr/bin/env bash
    set -euo pipefail
    n=0
    for f in claude/bin/*.sh claude/lib/synapse/*.sh claude/hooks/*.sh docs/*.sh setup.sh setup-obsidian-mcp.sh; do
        [ -f "$f" ] || continue
        bash -n "$f"
        n=$((n + 1))
    done
    echo "syntax ok: $n scripts"

# Verify, never regenerate: a `check` that quietly fixes what it is checking
# cannot fail, and the point is to catch a script edit committed without the
# regeneration that follows from it.

# Verify docs/scripts.md and the rendered diagrams match their sources.
docs-check:
    ./docs/generate-scripts-reference.sh --check
    ./docs/generate-diagrams.sh --check

# Regenerate both generated artefacts; diagrams need mermaid-cli and its Chromium.
fix:
    ./docs/generate-scripts-reference.sh
    ./docs/generate-diagrams.sh

# The same three things CI runs, in the same order, plus a syntax pass CI gets for
# free by executing the scripts.

# The full gate -- run before every commit.
check: syntax test docs-check
    @echo "all green"

# Several scripts shell out to the *installed* copy rather than the repo one, so
# an unsynced ~/.claude means testing a mix of old and new.

# Install into ~/.claude the way a user would.
install:
    ./setup.sh

# Show what changed against the pushed branch.
diff:
    @git --no-pager diff --stat @{u}.. 2>/dev/null || git --no-pager diff --stat
