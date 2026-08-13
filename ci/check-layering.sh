#!/bin/bash
# The half of the layering the compiler cannot enforce.
#
# `build.zig`'s module graph already rejects a wrong-direction import -- but
# only once something references it. Zig analyses declarations lazily, so a
# `const x = @import("core");` in `ports` that nothing uses compiles silently,
# and `refAllDecls` in a test block reaches public declarations only. The
# module graph therefore makes bad layering unusable rather than unwritable,
# and this script is what makes it unwritable.
#
# It also enforces the rule no build graph can express: that `core` and `model`
# reach the system solely through an injected `std.Io`. Taking an `Io` and
# doing I/O through it is the design; naming `std.fs`, `std.process`,
# `std.time` or `std.http` is what gets rejected.
#
# Comment-only lines are skipped, so prose may name the forbidden namespaces --
# this file's own callers do. A trailing comment on a code line is not skipped
# and will be reported; that is deliberate, since the alternative is stripping
# `//` mid-line and thereby missing a real violation hiding after a URL.
#
# ONE AWK PASS, AND THAT IS THE WHOLE POINT OF THE SHAPE. This ran a `grep -o`
# and a `grep -qE` per *line* of every source file: ~20k lines, two forks each,
# which on macOS is 113 seconds of almost pure fork/exec -- the same 6.5ms-per-exec
# tax this project measured when it moved the bats suite into a Linux container,
# paid here by the fastest-sounding step in the gate. In awk it is one process for
# the whole tree and 0.1s, and a gate nobody minds running is the difference
# between a check and a formality.
set -euo pipefail

cd "$(dirname "$0")/.."

# Which module names each layer may @import, beyond `std` and `builtin`.
# Relative imports (anything ending in .zig) are sibling files and always fine.
#
# `treesitter` reaches `adapters` for the process helper; `adapters` must never
# reach back, or it acquires libtree-sitter by the side door. Apps are the wiring
# layer: they may reach every adapter module, including the ones that are separate
# modules precisely so a different app can leave them out.
find src -name '*.zig' | sort | xargs awk '
function allowed_for(f) {
    if (f ~ /^src\/model\//)                 return " ";
    if (f ~ /^src\/ports\//)                 return " model ";
    if (f ~ /^src\/core\//)                  return " model ports ";
    if (f ~ /^src\/adapters\/treesitter\//)  return " model ports core adapters ";
    if (f ~ /^src\/adapters\//)              return " model ports core ";
    return " model ports core adapters treesitter ";
}

FNR == 1 {
    allowed = allowed_for(FILENAME);
    pure = (FILENAME ~ /^src\/(core|model)\//);
    files++;
}

# Entirely a comment. Not a general Zig lexer: `//`, `///` and `//!` at the start
# of a line, and `\\` multiline-string lines.
/^[ \t]*(\/\/|\\\\)/ { next }

{
    # Every @import("name") on the line. `@import("` is 9 characters and `")` is 2.
    line = $0;
    while (match(line, /@import\("[^"]*"\)/)) {
        mod = substr(line, RSTART + 9, RLENGTH - 11);
        line = substr(line, RSTART + RLENGTH);
        if (mod == "std" || mod == "builtin" || mod ~ /\.zig$/) continue;
        if (index(allowed, " " mod " ") == 0) {
            printf "%s:%d: imports %c%s%c, which this layer may not reach\n",
                FILENAME, FNR, 39, mod, 39 > "/dev/stderr";
            bad = 1;
        }
    }

    # Purity: core and model reach the system only through an injected Io. The
    # bracket expressions stand in for \b, which POSIX ERE does not have.
    if (pure && $0 ~ /(^|[^A-Za-z0-9_])std\.(fs|process|time|http)([^A-Za-z0-9_]|$)/) {
        printf "%s:%d: names a std namespace core must reach through its Io\n",
            FILENAME, FNR > "/dev/stderr";
        bad = 1;
    }
}

END {
    if (bad) {
        print "layering: violations above" > "/dev/stderr";
        exit 1;
    }
    printf "layering ok: %d files\n", files;
}
'
