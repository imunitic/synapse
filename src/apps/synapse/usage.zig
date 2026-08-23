//! The subcommand listing, shared by `synapse` and `synapse-fake` -- one
//! text, two binaries, so the dispatch tables can't describe themselves
//! differently (`tests/cli-reference.bats` catches it if they ever do).

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
