--  `graph-wipe [--dry-run]`: removes this namespace, keeping the hand-written
--  notes of its nodes.
package Synapse.Commands.Graph_Wipe is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Graph_Wipe;
