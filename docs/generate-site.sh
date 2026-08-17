#!/bin/bash
# Builds the GitHub Pages docs site: converts every docs/*.md plus the repo
# root README.md to HTML via pandoc, rewriting the internal .md links pandoc
# itself never touches, and wraps every page in the same left-sidebar nav
# (docs/site.css positions it; this script only emits the markup).
#
#   docs/generate-site.sh <output-dir>
#
# Page mapping, not a generic basename loop, because two files are both
# named README.md and need different roles: the root README becomes the
# site's own landing page (project pitch, install instructions -- the thing
# a first-time visitor actually needs), and docs/README.md becomes a
# secondary "how the pieces fit together" page, not index.html.
#
# Not covered by `just docs-check`, unlike cli.md/the diagrams: those are
# generated *and committed*, so staleness is a real drift to catch. This
# script's output is never committed -- it's built fresh in CI and deployed
# directly -- so there is nothing checked-in to compare against.
set -euo pipefail

out="${1:?usage: generate-site.sh <output-dir>}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v pandoc >/dev/null || { echo "pandoc is required" >&2; exit 1; }

mkdir -p "$out"
cp -r "$here/diagrams" "$out/diagrams"
cp "$here/site.css" "$out/site.css"

# {source path} {output basename} {sidebar label} pairs, sidebar order.
pages=(
  "$root/README.md|index.html|Home"
  "$here/README.md|docs.html|Documentation"
  "$here/synapse-vault.md|synapse-vault.html|Synapse Vault"
  "$here/synapse-graph.md|synapse-graph.html|Synapse Graph"
  "$here/design-task-workflow.md|design-task-workflow.html|Design -> Task Workflow"
  "$here/synapse-code-cache.md|synapse-code-cache.html|Synapse Code Cache"
  "$here/cli.md|cli.html|CLI Reference"
  "$here/synapse-config.md|synapse-config.html|Configuration Reference"
)

# The diagrams/ directory has no index of its own -- a bare `diagrams/` link
# (docs/README.md has one) 404s on a static site with no directory listing.
# Give it a real, if minimal, one.
{
  echo '<!doctype html><html><head><meta charset="utf-8">'
  echo '<title>Diagrams — Synapse</title><link rel="stylesheet" href="../site.css"></head><body>'
  echo '<main><h1>Diagrams</h1><ul>'
  for png in "$here"/diagrams/*.png; do
    name="$(basename "$png")"
    echo "<li><a href=\"$name\"><img src=\"$name\" alt=\"$name\" style=\"max-width:100%\"></a><br>$name</li>"
  done
  echo '</ul></main></body></html>'
} > "$out/diagrams/index.html"

# The sidebar is identical on every page -- no active-page highlighting, kept
# simple since that's what was actually asked for.
nav='<nav id="sidebar"><div class="sidebar-title">Synapse</div><ul>'
for p in "${pages[@]}"; do
  IFS='|' read -r _ target label <<< "$p"
  nav="$nav<li><a href=\"$target\">$label</a></li>"
done
nav="$nav</ul></nav><div id=\"content\">"

nav_file="$(mktemp)"
close_file="$(mktemp)"
trap 'rm -f "$nav_file" "$close_file"' EXIT
printf '%s' "$nav" > "$nav_file"
printf '</div>' > "$close_file"

n=0
for p in "${pages[@]}"; do
  IFS='|' read -r src target label <<< "$p"
  [ -f "$src" ] || { echo "missing: $src" >&2; exit 1; }

  # Internal cross-links: sibling .md files (optionally #fragment) resolve
  # to the .html this loop produces; the root README's docs/foo.md links
  # drop the docs/ prefix the same way; LICENSE has no rendered page here,
  # so it points at the real file on GitHub instead of 404ing.
  sed -E \
    -e 's/\]\((docs\/)?README\.md(#[a-zA-Z0-9_-]*)?\)/](docs.html\2)/g' \
    -e 's/\]\((docs\/)?([a-zA-Z0-9_-]+)\.md(#[a-zA-Z0-9_-]*)?\)/](\2.html\3)/g' \
    -e 's/\]\(LICENSE\)/](https:\/\/github.com\/imunitic\/synapse\/blob\/main\/LICENSE)/g' \
    "$src" \
    | pandoc --from gfm --to html5 --standalone \
        --metadata pagetitle="$label — Synapse" \
        -c site.css -B "$nav_file" -A "$close_file" \
        -o "$out/$target"
  n=$((n + 1))
done

echo "site built: $out ($n pages)"
