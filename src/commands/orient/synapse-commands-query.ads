--  `query [--namespace <repo>@<branch>] <subcommand> [args]`: read-only
--  questions about the graph of a checkout.
--
--    body    <node> [--full | --lines <ranges>]
--    sources <node> [--count | --modules | --filter <pattern>]
--    field   <node> <key>  or  field --file <path> <key>
--    stale                 nodes whose files no longer match
--    drift                 what changed since each node's commit
--    grounding [<node> --list]
--    links   <node> [--inbound | --closure]  or  links --check
--    symbol  <name> <node>
--
--  `--namespace` names a namespace directly, which is how a query reaches
--  another checkout's graph. `stale`, `drift`, `grounding` and `symbol` read
--  the checkout's real files, so under it they need `SYNAPSE_REPO_ROOT`:
--  reading through an empty root would call every source missing. `stale`,
--  `drift`, `grounding` and `links --check` print nothing when they find
--  nothing, and exit 1 means they could not run, never that all is clean.
package Synapse.Commands.Query is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Query;
