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
--
--  Given execution ids instead, it removes those, in the order given and
--  once each, whatever their age or status; one that is running, or is not
--  recorded, is kept and reported, and then it exits 1.
--
--  With --format json nothing is printed per execution; one
--  synapse-pipeline-cleanup/v1 document at the end lists the executions
--  removed (or, with --dry-run, that would be) and the ones kept, each with
--  why: running, too_recent, not_found or cannot_remove.

package Synapse.Pipeline.Commands.Cleanup is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Cleanup;
