with Ada.Containers.Vectors;
with Ada.Exceptions;
with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Core.JSON;
with Synapse.Core.Note_Model;
with Synapse.Core.Note_Schema;

--  A note checked against a schema that Note_Schema.Validate_Schema has
--  accepted. A schema that has not been validated may raise.
--
--  Rules are evaluated with the operators of Note_Operators; an exception of
--  JSON_Logic (an operator given too few arguments, say) is not caught.

package Synapse.Core.Note_Check is

   package JSON renames Synapse.Core.JSON;

   --  The first problem a write would be refused for, or valid. Fields are
   --  checked in the schema's order, then the body, then the `checks:` rules
   --  in order. A failing rule gives its `message:`, or `rule failed: ` and
   --  the rule as JSON, cut to 512 bytes.
   function Validate_Note
     (Schema : JSON.Value;
      Note   : String;
      Path   : String;
      Ctx    : Note_Model.Context) return Note_Schema.Check_Result;

   type Finding is record
      Message : Ada.Strings.Unbounded.Unbounded_String;
      Level   : Note_Schema.Severity;
   end record;

   package Finding_Vectors is new Ada.Containers.Vectors (Positive, Finding);

   --  One finding for every `lints:` rule that does not hold, each with its
   --  own severity. A rule of severity `ignore` is not evaluated. A schema
   --  with no `lints:` gives none. The note is linted as an update.
   function Lint_Note
     (Schema : JSON.Value; Note, Path : String) return Finding_Vectors.Vector;

   subtype Maybe_Text is Synapse.Core.Optional_Text.Option;

   --  The `schema:` field of a note's frontmatter, quoted or not. A list, a
   --  mapping or an empty value is no identifier.
   function Schema_Id (Note : String) return Maybe_Text;

   --  The name a rule's failure is reported under: `InvalidArguments`,
   --  `UnknownOperator`, `PatternTooComplex`, and the exception's own name for
   --  anything else.
   function Fault_Name (E : Ada.Exceptions.Exception_Occurrence) return String;

end Synapse.Core.Note_Check;
