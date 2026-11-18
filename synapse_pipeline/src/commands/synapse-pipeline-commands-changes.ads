--  `synapse-pipeline changes <execution-id> [--step <name>]
--  [--format json|text]`: what the steps of a run changed in the folder they
--  worked in, from the run's record.
--
--  Each session that changed something left a patch in the record, as `git
--  diff` prints it. They are printed in the order the steps ran, one after
--  another, each under a line that names its step, visit and attempt. A new
--  file whose content was over the limit is there as its path and number of
--  lines. The format `json` is for a program: a `steps` list with the step,
--  visit, attempt and patch of each, and the `directory` the steps worked in.

package Synapse.Pipeline.Commands.Changes is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Changes;
