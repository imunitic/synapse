//! The subcommand listing, shared by `synapse` and `synapse-fake` -- one
//! text, two binaries, so the dispatch tables can't describe themselves
//! differently (`tests/integration/cli_reference_test.zig` catches it if
//! they ever do).

pub const text =
    \\usage: synapse <subcommand> [args]
    \\
    \\  tags <file>                tags for one file
    \\  tags --paths <list-file>   tags for every listed file, in one batch
    \\  tags --list-extensions     every extension with a usable grammar
    \\  tags-cache --repo-root <dir> --cache <file> --paths <tsv>
    \\  tags-cache --dump <file>   what the cache holds
    \\  tags-cache --refs <file>   _refs.tsv rows from the cache
    \\  index build --unassigned <file>   _index.bin from path<TAB>node on stdin
    \\  index unassigned           every path no node claims
    \\  index lookup <path>        the nodes claiming one path
    \\  enumerate [--reenumerate]  tracked files worth graphing, into the work dir
    \\  build-lists [--reenumerate]  manifest.tsv into one path list per node
    \\  vocab [--lists <dir>]      symbol vocabulary by group
    \\  rank --sources <file>      a node's sources by reading value
    \\  query <subcommand> [args]  read-only queries against the graph
    \\  write-node --title <t> --summary <s> --paths <f> --body <f>
    \\  frontmatter get <path> <key>             read one frontmatter field
    \\  frontmatter set <path> <key> <value>    set one frontmatter field, byte-preserving
    \\  frontmatter set <path> --add-tag|--remove-tag <tag>   same, for the tags field
    \\  vault-read <path>          a note's full body
    \\  vault-write <path>         write a note's full body, from stdin
    \\  vault-list                 every note in the vault, recursively
    \\  vault-check                read-only conformance audit over schema-declaring notes
    \\  vault-search [--fields <f1,f2,...>]   JsonLogic filter from stdin, TSV rows out
    \\  vault-search-text <query> [--path-filter]   full-text relevance search, optionally path-scoped
    \\  vault-doc-map <path>       headings/block ids/frontmatter keys, for a vault-patch target
    \\  vault-patch <path> --heading|--block|--frontmatter <target>
    \\              [--append|--prepend|--replace] [--create]   content from stdin
    \\  vault-backlinks <path>     node<TAB>count, per file linking to <path>
    \\  vault-links <path>         outgoing link targets from <path>
    \\  vault-unresolved           source<TAB>target<TAB>count, one row per broken link
    \\  vault-orphans              notes with no backlinks
    \\  vault-deadends             notes with no outgoing links
    \\  vault-ambiguous            source<TAB>target<TAB>candidate<TAB>count, one row per (source, target, candidate)
    \\  vault-rename <old-path> <new-path>   moves a note and rewrites every referring wikilink
    \\  build-refs [--cache <f>] [--out <f>]   _refs.tsv from the tags cache
    \\  build-deps [--repo <dir>] [--out <f>]  _deps.tsv, per-file declared dependencies
    \\  build-namespaces [--repo <dir>] [--out <f>]  _namespaces.tsv, per-file declared namespace
    \\  callers <name> [--all]     repo-wide sites of an exact name
    \\  gate --vocab <file> [--all] [--top N]   clusters owning no vocabulary
    \\  link-graph --refs <f> --lists <dir> [--top N]   candidate node links
    \\  brief --lists <dir> [--rank <dir>] [--links <f>]   one data file per node
    \\  push-nodes [NN ...]        write one node per authored body
    \\  build-project-index        the namespace's Index.md node map
    \\  namespace [--repo <dir>]   the {repo}@{branch} key for a checkout
    \\  doctor [--repo <dir>]      check every precondition the rest of the system
    \\                             tolerates silently
    \\  build-index                _index.bin from the work dir's lists
    \\  graph-clean [--dry-run]    drop namespaces whose branch is gone upstream
    \\  graph-wipe [--dry-run]     drop this namespace, preserving hand Notes
    \\
;
