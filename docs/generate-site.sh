#!/bin/bash
# Builds the GitHub Pages docs site: converts every docs/*.md plus the repo
# root README.md to HTML via pandoc, rewriting the internal .md links pandoc
# itself never touches, and wraps every page in the same left-sidebar nav
# (docs/site.css positions it; this script only emits the markup).
#
#   docs/generate-site.sh <output-dir>
#
# index.html is a build-time-only merge, not a copy of either source file
# verbatim: the repo's own README.md and docs/README.md serve their own
# separate readers (a GitHub visitor skimming the repo; someone already
# committed to reading the docs) and stay exactly as they are -- this
# script only assembles what a *docs-site* landing page needs from each:
# README.md's intro pitch plus its "New machine setup" install
# instructions, followed by docs/README.md's own list of components and
# their doc links. Nothing here writes back to either source file.
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# README.md from the start through the end of "## New machine setup" --
# stops at the next ## heading ("## Synapse Vault -- the notes"), a
# pattern match rather than a hardcoded line number so it tracks the file
# instead of silently truncating wrong after an unrelated edit. awk, not
# GNU-sed range syntax, since the macOS-shipped BSD sed rejects it.
awk '/^## Synapse Vault/{exit} {print}' "$root/README.md" > "$work/home.md"

# The whole rest of docs/README.md follows -- component-and-doc-links list,
# the diagram walkthrough, "The three components, and why they are
# separate", "What a session actually gets" -- its own H1 demoted to H2
# since it is now a section of a longer page, not a page title of its own.
{
  echo
  sed 's/^# Documentation/## Documentation/' "$here/README.md"
} >> "$work/home.md"

# {source path} {output basename} {sidebar label} pairs, sidebar order.
# "Documentation" is gone as its own entry -- docs/README.md's content now
# lives inside Home instead of behind a separate, confusingly-named link.
pages=(
  "$work/home.md|index.html|Home"
  "$here/synapse-vault.md|synapse-vault.html|Synapse Vault"
  "$here/synapse-graph.md|synapse-graph.html|Synapse Graph"
  "$here/design-task-workflow.md|design-task-workflow.html|Design -> Task Workflow"
  "$here/synapse-code-cache.md|synapse-code-cache.html|Synapse Code Cache"
  "$here/cli.md|cli.html|CLI Reference"
  "$here/synapse-config.md|synapse-config.html|Configuration Reference"
  "|diagrams/|Diagrams"
)

# The diagrams/ directory has no index of its own -- a bare `diagrams/` link
# 404s on a static site with no directory listing. Give it a real one, and
# keep it reachable now that it's not just a link mid-paragraph on Home
# anymore -- it gets its own sidebar entry below.
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

nav_file="$work/nav.html"
close_file="$work/close.html"
printf '%s' "$nav" > "$nav_file"
printf '</div>' > "$close_file"

n=0
for p in "${pages[@]}"; do
  IFS='|' read -r src target label <<< "$p"
  [ -n "$src" ] || continue  # the Diagrams entry has its own page already, built above
  [ -f "$src" ] || { echo "missing: $src" >&2; exit 1; }

  # Internal cross-links: sibling .md files (optionally #fragment) resolve
  # to the .html this loop produces; the root README's docs/foo.md links
  # drop the docs/ prefix the same way; a link to either README.md now
  # means Home; LICENSE has no rendered page here, so it points at the
  # real file on GitHub instead of 404ing.
  sed -E \
    -e 's/\]\((docs\/)?README\.md(#[a-zA-Z0-9_-]*)?\)/](index.html\2)/g' \
    -e 's/\]\((docs\/)?([a-zA-Z0-9_-]+)\.md(#[a-zA-Z0-9_-]*)?\)/](\2.html\3)/g' \
    -e 's/\]\(LICENSE\)/](https:\/\/github.com\/imunitic\/synapse\/blob\/main\/LICENSE)/g' \
    -e 's/\]\(#dependencies\)/](https:\/\/github.com\/imunitic\/synapse#dependencies)/g' \
    "$src" \
    | pandoc --from gfm --to html5 --standalone \
        --metadata pagetitle="$label — Synapse" \
        -c site.css -B "$nav_file" -A "$close_file" \
        -o "$out/$target"
  n=$((n + 1))
done

echo "site built: $out ($n pages, plus diagrams/index.html)"
