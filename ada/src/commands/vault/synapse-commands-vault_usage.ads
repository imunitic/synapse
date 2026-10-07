--  The usage text of each `vault-*` subcommand and of `frontmatter`, one
--  per subcommand: `--help` on one answers for that one alone.

package Synapse.Commands.Vault_Usage is

   LF : constant Character := Character'Val (10);

   Read : constant String :=
     "usage: synapse vault-read <path>" & LF & "" & LF &
     "  <path>  the note's full vault-relative path, e.g. " &
     "tasks/proj/foo.md" & LF;

   Write : constant String :=
     "usage: synapse vault-write <path>" & LF & "" & LF &
     "  <path>  the note's full vault-relative path, e.g. " &
     "tasks/proj/foo.md" & LF &
     "  stdin   the note's whole new body, frontmatter inc" & "luded" & LF;

   List : constant String :=
     "usage: synapse vault-list" & LF & "" & LF &
     "  every note in the vault, recursively, one path per" & " line" & LF;

   Check : constant String :=
     "usage: synapse vault-check" & LF & "" & LF &
     "  read-only conformance audit over every schema-decl" & "aring note" &
     LF;

   Search : constant String :=
     "usage: synapse vault-search [--fields <f1,f2,...>]" & LF & "" & LF &
     "  --fields  frontmatter keys to print after the path" &
     ", comma-separated" & LF &
     "  stdin     a JsonLogic rule over frontmatter/conten" & "t/tags" & LF &
     "  rows print as path<TAB>field1<TAB>field2..., or ba" &
     "re paths with no --fields" & LF;

   Search_Text : constant String :=
     "usage: synapse vault-search-text <query> [--namespac" &
     "e <repo>@<branch>] [--path-filter]" & LF & "" & LF &
     "  <query>        full-text relevance search: node<TA" &
     "B>score<TAB>line ranges, best 10 notes" & LF &
     "  --namespace    only that graph's nodes, the value " &
     "synapse query --namespace takes" & LF &
     "  --path-filter  scope it first by a JsonLogic path " &
     "filter on stdin" & LF;

   Doc_Map : constant String :=
     "usage: synapse vault-doc-map <path>" & LF & "" & LF &
     "  every target a vault-patch could name, as kind<TAB" & ">value --" &
     LF & "  kind one of heading/block/frontmatter" & LF;

   Patch : constant String :=
     "usage: synapse vault-patch <path> --heading <h>|--bl" &
     "ock <id>|--frontmatter <key>" & LF &
     "            [--append|--prepend|--replace|--rename-h" &
     "eading] [--create]" & LF & "" & LF &
     "  --heading          a ::-joined heading path, e.g. " &
     """Notes::Sub""" & LF & "  --block            a block id" & LF &
     "  --frontmatter      a frontmatter key" & LF &
     "  --replace          the default when no operation i" & "s given" & LF &
     "  --rename-heading   relabel the heading line itself" &
     ", --heading only" & LF &
     "  --create           create a missing section, --hea" & "ding only" &
     LF & "  stdin              the content to write" & LF;

   Backlinks : constant String :=
     "usage: synapse vault-backlinks <path>" & LF & "" & LF &
     "  node<TAB>count, one row per file linking to <path>" & LF;

   Links : constant String :=
     "usage: synapse vault-links <path>" & LF & "" & LF &
     "  outgoing link targets from <path>, one per line" & LF;

   Unresolved : constant String :=
     "usage: synapse vault-unresolved" & LF & "" & LF &
     "  source<TAB>target<TAB>count, one row per broken li" & "nk" & LF;

   Orphans : constant String :=
     "usage: synapse vault-orphans" & LF & "" & LF &
     "  notes with no backlinks, one path per line" & LF;

   Deadends : constant String :=
     "usage: synapse vault-deadends" & LF & "" & LF &
     "  notes with no outgoing links, one path per line" & LF;

   Ambiguous : constant String :=
     "usage: synapse vault-ambiguous" & LF & "" & LF &
     "  source<TAB>target<TAB>candidate<TAB>count, one row" & " per" & LF &
     "  (source, target, candidate)" & LF;

   Rename : constant String :=
     "usage: synapse vault-rename <old-path> <new-path>" & LF & "" & LF &
     "  moves a note and rewrites every referring wikilink" & ", syncing its" &
     LF & "  title:/H1 to the new filename" & LF;

   Delete : constant String :=
     "usage: synapse vault-delete <path>" & LF & "" & LF &
     "  removes a note, unlinking every referring wikilink" &
     " to plain text" & LF;

   Frontmatter : constant String :=
     "usage: synapse frontmatter get <path> <key>" & LF &
     "       synapse frontmatter set <path> <key> <value>" & LF &
     "       synapse frontmatter set <path> --add-tag <tag" & ">" & LF &
     "       synapse frontmatter set <path> --remove-tag <" & "tag>" & LF &
     "" & LF & "  <path>   the note's full vault-relative path, e.g." &
     " tasks/proj/foo.md" & LF &
     "  <value>  bare sets a scalar field; comma-separated" &
     " sets an array" & LF;

end Synapse.Commands.Vault_Usage;
