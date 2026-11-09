with Ada.Strings.Unbounded;
package body Synapse.Core.Conf is

   use Ada.Strings.Unbounded;

   function Is_Name_Start (C : Character) return Boolean is
     (C in 'A' .. 'Z' | 'a' .. 'z' | '_');

   function Is_Name_Part (C : Character) return Boolean is
     (Is_Name_Start (C) or else C in '0' .. '9');

   --  The length of the shell name at the start of S: a letter or `_`, then
   --  letters, digits and `_`. Zero when S does not start one.
   function Name_Length (S : String) return Natural is
      N : Natural := 0;
   begin
      if S'Length = 0 or else not Is_Name_Start (S (S'First)) then
         return 0;
      end if;
      N := 1;
      while N < S'Length and then Is_Name_Part (S (S'First + N)) loop
         N := N + 1;
      end loop;
      return N;
   end Name_Length;

   function Is_Name (S : String) return Boolean is
     (S'Length > 0 and then Name_Length (S) = S'Length);

   function Unquote (Raw : String) return String is
   begin
      if Raw'Length >= 2 and then Raw (Raw'First) in '"' | '''
        and then Raw (Raw'Last) = Raw (Raw'First)
      then
         return Raw (Raw'First + 1 .. Raw'Last - 1);
      end if;
      for I in Raw'Range loop
         if Raw (I) in '#' | ' ' | Character'Val (9) then
            return Raw (Raw'First .. I - 1);
         end if;
      end loop;
      return Raw;
   end Unquote;

   function Trim (S : String; Set : String) return String is
      function Member (C : Character) return Boolean is
      begin
         for X of Set loop
            if X = C then
               return True;
            end if;
         end loop;
         return False;
      end Member;

      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      while First <= Last and then Member (S (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Member (S (Last)) loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trim;

   Blanks : constant String := " " & Character'Val (9) & Character'Val (13);

   --  Where the name of the key starts in Line when Line assigns Key, else
   --  zero: after any indentation and an `export `; a comment or a longer
   --  key is not an assignment of Key.
   function Key_Start (Line, Key : String) return Natural is
      First : Natural := Line'First;
   begin
      while First <= Line'Last and then Line (First) in ' ' | Character'Val (9)
      loop
         First := First + 1;
      end loop;
      if First > Line'Last or else Line (First) = '#' then
         return 0;
      end if;
      if First + 6 <= Line'Last and then Line (First .. First + 6) = "export "
      then
         First := First + 7;
         while First <= Line'Last
           and then Line (First) in ' ' | Character'Val (9)
         loop
            First := First + 1;
         end loop;
      end if;
      if First + Key'Length <= Line'Last
        and then Line (First .. First + Key'Length - 1) = Key
        and then Line (First + Key'Length) = '='
      then
         return First;
      end if;
      return 0;
   end Key_Start;

   --  Calls Each with every line of Text, without its line feed, and whether
   --  that line feed was there.
   procedure For_Each_Line
     (Text : String;
      Each : not null access procedure (Line : String; Ended : Boolean))
   is
      Start : Natural := Text'First;
   begin
      for I in Text'First .. Text'Last + 1 loop
         if I > Text'Last then
            if Start <= Text'Last then
               Each (Text (Start .. Text'Last), False);
            end if;
         elsif Text (I) = Character'Val (10) then
            Each (Text (Start .. I - 1), True);
            Start := I + 1;
         end if;
      end loop;
   end For_Each_Line;

   function Get (Text, Key : String) return Maybe_Text is
      Result : Maybe_Text;

      procedure Take (Line : String; Ended : Boolean) is
         pragma Unreferenced (Ended);
         At_Key : constant Natural := Key_Start (Line, Key);
      begin
         if At_Key /= 0 then
            Result :=
              (Found => True,
               Value =>
                 To_Unbounded_String
                   (Unquote
                      (Trim (Line (At_Key + Key'Length + 1 .. Line'Last),
                             Blanks))));
         end if;
      end Take;
   begin
      For_Each_Line (Text, Take'Access);
      return Result;
   end Get;

   --  Value as it is written after the `=`.
   function Written (Value : String) return String is
      Has_Single : Boolean := False;
      Has_Double : Boolean := False;
      Needs      : Boolean := Value'Length = 0;
   begin
      for C of Value loop
         if C = Character'Val (10) then
            raise Unrepresentable;
         elsif C = '"' then
            Has_Double := True;
         elsif C = ''' then
            Has_Single := True;
         elsif C in ' ' | Character'Val (9) | '#' then
            Needs := True;
         end if;
      end loop;
      if Has_Double and then Has_Single then
         raise Unrepresentable;
      elsif Has_Double then
         return "'" & Value & "'";
      elsif Has_Single or else Needs then
         return '"' & Value & '"';
      end if;
      return Value;
   end Written;

   --  Where what follows the value of Key's assignment starts in Line: after
   --  the closing quote of a quoted value, else at the first blank, tab, `#`
   --  or carriage return. At_Key is where the name of the key starts.
   function After_Value (Line, Key : String; At_Key : Positive) return Positive
   is
      First : constant Positive := At_Key + Key'Length + 1;
   begin
      if First <= Line'Last and then Line (First) in '"' | ''' then
         for I in First + 1 .. Line'Last loop
            if Line (I) = Line (First) then
               return I + 1;
            end if;
         end loop;
      end if;
      for I in First .. Line'Last loop
         if Line (I) in ' ' | Character'Val (9) | '#' | Character'Val (13)
         then
            return I;
         end if;
      end loop;
      return Line'Last + 1;
   end After_Value;

   function Set (Text, Key, Value : String) return String is
      Last_Line : Natural := 0;
      Count     : Natural := 0;
      Seen      : Natural := 0;
      Result    : Unbounded_String;
      Quoted    : constant String := Written (Value);

      procedure Find (Line : String; Ended : Boolean) is
         pragma Unreferenced (Ended);
      begin
         Count := Count + 1;
         if Key_Start (Line, Key) /= 0 then
            Last_Line := Count;
         end if;
      end Find;

      procedure Copy (Line : String; Ended : Boolean) is
      begin
         Seen := Seen + 1;
         if Seen = Last_Line then
            declare
               At_Key : constant Positive := Key_Start (Line, Key);
            begin
               Append (Result, Line (Line'First .. At_Key - 1));
               Append (Result, Key & "=" & Quoted);
               Append
                 (Result,
                  Line (After_Value (Line, Key, At_Key) .. Line'Last));
            end;
         else
            Append (Result, Line);
         end if;
         if Ended then
            Append (Result, Character'Val (10));
         end if;
      end Copy;
   begin
      For_Each_Line (Text, Find'Access);
      if Last_Line = 0 then
         Append (Result, Text);
         if Text'Length > 0 and then Text (Text'Last) /= Character'Val (10)
         then
            Append (Result, Character'Val (10));
         end if;
         Append (Result, Key & "=" & Quoted & Character'Val (10));
      else
         For_Each_Line (Text, Copy'Access);
      end if;
      return To_String (Result);
   end Set;

   function Unset (Text, Key : String) return String is
      Result : Unbounded_String;

      procedure Copy (Line : String; Ended : Boolean) is
      begin
         if Key_Start (Line, Key) = 0 then
            Append (Result, Line);
            if Ended then
               Append (Result, Character'Val (10));
            end if;
         end if;
      end Copy;
   begin
      For_Each_Line (Text, Copy'Access);
      return To_String (Result);
   end Unset;

   function Expand
     (Raw : String; Vars : Ports.Variables.Variables'Class) return String
   is
      Result : Unbounded_String;
      I      : Natural := Raw'First;

      procedure Append_Variable (Name : String) is
         Found : constant Ports.Variables.Maybe_Value := Vars.Get (Name);
      begin
         if Found.Found then
            Append (Result, Found.Value);
         end if;
      end Append_Variable;
   begin
      --  `~` only at the start, alone or before `/`.
      if Raw'Length > 0 and then Raw (Raw'First) = '~'
        and then (Raw'Length = 1 or else Raw (Raw'First + 1) = '/')
      then
         Append_Variable ("HOME");
         I := Raw'First + 1;
      end if;

      while I <= Raw'Last loop
         if Raw (I) = '\' and then I < Raw'Last and then Raw (I + 1) = '$' then
            Append (Result, '$');
            I := I + 2;
         elsif Raw (I) /= '$' then
            Append (Result, Raw (I));
            I := I + 1;
         elsif I < Raw'Last and then Raw (I + 1) = '{' then
            declare
               Close : Natural := 0;
            begin
               for K in I + 2 .. Raw'Last loop
                  if Raw (K) = '}' then
                     Close := K;
                     exit;
                  end if;
               end loop;
               if Close = 0 or else not Is_Name (Raw (I + 2 .. Close - 1)) then
                  Append (Result, '$');  --  left as written
                  I := I + 1;
               else
                  Append_Variable (Raw (I + 2 .. Close - 1));
                  I := Close + 1;
               end if;
            end;
         else
            declare
               Length : constant Natural :=
                 (if I < Raw'Last then Name_Length (Raw (I + 1 .. Raw'Last))
                  else 0);
            begin
               if Length = 0 then
                  Append (Result, '$');
                  I := I + 1;
               else
                  Append_Variable (Raw (I + 1 .. I + Length));
                  I := I + 1 + Length;
               end if;
            end;
         end if;
      end loop;
      return To_String (Result);
   end Expand;

   function Value
     (Text, Key : String; Vars : Ports.Variables.Variables'Class)
      return Maybe_Text
   is
      Raw : constant Maybe_Text := Get (Text, Key);
   begin
      if not Raw.Found then
         return (Found => False);
      end if;
      return
        (Found => True,
         Value => To_Unbounded_String (Expand (To_String (Raw.Value), Vars)));
   end Value;

end Synapse.Core.Conf;
