--  Note schemas: checking that a schema document is itself well formed.
--
--  A schema document (read by Schema_YAML) declares the frontmatter fields a
--  note may have, the body structure it must follow, and the JsonLogic
--  `checks:` and `lints:` that apply to it. Validate_Schema checks the
--  document against the v1 schema language and reports the first problem as a
--  one-line diagnostic; a schema that passes can be used to check notes.

with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.JSON_Logic;

package Synapse.Core.Note_Schema is

   package JSON renames Synapse.Core.JSON;

   --  What a `lints:` rule's finding does: Ignore skips the rule, Warn is
   --  advisory, Error_Level blocks a write the way a failed check does.
   type Severity is (Ignore, Warn, Error_Level);

   type Maybe_Severity (Found : Boolean := False) is record
      case Found is
         when True =>
            Level : Severity;

         when False =>
            null;
      end case;
   end record;

   --  `ignore`, `warn` or `error`.
   function Parse_Severity (Text : String) return Maybe_Severity;

   --  Valid, or the diagnostic for the first problem found.
   type Check_Result (Valid : Boolean := True) is record
      case Valid is
         when True =>
            null;

         when False =>
            Message : Ada.Strings.Unbounded.Unbounded_String;
      end case;
   end record;

   --  Checks Root against the v1 schema language, in this order: the header
   --  (`schema` and `id`, which must equal Expected_Id), the frontmatter
   --  rules, the body rules, `checks:` and `lints:`. A rule may use an
   --  operator that is built in or that Ops provides, and nothing else.
   function Validate_Schema
     (Root        : JSON.Value;
      Expected_Id : String;
      Ops         : JSON_Logic.Operator_Set'Class := JSON_Logic.No_Operators)
      return Check_Result;

end Synapse.Core.Note_Schema;
