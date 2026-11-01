package body Synapse.Pipeline.Lexer is

   use Ada.Strings.Unbounded;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   function Is_Letter (C : Character) return Boolean is
     (C in 'A' .. 'Z' or else C in 'a' .. 'z');

   function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');

   --  The second and later bytes of a UTF-8 character.
   function Is_Continuation (C : Character) return Boolean is
     (Character'Pos (C) in 16#80# .. 16#BF#);

   function Describe (Kind : JSON.Parse_Error_Kind) return String is
     (case Kind is
        when JSON.Unexpected_Character => "unexpected character",
        when JSON.Unexpected_End       => "unexpected end",
        when JSON.Invalid_Escape       => "invalid escape",
        when JSON.Invalid_UTF8         => "invalid UTF-8",
        when JSON.Invalid_Number       => "invalid number",
        when JSON.Trailing_Data        => "unexpected data after the value",
        when JSON.Too_Deep             => "nested too deeply");

   function Tokenize (Source : String) return Lex_Results.Result is
      Tokens     : Token_Vectors.Vector;
      Pos        : Positive := Source'First;
      Line       : Positive := 1;
      Line_Start : Positive := Source'First;
      Failed     : Boolean := False;
      Problem    : Source_Errors.Source_Error;

      function Has (Offset : Natural) return Boolean is
        (Pos + Offset <= Source'Last);

      function At_Offset (Offset : Natural) return Character is
        (Source (Pos + Offset));

      --  Where Index is, given that Line and Line_Start describe the line
      --  Pos is on and Index is not before Pos.
      procedure Locate
        (Index : Positive; Where_Line : out Positive;
         Where_Column : out Positive)
      is
         Start : Positive := Line_Start;
      begin
         Where_Line := Line;
         for J in Line_Start .. Index - 1 loop
            if Source (J) = LF then
               Where_Line := Where_Line + 1;
               Start := J + 1;
            end if;
         end loop;
         Where_Column := 1;
         for J in Start .. Index - 1 loop
            if not Is_Continuation (Source (J)) then
               Where_Column := Where_Column + 1;
            end if;
         end loop;
      end Locate;

      procedure Fail (Index : Positive; Message : String) is
      begin
         if not Failed then
            Failed := True;
            Problem.Message := To_Unbounded_String (Message);
            Locate (Index, Problem.Line, Problem.Column);
         end if;
      end Fail;

      --  Moves Pos forward, keeping the line count.
      procedure Move_To (New_Pos : Positive) is
      begin
         for J in Pos .. New_Pos - 1 loop
            if Source (J) = LF then
               Line := Line + 1;
               Line_Start := J + 1;
            end if;
         end loop;
         Pos := New_Pos;
      end Move_To;

      --  The token of Kind at Pos, Length characters long. Text is the name,
      --  the string or the digits; Number and Value are an integer's value
      --  and a JSON literal's.
      procedure Emit
        (Kind : Token_Kind; Length : Positive; Text : String := "";
         Number : Long_Long_Integer := 0;
         Value : JSON.Value := JSON.Null_Value)
      is
         Where_Line, Where_Column : Positive;
         Made : Token (Kind);
      begin
         Locate (Pos, Where_Line, Where_Column);
         Made.Line := Where_Line;
         Made.Column := Where_Column;
         case Kind is
            when Identifier =>
               Made.Name := To_Unbounded_String (Text);

            when String_Literal =>
               Made.Text := To_Unbounded_String (Text);

            when Integer_Literal =>
               Made.Numeral := To_Unbounded_String (Text);
               Made.Number := Number;

            when JSON_Literal =>
               Made.Source := To_Unbounded_String (Text);
               Made.Json := Value;

            when Arrow | Fat_Arrow | Left_Brace | Right_Brace | Left_Bracket
               | Right_Bracket | Comma | Semicolon | End_Of_Input =>
               null;
         end case;
         Tokens.Append (Made);
         Move_To (Pos + Length);
      end Emit;

      procedure Skip_Blank is
      begin
         while Pos <= Source'Last loop
            declare
               C : constant Character := Source (Pos);
            begin
               if C in ' ' | LF | Character'Val (9) | Character'Val (13) then
                  Move_To (Pos + 1);
               elsif C = '-' and then Has (1) and then At_Offset (1) = '-'
               then
                  while Pos <= Source'Last and then Source (Pos) /= LF loop
                     Move_To (Pos + 1);
                  end loop;
               else
                  exit;
               end if;
            end;
         end loop;
      end Skip_Blank;

      procedure Lex_Identifier is
         Stop : Positive := Pos;
      begin
         while Stop < Source'Last
           and then (Is_Letter (Source (Stop + 1))
                     or else Is_Digit (Source (Stop + 1))
                     or else Source (Stop + 1) = '_')
         loop
            Stop := Stop + 1;
         end loop;
         Emit
           (Identifier, Stop - Pos + 1, Text => Source (Pos .. Stop));
      end Lex_Identifier;

      procedure Lex_Integer is
         Stop  : Positive := Pos;
         Value : Long_Long_Integer := 0;
      begin
         while Stop <= Source'Last and then Is_Digit (Source (Stop)) loop
            declare
               Digit : constant Long_Long_Integer :=
                 Character'Pos (Source (Stop)) - Character'Pos ('0');
            begin
               if Value > (Long_Long_Integer'Last - Digit) / 10 then
                  Fail (Pos, "integer out of range");
                  return;
               end if;
               Value := Value * 10 + Digit;
            end;
            Stop := Stop + 1;
         end loop;
         if Stop <= Source'Last
           and then (Is_Letter (Source (Stop)) or else Source (Stop) = '_')
         then
            Fail (Pos, "malformed number");
            return;
         end if;
         Emit
           (Integer_Literal, Stop - Pos, Text => Source (Pos .. Stop - 1),
            Number => Value);
      end Lex_Integer;

      --  A string between triple quotes: everything up to the next triple
      --  quote, as it stands.
      procedure Lex_Block_String is
         Stop : Positive := Pos + 3;
      begin
         while Stop + 2 <= Source'Last loop
            if Source (Stop .. Stop + 2) = """""""" then
               Emit
                 (String_Literal, Stop + 3 - Pos,
                  Text => Source (Pos + 3 .. Stop - 1));
               return;
            end if;
            Stop := Stop + 1;
         end loop;
         Fail (Pos, "unterminated triple-quoted string");
      end Lex_Block_String;

      --  A string in double quotes, unescaped the way JSON unescapes one.
      procedure Lex_String is
         Stop : Positive := Pos + 1;
      begin
         while Stop <= Source'Last and then Source (Stop) /= '"' loop
            if Source (Stop) = LF then
               Fail
                 (Stop,
                  "a line break in a string; use a triple-quoted string");
               return;
            elsif Source (Stop) = '\' then
               Stop := Stop + 1;
            end if;
            Stop := Stop + 1;
         end loop;
         if Stop > Source'Last then
            Fail (Pos, "unterminated string");
            return;
         end if;
         declare
            Parsed : constant JSON.Parse_Result :=
              JSON.Parse (Source (Pos .. Stop));
         begin
            if not Parsed.Ok then
               Fail
                 (Pos + Parsed.Offset,
                  "bad string: " & Describe (Parsed.Error));
            else
               Emit
                 (String_Literal, Stop - Pos + 1,
                  Text => JSON.As_String (Parsed.Item));
            end if;
         end;
      end Lex_String;

      --  A JSON value that starts at Pos with a brace or a bracket, to the
      --  character that closes it. Quotes and escapes are followed so that a
      --  bracket inside a string does not count; the text is then parsed as
      --  JSON, which is what says whether it is one.
      procedure Lex_JSON is
         Depth : Natural := 0;
         Stop  : Positive := Pos;
         Quote : Boolean := False;
      begin
         while Stop <= Source'Last loop
            declare
               C : constant Character := Source (Stop);
            begin
               if Quote then
                  if C = '\' then
                     Stop := Stop + 1;
                  elsif C = '"' then
                     Quote := False;
                  end if;
               elsif C = '"' then
                  Quote := True;
               elsif C in '{' | '[' then
                  Depth := Depth + 1;
               elsif C in '}' | ']' then
                  Depth := Depth - 1;
                  exit when Depth = 0;
               end if;
            end;
            Stop := Stop + 1;
         end loop;
         if Stop > Source'Last then
            Fail (Pos, "unterminated JSON value");
            return;
         end if;
         declare
            Parsed : constant JSON.Parse_Result :=
              JSON.Parse (Source (Pos .. Stop));
         begin
            if not Parsed.Ok then
               Fail
                 (Pos + Parsed.Offset,
                  "bad JSON value: " & Describe (Parsed.Error));
            else
               Emit
                 (JSON_Literal, Stop - Pos + 1, Text => Source (Pos .. Stop),
                  Value => Parsed.Item);
            end if;
         end;
      end Lex_JSON;

      function After_Fat_Arrow return Boolean is
        (not Tokens.Is_Empty and then Tokens.Last_Element.Kind = Fat_Arrow);

      procedure Lex_Punctuation (C : Character) is
      begin
         case C is
            when '{' =>
               Emit (Left_Brace, 1);

            when '}' =>
               Emit (Right_Brace, 1);

            when '[' =>
               Emit (Left_Bracket, 1);

            when ']' =>
               Emit (Right_Bracket, 1);

            when ',' =>
               Emit (Comma, 1);

            when ';' =>
               Emit (Semicolon, 1);

            when '-' =>
               if Has (1) and then At_Offset (1) = '>' then
                  Emit (Arrow, 2);
               else
                  Fail (Pos, "a lone '-'; an arrow is '->'");
               end if;

            when '=' =>
               if Has (1) and then At_Offset (1) = '>' then
                  Emit (Fat_Arrow, 2);
               else
                  Fail (Pos, "a lone '='; an association is '=>'");
               end if;

            when others =>
               if C in ' ' .. '~' then
                  Fail (Pos, "unexpected character '" & C & "'");
               else
                  Fail
                    (Pos,
                     "unexpected character (code"
                     & Natural'Image (Character'Pos (C)) & ")");
               end if;
         end case;
      end Lex_Punctuation;

   begin
      while not Failed loop
         Skip_Blank;
         exit when Pos > Source'Last;
         declare
            C : constant Character := Source (Pos);
         begin
            if Is_Letter (C) then
               Lex_Identifier;
            elsif Is_Digit (C) then
               Lex_Integer;
            elsif C = '"' then
               if Has (2) and then At_Offset (1) = '"'
                 and then At_Offset (2) = '"'
               then
                  Lex_Block_String;
               else
                  Lex_String;
               end if;
            elsif C in '{' | '[' and then After_Fat_Arrow then
               Lex_JSON;
            else
               Lex_Punctuation (C);
            end if;
         end;
      end loop;
      if Failed then
         return Lex_Results.Failure (Problem);
      end if;
      declare
         Where_Line, Where_Column : Positive;
      begin
         Locate (Pos, Where_Line, Where_Column);
         Tokens.Append
           (Token'
              (Kind => End_Of_Input, Line => Where_Line,
               Column => Where_Column));
      end;
      return Lex_Results.Success (Tokens);
   end Tokenize;

end Synapse.Pipeline.Lexer;
