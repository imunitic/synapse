with Ada.Long_Float_Text_IO;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

with Synapse.Core.JSON_Lexical;
with Synapse.Core.Decimal_Image;

package body Synapse.Core.JSON with
  SPARK_Mode => Off
is

   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;

   package Lexical renames Synapse.Core.JSON_Lexical;

   procedure Free is new Ada.Unchecked_Deallocation (Node, Node_Access);

   ---------------------------------------------------------------------------
   --  Ownership
   ---------------------------------------------------------------------------

   overriding procedure Adjust (V : in out Value) is
   begin
      if V.Ref /= null then
         V.Ref.Count := V.Ref.Count + 1;
      end if;
   end Adjust;

   overriding procedure Finalize (V : in out Value) is
      Doomed : Node_Access := V.Ref;
   begin
      V.Ref := null;
      if Doomed /= null then
         Doomed.Count := Doomed.Count - 1;
         if Doomed.Count = 0 then
            Free (Doomed);
         end if;
      end if;
   end Finalize;

   function Wrap (N : Node_Access) return Value is
     (Ada.Finalization.Controlled with Ref => N);

   ---------------------------------------------------------------------------
   --  Construction
   ---------------------------------------------------------------------------

   function Make_Boolean (B : Boolean) return Value is
     (Wrap (new Node'(K => JSON_Boolean, Count => 1, Flag => B)));

   function Make_Integer (I : Long_Long_Integer) return Value is
     (Wrap (new Node'(K => JSON_Integer, Count => 1, Int => I)));

   function Make_Float (F : Long_Float) return Value is
     (Wrap (new Node'(K => JSON_Float, Count => 1, Flt => F)));

   function Make_Number_String (Text : String) return Value is
     (Wrap
        (new Node'
           (K    => JSON_Number_String, Count => 1,
            Text => To_Unbounded_String (Text))));

   function Make_String (S : String) return Value is
     (Wrap
        (new Node'
           (K => JSON_String, Count => 1, Text => To_Unbounded_String (S))));

   function Make_Array (Items : Value_Array) return Value is
      Vector : Value_Vectors.Vector;
   begin
      for Item of Items loop
         Vector.Append (Item);
      end loop;
      return Wrap (new Node'(K => JSON_Array, Count => 1, Items => Vector));
   end Make_Array;

   --  Adds a member, or replaces the value of an existing key in place.
   procedure Put_Member
     (Members : in out Member_Vectors.Vector; Key : Unbounded_String;
      Item    :        Value)
   is
   begin
      for I in Members.First_Index .. Members.Last_Index loop
         if Members (I).Key = Key then
            Members.Replace_Element (I, (Key => Key, Item => Item));
            return;
         end if;
      end loop;
      Members.Append (Member'(Key => Key, Item => Item));
   end Put_Member;

   function Make_Object (Members : Member_Array) return Value is
      Vector : Member_Vectors.Vector;
   begin
      for M of Members loop
         Put_Member (Vector, M.Key, M.Item);
      end loop;
      return Wrap (new Node'(K => JSON_Object, Count => 1, Members => Vector));
   end Make_Object;

   ---------------------------------------------------------------------------
   --  Inspection
   ---------------------------------------------------------------------------

   function Kind_Of (V : Value) return Kind is
     (if V.Ref = null then JSON_Null else V.Ref.K);

   function As_Boolean (V : Value) return Boolean is (V.Ref.Flag);

   function As_Integer (V : Value) return Long_Long_Integer is (V.Ref.Int);

   function As_Float (V : Value) return Long_Float is (V.Ref.Flt);

   function As_String (V : Value) return String is (To_String (V.Ref.Text));

   function Length (V : Value) return Natural is
     (if V.Ref.K = JSON_Array then Natural (V.Ref.Items.Length)
      else Natural (V.Ref.Members.Length));

   function Element (V : Value; Index : Positive) return Value is
     (V.Ref.Items (Index));

   function Find (V : Value; Key : String) return Natural is
   begin
      for I in V.Ref.Members.First_Index .. V.Ref.Members.Last_Index loop
         if To_String (V.Ref.Members (I).Key) = Key then
            return I;
         end if;
      end loop;
      return 0;
   end Find;

   function Has_Member (V : Value; Key : String) return Boolean is
     (Find (V, Key) /= 0);

   function Member_Value (V : Value; Key : String) return Value is
     (V.Ref.Members (Find (V, Key)).Item);

   function Member_Key (V : Value; Index : Positive) return String is
     (To_String (V.Ref.Members (Index).Key));

   function Member_At (V : Value; Index : Positive) return Value is
     (V.Ref.Members (Index).Item);

   overriding function "=" (L, R : Value) return Boolean is
   begin
      if Kind_Of (L) /= Kind_Of (R) then
         return False;
      end if;

      case Kind_Of (L) is
         when JSON_Null =>
            return True;

         when JSON_Boolean =>
            return L.Ref.Flag = R.Ref.Flag;

         when JSON_Integer =>
            return L.Ref.Int = R.Ref.Int;

         when JSON_Float =>
            return L.Ref.Flt = R.Ref.Flt;

         when JSON_Number_String | JSON_String =>
            return L.Ref.Text = R.Ref.Text;

         when JSON_Array =>
            if L.Ref.Items.Length /= R.Ref.Items.Length then
               return False;
            end if;
            for I in L.Ref.Items.First_Index .. L.Ref.Items.Last_Index loop
               if L.Ref.Items (I) /= R.Ref.Items (I) then
                  return False;
               end if;
            end loop;
            return True;

         when JSON_Object =>
            if L.Ref.Members.Length /= R.Ref.Members.Length then
               return False;
            end if;
            for M of L.Ref.Members loop
               declare
                  Other : constant Natural := Find (R, To_String (M.Key));
               begin
                  if Other = 0 or else M.Item /= R.Ref.Members (Other).Item
                  then
                     return False;
                  end if;
               end;
            end loop;
            return True;
      end case;
   end "=";

   ---------------------------------------------------------------------------
   --  Parsing
   ---------------------------------------------------------------------------

   function Parse (Text : String) return Parse_Result is

      Failure : exception;

      Pos        : Positive         := Text'First;
      Error_Kind : Parse_Error_Kind := Unexpected_End;
      Error_At   : Natural          := 0;

      procedure Fail (Reason : Parse_Error_Kind; At_Index : Positive) is
      begin
         Error_Kind := Reason;
         Error_At   := At_Index - Text'First;
         raise Failure;
      end Fail;

      function At_End return Boolean is (Pos > Text'Last);

      procedure Skip_Whitespace is
      begin
         while not At_End
           and then Text (Pos) in ' ' | ASCII.HT | ASCII.LF | ASCII.CR
         loop
            Pos := Pos + 1;
         end loop;
      end Skip_Whitespace;

      --  The next character, which must exist.
      function Peek return Character is
      begin
         if At_End then
            Fail (Unexpected_End, Text'Last + 1);
         end if;
         return Text (Pos);
      end Peek;

      procedure Expect (C : Character) is
      begin
         if Peek /= C then
            Fail (Unexpected_Character, Pos);
         end if;
         Pos := Pos + 1;
      end Expect;

      procedure Expect_Word (Word : String) is
      begin
         for C of Word loop
            Expect (C);
         end loop;
      end Expect_Word;

      --  Four hexadecimal digits at Pos, as a number.
      function Hex4 return Natural is
         Result : Natural := 0;
      begin
         for K in 1 .. 4 loop
            if At_End then
               Fail (Unexpected_End, Text'Last + 1);
            end if;
            declare
               Digit : constant Integer := Lexical.Hex_Value (Text (Pos));
            begin
               if Digit < 0 then
                  Fail (Invalid_Escape, Pos);
               end if;
               Result := Result * 16 + Digit;
               Pos    := Pos + 1;
            end;
         end loop;
         return Result;
      end Hex4;

      --  Pos is just past the opening quote.
      function Parse_String return Unbounded_String is
         Result : Unbounded_String;
      begin
         loop
            declare
               C : constant Character := Peek;
            begin
               if C = '"' then
                  Pos := Pos + 1;
                  return Result;
               elsif Character'Pos (C) < 32 then
                  Fail (Unexpected_Character, Pos);
               elsif C /= '\' then
                  Append (Result, C);
                  Pos := Pos + 1;
               else
                  declare
                     Escape_At : constant Positive := Pos;
                  begin
                     Pos := Pos + 1;
                     case Peek is
                        when '"' =>
                           Append (Result, '"');
                           Pos := Pos + 1;

                        when '\' =>
                           Append (Result, '\');
                           Pos := Pos + 1;

                        when '/' =>
                           Append (Result, '/');
                           Pos := Pos + 1;

                        when 'b' =>
                           Append (Result, ASCII.BS);
                           Pos := Pos + 1;

                        when 'f' =>
                           Append (Result, ASCII.FF);
                           Pos := Pos + 1;

                        when 'n' =>
                           Append (Result, ASCII.LF);
                           Pos := Pos + 1;

                        when 'r' =>
                           Append (Result, ASCII.CR);
                           Pos := Pos + 1;

                        when 't' =>
                           Append (Result, ASCII.HT);
                           Pos := Pos + 1;

                        when 'u' =>
                           Pos := Pos + 1;
                           declare
                              Unit   : constant Natural := Hex4;
                              Scalar : Natural          := Unit;
                           begin
                              if Unit in 16#DC00# .. 16#DFFF# then
                                 Fail (Invalid_Escape, Escape_At);
                              elsif Unit in 16#D800# .. 16#DBFF# then
                                 --  A high surrogate needs its low half.
                                 if Pos + 1 > Text'Last
                                   or else Text (Pos) /= '\'
                                   or else Text (Pos + 1) /= 'u'
                                 then
                                    Fail (Invalid_Escape, Escape_At);
                                 end if;
                                 Pos := Pos + 2;
                                 declare
                                    Low : constant Natural := Hex4;
                                 begin
                                    if Low not in 16#DC00# .. 16#DFFF# then
                                       Fail (Invalid_Escape, Escape_At);
                                    end if;
                                    Scalar :=
                                      Lexical.Combine_Surrogates (Unit, Low);
                                 end;
                              end if;
                              Append (Result, UTF8.Encode (Scalar));
                           end;

                        when others =>
                           Fail (Invalid_Escape, Escape_At);
                     end case;
                  end;
               end if;
            end;
         end loop;
      end Parse_String;

      function Parse_Number return Value is
         Last : constant Natural := Lexical.Scan_Number (Text, Pos);
      begin
         if Last = 0 then
            Fail (Invalid_Number, Pos);
         end if;

         declare
            Token : constant String := Text (Pos .. Last);
         begin
            Pos := Last + 1;
            if not Lexical.Has_Fraction_Or_Exponent (Token) then
               begin
                  return Make_Integer (Long_Long_Integer'Value (Token));
               exception
                  when Constraint_Error =>
                     return Make_Number_String (Token);
               end;
            end if;

            begin
               declare
                  F : constant Long_Float := Long_Float'Value (Token);
               begin
                  if not F'Valid or else abs F > Long_Float'Last then
                     return Make_Number_String (Token);
                  end if;
                  return Make_Float (F);
               end;
            exception
               when Constraint_Error =>
                  return Make_Number_String (Token);
            end;
         end;
      end Parse_Number;

      function Parse_Value (Depth : Natural) return Value;

      function Parse_Array (Depth : Natural) return Value is
         Items : Value_Vectors.Vector;
      begin
         if Depth >= Max_Depth then
            Fail (Too_Deep, Pos);
         end if;
         Pos := Pos + 1;
         Skip_Whitespace;
         if Peek = ']' then
            Pos := Pos + 1;
            return
              Wrap (new Node'(K => JSON_Array, Count => 1, Items => Items));
         end if;
         loop
            Skip_Whitespace;
            Items.Append (Parse_Value (Depth + 1));
            Skip_Whitespace;
            case Peek is
               when ',' =>
                  Pos := Pos + 1;

               when ']' =>
                  Pos := Pos + 1;
                  return
                    Wrap
                      (new Node'(K => JSON_Array, Count => 1, Items => Items));

               when others =>
                  Fail (Unexpected_Character, Pos);
            end case;
         end loop;
      end Parse_Array;

      function Parse_Object (Depth : Natural) return Value is
         Members : Member_Vectors.Vector;
      begin
         if Depth >= Max_Depth then
            Fail (Too_Deep, Pos);
         end if;
         Pos := Pos + 1;
         Skip_Whitespace;
         if Peek = '}' then
            Pos := Pos + 1;
            return
              Wrap
                (new Node'(K => JSON_Object, Count => 1, Members => Members));
         end if;
         loop
            Skip_Whitespace;
            Expect ('"');
            declare
               Key : constant Unbounded_String := Parse_String;
            begin
               Skip_Whitespace;
               Expect (':');
               Skip_Whitespace;
               Put_Member (Members, Key, Parse_Value (Depth + 1));
            end;
            Skip_Whitespace;
            case Peek is
               when ',' =>
                  Pos := Pos + 1;

               when '}' =>
                  Pos := Pos + 1;
                  return
                    Wrap
                      (new Node'
                         (K => JSON_Object, Count => 1, Members => Members));

               when others =>
                  Fail (Unexpected_Character, Pos);
            end case;
         end loop;
      end Parse_Object;

      function Parse_Value (Depth : Natural) return Value is
      begin
         case Peek is
            when '{' =>
               return Parse_Object (Depth);

            when '[' =>
               return Parse_Array (Depth);

            when '"' =>
               Pos := Pos + 1;
               declare
                  S : constant Unbounded_String := Parse_String;
               begin
                  return
                    Wrap (new Node'(K => JSON_String, Count => 1, Text => S));
               end;

            when 't' =>
               Expect_Word ("true");
               return Make_Boolean (True);

            when 'f' =>
               Expect_Word ("false");
               return Make_Boolean (False);

            when 'n' =>
               Expect_Word ("null");
               return Null_Value;

            when '-' | '0' .. '9' =>
               return Parse_Number;

            when others =>
               Fail (Unexpected_Character, Pos);
         end case;
         return Null_Value;
      end Parse_Value;

      --  The first malformed UTF-8 sequence, if any.
      procedure Check_UTF8 is
         I : Positive := Text'First;
      begin
         while I <= Text'Last loop
            declare
               Step : constant Natural := UTF8.Sequence_Length (Text, I);
            begin
               if Step = 0 then
                  Fail (Invalid_UTF8, I);
               end if;
               I := I + Step;
            end;
         end loop;
      end Check_UTF8;

   begin
      if Text'Length > 0 then
         Check_UTF8;
      end if;

      Skip_Whitespace;
      declare
         Result : constant Value := Parse_Value (0);
      begin
         Skip_Whitespace;
         if not At_End then
            Fail (Trailing_Data, Pos);
         end if;
         return (Ok => True, Item => Result);
      end;

   exception
      when Failure =>
         return (Ok => False, Error => Error_Kind, Offset => Error_At);
   end Parse;

   ---------------------------------------------------------------------------
   --  Writing
   ---------------------------------------------------------------------------

   function Escape (S : String) return String is
      Hex    : constant String := "0123456789abcdef";
      Result : String (1 .. Lexical.Escaped_Length (S));
      Last   : Natural         := 0;

      procedure Put (C : Character) is
      begin
         Last          := Last + 1;
         Result (Last) := C;
      end Put;
   begin
      for C of S loop
         case Lexical.Escape_Width (C) is
            when 1 =>
               Put (C);

            when 2 =>
               Put ('\');
               Put
                 (case C is when '"' => '"', when '\' => '\',
                    when ASCII.BS => 'b', when ASCII.FF => 'f',
                    when ASCII.LF => 'n', when ASCII.CR => 'r',
                    when others => 't');

            when others =>
               Put ('\');
               Put ('u');
               Put ('0');
               Put ('0');
               Put (Hex (Character'Pos (C) / 16 + 1));
               Put (Hex (Character'Pos (C) mod 16 + 1));
         end case;
      end loop;
      return Result;
   end Escape;

   --  The fewest digits that read back as F, in JSON number syntax with a
   --  fraction or exponent.
   function Float_Text (F : Long_Float) return String is
      Buffer : String (1 .. 64) := [others => ' '];
   begin
      if F = 0.0 then
         return
           (if Long_Float'Copy_Sign (1.0, F) < 0.0 then "-0.0" else "0.0");
      end if;

      for Digits_Used in 1 .. 17 loop
         Ada.Long_Float_Text_IO.Put
           (To => Buffer, Item => F, Aft => Digits_Used - 1, Exp => 3);
         exit when Long_Float'Value (Buffer) = F;
      end loop;

      declare
         Text        : constant String               :=
           Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both);
         Negative    : constant Boolean := Text (Text'First) = '-';
         From        : constant Positive             :=
           (if Negative then Text'First + 1 else Text'First);
         E_At        : constant Natural := Ada.Strings.Fixed.Index (Text, "E");
         Mantissa    : constant String := Text (From .. E_At - 1);
         Exponent    : constant Integer              :=
           Integer'Value (Text (E_At + 1 .. Text'Last));
         Digits_Text : String (1 .. Mantissa'Length) := [others => '0'];
         Count       : Natural                       := 0;
      begin
         for C of Mantissa loop
            if C /= '.' then
               Count               := Count + 1;
               Digits_Text (Count) := C;
            end if;
         end loop;
         while Count > 1 and then Digits_Text (Count) = '0' loop
            Count := Count - 1;
         end loop;

         declare
            D    : constant String := Digits_Text (1 .. Count);
            Sign : constant String := (if Negative then "-" else "");
         begin
            if Exponent in 0 .. 20 then
               if D'Length <= Exponent + 1 then
                  return
                    Sign & D & String'(1 .. Exponent + 1 - D'Length => '0') &
                    ".0";
               end if;
               return
                 Sign & D (1 .. Exponent + 1) & "." &
                 D (Exponent + 2 .. D'Last);
            elsif Exponent in -5 .. -1 then
               return Sign & "0." & String'(1 .. -Exponent - 1 => '0') & D;
            else
               return
                 Sign & D (1 .. 1) & "." &
                 (if D'Length > 1 then D (2 .. D'Last) else "0") & "e" &
                 (if Exponent < 0 then "-" else "+") &
                 Decimal_Image.Image (abs Exponent);
            end if;
         end;
      end;
   end Float_Text;

   procedure Write (V : Value; Into : in out Unbounded_String) is
   begin
      case Kind_Of (V) is
         when JSON_Null =>
            Append (Into, "null");

         when JSON_Boolean =>
            Append (Into, (if V.Ref.Flag then "true" else "false"));

         when JSON_Integer =>
            Append (Into, Decimal_Image.Image (V.Ref.Int));

         when JSON_Float =>
            Append (Into, Float_Text (V.Ref.Flt));

         when JSON_Number_String =>
            Append (Into, V.Ref.Text);

         when JSON_String =>
            Append (Into, '"');
            Append (Into, Escape (To_String (V.Ref.Text)));
            Append (Into, '"');

         when JSON_Array =>
            Append (Into, '[');
            for I in V.Ref.Items.First_Index .. V.Ref.Items.Last_Index loop
               if I /= V.Ref.Items.First_Index then
                  Append (Into, ',');
               end if;
               Write (V.Ref.Items (I), Into);
            end loop;
            Append (Into, ']');

         when JSON_Object =>
            Append (Into, '{');
            for I in V.Ref.Members.First_Index .. V.Ref.Members.Last_Index loop
               if I /= V.Ref.Members.First_Index then
                  Append (Into, ',');
               end if;
               Append (Into, '"');
               Append (Into, Escape (To_String (V.Ref.Members (I).Key)));
               Append (Into, '"');
               Append (Into, ':');
               Write (V.Ref.Members (I).Item, Into);
            end loop;
            Append (Into, '}');
      end case;
   end Write;

   function To_String (V : Value) return String is
      Result : Unbounded_String;
   begin
      Write (V, Result);
      return Ada.Strings.Unbounded.To_String (Result);
   end To_String;

end Synapse.Core.JSON;
