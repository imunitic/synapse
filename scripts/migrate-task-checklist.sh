#!/usr/bin/env bash
# One-shot migration for sb-083: give every legacy task note a `## Checklist`
# heading, inserted immediately before the note's first flat checklist item.
#
# Before/sb-083, checklist items sat directly under the H1 ("everything under
# the title before the first ##"). After, they belong under a `## Checklist`
# H2 (a sibling of `## Notes`), which is what makes a `vault-patch --heading
# "{H1}::Checklist" --replace` scope a checklist-only edit correctly.
#
# Idempotent: notes that already carry a `## Checklist` heading are skipped.
# Only files that look like task notes (a `task_id:` frontmatter field) are
# touched. Run deliberately, once:
#
#   scripts/migrate-task-checklist.sh <vault-dir>   # cd to file's real path
#
# When the vault dir is not given, $SYNAPSE_VAULT_DIR is used.
set -euo pipefail

vault="${1:-${SYNAPSE_VAULT_DIR:-}}"
if [[ -z "$vault" || ! -d "$vault" ]]; then
  echo "usage: $0 <vault-dir>   (or set SYNAPSE_VAULT_DIR)" >&2
  exit 2
fi

changed=0
skipped=0
while IFS= read -r -d '' f; do
  if ! grep -q '^task_id:' "$f"; then
    continue
  fi
  if grep -q '^## Checklist' "$f"; then
    ((skipped += 1))
    continue
  fi

  out="$(mktemp)"
  if awk '
    BEGIN { done = 0; fenced = 0 }
    /^```/ || /^~~~/ { fenced = !fenced }
    !done && !fenced && /^- \[[ xX]\]/ {
      print "## Checklist"
      print ""
      done = 1
    }
    { print }
  ' "$f" > "$out" && ! cmp -s "$out" "$f"; then
    mv "$out" "$f"
    echo "  migrated: $f"
    ((changed += 1))
  else
    rm -f "$out"
  fi
done < <(find "$vault/tasks" -name '*.md' -print0 2>/dev/null)

echo "migrated $changed task note(s); skipped $skipped that already had a Checklist heading"