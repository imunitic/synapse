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
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
report() { printf '%s\n' "$1" >&2; fail=1; }

# Which module names each layer may @import, beyond `std` and `builtin`.
# Relative imports (anything ending in .zig) are sibling files and always fine.
allowed_for() {
    case "$1" in
        src/model/*)    echo "" ;;
        src/ports/*)    echo "model" ;;
        src/core/*)     echo "model ports" ;;
        src/adapters/*) echo "model ports core" ;;
        src/apps/*)     echo "model ports core adapters" ;;
        *)              echo "model ports core adapters" ;;
    esac
}

# Lines that are entirely a comment. Not a general Zig lexer: it skips `//`,
# `///` and `//!` at the start of a line, and `\\` multiline-string lines.
code_lines() {
    grep -nv '^[[:space:]]*\(//\|\\\\\)' "$1" || true
}

while IFS= read -r file; do
    allowed="$(allowed_for "$file")"

    while IFS= read -r numbered; do
        line="${numbered#*:}"
        lineno="${numbered%%:*}"

        # Layering: every @import("name") that is not a sibling .zig file.
        while read -r mod; do
            [ -n "$mod" ] || continue
            case "$mod" in
                std | builtin | *.zig) continue ;;
            esac
            case " $allowed " in
                *" $mod "*) ;;
                *) report "$file:$lineno: imports '$mod', which this layer may not reach" ;;
            esac
        done < <(printf '%s\n' "$line" | grep -o '@import("[^"]*")' | sed 's/@import("//; s/")//')

        # Purity: core and model reach the system only through an injected Io.
        case "$file" in
            src/core/* | src/model/*)
                if printf '%s\n' "$line" | grep -qE '\bstd\.(fs|process|time|http)\b'; then
                    report "$file:$lineno: names a std namespace core must reach through its Io"
                fi
                ;;
        esac
    done < <(code_lines "$file")
done < <(find src -name '*.zig' | sort)

if [ "$fail" -ne 0 ]; then
    echo "layering: violations above" >&2
    exit 1
fi

echo "layering ok: $(find src -name '*.zig' | wc -l | tr -d ' ') files"
