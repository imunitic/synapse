with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;

--  The checks on one field's value that a note's frontmatter and a pipeline
--  input share: its type, `const`, `min_length`, `pattern`, `enum` and the
--  timestamp form. The value is JSON, so both callers report a problem in
--  the same words.

package Synapse.Core.Field_Rules is

   package JSON renames Synapse.Core.JSON;

   --  The first problem with Value under Rule (a field rule a schema
   --  validator has accepted), as "<Prefix>: <problem>", or nothing.
   --  `required`, `mutable`, `description` and `items` are not looked at
   --  here. The type `any` takes every value; `string` and `timestamp` take
   --  a string, `integer` an integer, `boolean` a boolean and `list` an
   --  array. `const`, `min_length`, `pattern`, `enum` and the timestamp
   --  form apply to a string only.
   function Check_Value
     (Prefix : String; Rule : JSON.Value; Value : JSON.Value)
      return Synapse.Core.Optional_Text.Option;

end Synapse.Core.Field_Rules;
