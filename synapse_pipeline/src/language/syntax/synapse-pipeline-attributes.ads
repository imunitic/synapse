with Synapse.Core.Options;
with Synapse.Pipeline.Source_Errors;
with Synapse.Pipeline.Syntax;

--  What each attribute may be: where it may appear and what it may hold. An
--  attribute is checked on its own here; that two of them do not contradict,
--  or that a name they hold refers to something, is checked where the whole
--  definition is.
--
--    Agent            step, system   a name
--    System           step           a name
--    Prompt           step, system, agent   a string, not empty
--    Skill            step, system, agent   a string, a skill name
--    Harness          step, system   a name
--    Model            step, system   a name or a string
--    Permissions      step, system   a name
--    Timeout          step, system   a string such as "30m", at most 30 days
--    Retries          step, system   an integer, at most 100
--    Outcomes         step, system   a JSON object from each outcome to its
--                                    meaning, see Outcomes
--    When             edge           a name or a JSON value
--    Max_Iterations   edge           an integer, from 1 to 100

package Synapse.Pipeline.Attributes is

   type Context is
     (Step_Context, Edge_Context, System_Context, Agent_Context);

   package Error_Options is new Synapse.Core.Options
     (Source_Errors.Source_Error);

   --  What is wrong with Item as an attribute of a Where, or nothing. The
   --  error is at the attribute's name when the attribute does not belong
   --  there, and at its value when the value is wrong.
   function Check
     (Where : Context; Item : Syntax.Attribute) return Error_Options.Option;

   --  Whether Name is one of the attributes there are.
   function Is_Known (Name : String) return Boolean;

end Synapse.Pipeline.Attributes;
