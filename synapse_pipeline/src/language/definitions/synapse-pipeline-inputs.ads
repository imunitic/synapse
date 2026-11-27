with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;

--  The input a run starts with, held to the pipeline's `Input` declaration.
--
--  A pipeline without a declaration takes any input as it is. With one, the
--  input is checked by `Synapse.Core.Object_Schema.Validate_Object`, after
--  two conveniences: a plain JSON string is taken as the value of the one
--  required field when that field is the only required one and a `string`,
--  and no input at all (null) is checked as `{}`. An accepted input drops
--  the optional fields given as "" or [], which count as not given.

package Synapse.Pipeline.Inputs is

   package JSON renames Synapse.Core.JSON;

   --  The input to run with, or every problem with the one given.
   type Acceptance (Accepted : Boolean := False) is record
      case Accepted is
         when True =>
            Input : JSON.Value;

         when False =>
            Problems : Synapse.Core.Text_Lists.Vector;
      end case;
   end record;

   --  Given held to Declared, a pipeline's resolved `Input` (null when it
   --  declares none, otherwise valid per `Validate_Declaration`).
   function Accept_Input (Declared, Given : JSON.Value) return Acceptance;

   --  The name of the one required field when it is the only required one
   --  and a `string`: the field a plain sentence fills. Nothing otherwise,
   --  and nothing without a declaration.
   function Single_Text_Field
     (Declared : JSON.Value) return Synapse.Core.Optional_Text.Option;

end Synapse.Pipeline.Inputs;
