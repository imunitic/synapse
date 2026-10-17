--  `brief`: one self-contained data file for each node, with everything a
--  concurrent author needs except the prose: the sources list, both ranked
--  pools, the node's own candidate links and every node's title. Data and not
--  instructions; what an author does with it is the skill's.
package Synapse.Commands.Brief is

   --  `brief --lists <dir> [--rank <dir>] [--links <file>] [--repo <path>]
   --  [--out <dir>]`: `brief/NNN.md` under the output directory. A missing
   --  rank directory or link graph is advice: empty sections and a warning. A
   --  missing or empty lists directory is fatal.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Brief;
