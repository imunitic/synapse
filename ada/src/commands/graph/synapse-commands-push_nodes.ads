with Synapse.Commands.Context;

--  `push-nodes [NN ...]`: one node written for each authored body, pairing
--  `$SYNAPSE_WORK_DIR/b-NN.md` with `lists/NN.txt` and `lists/NN.title`.
--  With no numbers the nodes are the union of the staged lists and the
--  authored bodies, so a node with no body reports as skipped and does not
--  vanish. Any node that fails makes the run fail, and so does a run that
--  pushed nothing: a no-op would otherwise read as success.
package Synapse.Commands.Push_Nodes is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  The command for an already resolved context. Explicit says Targets
   --  came from the command line; when it did not, they are discovered.
   function Push
     (Env      : Environment; Ctx : Context.Context; Targets : Lists.Vector;
      Explicit : Boolean) return Exit_Code;

end Synapse.Commands.Push_Nodes;
