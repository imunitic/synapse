#!/bin/bash
# Builds the GitHub Pages docs site: converts every project's docs/*.md to
# HTML via pandoc, rewriting the internal .md links pandoc itself never
# touches, and wraps every page in the same left-sidebar nav (site.css
# positions it; this script only emits the markup). Two projects now
# (`docs/synapse/`, `docs/synapse-bard/`), each rendered into its own
# subdirectory of the output with its own sidebar, plus one top-level
# landing page linking into both.
#
#   docs/generate-site.sh <output-dir>
#
# index.html is a build-time-only merge, not a copy of any source file
# verbatim: the repo's own README.md stays exactly as it is (a GitHub
# visitor's entry point) -- this script only pulls its intro pitch plus
# "New machine setup" into the site's own landing page, followed by a short,
# generated-here list of the two projects' doc sections. Nothing writes back
# to README.md.
#
# Not covered by `just docs-check`, unlike each project's own cli.md/rendered
# diagrams: those are generated *and committed*, so staleness is a real drift
# to catch. This script's output is never committed -- built fresh in CI and
# deployed directly -- so there is nothing checked-in to compare against.
set -euo pipefail

out="${1:?usage: generate-site.sh <output-dir>}"
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v pandoc >/dev/null || { echo "pandoc is required" >&2; exit 1; }

mkdir -p "$out"
cp "$here/site.css" "$out/site.css"
cp "$here/logo.svg" "$out/logo.svg"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# SVG favicons work in every browser that matters here; injected via
# --include-in-header since -B/-A only reach <body>, not <head>.
favicon_file="$work/favicon.html"
printf '<link rel="icon" href="logo.svg" type="image/svg+xml">' > "$favicon_file"
favicon_file_nested="$work/favicon-nested.html"
printf '<link rel="icon" href="../logo.svg" type="image/svg+xml">' > "$favicon_file_nested"

# Renders one project's pages into "$out/$1/". `$3` is a newline-separated
# list of "src|basename|sidebar label" triples, sidebar order -- same shape
# generate-site.sh always used, now scoped per project instead of global.
# Every page in a project links relative to its own directory (siblings, no
# ../ needed) except the sidebar's own "All docs" link back up to the root.
#
# Takes the page list as one newline-joined string, not a bash array --
# `local -n` namerefs need bash 4.3+, and this repo runs on the macOS-shipped
# bash 3.2 locally (the same reason the rest of this repo's scripts stay off
# GNU-only sed/bash features).
render_project() { # render_project <dir> <label> <newline-joined pages>
  local dir="$1" label="$2" pages="$3"
  local proot="$out/$dir"
  mkdir -p "$proot"

  local nav="<nav id=\"sidebar\"><div class=\"sidebar-title\">$label</div><ul>"
  nav="$nav<li><a href=\"../index.html\">&larr; All docs</a></li>"
  local p target plabel
  while IFS='|' read -r _ target plabel; do
    [ -n "$target" ] || continue
    nav="$nav<li><a href=\"$target\">$plabel</a></li>"
  done <<< "$pages"
  nav="$nav</ul></nav><div id=\"content\">"

  local nav_file="$work/$dir-nav.html"
  local close_file="$work/close.html"
  printf '%s' "$nav" > "$nav_file"
  printf '</div>' > "$close_file"

  local src n=0
  while IFS='|' read -r src target plabel; do
    [ -n "$src" ] || continue  # a Diagrams-style entry with its own page built separately
    [ -f "$src" ] || { echo "missing: $src" >&2; exit 1; }

    # Sibling .md files (optionally #fragment) resolve to the .html this
    # loop produces; a link to this project's own README.md means its Home.
    sed -E \
      -e "s/\\]\\((README\\.md|$dir\\/README\\.md)(#[a-zA-Z0-9_-]*)?\\)/](index.html\\2)/g" \
      -e 's/\]\(([a-zA-Z0-9_-]+)\.md(#[a-zA-Z0-9_-]*)?\)/](\1.html\2)/g' \
      "$src" \
      | pandoc --from gfm --to html5 --standalone \
          --metadata pagetitle="$plabel — $label" \
          -c ../site.css -H "$favicon_file_nested" -B "$nav_file" -A "$close_file" \
          -o "$proot/$target"
    n=$((n + 1))
  done <<< "$pages"
  echo "  $dir: $n pages" >&2
}

# --- Synapse ---------------------------------------------------------------
mkdir -p "$out/synapse/diagrams"
cp -r "$here/synapse/diagrams/"*.png "$out/synapse/diagrams/" 2>/dev/null || true

synapse_pages="$here/synapse/README.md|index.html|Home
$here/synapse/synapse-vault.md|synapse-vault.html|Synapse Vault
$here/synapse/synapse-graph.md|synapse-graph.html|Synapse Graph
$here/synapse/design-task-workflow.md|design-task-workflow.html|Design -> Task Workflow
$here/synapse/synapse-code-cache.md|synapse-code-cache.html|Synapse Code Cache
$here/synapse/cli.md|cli.html|CLI Reference
$here/synapse/synapse-config.md|synapse-config.html|Configuration Reference
|diagrams/|Diagrams"
render_project synapse "Synapse" "$synapse_pages"

# The diagrams/ directory has no index of its own -- a bare `diagrams/` link
# 404s on a static site with no directory listing.
{
  echo '<!doctype html><html><head><meta charset="utf-8">'
  echo '<title>Diagrams — Synapse</title><link rel="stylesheet" href="../../site.css">'
  echo '<link rel="icon" href="../../logo.svg" type="image/svg+xml"></head><body>'
  echo '<main><h1>Diagrams</h1><ul>'
  for png in "$here"/synapse/diagrams/*.png; do
    name="$(basename "$png")"
    echo "<li><a href=\"$name\"><img src=\"$name\" alt=\"$name\" style=\"max-width:100%\"></a><br>$name</li>"
  done
  echo '</ul></main></body></html>'
} > "$out/synapse/diagrams/index.html"

# --- Synapse Bard ------------------------------------------------------------
synapse_bard_pages="$here/synapse-bard/README.md|index.html|Home
$here/synapse-bard/cli.md|cli.html|CLI Reference"
render_project synapse-bard "Synapse Bard" "$synapse_bard_pages"

# --- Top-level landing page --------------------------------------------------
# README.md from the start through the end of "## New machine setup" -- stops
# at the next ## heading, a pattern match rather than a hardcoded line number
# so it tracks the file instead of silently truncating wrong after an
# unrelated edit. awk, not GNU-sed range syntax, since the macOS-shipped BSD
# sed rejects it.
awk '/^## Synapse Vault/{exit} {print}' "$root/README.md" > "$work/home.md"

{
  echo
  echo '## Documentation'
  echo
  echo 'This repository packages two Claude Code plugins, each with its own docs section:'
  echo
  echo '- **[Synapse](synapse/index.html)** -- durable memory and the per-repo code graph, the'
  echo '  original component this repo was built around.'
  echo '- **[Synapse Bard](synapse-bard/index.html)** -- the same underlying approach, retargeted at a'
  echo '  YAML-templated fiction book bible instead of a code repo.'
} >> "$work/home.md"

# The landing page needs the same #sidebar/#content wrapper every other
# page gets -- body{display:flex} in site.css applies unconditionally, so
# a page missing this wrapper doesn't just lose the sidebar, every one of
# pandoc's own top-level blocks (each heading, paragraph, list) becomes
# its own flex item and lays out side by side as parallel columns of
# wrapped text. Caught live: shipped without it once already.
top_nav='<nav id="sidebar"><div class="sidebar-title">Synapse</div><ul>'
top_nav="$top_nav<li><a href=\"index.html\">Home</a></li>"
top_nav="$top_nav<li><a href=\"synapse/index.html\">Synapse</a></li>"
top_nav="$top_nav<li><a href=\"synapse-bard/index.html\">Synapse Bard</a></li>"
top_nav="$top_nav</ul></nav><div id=\"content\">"
top_nav_file="$work/top-nav.html"
top_close_file="$work/top-close.html"
printf '%s' "$top_nav" > "$top_nav_file"
printf '</div>' > "$top_close_file"

sed -E \
  -e 's/\]\(README\.md(#[a-zA-Z0-9_-]*)?\)/](index.html\1)/g' \
  -e 's/\]\(docs\/synapse\/([a-zA-Z0-9_-]+)\.md(#[a-zA-Z0-9_-]*)?\)/](synapse\/\1.html\2)/g' \
  -e 's/\]\(LICENSE\)/](https:\/\/github.com\/imunitic\/synapse\/blob\/main\/LICENSE)/g' \
  -e 's/\]\(#dependencies\)/](https:\/\/github.com\/imunitic\/synapse#dependencies)/g' \
  -e 's/src="docs\/logo\.svg"/src="logo.svg"/g' \
  "$work/home.md" \
  | pandoc --from gfm --to html5 --standalone \
      --metadata pagetitle="Synapse" \
      -c site.css -H "$favicon_file" -B "$top_nav_file" -A "$top_close_file" \
      -o "$out/index.html"

echo "site built: $out"
