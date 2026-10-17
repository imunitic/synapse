--  `build-project-index`: the node map of a namespace, `Index.md`, written to
--  the vault from the nodes that are in it. It carries the `remote` the
--  session start hook checks before it injects a pointer.
package Synapse.Commands.Project_Index is

   --  `build-project-index`: a bullet for each `lists/NNN.title`, with the
   --  node's summary and how many files the list holds. A node that is not in
   --  the vault and a node with no summary are each an error with its own
   --  advice, since the index is built from the nodes and from nothing the
   --  build kept.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Project_Index;
