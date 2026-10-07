--  `rank`: the sources of a node in the order they are worth reading, for the
--  author of its prose. Code is ranked by its definitions per kilobyte from
--  the tags cache `vocab` filled, never tagged here: several nodes ranking at
--  once must not become several writers of one cache. Declarative files are
--  ranked by the code that consumes them.
package Synapse.Commands.Rank is

   --  `rank --sources <file> [--repo <path>] [--out <dir>] [--top N]
   --  [--tier code|dsl] [--pool summary|crux]` prints
   --  `tier<TAB>score<TAB>path`, code first; `rank --lists <dir> ...` writes
   --  both pools of every node to `rank/NNN.summary.tsv` and
   --  `rank/NNN.crux.tsv`.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Rank;
