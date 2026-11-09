with Synapse.Core.JSON;

--  A JSON value as text a person reads: one member or element to a line, two
--  spaces to a level, `": "` between a key and its value, and `[]` and `{}`
--  for what is empty. Members and elements are in the order they have.
--  Strings and numbers are written as Synapse.Core.JSON.To_String writes
--  them.

package Synapse.Core.JSON_Indent with
  SPARK_Mode => Off
is

   function Indented (V : JSON.Value) return String;

end Synapse.Core.JSON_Indent;
