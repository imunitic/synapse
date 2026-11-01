with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Results;
with Synapse.Pipeline.Source_Errors;

--  The first layer of the pipeline language: source text to a list of tokens.
--
--  Source is UTF-8. Whitespace separates tokens and is otherwise ignored, and
--  a comment runs from `--` to the end of the line. The tokens:
--
--    Identifier      a letter, then letters, digits and underscores; case is
--                    kept and is significant
--    String_Literal  `"..."` with JSON escapes, or a verbatim block between
--                    two triple quotes that may span lines
--    Integer_Literal decimal digits
--    JSON_Literal    after `=>`, a `{` or `[` begins a strict JSON value
--                    that runs to its matching close
--    Arrow, Fat_Arrow, the braces and brackets, Comma and Semicolon
--
--  The list always ends with an End_Of_Input token. Positions are a line and
--  a column, both counted from 1, the column in characters rather than bytes.

package Synapse.Pipeline.Lexer is

   type Token_Kind is
     (Identifier, String_Literal, Integer_Literal, JSON_Literal, Arrow,
      Fat_Arrow, Left_Brace, Right_Brace, Left_Bracket, Right_Bracket, Comma,
      Semicolon, End_Of_Input);

   --  A token, with the fields its kind has and no others. Reading a field
   --  of another kind raises Constraint_Error.
   type Token (Kind : Token_Kind := End_Of_Input) is record
      Line   : Positive := 1;
      Column : Positive := 1;

      case Kind is
         when Identifier =>
            --  The name, as written.
            Name : Ada.Strings.Unbounded.Unbounded_String;

         when String_Literal =>
            --  The text between the quotes, unescaped.
            Text : Ada.Strings.Unbounded.Unbounded_String;

         when Integer_Literal =>
            Numeral : Ada.Strings.Unbounded.Unbounded_String;
            Number : Long_Long_Integer := 0;

         when JSON_Literal =>
            --  The source text, and what it parses to.
            Source : Ada.Strings.Unbounded.Unbounded_String;
            Json   : Synapse.Core.JSON.Value;

         when Arrow | Fat_Arrow | Left_Brace | Right_Brace | Left_Bracket
            | Right_Bracket | Comma | Semicolon | End_Of_Input =>
            null;
      end case;
   end record;

   package Token_Vectors is new Ada.Containers.Vectors (Positive, Token);

   package Lex_Results is new Synapse.Core.Results
     (Token_Vectors.Vector, Source_Errors.Source_Error);

   --  The tokens of Source, or the first thing wrong with it and where.
   function Tokenize (Source : String) return Lex_Results.Result with
     Pre => Source'Last < Positive'Last;

end Synapse.Pipeline.Lexer;
