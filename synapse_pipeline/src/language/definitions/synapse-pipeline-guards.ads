with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Core.Results;
with Synapse.Core.Text_Lists;

--  The guards on a pipeline's edges: what a guard may see, whether a guard is
--  a rule that can be evaluated, and whether it holds of a step's result.
--
--  A guard is a JsonLogic rule over the finished step's result and nothing
--  else: `outcome`, `summary` and `data`, whatever else the result document
--  holds. It must come to a boolean; any other answer, and any rule the
--  evaluator cannot run, is a failure to report and not an answer, so a guard
--  that is wrong never moves a pipeline.

package Synapse.Pipeline.Guards is

   package JSON renames Synapse.Core.JSON;

   --  The result of a step as a guard sees it.
   function View
     (Outcome, Summary : String; Data : JSON.Value) return JSON.Value;

   --  What is wrong with Guard as a rule, found without running it: it must
   --  be a single rule, and every rule in it must name an operator the
   --  evaluator has. Nothing when it looks fine.
   function Problem (Guard : JSON.Value)
      return Synapse.Core.Optional_Text.Option;

   --  The data fields Guard reads: the first segment after `data.` of every
   --  `{"var": ...}` in it whose path is a literal string starting with
   --  `data.`, each named once, in the order first seen. A `var` given as a
   --  list reads its first element; a path that is not a literal string is
   --  skipped, since what it reads is not known until the guard runs.
   function Data_Fields_Read (Guard : JSON.Value)
      return Synapse.Core.Text_Lists.Vector;

   package Guard_Results is new Synapse.Core.Results
     (Boolean, Ada.Strings.Unbounded.Unbounded_String);

   --  Whether Guard holds of Result, a document with `outcome`, `summary`
   --  and `data` members. Only those three are visible to the rule; a missing
   --  field reads as null.
   function Holds
     (Guard : JSON.Value; Result : JSON.Value) return Guard_Results.Result;

end Synapse.Pipeline.Guards;
