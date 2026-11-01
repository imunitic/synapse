with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Core.Options;

--  How a step can fail to produce a result. A failure never advances a
--  pipeline: the step it happened in is the one a caller starts from again.

package Synapse.Pipeline.Failures is

   type Failure_Kind is
     (Execution_Error,
      Result_Contract_Failure,
      Quota_Exhausted,
      Ceiling_Reached);

   package Kind_Options is new Synapse.Core.Options (Failure_Kind);

   --  The name in a document: `execution_error`, `result_contract_failure`,
   --  `quota_exhausted`, `ceiling_reached`.
   function Name_Of (Kind : Failure_Kind) return String is
     (case Kind is
        when Execution_Error          => "execution_error",
        when Result_Contract_Failure  => "result_contract_failure",
        when Quota_Exhausted          => "quota_exhausted",
        when Ceiling_Reached          => "ceiling_reached");

   function Find (Name : String) return Kind_Options.Option;

   type Failure is record
      Kind    : Failure_Kind := Execution_Error;

      --  The step it happened in.
      Step    : Ada.Strings.Unbounded.Unbounded_String;
      Message : Ada.Strings.Unbounded.Unbounded_String;

      --  When a quota resets, as the harness said it, if it did.
      Reset   : Synapse.Core.Optional_Text.Option;
   end record;

end Synapse.Pipeline.Failures;
