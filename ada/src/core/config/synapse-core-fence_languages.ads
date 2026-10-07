with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  Which fence language a crux block's file extension gets. A flat JSON
--  object, `{".ext": "lang"}`, and no ordered list: a path ends in one
--  registered extension at a time, so there is no question of precedence. The
--  registry ships empty, and what it does not map gets no language: a bare
--  fence.

package Synapse.Core.Fence_Languages is

   use Ada.Strings.Unbounded;

   type Entry_Type is record
      Extension : Unbounded_String;
      Language  : Unbounded_String;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors (Positive, Entry_Type);

   --  In file order.
   type Registry is record
      Entries : Entry_Vectors.Vector;
   end record;

   Malformed : exception;

   --  The registry a JSON object of extension to language describes. A member
   --  whose value is not a string is left out, and anything but an object is
   --  an empty registry. Raises Malformed when the text is not JSON.
   function Parse (Text : String) return Registry;

   --  The fence language of a path: the first entry whose extension the path
   --  ends with, empty when there is none.
   function Language_For (R : Registry; Path : String) return String;

end Synapse.Core.Fence_Languages;
