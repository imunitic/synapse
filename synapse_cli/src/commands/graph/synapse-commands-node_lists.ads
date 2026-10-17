with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  The path lists `build-lists` wrote, read back: `NNN.title` and `NNN.txt`
--  for each node from 001 to the most a namespace can have.
package Synapse.Commands.Node_Lists is

   type Node is record
      Number   : Positive;
      --  The first line of the title file, without its blanks.
      Title    : Ada.Strings.Unbounded.Unbounded_String;
      Txt_Path : Ada.Strings.Unbounded.Unbounded_String;
      --  Every line of the list but the empty ones, without a trailing
      --  carriage return.
      Paths    : Lists.Vector;
      --  How many lines have something other than blanks in them.
      Files    : Natural;
   end record;

   package Node_Vectors is new Ada.Containers.Vectors (Positive, Node);

   --  Each node of Dir that has a title and a list, ascending. One without
   --  either, or with a title of only blanks, is not one.
   function Read (Dir : String) return Node_Vectors.Vector;

   --  `007` for 7.
   function Slug (Number : Positive) return String;

end Synapse.Commands.Node_Lists;
