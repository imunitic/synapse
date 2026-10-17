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

   function Get (Text, Key : String) return Maybe_Text is
      Result : Maybe_Text;
      Start  : Natural := Text'First;

      procedure Take (Raw : String) is
         Blanks : constant String :=
           " " & Character'Val (9) & Character'Val (13);
         Line   : constant String := Trim (Raw, Blanks);
         First  : Natural         := Line'First;
      begin
         if Line'Length = 0 or else Line (Line'First) = '#' then
            return;
         end if;
         if Line'Length >= 7
           and then Line (Line'First .. Line'First + 6) = "export "
         then
            First := Line'First + 7;
            while First <= Line'Last
              and then Line (First) in ' ' | Character'Val (9)
            loop
               First := First + 1;
            end loop;
         end if;
         declare
            Body_Text : constant String := Line (First .. Line'Last);
         begin
            if Body_Text'Length > Key'Length
              and then
                Body_Text
                  (Body_Text'First .. Body_Text'First + Key'Length - 1) =
                Key
              and then Body_Text (Body_Text'First + Key'Length) = '='
            then
               Result :=
                 (Found => True,
                  Value =>
                    To_Unbounded_String
                      (Unquote
                         (Trim
                            (Body_Text
                               (Body_Text'First + Key'Length + 1 ..
                                    Body_Text'Last),
                             " " & Character'Val (9)))));
            end if;
         end;
      end Take;
   begin
      for I in Text'First .. Text'Last + 1 loop
         if I > Text'Last or else Text (I) = Character'Val (10) then
            Take (Text (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      return Result;
   end Get;

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
