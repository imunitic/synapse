package body Synapse.Core.Projects is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Is_Blank (C : Character) return Boolean is
     (C = ' ' or else C = Character'Val (9) or else C = Character'Val (13));

   function Trimmed (Text : String) return String is
      First : Positive := Text'First;
      Last  : Natural  := Text'Last;
   begin
      while First <= Last and then Is_Blank (Text (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Is_Blank (Text (Last)) loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   function Parse (Text : String) return Project_List is
      Result : Project_List;
      Start  : Positive := Text'First;

      procedure Take (Raw : String) is
         Line    : constant String := Trimmed (Raw);
         At_Sign : Natural         := 0;
      begin
         if Line = "" or else Line (Line'First) = '#' then
            return;
         end if;
         for I in Line'Range loop
            if Line (I) = '=' then
               At_Sign := I;
               exit;
            end if;
         end loop;
         if At_Sign <= Line'First then
            return;
         end if;
         declare
            Name   : constant String :=
              Trimmed (Line (Line'First .. At_Sign - 1));
            Prefix : constant String :=
              Trimmed (Line (At_Sign + 1 .. Line'Last));
         begin
            if Name /= "" and then Prefix /= "" then
               Result.Append
                 (Project'(Name   => To_Unbounded_String (Name),
                           Prefix => To_Unbounded_String (Prefix)));
            end if;
         end;
      end Take;
   begin
      for I in Text'Range loop
         if Text (I) = LF then
            Take (Text (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      if Start <= Text'Last then
         Take (Text (Start .. Text'Last));
      end if;
      return Result;
   end Parse;

   function Valid_Name (Name : String) return Boolean is
   begin
      if Name'Length = 0 or else Name'Length > 64 then
         return False;
      end if;
      for I in Name'Range loop
         declare
            C     : constant Character := Name (I);
            Plain : constant Boolean :=
              C in 'a' .. 'z' or else C in '0' .. '9';
         begin
            if I = Name'First then
               if not Plain then
                  return False;
               end if;
            elsif not (Plain or else C = '.' or else C = '_' or else C = '-')
            then
               return False;
            end if;
         end;
      end loop;
      return True;
   end Valid_Name;

   function Valid_Prefix (Prefix : String) return Boolean is
   begin
      if Prefix'Length = 0 or else Prefix'Length > 32
        or else Prefix (Prefix'First) not in 'a' .. 'z'
        or else Prefix (Prefix'Last) = '-'
      then
         return False;
      end if;
      for C of Prefix loop
         if not (C in 'a' .. 'z' or else C in '0' .. '9' or else C = '-')
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Prefix;

   function Refusal
     (Name, Prefix : String; Known : Project_List) return String is
   begin
      if not Valid_Name (Name) then
         return
           "A project name is lower case letters, digits, dots, " &
           "underscores and hyphens, and starts with a letter or a digit.";
      end if;
      if not Valid_Prefix (Prefix) then
         return
           "A prefix is lower case letters, digits and hyphens, starts " &
           "with a letter and does not end with a hyphen.";
      end if;
      for Item of Known loop
         if To_String (Item.Name) = Name then
            return
              Name & " is already a project, with the prefix " &
              To_String (Item.Prefix) & ".";
         elsif To_String (Item.Prefix) = Prefix then
            return
              "The prefix " & Prefix & " is already the prefix of " &
              To_String (Item.Name) & ".";
         end if;
      end loop;
      return "";
   end Refusal;

   function With_Added (Text, Name, Prefix : String) return String is
   begin
      return
        Text &
        (if Text = "" or else Text (Text'Last) = LF then "" else "" & LF) &
        Name & "=" & Prefix & LF;
   end With_Added;

end Synapse.Core.Projects;
