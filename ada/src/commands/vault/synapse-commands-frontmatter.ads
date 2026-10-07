with Ada.Strings.Unbounded;

--  `frontmatter get|set`: byte-preserving reads and single-key writes of a
--  note's frontmatter, the note addressed by its whole vault path.
package Synapse.Commands.Frontmatter is

   type Operation is (Invalid, Get, Set_Value, Add_Tag, Remove_Tag);

   --  What the arguments ask for. Invalid is every rejection: a missing
   --  piece, an unknown word, a tag flag together with `<key> <value>`.
   type Request is record
      Op    : Operation := Invalid;
      Path  : Ada.Strings.Unbounded.Unbounded_String;
      Key   : Ada.Strings.Unbounded.Unbounded_String;
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Key is the field of Get and Set_Value, Value the new value of Set_Value
   --  and the tag of Add_Tag and Remove_Tag.
   function Parse (Args : Lists.Vector) return Request;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Frontmatter;
