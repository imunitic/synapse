--  `synapse-pipeline definitions [--format json|text]`: every definition the
--  search directories hold and every file that did not load.
--
--  The definitions are loaded as `check` loads them. Each is listed with its
--  kind, name and file, in alphabetical order of name; each problem the load
--  found is listed with its file, line, column and message. Nothing beyond
--  loading is validated, and the exit code is 0 whatever is found.

package Synapse.Pipeline.Commands.Definitions is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Definitions;
