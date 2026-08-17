#!/bin/bash
# Builds the GitHub Pages docs site: converts every docs/*.md to HTML via
# pandoc, rewriting internal .md links to .html (pandoc converts content but
# never rewrites links, so left alone every cross-doc link would 404 on the
# deployed site), and copies docs/diagrams/ alongside for the images each doc
# already references with a relative path. docs/README.md becomes the site's
# index.html -- it's already written as this doc set's own landing page (a
# short table of contents), not renamed specially by convention.
#
#   docs/generate-site.sh <output-dir>
#
# Not covered by `just docs-check`, unlike cli.md/the diagrams: those are
# generated *and committed*, so staleness is a real drift to catch. This
# script's output is never committed -- it's built fresh in CI and deployed
# directly -- so there is nothing checked-in to compare against.
set -euo pipefail

out="${1:?usage: generate-site.sh <output-dir>}"
here="$(cd "$(dirname "$0")" && pwd)"

command -v pandoc >/dev/null || { echo "pandoc is required" >&2; exit 1; }

mkdir -p "$out"
cp -r "$here/diagrams" "$out/diagrams"

n=0
for f in "$here"/*.md; do
    name="$(basename "$f" .md)"
    target="$name.html"
    [ "$name" = "README" ] && target="index.html"

    # Internal cross-links point at sibling .md files (optionally with a
    # #fragment) -- rewrite to the .html files this loop is producing.
    sed -E 's/\]\(([a-zA-Z0-9_-]+)\.md(#[a-zA-Z0-9_-]*)?\)/](\1.html\2)/g' "$f" \
        | pandoc --from gfm --to html5 --standalone --metadata title="$name" \
            -o "$out/$target"
    n=$((n + 1))
done

echo "site built: $out ($n pages)"
