#!/bin/bash
# Compile for every release target.
#
# A POSIX path assumption, a `/tmp` default or a shell-out in core is a
# portability bug that surfaces only on the platform lacking the thing --
# which, for synapse-bard's author, means surfacing on her Windows machine
# rather than on ours. Compiling all three targets moves that to the moment
# the line is written.
#
# This is the single definition of the release matrix: `just build-targets`
# and the CI job both run this script rather than each keeping their own copy
# of the list, because two copies of a list is one copy that goes stale.
set -euo pipefail

cd "$(dirname "$0")/.."

# aarch64-macos is where the hooks actually run; x86_64-linux is CI, the test
# container, and bard's Android cloud session.
#
# x86_64-windows is deliberately absent, and its absence is a correction
# rather than an omission. Windows is *bard's* target -- its author's machine
# -- and bard does not exist yet. `synapse` is a developer tool for macOS and
# Linux, and cross-compiling it to Windows was over-broad from the start. It
# is also now impossible: `std.DynLib` is a compile error on Windows in Zig
# 0.16 ("unsupported platform"), and `synapse` loads grammars through it.
#
# That costs nothing bard needs. Bard uses the frontmatter extractor, links no
# libtree-sitter, and loads nothing dynamically -- which is exactly why it is
# a separate module. When bard exists it brings its own Windows target, and
# the portability guard this list provides moves with it.
targets=(x86_64-linux aarch64-macos)

command -v zig >/dev/null || { echo "zig not on PATH -- brew install zig" >&2; exit 1; }

for t in "${targets[@]}"; do
    printf '  %-16s' "$t"
    zig build -Dtarget="$t"
    echo ok
done

echo "targets ok: ${#targets[@]}"
