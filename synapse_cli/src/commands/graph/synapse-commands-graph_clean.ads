--  `graph-clean [--dry-run]`: removes the namespaces of branches that were
--  deleted upstream, and reports the ones it cannot be sure about.
package Synapse.Commands.Graph_Clean is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Graph_Clean;
