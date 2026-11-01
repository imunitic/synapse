with Synapse.Core.Results;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Namespaces;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Source_Errors;

--  A pipeline definition and the systems and agents it names, made into the
--  one thing a run works from.
--
--  A step is merged with its system:
--    * each of Harness, Model, Permissions, Tools, Timeout, Retries and Agent
--      is the step's own when it has one, else the system's;
--    * the assignment is the step's `Prompt` or `Skill` when it has either,
--      and then the system's is dropped whole; otherwise it is the system's;
--    * the role is the instructions of the agent that results.
--  A step with no harness of its own or from its system takes the default
--  one. The guard of a bare name such as `Changes_Requested` becomes the
--  JsonLogic test `outcome == "Changes_Requested"`; a guard written as JSON is
--  kept as it is.
--
--  This is for a pipeline that validation passed. Anything missing that it
--  would have caught is reported as a failure, not raised.

package Synapse.Pipeline.Resolution is

   package Resolve_Results is new Synapse.Core.Results
     (Resolved.Pipeline, Source_Errors.Source_Error);

   function Resolve
     (Defs            : Namespaces.Namespace;
      Name            : String;
      Default_Harness : Harnesses.Kind_Options.Option)
      return Resolve_Results.Result;

end Synapse.Pipeline.Resolution;
