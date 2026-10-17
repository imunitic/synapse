--  `index` and `build-index`: the read and write surface of `_index.bin`, the
--  map from each file to the nodes that claim it.
package Synapse.Commands.Index is

   --  `index build|unassigned|lookup|nodes|paths|add-unassigned`.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `build-index`: the whole of `index build --lists`, every path taken
   --  from the work directory.
   function Run_Build_Index
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Index;
