with Synapse.Core.JSON;

--  Reading what a harness wrote as one JSON object per line, which is how
--  each of the three writes both its output and its transcript.

package Synapse.Pipeline.Json_Lines is

   package JSON renames Synapse.Core.JSON;

   --  Calls Each with every line of Text that is a JSON object. A line that is
   --  blank, is not JSON or is not an object is skipped, so a line still being
   --  written when Text was read does not stop the others.
   procedure For_Each_Line
     (Text : String; Each : not null access procedure (Item : JSON.Value));

   --  The string member Key of Item, empty when Item is not an object or has
   --  no such string member.
   function Text_Member (Item : JSON.Value; Key : String) return String;

   --  The member Key of Item, null when Item is not an object or has none.
   function Object_Member (Item : JSON.Value; Key : String) return JSON.Value;

end Synapse.Pipeline.Json_Lines;
