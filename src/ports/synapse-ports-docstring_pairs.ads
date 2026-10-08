with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  What a command learns about the docstrings of one file: each comment run
--  and the declaration directly below it. Where the pairs come from is the
--  factory's (`Extractor_Factory`): the real one parses with a grammar, a
--  test scripts them.
package Synapse.Ports.Docstring_Pairs is

   use Ada.Strings.Unbounded;

   --  One comment run and the declaration directly below it.
   type Pair is record
      --  The declaration's raw node type.
      Kind                 : Unbounded_String;
      --  The declaration's first line of text.
      Name                 : Unbounded_String;
      --  Each comment of the run, joined by line feeds.
      Docstring_Text       : Unbounded_String;
      --  The declaration's whole text.
      Decl_Text            : Unbounded_String;
      --  1-based and inclusive, the numbering the docstring index uses.
      Docstring_Start_Line : Positive;
      Docstring_End_Line   : Positive;
      Decl_Start_Line      : Positive;
      Decl_End_Line        : Positive;
   end record;

   package Pair_Vectors is new Ada.Containers.Vectors (Positive, Pair);

   --  No_Grammar: nothing registered or usable for the extension. Failed: a
   --  grammar that would not parse the file.
   type Finding_Kind is (No_Grammar, Failed, Found);

   type Finding (Kind : Finding_Kind := No_Grammar) is record
      case Kind is
         when Found =>
            Pairs : Pair_Vectors.Vector;

         when No_Grammar | Failed =>
            null;
      end case;
   end record;

end Synapse.Ports.Docstring_Pairs;
