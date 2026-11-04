--  `synapse-pipeline cleanup`: removes the records of executions that are
--  over.
--
--  An execution whose socket answers is running and is never removed. One
--  that does not answer is removed when its last write is older than the age
--  given, 30 days when none is. With --all an execution that completed or
--  failed is removed whatever its age; one that was interrupted, or has no
--  summary to date it by, is still kept until it is old enough, since nothing
--  shows that it is not still going. A whole execution directory goes or none
--  of it does.

package Synapse.Pipeline.Commands.Cleanup is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Cleanup;
