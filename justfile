# Task runner for this repo. The recipes here mirror .github/workflows/tests.yml
# deliberately: the point is that "green locally" and "green in CI" cannot mean
# different things. If you change the gate, change it in both places.
#
#   just              list the recipes
#   just test-changed the tests covering what you changed -- the per-commit run
#   just test-linux   the whole suite in the container, ~30s -- for a broad change
#   just check        the full gate -- before PUSHING, not before every commit
#   just fix          regenerate whatever `check` verifies
#   just ci-local     what CI actually runs, locally, via act
#
# WHAT TO RUN WHEN. The gate is cheap now (26s measured, warm) but it is still not the
# answer to every change, and reaching for it reflexively trains the habit of not
# thinking about what a change can actually break:
#
#   changed a .zig file         just test-changed
#   changed a hook               just test-for <the file>
#   changed docs/ or README     nothing -- prose has no test to fail
#   changed plugins/*/**/*.md   just test tests/legacy-commands.bats
#   changed a lot, or unsure    just test-linux
#   about to push               just check
#
# Two of those deserve their reason stated. Shipped instructions under `plugins/*/`
# LOOK like documentation and are not: they install into ~/.claude and are covered
# by tests, which is how a skill telling Claude to run a command that does not exist
# got caught. And each project's `cli.md` plus the rendered diagrams are generated, so
# editing what they are generated *from* means `just fix`, not `just docs-check`.
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

# The binary the suite actually runs -- `synapse tags` with the grammar
# compile-and-load step stubbed, standing in for the fake `tree-sitter` that
# linking libtree-sitter retired. A dependency of every bats recipe rather than
# a note in the README: `zig build` is a no-op when nothing changed, and the
# failure mode it prevents is a suite silently testing yesterday's binary.
_fake:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v zig >/dev/null || { echo "zig not on PATH -- brew install zig" >&2; exit 1; }
    zig build fake

# Run the suite in parallel; pass file paths to narrow it.
test *FILES: _fake
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
test-serial *FILES: _fake
    bats {{ if FILES == "" { "tests/" } else { FILES } }}

# THE PER-COMMIT RUN. It runs the tests that name the files you give it, and coverage
# by grep is a lower bound: a test can exercise a script without ever spelling its
# path, through an installed copy that another script invokes. So this narrows, it
# does not verify -- which is the right trade for a commit and the wrong one for a
# push, where `just check` covers what this cannot see.
#
# No always-run file anymore. `setup.bats` used to fill that role -- cheap, and
# it caught the install breaking, which nothing else did -- but installing is
# now Claude Code's own job (marketplace add / plugin install), not a script
# this repo ships and can unit-test cheaply. What actually verifies the
# plugin install path is the sb-019 podman-style end-to-end test, run by hand
# when the install mechanics themselves change, not on every commit.
# `synapse-pipeline` and `synapse-rebuild-scenario` were also once in this set
# and have been taken out, on measurement -- they are 12 tests but 21% of the
# suite's CPU, and rebuild-scenario's slowest single test is 50s, so together
# they were 35s of a 42s narrowed run. Keeping them made the inner loop 6x
# slower to re-cover ground `check` covers anyway, which is a bad trade for a
# loop whose whole value is being fast enough to actually run.
#
# Groups are derived rather than listed on purpose. A hand-maintained group list is
# one more thing that silently stops matching reality, and the coupling here is dense
# enough to guarantee it: synapse tags alone is exercised by seven files.

# Run only the tests covering the given source files, plus the integration ones.
test-for +PATHS:
    #!/usr/bin/env bash
    set -euo pipefail
    picked=""
    for p in {{ PATHS }}; do
        b="$(basename "$p")"
        # A test file given directly is itself the target.
        case "$p" in tests/*.bats) picked="$picked $p"; continue ;; esac
        hits="$(grep -l -- "$b" tests/*.bats 2>/dev/null || true)"
        [ -n "$hits" ] || echo "no test names '$b' -- relying on the integration files" >&2
        picked="$picked $hits"
    done
    files="$(printf '%s' "$picked" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
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

# Every podman call below names its connection explicitly, and nothing here
# changes which connection is default or reconfigures an existing machine --
# both belong to whoever owns the box, not to this repo. The default
# connection is not reliably a local machine: on a box that also talks to a
# remote engine over SSH it points there, and an unqualified `podman
# build`/`podman run` then builds the image on that host and bind-mounts a
# /repo path that does not exist on it. `podman machine init` is reached for
# the same reason only when there is no machine at all -- against an existing
# one it would either fail outright or, under a fresh name, take the default
# connection with it. Set CONTAINER_CONNECTION to override the choice.

# Echo the Podman machine the Linux recipes use; init one only if none exists.
_podman-machine:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v podman >/dev/null || { echo "podman not on PATH -- brew install podman" >&2; exit 1; }
    if [ -n "${CONTAINER_CONNECTION:-}" ]; then echo "$CONTAINER_CONNECTION"; exit 0; fi
    # `-q` marks the default machine with a trailing `*` -- strip it, or
    # every `--connection` lookup downstream fails on the decorated name.
    machines="$(podman machine list -q | sed 's/\*$//')"
    if [ -z "$machines" ]; then
        podman machine init --cpus 8 --memory 8192 >/dev/null
        echo podman-machine-default
    elif [ "$(printf '%s\n' "$machines" | wc -l)" -eq 1 ]; then
        printf '%s\n' "$machines"
    elif printf '%s\n' "$machines" | grep -qx podman-machine-default; then
        echo podman-machine-default
    else
        echo "several Podman machines, none of them podman-machine-default --" >&2
        echo "pick one with CONTAINER_CONNECTION=<name>:" >&2
        printf '%s\n' "$machines" | sed 's/^/  /' >&2
        exit 1
    fi

# The recipes below invoke `_podman-ready` from their own body, passing the
# machine they already resolved, rather than declaring it as a `:` dependency:
# a just dependency can only be given arguments that are just expressions, not
# a value computed by the recipe's shell, so a dependency would have to resolve
# the machine a second time -- a second `podman machine list`, and a second
# chance to disagree with the name the recipe itself goes on to use.

# Build/refresh the Linux test image and make sure that machine is up.
_podman-ready MACHINE="":
    #!/usr/bin/env bash
    set -euo pipefail
    machine="{{ MACHINE }}"
    [ -n "$machine" ] || machine="$(just _podman-machine)"
    podman machine start "$machine" >/dev/null 2>&1 || true
    podman --connection "$machine" info >/dev/null 2>&1 || {
        echo "podman connection '$machine' is not reachable -- 'podman machine start $machine'" >&2
        exit 1
    }
    podman --connection "$machine" build -q -t synapse-test -f ci/Containerfile ci >/dev/null

# Full suite under Linux/Podman -- the default full-suite run, not `just test`.
test-linux:
    #!/usr/bin/env bash
    set -euo pipefail
    machine="$(just _podman-machine)"
    just _podman-ready "$machine"
    # The container has no Zig in it, and the host's native `synapse-fake` is a
    # macOS binary. Cross-compile a Linux one into its own prefix -- under
    # zig-out/ so .gitignore already covers it, and separate so it never
    # overwrites the native build a `just test` on the host would then run.
    command -v zig >/dev/null || { echo "zig not on PATH -- brew install zig" >&2; exit 1; }
    zig build fake -Dtarget=x86_64-linux --prefix zig-out/linux
    # The hook binary needs no stub -- it links no grammar -- but it does need to
    # be a Linux binary, so it is cross-compiled the same way. `install` rather
    # than `fake`, since that step is what carries it.
    zig build -Dtarget=x86_64-linux --prefix zig-out/linux
    podman --connection "$machine" run --rm -v "$(pwd):/repo:Z" -w /repo \
      -e SYNAPSE_FAKE_BIN=/repo/zig-out/linux/bin/synapse-fake \
      -e SYNAPSE_HOOK_BIN=/repo/zig-out/linux/bin/synapse-hook synapse-test \
      bats --jobs "$(getconf _NPROCESSORS_ONLN)" tests/

# Needs `brew install act` once -- podman-ready's Podman machine is reused.
# Tests committed HEAD, same as a real push would -- see the recipe body for
# why (a worktree's own .git is a pointer act cannot resolve on its own).
# Scoped to tests.yml (-W, not -j -- act's -j takes one job ID, not a list)
# so both its jobs (zig, bats) run without also pulling in release.yml.

# What CI actually runs, locally, via act -- the pre-push check.
ci-local:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v act >/dev/null || { echo "act not on PATH -- brew install act" >&2; exit 1; }
    machine="$(just _podman-machine)"
    just _podman-ready "$machine"
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
    sock="$(podman machine inspect "$machine" | jq -r '.[0].ConnectionInfo.PodmanSocket.Path')"
    (cd "$clone" && DOCKER_HOST="unix://$sock" act -W .github/workflows/tests.yml --container-daemon-socket - \
      -P ubuntu-latest=catthehacker/ubuntu:act-latest)

# `just` stays the task runner and calls `zig build`, never the other way round:
# the gate also has to launch bats, podman, act and mermaid-cli, none of which
# `std.Build.Step.Run` would express better than a recipe does.
#
# No version guard here beyond the `command -v`. `build.zig.zon` pins
# `minimum_zig_version`, so an old toolchain is rejected by `zig build` itself
# with a better message than this recipe could produce, and a second check
# would be one more place to forget when the pin moves.

# Compile the Zig binary.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v zig >/dev/null || { echo "zig not on PATH -- brew install zig" >&2; exit 1; }
    # Not `ls zig-out/bin`: cross-target builds install alongside the native
    # one, so the directory accumulates other platforms' artefacts and listing
    # it would report them as though this build had produced them.
    zig build
    echo "zig build ok: zig-out/bin/synapse"

# Zig unit tests -- internals only; `just test` owns the CLI contract.
test-zig:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v zig >/dev/null || { echo "zig not on PATH -- brew install zig" >&2; exit 1; }
    zig build test
    echo "zig tests ok"

# Deliberately not part of `check`/CI: under a plain `zig build test`, a
# `std.testing.fuzz`-based test runs exactly once with an empty corpus, a
# smoke check, not real coverage (verified live, sb-024). Real randomized,
# coverage-guided fuzzing only happens under `--fuzz`, which runs
# continuously (a web UI, by default no iteration limit) until stopped --
# an interactive activity to run yourself, not a pass/fail gate. Pass a
# limit to bound it instead of leaving it open-ended, e.g. `just fuzz 100K`.

# Continuous, coverage-guided fuzzing (a person runs this, CI doesn't).
fuzz LIMIT="":
    #!/usr/bin/env bash
    set -euo pipefail
    command -v zig >/dev/null || { echo "zig not on PATH -- brew install zig" >&2; exit 1; }
    if [ -n "{{ LIMIT }}" ]; then
        zig build test --fuzz="{{ LIMIT }}"
    else
        zig build test --fuzz
    fi

# The other half of the layering. `build.zig`'s module graph rejects a
# wrong-direction import, but only once something references it -- Zig analyses
# declarations lazily, so a dead one compiles. This catches those, and the rule
# no build graph can express: that core reaches the system only through its Io.

# Compile for every release target. A POSIX path assumption, a /tmp default or
# a shell-out in core is a portability bug that only surfaces on the platform
# that lacks the thing -- which, for bard's author, means surfacing on her
# Windows machine rather than on ours. Compiling all three here moves that to
# the moment the line is written.

# Compile for all three release targets.
build-targets:
    ./ci/build-targets.sh

# Verify the module layering and core's purity.
layering:
    ./ci/check-layering.sh

# Catches the class of typo that only surfaces when a rarely-taken branch runs --
# an unbalanced quote inside an awk program embedded in a heredoc, say.

# Parse-check every shipped script without executing it.
syntax:
    #!/usr/bin/env bash
    set -euo pipefail
    n=0
    # claude/bin and claude/lib/synapse are gone -- the tooling is two
    # binaries. Every shipped hook/setup script is .cjs now (packages/synapse/,
    # plugins/synapse-bard/hooks/), not .sh -- nothing left for this recipe
    # to parse-check there, but plugins/*/hooks/*.sh stays in the glob list
    # rather than being deleted: the `[ -f ]` guard below makes an empty
    # match harmless, and the moment a `.sh` script reappears in any
    # plugin's hooks dir, this starts checking it again automatically.
    # docs/*/*.sh reaches each project's own generators (docs/synapse/,
    # docs/synapse-bard/); docs/*.sh still needed for generate-site.sh,
    # which stays at the top level since it builds all of them into one site.
    for f in ci/*.sh docs/*.sh docs/*/*.sh plugins/*/hooks/*.sh; do
        [ -f "$f" ] || continue
        bash -n "$f"
        n=$((n + 1))
    done
    echo "syntax ok: $n scripts"

# Verify, never regenerate: a `check` that quietly fixes what it is checking
# cannot fail, and the point is to catch a script edit committed without the
# regeneration that follows from it.

# Verify each project's generated cli.md and rendered diagrams match their sources.
docs-check:
    ./docs/synapse/generate-cli-reference.sh --check
    ./docs/synapse/generate-diagrams.sh --check
    ./docs/synapse-bard/generate-cli-reference.sh --check
    ./docs/synapse-bard/generate-diagrams.sh --check

# Regenerate all generated artefacts; diagrams need mermaid-cli and its Chromium.
fix:
    ./docs/synapse/generate-cli-reference.sh
    ./docs/synapse/generate-diagrams.sh
    ./docs/synapse-bard/generate-cli-reference.sh
    ./docs/synapse-bard/generate-diagrams.sh

# What CI runs, in the same order, plus a syntax pass CI gets for free by
# executing the scripts. `build` comes first because a compile error should not
# cost a full bats run to discover, and because everything after it will
# eventually be exercising the binary it produces.
#
# The bats step is `test-linux`, not `test`, and the difference is not small:
# measured on the same commit and the same 443 tests, the container is ~30s where
# the host is six to seven minutes. Both parallelise, so the gap is macOS
# fork/exec cost -- 6.5ms against 0.24ms per exec on the same M3, 27x.
#
# End to end that took this whole gate from ~8min to 2:20, and then to 26s: the
# remaining 2:20 turned out to be almost entirely `layering`, which forked two greps
# per source line and paid the same macOS fork/exec tax measured above -- 113s, in
# the step that sounded like the cheapest in the gate. One awk pass, 0.06s. What is
# left, measured: test-linux ~30s, build-targets 5s, test-zig 2s, docs-check 2s,
# syntax and layering under a second between them.
#
# A gate that takes eight minutes gets run less often than one that takes half a
# minute, and a gate nobody runs is worth nothing. That is also the answer to why
# `build-targets` is in here rather than CI-only: at 5s it cannot be the reason
# anyone skips the gate, and leaving it out would mean a green local run can still
# fail the push.
#
# The full gate -- run before pushing (see WHAT TO RUN WHEN at the top).
check: build build-targets test-zig layering syntax test-linux docs-check
    @echo "all green"

# For when podman is not available, and as the answer to "is this a container
# artefact?" -- the container runs Linux with a DebugAllocator that reports leaks
# the native build stays silent about, so a failure there and not here is a real
# finding rather than a flake. It found two.
#
# The full gate with the bats suite on the host instead of in the container.
check-local: build build-targets test-zig layering syntax test docs-check
    @echo "all green (host bats)"

# Show what changed against the pushed branch.
diff:
    @git --no-pager diff --stat @{u}.. 2>/dev/null || git --no-pager diff --stat
