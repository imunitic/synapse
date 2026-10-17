--  `link-graph`: the candidate links between nodes, computed from the
--  reference index and the path lists before any prose is written. Not
--  `query links`, which reads the links of a node already written.
package Synapse.Commands.Link_Graph is

   --  `link-graph --refs <f> --lists <dir> [--deps <f>] [--namespaces <f>]
   --  [--top N] [--out <dir>]`: `links.tsv`, the strongest edges of each
   --  node. The dependency and namespace tables, when both exist, add the
   --  edges that import resolution can tell apart.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Link_Graph;
