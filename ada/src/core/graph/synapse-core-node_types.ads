with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Kind_Synonyms;

--  Guessing which node types of a grammar are declarations, and which field
--  holds the name, from the grammar's own `node-types.json`. A heuristic and
--  not a reading of the schema, which says nothing about meaning: a suffix
--  or prefix test on the type name, and a field called `name`. It reads JSON
--  only. The second half, finding a name for a type that has no `name` field,
--  needs a parsed tree and is the tagger's.
--
--  The kind synonym rules are consulted and not only applied afterwards: a
--  rule can name a type the heuristic missed altogether, such as a type that
--  is a whole function with its body but has none of the declaration
--  suffixes, which a rule that only relabels could never reach.

package Synapse.Core.Node_Types is

   use Ada.Strings.Unbounded;

   Malformed : exception;

   --  One node type judged declaration-shaped, and how to find its name.
   type Guess is record
      --  The grammar's own node type name.
      Type_Name      : Unbounded_String;
      --  A kind from the vocabulary of a tag, from whichever rule matched.
      Kind           : Unbounded_String;
      --  Whether the type declares a `name` field. True means the generated
      --  query covers it; false means only the tagger's walk can.
      Has_Name_Field : Boolean := False;
   end record;

   package Guess_Vectors is new Ada.Containers.Vectors (Positive, Guess);

   --  The kind of a declaration that matches a suffix and no prefix word.
   Generic_Kind : constant String := "function";

   --  The declaration-shaped types of the text of a `node-types.json`, in
   --  file order. An entry is one when it is named (an anonymous type is
   --  punctuation or a keyword), and either a rule gives its type a kind in
   --  Scope or its name ends in `declaration`, `definition`, `_item`,
   --  `_specifier`, `decl`, `def` or `_binding`, whatever the case. Its kind
   --  is the rule's, else the word it starts with (`class`, `struct`, `enum`,
   --  `interface`, `trait`, `module`, `namespace`, `const`, `var`,
   --  `variable`, `param`, `parameter`, `package`, `import`, `container`,
   --  `error`, `test`) when the word ends the name or is followed by `_` or a
   --  capital letter, else Generic_Kind. A name beginning with such a word and
   --  nothing more is not a declaration: a type called `struct` is a type
   --  expression. Anything but an array has none. Raises Malformed when the
   --  text is not JSON.
   function Classify
     (Json_Text : String; Rules : Kind_Synonyms.Rule_List; Scope : String)
      return Guess_Vectors.Vector;

   --  One pattern per guess with a name field, in the capture shape of a tags
   --  query, each followed by a line feed. A guess with no name field adds
   --  nothing.
   function Build_Query (Guesses : Guess_Vectors.Vector) return String;

end Synapse.Core.Node_Types;
