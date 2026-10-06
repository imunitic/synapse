with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  The types the code graph is made of. Small, and free of any notion of
--  where a definition or a reference came from or where it is stored.

package Synapse.Core.Graph_Model with SPARK_Mode => Off is

   use Ada.Strings.Unbounded;

   --  A reference is not necessarily a call (`implements Foo` is a reference
   --  of kind `implementation`), so filtering on the role alone over-reports.
   type Role is (Def, Ref);

   --  The role as written in the files: `def` or `ref`.
   function Image (R : Role) return String
   is (case R is when Def => "def", when Ref => "ref");

   type Maybe_Role (Found : Boolean := False) is record
      case Found is
         when True =>
            Value : Role;

         when False =>
            null;
      end case;
   end record;

   function Parse (Text : String) return Maybe_Role;

   --  One tagged symbol occurrence.
   type Tag is record
      --  Trimmed: tree-sitter pads this column with blanks, and an exact
      --  lookup against the raw text would find nothing.
      Name       : Unbounded_String;
      Kind       : Unbounded_String;  --  class, method, call, implementation..
      Which      : Role;
      --  As tree-sitter numbers it, unchanged: the rows of `_refs.tsv` and
      --  `path:line` output must not move.
      Line       : Natural;
      --  The source line the occurrence is on, as tree-sitter echoed it.
      Expression : Unbounded_String;
   end record;

   --  A SHA-1 as 20 bytes: half the size of its hex form in a cache record,
   --  and compared with one comparison.
   type Hash is array (1 .. 20) of Natural range 0 .. 255;

   type Hash_Result (Valid : Boolean := False) is record
      case Valid is
         when True =>
            Value : Hash;

         when False =>
            null;
      end case;
   end record;

   --  Exactly 40 hexadecimal digits, either case. Anything else is refused
   --  and never padded.
   function Hash_From_Hex (Hex : String) return Hash_Result;

   --  40 lowercase hexadecimal digits.
   function Hash_To_Hex (Value : Hash) return String
   with Post => Hash_To_Hex'Result'Length = 40;

   --  A source file a node claims, at the content hash it was last seen with.
   type Source_Ref is record
      Path  : Unbounded_String;
      Which : Hash;
   end record;

   package Source_Vectors is new Ada.Containers.Vectors (Positive, Source_Ref);

   --  A graph node: a cluster of sources with prose about them. Only what the
   --  graph itself reasons about: the parts a person or a model writes are
   --  not here.
   type Node is record
      Name    : Unbounded_String;
      Sources : Source_Vectors.Vector;
      Stale   : Boolean := False;
   end record;

end Synapse.Core.Graph_Model;
