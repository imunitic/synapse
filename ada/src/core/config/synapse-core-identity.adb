package body Synapse.Core.Identity is

   function Is_Blank (C : Character) return Boolean is
     (C in ' ' | Character'Val (9) | Character'Val (13) | Character'Val (10));

   function Trimmed (S : String) return String is
      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      while First <= Last and then Is_Blank (S (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Is_Blank (S (Last)) loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trimmed;

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function Last_Index (S : String; C : Character) return Natural is
   begin
      for I in reverse S'Range loop
         if S (I) = C then
            return I;
         end if;
      end loop;
      return 0;
   end Last_Index;

   function Repo_Name (Remote : String) return String is
      First : Natural := Remote'First;
      Last  : Natural := Remote'Last;
   begin
      if Last > First and then Remote (Last) = '/' then
         Last := Last - 1;
      end if;
      declare
         Slash : constant Natural := Last_Index (Remote (First .. Last), '/');
      begin
         if Slash > 0 then
            First := Slash + 1;
         end if;
      end;
      --  `:` for the scp-like form, and for a remote with no slash at all.
      declare
         Colon : constant Natural := Last_Index (Remote (First .. Last), ':');
      begin
         if Colon > 0 then
            First := Colon + 1;
         end if;
      end;
      if Last - First + 1 >= 4 and then Remote (Last - 3 .. Last) = ".git" then
         Last := Last - 4;
      end if;
      return Remote (First .. Last);
   end Repo_Name;

   function Sanitize_Branch (Branch : String) return String is
      Result : String := Branch;
   begin
      for C of Result loop
         for Illegal of Illegal_In_Branch loop
            if C = Illegal then
               C := '-';
               exit;
            end if;
         end loop;
      end loop;
      return Result;
   end Sanitize_Branch;

   function Parse_Git_Dir_File (Content : String) return Maybe_Text is
      Start : Natural := Content'First;
   begin
      for I in Content'First .. Content'Last + 1 loop
         if I > Content'Last or else Content (I) = Character'Val (10) then
            declare
               Line : constant String := Trimmed (Content (Start .. I - 1));
            begin
               if Starts_With (Line, "gitdir:") then
                  declare
                     Path : constant String :=
                       Trimmed (Line (Line'First + 7 .. Line'Last));
                  begin
                     if Path'Length = 0 then
                        return (Found => False);
                     end if;
                     return
                       (Found => True, Value => To_Unbounded_String (Path));
                  end;
               end if;
            end;
            Start := I + 1;
         end if;
      end loop;
      return (Found => False);
   end Parse_Git_Dir_File;

   function Parse_Head (Content : String) return Maybe_Text is
      Line : constant String := Trimmed (Content);
   begin
      if not Starts_With (Line, "ref:") then
         return (Found => False);
      end if;
      declare
         Reference : constant String :=
           Trimmed (Line (Line'First + 4 .. Line'Last));
      begin
         if Starts_With (Reference, "refs/heads/")
           and then Reference'Length > 11
         then
            return
              (Found => True,
               Value =>
                 To_Unbounded_String
                   (Reference (Reference'First + 11 .. Reference'Last)));
         end if;
         return (Found => False);
      end;
   end Parse_Head;

   --  The value of a config line's right side: quoted, or cut at a `#` or `;`.
   function Config_Value (Raw : String) return String is
   begin
      if Raw'Length >= 2 and then Raw (Raw'First) = '"' then
         for I in Raw'First + 1 .. Raw'Last loop
            if Raw (I) = '"' then
               return Raw (Raw'First + 1 .. I - 1);
            end if;
         end loop;
         return Raw (Raw'First + 1 .. Raw'Last);
      end if;
      for I in Raw'Range loop
         if Raw (I) in '#' | ';' then
            return Trimmed (Raw (Raw'First .. I - 1));
         end if;
      end loop;
      return Trimmed (Raw);
   end Config_Value;

   function Lower (S : String) return String is
      Result : String := S;
   begin
      for C of Result loop
         if C in 'A' .. 'Z' then
            C := Character'Val (Character'Pos (C) + 32);
         end if;
      end loop;
      return Result;
   end Lower;

   function Remote_Url_From_Config
     (Config, Preferred : String) return Maybe_Text
   is
      First        : Maybe_Text;
      In_Remote    : Boolean := False;
      Is_Preferred : Boolean := False;
      Start        : Natural := Config'First;

      procedure Take (Raw : String; Done : out Maybe_Text) is
         Line : constant String := Trimmed (Raw);
      begin
         Done := (Found => False);
         if Line'Length = 0 or else Line (Line'First) in '#' | ';' then
            return;
         end if;

         if Line (Line'First) = '[' then
            In_Remote    := False;
            Is_Preferred := False;
            for Close in Line'Range loop
               if Line (Close) = ']' then
                  declare
                     Header : constant String :=
                       Line (Line'First + 1 .. Close - 1);
                  begin
                     if Starts_With (Header, "remote") then
                        declare
                           Rest : constant String :=
                             Trimmed
                               (Header (Header'First + 6 .. Header'Last));
                           Name : constant String :=
                             (if
                                Rest'Length >= 2
                                and then Rest (Rest'First) = '"'
                                and then Rest (Rest'Last) = '"'
                              then Rest (Rest'First + 1 .. Rest'Last - 1)
                              elsif
                                Rest'Length > 1
                                and then Rest (Rest'First) = '.'
                              then Rest (Rest'First + 1 .. Rest'Last)
                              else "");
                        begin
                           if Name'Length > 0 then
                              In_Remote    := True;
                              Is_Preferred := Name = Preferred;
                           end if;
                        end;
                     end if;
                  end;
                  exit;
               end if;
            end loop;
            return;
         end if;

         if not In_Remote then
            return;
         end if;
         for Eq in Line'Range loop
            if Line (Eq) = '=' then
               if Lower (Trimmed (Line (Line'First .. Eq - 1))) = "url" then
                  declare
                     Value : constant String :=
                       Config_Value (Trimmed (Line (Eq + 1 .. Line'Last)));
                  begin
                     if Value'Length > 0 then
                        if Is_Preferred then
                           Done :=
                             (Found => True,
                              Value => To_Unbounded_String (Value));
                        elsif not First.Found then
                           First :=
                             (Found => True,
                              Value => To_Unbounded_String (Value));
                        end if;
                     end if;
                  end;
               end if;
               exit;
            end if;
         end loop;
      end Take;
   begin
      for I in Config'First .. Config'Last + 1 loop
         if I > Config'Last or else Config (I) = Character'Val (10) then
            declare
               Done : Maybe_Text;
            begin
               Take (Config (Start .. I - 1), Done);
               if Done.Found then
                  return Done;
               end if;
            end;
            Start := I + 1;
         end if;
      end loop;
      return First;
   end Remote_Url_From_Config;

end Synapse.Core.Identity;
