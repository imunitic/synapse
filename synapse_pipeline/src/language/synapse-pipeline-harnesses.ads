with Ada.Strings.Unbounded;

with Synapse.Core.Options;
with Synapse.Core.Results;
with Synapse.Ports.Variables;

--  The harnesses a step can run on: the three agent programs Synapse supports.
--  A closed set, so that a name in a definition is checked against it and
--  nothing about a harness is looked up by a string.

package Synapse.Pipeline.Harnesses is

   type Harness_Kind is (Claude, Codex, Opencode);

   package Kind_Options is new Synapse.Core.Options (Harness_Kind);

   --  The name as a definition writes it, such as `Claude`.
   function Name_Of (Kind : Harness_Kind) return String is
     (case Kind is
        when Claude   => "Claude",
        when Codex    => "Codex",
        when Opencode => "Opencode");

   --  The harness a name stands for, or nothing. Names are exact: `claude`
   --  is not `Claude`.
   function Find (Name : String) return Kind_Options.Option;

   --  The variable that names the harness a step uses when neither it nor its
   --  system names one.
   Default_Variable : constant String := "SYNAPSE_PIPELINE_HARNESS";

   package Default_Results is new Synapse.Core.Results
     (Kind_Options.Option, Ada.Strings.Unbounded.Unbounded_String);

   --  The default harness: nothing when the variable is unset or empty, the
   --  harness it names, or why it names none.
   function Default
     (V : Synapse.Ports.Variables.Variables'Class)
      return Default_Results.Result;

   --  Every name, for saying what was expected: `Claude, Codex, Opencode`.
   function Names return String;

end Synapse.Pipeline.Harnesses;
