--  The subcommand listing, one text for every entry point, so a table cannot
--  describe itself differently from the usage a person reads.

package Synapse.Commands.Usage is

   LF : constant Character := Character'Val (10);

   Text : constant String :=
      "usage: synapse <subcommand> [args]" & LF &
      "" & LF &
      "  tags <file>                tags for one file" & LF &
      "  tags --paths <list-file>   tags for every listed file, i" &
      "n one batch" & LF &
      "  tags --list-extensions     every extension with a usable" &
      " grammar" & LF &
      "  tags-cache --repo-root <dir> --cache <file> --paths <tsv" &
      ">" & LF &
      "  tags-cache --dump <file>   what the cache holds" & LF &
      "  tags-cache --refs <file>   _refs.tsv rows from the cache" & LF &
      "  index build --unassigned <file>   _index.bin from path<T" &
      "AB>node on stdin" & LF &
      "  index unassigned           every path no node claims" & LF &
      "  index lookup <path>        the nodes claiming one path" & LF &
      "  enumerate [--reenumerate]  tracked files worth graphing," &
      " into the work dir" & LF &
      "  build-lists [--reenumerate]  manifest.tsv into one path " &
      "list per node" & LF &
      "  vocab [--lists <dir>]      symbol vocabulary by group" & LF &
      "  rank --sources <file>      a node's sources by reading v" &
      "alue" & LF &
      "  query <subcommand> [args]  read-only queries against the" &
      " graph" & LF &
      "  write-node --title <t> --summary <s> --paths <f> --body " &
      "<f>" & LF &
      "  frontmatter get <path> <key>             read one frontm" &
      "atter field" & LF &
      "  frontmatter set <path> <key> <value>    set one frontmat" &
      "ter field, byte-preserving" & LF &
      "  frontmatter set <path> --add-tag|--remove-tag <tag>   sa" &
      "me, for the tags field" & LF &
      "  vault-read <path>          a note's full body" & LF &
      "  vault-write <path>         write a note's full body, fro" &
      "m stdin" & LF &
      "  vault-list                 every note in the vault, recu" &
      "rsively" & LF &
      "  vault-check                read-only conformance audit o" &
      "ver schema-declaring notes" & LF &
      "  vault-search [--fields <f1,f2,...>]   JsonLogic filter f" &
      "rom stdin, TSV rows out" & LF &
      "  vault-search-text <query> [--namespace <repo>@<branch>] " &
      "[--path-filter]   full-text search: node, score, matching " &
      "line ranges" & LF &
      "  vault-doc-map <path>       headings/block ids/frontmatte" &
      "r keys, for a vault-patch target" & LF &
      "  vault-patch <path> --heading|--block|--frontmatter <targ" &
      "et>" & LF &
      "              [--append|--prepend|--replace] [--create]   " &
      "content from stdin" & LF &
      "  vault-backlinks <path>     node<TAB>count, per file link" &
      "ing to <path>" & LF &
      "  vault-links <path>         outgoing link targets from <p" &
      "ath>" & LF &
      "  vault-unresolved           source<TAB>target<TAB>count, " &
      "one row per broken link" & LF &
      "  vault-orphans              notes with no backlinks" & LF &
      "  vault-deadends             notes with no outgoing links" & LF &
      "  vault-ambiguous            source<TAB>target<TAB>candida" &
      "te<TAB>count, one row per (source, target, candidate)" & LF &
      "  vault-rename <old-path> <new-path>   moves a note and re" &
      "writes every referring wikilink" & LF &
      "  vault-delete <path>        removes a note, unlinking eve" &
      "ry referring wikilink to plain text" & LF &
      "  build-refs [--cache <f>] [--out <f>]   _refs.tsv from th" &
      "e tags cache" & LF &
      "  build-deps [--repo <dir>] [--out <f>]  _deps.tsv, per-fi" &
      "le declared dependencies" & LF &
      "  build-namespaces [--repo <dir>] [--out <f>]  _namespaces" &
      ".tsv, per-file declared namespace" & LF &
      "  callers <name> [--all]     repo-wide sites of an exact n" &
      "ame" & LF &
      "  gate --vocab <file> [--all] [--top N]   clusters owning " &
      "no vocabulary" & LF &
      "  link-graph --refs <f> --lists <dir> [--top N]   candidat" &
      "e node links" & LF &
      "  brief --lists <dir> [--rank <dir>] [--links <f>]   one d" &
      "ata file per node" & LF &
      "  push-nodes [NN ...]        write one node per authored b" &
      "ody" & LF &
      "  build-project-index        the namespace's Index.md node" &
      " map" & LF &
      "  namespace [--repo <dir>]   the {repo}@{branch} key for a" &
      " checkout" & LF &
      "  now [--built-at]           machine-local timestamp, RFC3" &
      "339 or built_at's shape" & LF &
      "  context                    this checkout's graph path an" &
      "d the question-to-command map" & LF &
      "  doctor [--repo <dir>]      check every precondition the " &
      "rest of the system" & LF &
      "                             tolerates silently" & LF &
      "  build-index                _index.bin from the work dir'" &
      "s lists" & LF &
      "  graph-clean [--dry-run]    drop namespaces whose branch " &
      "is gone upstream" & LF &
      "  graph-wipe [--dry-run]     drop this namespace, preservi" &
      "ng hand Notes" & LF &
      "  comments-check <path>      docstring staleness for one f" &
      "ile, Tier 2 (read-time)" & LF &
      "  comments-sweep [--reenumerate]   docstring staleness, ev" &
      "ery tracked file, on demand" & LF &
      "";

end Synapse.Commands.Usage;
