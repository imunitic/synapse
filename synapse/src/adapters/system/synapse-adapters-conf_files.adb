with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.Conf;
with Synapse.Core.Words;

package body Synapse.Adapters.Conf_Files is

   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Kind;

   Largest_File : constant := 1_024 * 1_024;

   function Setting (V : Variables; Name : String) return String is
      Found : constant Vars.Maybe_Value := V.Get (Name);
   begin
      return (if Found.Found then To_String (Found.Value) else "");
   end Setting;

   function Is_Set (V : Variables; Name : String) return Boolean is
     (V.Get (Name).Found);

   function Exists (Path : String) return Boolean is
   begin
      return Ada.Directories.Exists (Path);
   exception
      when others =>
         return False;
   end Exists;

   function Found (Path : String) return Maybe_Path is
     (if Exists (Path) then
        (Found => True, Value => To_Unbounded_String (Path))
      else (Found => False));

   --  Tiers 1 to 3: the part that names a file a caller could also write to.
   function Resolve_Existing (V : Variables; Name : String) return Maybe_Path
   is
      Xdg  : constant String  := Setting (V, "XDG_CONFIG_HOME");
      Home : constant Boolean := Is_Set (V, "HOME");
      Dir  : constant String  := Setting (V, "HOME");
   begin
      if Xdg /= "" then
         declare
            Hit : constant Maybe_Path := Found (Xdg & "/synapse/" & Name);
         begin
            if Hit.Found then
               return Hit;
            end if;
         end;
      end if;
      if Home then
         declare
            Config : constant Maybe_Path :=
              Found (Dir & "/.config/synapse/" & Name);
         begin
            if Config.Found then
               return Config;
            end if;
         end;
         return Found (Dir & "/.claude/" & Name);
      end if;
      return (Found => False);
   end Resolve_Existing;

   function Resolve_Conf_Path (V : Variables; Name : String) return Maybe_Path
   is
      Existing : constant Maybe_Path := Resolve_Existing (V, Name);
   begin
      if Existing.Found then
         return Existing;
      end if;
      declare
         Content : constant String := Setting (V, "SYNAPSE_CONTENT_ROOT");
      begin
         if Content /= "" then
            return Found (Content & "/" & Name & ".template");
         end if;
      end;
      return (Found => False);
   end Resolve_Conf_Path;

   function Is_Directory (Path : String) return Boolean is
   begin
      return
        Ada.Directories.Exists (Path)
        and then Ada.Directories.Kind (Path) = Ada.Directories.Directory;
   exception
      when others =>
         return False;
   end Is_Directory;

   function Resolve_Write_Path (V : Variables; Name : String) return String is
      Existing : constant Maybe_Path := Resolve_Existing (V, Name);
      Xdg      : constant String     := Setting (V, "XDG_CONFIG_HOME");
      Home     : constant String     := Setting (V, "HOME");
   begin
      if Existing.Found then
         return To_String (Existing.Value);
      end if;
      if Xdg /= "" then
         return Xdg & "/synapse/" & Name;
      end if;
      if Is_Set (V, "HOME") then
         if Is_Directory (Home & "/.config") then
            return Home & "/.config/synapse/" & Name;
         end if;
         return Home & "/.claude/" & Name;
      end if;
      raise No_Home;
   end Resolve_Write_Path;

   function Resolve (V : Variables; Key : String) return Maybe_Path is
      Direct : constant String := Setting (V, Key);
   begin
      if Direct /= "" then
         return (Found => True, Value => To_Unbounded_String (Direct));
      end if;
      declare
         function Name_At (N : Positive) return String is
           (if N = 1 then Primary_Name else Legacy_Name);
      begin
         for N in 1 .. 2 loop
            declare
               Path : constant Maybe_Path :=
                 Resolve_Conf_Path (V, Name_At (N));
            begin
               if Path.Found then
                  declare
                     Text  : constant String               :=
                       File_Bytes.Read (To_String (Path.Value), Largest_File);
                     Value : constant Core.Conf.Maybe_Text :=
                       Core.Conf.Value (Text, Key, V);
                  begin
                     if Value.Found and then Length (Value.Value) > 0 then
                        return (Found => True, Value => Value.Value);
                     end if;
                  end;
               end if;
            exception
               when others =>
                  null;  --  unreadable or too large: try the next
            end;
         end loop;
      end;
      return (Found => False);
   end Resolve;

   function Vault_Dir (V : Variables) return Maybe_Path is
     (Resolve (V, "SYNAPSE_VAULT_DIR"));

   function Push_Every (V : Variables) return Natural is
      Setting_Value : constant Maybe_Path :=
        Resolve (V, "SYNAPSE_VAULT_PUSH_EVERY");
   begin
      if not Setting_Value.Found then
         return 5;
      end if;
      declare
         Text : constant String := To_String (Setting_Value.Value);
      begin
         if Text'Length = 0 or else Text'Length > 9
           or else not (for all C of Text => C in '0' .. '9')
         then
            return 5;
         end if;
         return Natural'Value (Text);
      end;
   end Push_Every;

   function Load_Stopwords (V : Variables) return Core.Text_Lists.Set is
      Name  : constant String := "synapse-prompt-stopwords.conf";
      Empty : Core.Text_Lists.Set;
   begin
      if not Is_Set (V, "HOME") then
         return Empty;
      end if;
      declare
         Found : constant Maybe_Path := Resolve_Conf_Path (V, Name);
         Path  : constant String     :=
           (if Found.Found then To_String (Found.Value)
            else Setting (V, "HOME") & "/.claude/" & Name);
      begin
         return
           Core.Words.Parse_Stopwords (File_Bytes.Read (Path, Largest_File));
      exception
         when others =>
            return Empty;
      end;
   end Load_Stopwords;

end Synapse.Adapters.Conf_Files;
