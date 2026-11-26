--  `synapse-pipeline name <execution-id> [<text>]`: names an execution, or
--  removes its name when no text is given.
--
--  The name is kept in the execution's record, so it works whether the run is
--  going on or over; the run itself is never asked. A text that is not one
--  line of 1 to 120 characters is a usage error, and an execution the work
--  directory does not hold is an error.

package Synapse.Pipeline.Commands.Name is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Name;
