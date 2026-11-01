with Ada.Strings.Unbounded;

package body Synapse.Pipeline.Parser is

   use Ada.Strings.Unbounded;
   use type Syntax.Definition_Kind;

   function Describe (T : Lexer.Token) return String is
     (case T.Kind is
        when Lexer.Identifier      => "'" & To_String (T.Name) & "'",
        when Lexer.String_Literal  => "a string",
        when Lexer.Integer_Literal => "the number " & To_String (T.Numeral),
        when Lexer.JSON_Literal    => "a JSON value",
        when Lexer.Arrow           => "'->'",
        when Lexer.Fat_Arrow       => "'=>'",
        when Lexer.Left_Brace      => "'{'",
        when Lexer.Right_Brace     => "'}'",
        when Lexer.Left_Bracket    => "'['",
        when Lexer.Right_Bracket   => "']'",
        when Lexer.Comma           => "','",
        when Lexer.Semicolon       => "';'",
        when Lexer.End_Of_Input    => "the end of the file");

   function Reference_Of (T : Lexer.Token) return Syntax.Reference is
     (Name => T.Name, Line => T.Line, Column => T.Column)
   with Pre => T.Kind = Lexer.Identifier;

   function Value_Of (T : Lexer.Token) return Syntax.Value is
     (case T.Kind is
        when Lexer.Identifier      =>
          (Kind => Syntax.Name_Value, Line => T.Line, Column => T.Column,
           Name => T.Name),
        when Lexer.String_Literal  =>
          (Kind => Syntax.String_Value, Line => T.Line, Column => T.Column,
           Text => T.Text),
        when Lexer.Integer_Literal =>
          (Kind => Syntax.Integer_Value, Line => T.Line,
           Column => T.Column, Number => T.Number),
        when others                =>
          (Kind => Syntax.JSON_Value, Line => T.Line, Column => T.Column,
           Source => T.Source, Json => T.Json))
   with
     Pre =>
       T.Kind in Lexer.Identifier | Lexer.String_Literal
                 | Lexer.Integer_Literal | Lexer.JSON_Literal;

   function Parse
     (Tokens : Lexer.Token_Vectors.Vector) return Parse_Results.Result
   is
      Pos     : Positive := Tokens.First_Index;
      Failed  : Boolean := False;
      Problem : Source_Errors.Source_Error;

      function Here return Lexer.Token is (Tokens (Pos));

      procedure Fail (T : Lexer.Token; Message : String) is
      begin
         if not Failed then
            Failed := True;
            Problem := Source_Errors.Make (Message, T.Line, T.Column);
         end if;
      end Fail;

      procedure Advance is
      begin
         if Here.Kind /= Lexer.End_Of_Input then
            Pos := Pos + 1;
         end if;
      end Advance;

      --  Takes a token of Kind, or fails saying what was wanted.
      function Expect (Kind : Lexer.Token_Kind; What : String) return Boolean
      is
      begin
         if Here.Kind = Kind then
            Advance;
            return True;
         end if;
         Fail (Here, "expected " & What & ", found " & Describe (Here));
         return False;
      end Expect;

      --  A name for a definition or a step: an identifier that is not one of
      --  the keywords. The token has not been taken.
      function Take_Name
        (What : String; Result : out Syntax.Reference) return Boolean
      is
         T : constant Lexer.Token := Here;
      begin
         if T.Kind /= Lexer.Identifier then
            Fail (T, "expected " & What & ", found " & Describe (T));
            return False;
         elsif Syntax.Is_Reserved (To_String (T.Name)) then
            Fail
              (T, "'" & To_String (T.Name) & "' is a keyword and cannot name "
                  & What);
            return False;
         end if;
         Result := Reference_Of (T);
         Advance;
         return True;
      end Take_Name;

      --  The name an edge leads to: a step, or the end of the run. The token
      --  has not been taken.
      function Take_Target (Result : out Syntax.Reference) return Boolean is
         T : constant Lexer.Token := Here;
      begin
         if T.Kind = Lexer.Identifier
           and then To_String (T.Name) = Syntax.End_Name
         then
            Result := Reference_Of (T);
            Advance;
            return True;
         end if;
         return Take_Name ("a step name after '->'", Result);
      end Take_Target;

      --  `[` attribute { `,` attribute } `]`, or `[]`.
      procedure Parse_Attributes
        (Into : in out Syntax.Attribute_Vectors.Vector)
      is
      begin
         if not Expect (Lexer.Left_Bracket, "'['") then
            return;
         end if;
         if Here.Kind = Lexer.Right_Bracket then
            Advance;
            return;
         end if;
         loop
            declare
               Name_Token : constant Lexer.Token := Here;
            begin
               if Name_Token.Kind /= Lexer.Identifier then
                  Fail
                    (Name_Token,
                     "expected an attribute name, found "
                     & Describe (Name_Token));
                  return;
               end if;
               Advance;
               if not Expect (Lexer.Fat_Arrow, "'=>'") then
                  return;
               end if;
               declare
                  Value_Token : constant Lexer.Token := Here;
               begin
                  if Value_Token.Kind
                     not in Lexer.Identifier | Lexer.String_Literal
                            | Lexer.Integer_Literal | Lexer.JSON_Literal
                  then
                     Fail
                       (Value_Token,
                        "expected a value after '=>', found "
                        & Describe (Value_Token));
                     return;
                  end if;
                  Advance;
                  Into.Append
                    (Syntax.Attribute'
                       (Name => Reference_Of (Name_Token),
                        Item => Value_Of (Value_Token)));
               end;
            end;
            if Here.Kind = Lexer.Comma then
               Advance;
            elsif Here.Kind = Lexer.Right_Bracket then
               Advance;
               return;
            else
               Fail (Here, "expected ',' or ']', found " & Describe (Here));
               return;
            end if;
         end loop;
      end Parse_Attributes;

      --  A statement of a pipeline: a step, or a chain of edges.
      procedure Parse_Statement
        (Steps : in out Syntax.Step_Vectors.Vector;
         Edges : in out Syntax.Edge_Vectors.Vector)
      is
         First : Syntax.Reference;
      begin
         if not Take_Name ("a step name", First) then
            return;
         end if;
         case Here.Kind is
            when Lexer.Left_Bracket =>
               declare
                  Made : Syntax.Step := (Name => First, others => <>);
               begin
                  Parse_Attributes (Made.Attributes);
                  if not Failed and then Expect (Lexer.Semicolon, "';'") then
                     Steps.Append (Made);
                  end if;
               end;

            when Lexer.Arrow =>
               declare
                  Chain      : Syntax.Reference_Vectors.Vector;
                  Attributes : Syntax.Attribute_Vectors.Vector;
                  Next       : Syntax.Reference;
               begin
                  Chain.Append (First);
                  while Here.Kind = Lexer.Arrow loop
                     Advance;
                     if not Take_Target (Next) then
                        return;
                     end if;
                     Chain.Append (Next);
                     if To_String (Next.Name) = Syntax.End_Name
                       and then Here.Kind = Lexer.Arrow
                     then
                        Fail
                          (Here,
                           "'" & Syntax.End_Name & "' ends the run, so no "
                           & "edge can leave it");
                        return;
                     end if;
                  end loop;
                  if Here.Kind = Lexer.Left_Bracket then
                     Parse_Attributes (Attributes);
                  end if;
                  if Failed or else not Expect (Lexer.Semicolon, "';'") then
                     return;
                  end if;
                  for I in Chain.First_Index .. Chain.Last_Index - 1 loop
                     Edges.Append
                       (Syntax.Edge'
                          (From => Chain (I), To => Chain (I + 1),
                           Attributes => Attributes));
                  end loop;
               end;

            when others =>
               Fail
                 (Here,
                  "expected '[' or '->' after the step name '"
                  & To_String (First.Name) & "', found " & Describe (Here));
         end case;
      end Parse_Statement;

      Result : Syntax.Definition;

      procedure Parse_Definition is
         Opening : constant Lexer.Token := Here;
         Kind    : Syntax.Definition_Kind;
         Name    : Syntax.Reference;
      begin
         if Opening.Kind = Lexer.Identifier
           and then To_String (Opening.Name) = "Pipeline"
         then
            Kind := Syntax.Pipeline_Definition;
         elsif Opening.Kind = Lexer.Identifier
           and then To_String (Opening.Name) = "System"
         then
            Kind := Syntax.System_Definition;
         elsif Opening.Kind = Lexer.Identifier
           and then To_String (Opening.Name) = "Agent"
         then
            Kind := Syntax.Agent_Definition;
         else
            Fail
              (Opening,
               "expected Pipeline, System or Agent, found "
               & Describe (Opening));
            return;
         end if;
         Advance;
         if not Take_Name
                  ("the name of the " & Syntax.Keyword (Kind), Name)
         then
            return;
         end if;
         case Kind is
            when Syntax.Pipeline_Definition =>
               Result := (Kind => Syntax.Pipeline_Definition, Name => Name,
                          others => <>);
               if not Expect (Lexer.Left_Brace, "'{'") then
                  return;
               end if;
               while not Failed and then Here.Kind /= Lexer.Right_Brace loop
                  if Here.Kind = Lexer.End_Of_Input then
                     Fail
                       (Here,
                        "expected '}' to close the pipeline, found the end "
                        & "of the file");
                     return;
                  end if;
                  Parse_Statement (Result.Steps, Result.Edges);
               end loop;
               if not Failed then
                  Advance;
               end if;

            when Syntax.System_Definition | Syntax.Agent_Definition =>
               if Kind = Syntax.System_Definition then
                  Result := (Kind => Syntax.System_Definition, Name => Name,
                             others => <>);
               else
                  Result := (Kind => Syntax.Agent_Definition, Name => Name,
                             others => <>);
               end if;
               Parse_Attributes (Result.Attributes);
               if not Failed then
                  if not Expect (Lexer.Semicolon, "';'") then
                     return;
                  end if;
               end if;
         end case;
      end Parse_Definition;

   begin
      Parse_Definition;
      if not Failed and then Here.Kind /= Lexer.End_Of_Input then
         Fail
           (Here,
            "expected the end of the file after the definition, found "
            & Describe (Here) & "; a file holds one definition");
      end if;
      if Failed then
         return Parse_Results.Failure (Problem);
      end if;
      return Parse_Results.Success (Result);
   end Parse;

   function Parse_Source (Source : String) return Parse_Results.Result is
      Lexed : constant Lexer.Lex_Results.Result := Lexer.Tokenize (Source);
   begin
      if not Lexer.Lex_Results.Is_Success (Lexed) then
         return Parse_Results.Failure (Lexer.Lex_Results.Error (Lexed));
      end if;
      return Parse (Lexer.Lex_Results.Value (Lexed));
   end Parse_Source;

end Synapse.Pipeline.Parser;
