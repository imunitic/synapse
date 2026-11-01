with Synapse.Core.Results;
with Synapse.Pipeline.Lexer;
with Synapse.Pipeline.Source_Errors;
with Synapse.Pipeline.Syntax;

--  The second layer of the pipeline language: tokens to the definition a file
--  holds. A file holds exactly one:
--
--    file       = definition End_Of_Input
--    definition = "Pipeline" Name "{" { statement } "}"
--               | "System" Name attributes ";"
--               | "Agent" Name attributes ";"
--    statement  = Name attributes ";"
--               | Name { "->" Name } [ attributes ] ";"        (one or more)
--    attributes = "[" [ attribute { "," attribute } ] "]"
--    attribute  = Name "=>" ( Name | String | Integer | JSON value )
--
--  The parser reads what is written and no more: that a step is declared
--  once, that an attribute is a real one or that an edge ends at a step that
--  exists is for the validation that follows. The three keywords may name an
--  attribute but not a definition or a step.

package Synapse.Pipeline.Parser is

   use type Lexer.Token_Kind;

   package Parse_Results is new Synapse.Core.Results
     (Syntax.Definition, Source_Errors.Source_Error);

   --  The definition in a token list that ends with End_Of_Input, or the
   --  first thing wrong with it and where.
   function Parse
     (Tokens : Lexer.Token_Vectors.Vector) return Parse_Results.Result
   with
     Pre =>
       not Tokens.Is_Empty
       and then Tokens.Last_Element.Kind = Lexer.End_Of_Input;

   --  The definition in a text: Tokenize, then Parse.
   function Parse_Source (Source : String) return Parse_Results.Result
   with Pre => Source'Last < Positive'Last;

end Synapse.Pipeline.Parser;
