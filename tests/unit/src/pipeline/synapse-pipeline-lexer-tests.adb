with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Interfaces;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Source_Errors;

package body Synapse.Pipeline.Lexer.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_32;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package JSON renames Synapse.Core.JSON;
   package Errors renames Synapse.Pipeline.Source_Errors;

   use type JSON.Kind;

   LF : constant Character := Character'Val (10);
   BS : constant Character := Character'Val (92);

   --  The tokens of Source, which must lex.
   function Lex (Source : String) return Token_Vectors.Vector is
      R : constant Lex_Results.Result := Tokenize (Source);
   begin
      Assert
        (Lex_Results.Is_Success (R),
         "lexes: " & (if Lex_Results.Is_Success (R) then ""
                      else Errors.Image (Lex_Results.Error (R))));
      return Lex_Results.Value_Or (R, Token_Vectors.Empty_Vector);
   end Lex;

   --  The one token a Source of a single token makes, before End_Of_Input.
   function Only (Source : String) return Token is
      V : constant Token_Vectors.Vector := Lex (Source);
   begin
      Assert (Natural (V.Length) = 2, "one token and the end: " & Source);
      return V.First_Element;
   end Only;

   function Kinds (V : Token_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for T of V loop
         Append (Result, Token_Kind'Image (T.Kind) & " ");
      end loop;
      return To_String (Result);
   end Kinds;

   --  Source must fail with Message in its text, at Line and Column.
   procedure Assert_Fails
     (Source  : String; Line, Column : Positive; Message : String;
      Label   : String)
   is
      R : constant Lex_Results.Result := Tokenize (Source);
   begin
      Assert (not Lex_Results.Is_Success (R), Label & ": fails");
      if not Lex_Results.Is_Success (R) then
         declare
            E : constant Errors.Source_Error := Lex_Results.Error (R);
         begin
            Assert
              (E.Line = Line and then E.Column = Column,
               Label & ": at " & Errors.Image (E));
            Assert
              (Ada.Strings.Fixed.Index (To_String (E.Message), Message) > 0,
               Label & ": says '" & Message & "', says " & Errors.Image (E));
         end;
      end if;
   end Assert_Fails;

   procedure Empty_Source_Is_Only_The_End (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      V : constant Token_Vectors.Vector := Lex ("");
   begin
      Assert (Kinds (V) = "END_OF_INPUT ", "just the end: " & Kinds (V));
      Assert
        (V.First_Element.Line = 1 and then V.First_Element.Column = 1,
         "at 1:1");
      Assert (Kinds (Lex (" " & LF & LF & "  ")) = "END_OF_INPUT ", "blank");
   end Empty_Source_Is_Only_The_End;

   procedure A_Pipeline_Lexes_To_Its_Tokens_With_Positions
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : constant Token_Vectors.Vector :=
        Lex
          ("Pipeline Develop_Feature {" & LF
           & "   Develop [Agent => Developer, Retries => 2];" & LF
           & "   Review -> Develop [When => Changes_Requested];" & LF
           & "}" & LF);
   begin
      Assert
        (Kinds (V) =
         "IDENTIFIER IDENTIFIER LEFT_BRACE "
         & "IDENTIFIER LEFT_BRACKET IDENTIFIER FAT_ARROW IDENTIFIER COMMA "
         & "IDENTIFIER FAT_ARROW INTEGER_LITERAL RIGHT_BRACKET SEMICOLON "
         & "IDENTIFIER ARROW IDENTIFIER LEFT_BRACKET IDENTIFIER FAT_ARROW "
         & "IDENTIFIER RIGHT_BRACKET SEMICOLON RIGHT_BRACE END_OF_INPUT ",
         "the kinds: " & Kinds (V));
      Assert
        (To_String (V (1).Name) = "Pipeline" and then V (1).Line = 1
         and then V (1).Column = 1,
         "Pipeline at 1:1");
      Assert
        (To_String (V (2).Name) = "Develop_Feature" and then V (2).Column = 10,
         "Develop_Feature at 1:10");
      Assert (V (3).Line = 1 and then V (3).Column = 26, "{ at 1:26");
      Assert (V (5).Line = 2 and then V (5).Column = 12, "[ at 2:12");
      Assert (V (7).Line = 2 and then V (7).Column = 19, "=> at 2:19");
      Assert
        (V (12).Number = 2 and then V (12).Column = 44, "2 at 2:44");
      Assert (V (14).Column = 46, "; at 2:46");
      Assert (V (16).Line = 3 and then V (16).Column = 11, "-> at 3:11");
      Assert (V (24).Line = 4 and then V (24).Column = 1, "} at 4:1");
      Assert
        (V.Last_Element.Line = 5 and then V.Last_Element.Column = 1,
         "the end at 5:1");
   end A_Pipeline_Lexes_To_Its_Tokens_With_Positions;

   procedure Comments_Run_To_The_End_Of_The_Line (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : constant Token_Vectors.Vector :=
        Lex
          ("A -- a comment { with => things" & LF & "B --" & LF & "C -- last");
   begin
      Assert
        (Kinds (V) = "IDENTIFIER IDENTIFIER IDENTIFIER END_OF_INPUT ",
         "only A B C: " & Kinds (V));
      Assert (V (2).Line = 2 and then V (3).Line = 3, "lines are kept");
      Assert
        (Kinds (Lex ("A->B")) = "IDENTIFIER ARROW IDENTIFIER END_OF_INPUT ",
         "an arrow is not a comment");
   end Comments_Run_To_The_End_Of_The_Line;

   procedure Identifiers_Keep_Their_Case (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      V : constant Token_Vectors.Vector := Lex ("Harness_Id h2 X_1_y");
   begin
      Assert
        (To_String (V (1).Name) = "Harness_Id"
         and then To_String (V (2).Name) = "h2"
         and then To_String (V (3).Name) = "X_1_y",
         "names as written");
   end Identifiers_Keep_Their_Case;

   procedure Strings_Are_Unescaped_Like_JSON (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      S : constant Token :=
        Only ("""a\nb \""q\"" " & BS & "u00e9 " & BS & BS & """");
   begin
      Assert (S.Kind = String_Literal, "a string");
      Assert
        (To_String (S.Text) = "a" & LF & "b ""q"" " & Character'Val (16#C3#)
         & Character'Val (16#A9#) & " \",
         "unescaped to UTF-8");
      Assert (To_String (Only ("""""").Text) = "", "the empty string");
      Assert
        (To_String (Only ("""[not {json}] -- nor a comment""").Text) =
         "[not {json}] -- nor a comment",
         "brackets and dashes inside a string are text");
   end Strings_Are_Unescaped_Like_JSON;

   procedure A_Triple_Quoted_Block_Is_Verbatim (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : constant Token_Vectors.Vector :=
        Lex
          ("""""""Line one" & LF & "  ""quoted"" \n stays" & LF & """"""""
           & " X");
   begin
      Assert (V (1).Kind = String_Literal, "a string");
      Assert
        (To_String (V (1).Text) =
         "Line one" & LF & "  ""quoted"" \n stays" & LF,
         "verbatim, escapes and all");
      Assert
        (V (2).Kind = Identifier and then V (2).Line = 3
         and then V (2).Column = 5,
         "the next token is on line 3, after the block");
      Assert (To_String (Only ("""""""""""""").Text) = "", "an empty block");
   end A_Triple_Quoted_Block_Is_Verbatim;

   procedure Integers_Are_Plain_Decimal (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Only ("0").Number = 0, "0");
      Assert (Only ("42").Number = 42, "42");
      Assert (To_String (Only ("007").Numeral) = "007", "digits as written");
      Assert
        (Only ("9223372036854775807").Number = Long_Long_Integer'Last,
         "the largest");
      Assert_Fails
        ("9223372036854775808", 1, 1, "out of range", "one too many");
      Assert_Fails ("12abc", 1, 1, "malformed number", "letters after digits");
      Assert_Fails ("12_", 1, 1, "malformed number", "underscore after");
   end Integers_Are_Plain_Decimal;

   procedure A_JSON_Literal_Follows_A_Fat_Arrow (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : constant Token_Vectors.Vector :=
        Lex
          ("When => {""a"": ""}]\"""", ""b"": [1, {""c"": 2}]};" & LF & "X");
   begin
      Assert
        (Kinds (V) = "IDENTIFIER FAT_ARROW JSON_LITERAL SEMICOLON "
         & "IDENTIFIER END_OF_INPUT ",
         "the literal is one token: " & Kinds (V));
      Assert
        (JSON.Kind_Of (V (3).Json) = JSON.JSON_Object
         and then JSON.Has_Member (V (3).Json, "b"),
         "an object, parsed");
      Assert
        (JSON.As_String (JSON.Member_Value (V (3).Json, "a")) = "}]""",
         "brackets and a quote inside a string do not end it");
      Assert
        (To_String (V (3).Source)(1) = '{' and then V (3).Column = 9,
         "the source text, at 1:9");
      Assert (V (5).Line = 2, "the next line");
   end A_JSON_Literal_Follows_A_Fat_Arrow;

   procedure A_JSON_Array_Literal_And_Multiple_Lines
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : constant Token_Vectors.Vector :=
        Lex ("Tools => [""Read""," & LF & "   ""Grep""]" & LF & "Next");
   begin
      Assert
        (Kinds (V) = "IDENTIFIER FAT_ARROW JSON_LITERAL IDENTIFIER "
         & "END_OF_INPUT ",
         "kinds: " & Kinds (V));
      Assert
        (JSON.Kind_Of (V (3).Json) = JSON.JSON_Array
         and then JSON.Length (V (3).Json) = 2,
         "an array of two");
      Assert
        (V (4).Line = 3 and then V (4).Column = 1,
         "lines counted through the literal");
   end A_JSON_Array_Literal_And_Multiple_Lines;

   procedure Braces_Mean_Their_Own_Thing_Away_From_A_Fat_Arrow
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Kinds (Lex ("Name { A [x => y] }")) =
         "IDENTIFIER LEFT_BRACE IDENTIFIER LEFT_BRACKET IDENTIFIER FAT_ARROW "
         & "IDENTIFIER RIGHT_BRACKET RIGHT_BRACE END_OF_INPUT ",
         "braces and brackets");
      Assert
        (Kinds (Lex ("a => b [")) =
         "IDENTIFIER FAT_ARROW IDENTIFIER LEFT_BRACKET END_OF_INPUT ",
         "only the token right after => starts a literal");
   end Braces_Mean_Their_Own_Thing_Away_From_A_Fat_Arrow;

   procedure Columns_Count_Characters_Not_Bytes (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : constant Token_Vectors.Vector :=
        Lex
          ("""" & Character'Val (16#C3#) & Character'Val (16#A9#) & """ X");
   begin
      Assert
        (V (2).Column = 5,
         "X is the fifth character on the line, not the sixth byte");
   end Columns_Count_Characters_Not_Bytes;

   procedure Errors_Name_The_Line_And_Column (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert_Fails
        ("Name => ""abc", 1, 9, "unterminated string", "unterminated string");
      Assert_Fails
        ("X => ""ab" & LF & "cd""", 1, 9, "line break in a string",
         "a line break in a string");
      Assert_Fails
        ("X => ""a\qb""", 1, 8, "invalid escape",
         "an invalid escape, at its backslash");
      Assert_Fails
        ("""""""abc", 1, 1, "unterminated triple-quoted", "open block");
      Assert_Fails
        ("A => {""a"": 1", 1, 6, "unterminated JSON", "an open JSON literal");
      Assert_Fails
        ("A => {""a"" 1}", 1, 11, "bad JSON value", "JSON missing a colon");
      Assert_Fails ("A = B", 1, 3, "lone '='", "a lone =");
      Assert_Fails ("A - B", 1, 3, "lone '-'", "a lone -");
      Assert_Fails ("A @ B", 1, 3, "unexpected character '@'", "an at sign");
      Assert_Fails
        ("A " & Character'Val (16#C3#) & Character'Val (16#A9#), 1, 3,
         "unexpected character (code", "non-ASCII outside a string");
      Assert_Fails
        ("A" & LF & "B" & LF & "  @", 3, 3, "unexpected character",
         "a later line");
      Assert_Fails
        ("A => {" & LF & "  ""k"": 1," & LF & "  ""j"" 2 }", 3, 7,
         "bad JSON value", "a position inside a multi-line literal");
   end Errors_Name_The_Line_And_Column;

   procedure Random_Source_Never_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Alphabet : constant String :=
        """\{}[]=>-,; " & LF & "A1_aZ9" & Character'Val (16#C3#)
        & Character'Val (16#A9#) & Character'Val (0) & "@";
      Seed     : Interfaces.Unsigned_32 := 12345;

      function Next (Limit : Positive) return Positive is
      begin
         Seed := Seed * 1664525 + 1013904223;
         return Natural (Seed / 65536) mod Limit + 1;
      end Next;
   begin
      for Round in 1 .. 4000 loop
         declare
            Source : String (1 .. Next (40));
         begin
            for I in Source'Range loop
               Source (I) := Alphabet (Next (Alphabet'Length));
            end loop;
            declare
               R : constant Lex_Results.Result := Tokenize (Source);
            begin
               if Lex_Results.Is_Success (R) then
                  Assert
                    (Lex_Results.Value (R).Last_Element.Kind = End_Of_Input,
                     "ends with the end: round" & Round'Image);
               else
                  Assert
                    (Lex_Results.Error (R).Line <=
                     Ada.Strings.Fixed.Count (Source, "" & LF) + 1,
                     "a line inside the source: round" & Round'Image);
               end if;
            end;
         exception
            when others =>
               Assert (False, "raised on round" & Round'Image);
         end;
      end loop;
   end Random_Source_Never_Raises;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Lexer");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Empty_Source_Is_Only_The_End'Access,
         "Empty source is only the end");
      Register_Routine
        (T, A_Pipeline_Lexes_To_Its_Tokens_With_Positions'Access,
         "A pipeline lexes to its tokens with positions");
      Register_Routine
        (T, Comments_Run_To_The_End_Of_The_Line'Access,
         "Comments run to the end of the line");
      Register_Routine
        (T, Identifiers_Keep_Their_Case'Access,
         "Identifiers keep their case");
      Register_Routine
        (T, Strings_Are_Unescaped_Like_JSON'Access,
         "Strings are unescaped like JSON");
      Register_Routine
        (T, A_Triple_Quoted_Block_Is_Verbatim'Access,
         "A triple-quoted block is verbatim");
      Register_Routine
        (T, Integers_Are_Plain_Decimal'Access, "Integers are plain decimal");
      Register_Routine
        (T, A_JSON_Literal_Follows_A_Fat_Arrow'Access,
         "A JSON literal follows a fat arrow");
      Register_Routine
        (T, A_JSON_Array_Literal_And_Multiple_Lines'Access,
         "A JSON array literal may span lines");
      Register_Routine
        (T, Braces_Mean_Their_Own_Thing_Away_From_A_Fat_Arrow'Access,
         "Braces mean their own thing away from a fat arrow");
      Register_Routine
        (T, Columns_Count_Characters_Not_Bytes'Access,
         "Columns count characters not bytes");
      Register_Routine
        (T, Errors_Name_The_Line_And_Column'Access,
         "Errors name the line and column");
      Register_Routine
        (T, Random_Source_Never_Raises'Access,
         "Random source never raises");
   end Register_Tests;

end Synapse.Pipeline.Lexer.Tests;
