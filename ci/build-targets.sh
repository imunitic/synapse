#!/bin/bash
# Compile for every release target.
#
# A POSIX path assumption, a `/tmp` default or a shell-out in core is a
# portability bug that surfaces only on the platform lacking the thing --
# which, for synapse-bard's author, means surfacing on her Windows machine
# rather than on ours. Compiling all three targets moves that to the moment
# the line is written.
#
# `just build-targets` and the CI job both run this script, which shares its
# target list (release-targets.sh) with the release workflow too -- one
# definition, three consumers, rather than each keeping its own copy.
set -euo pipefail

cd "$(dirname "$0")/.."

# The target list itself lives in release-targets.sh -- shared with the
# release workflow, which needs the exact same platforms for a different
# reason (what to ship, not just what to verify compiles).
source ci/release-targets.sh

command -v zig >/dev/null || { echo "zig not on PATH -- brew install zig" >&2; exit 1; }

# Two builds per target, not one. `zig build` compiles only what the executable
# references, and Zig analyses declarations lazily -- so a module nothing has
# wired up yet compiles on this machine and nowhere else, which is exactly
# where an assumption about byte order, padding or path separators would sit
# unnoticed. `test-build` compiles the test roots, which reference everything,
# and does not run them: these are other platforms' binaries.
for t in "${targets[@]}"; do
    printf '  %-16s' "$t"
    zig build -Dtarget="$t"
    zig build test-build -Dtarget="$t"
    echo ok
done

echo "targets ok: ${#targets[@]}"
