#!/bin/bash
# Checks that the Synapse Desktop docs pages, their committed screenshots and
# the spec that takes them agree on names.
#
# Usage: check-screenshots.sh
#
# Three sets of names:
#   - the screenshots the spec takes: shot(page, '<name>' in
#     synapse_desktop/e2e/docs-screenshots.spec.ts
#   - the images committed: docs/desktop/img/*.png
#   - the images the pages use: ](img/<name>.png in docs/desktop/*.md
#
# It fails, printing each offender, when a page uses an image that is not
# committed, when a committed image is used by no page, or when the spec takes
# a screenshot that has no committed image.
#
# Only names are compared, never the pictures: the same screen is drawn
# differently on macOS and on the Linux runner, so a byte or pixel comparison
# would fail for reasons that have nothing to do with the docs.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
spec="synapse_desktop/e2e/docs-screenshots.spec.ts"
img_dir="docs/desktop/img"

cd "$root"

[ -f "$spec" ] || { echo "missing $spec" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The names the spec takes, one per line.
{ grep -o "shot(page, '[a-z0-9-]*'" "$spec" || true; } \
    | sed "s/^shot(page, '//; s/'\$//" \
    | sort -u > "$work/taken"

# The images committed, one name per line.
: > "$work/committed"
for f in "$img_dir"/*.png; do
    [ -f "$f" ] || continue
    basename "$f" .png >> "$work/committed"
done
sort -u -o "$work/committed" "$work/committed"

# The images the pages use, as "<page>:<name>" lines, and the names alone.
: > "$work/uses"
for f in docs/desktop/*.md; do
    [ -f "$f" ] || continue
    grep -o '](img/[^)]*\.png' "$f" \
        | sed "s|^](img/||; s|\.png\$||; s|^|$f:|" >> "$work/uses" || true
done
cut -d: -f2- "$work/uses" | sort -u > "$work/used"

failed=0

while IFS=: read -r page name; do
    if ! grep -qxF "$name" "$work/committed"; then
        echo "$page uses img/$name.png, which is not in $img_dir/"
        failed=1
    fi
done < "$work/uses"

while read -r name; do
    if ! grep -qxF "$name" "$work/used"; then
        echo "$img_dir/$name.png is used by no page in docs/desktop/"
        failed=1
    fi
done < "$work/committed"

while read -r name; do
    if ! grep -qxF "$name" "$work/committed"; then
        echo "$spec takes '$name', which has no $img_dir/$name.png (run: just docs-screenshots)"
        failed=1
    fi
done < "$work/taken"

if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "desktop screenshots ok: $(wc -l < "$work/committed" | tr -d ' ') images"
