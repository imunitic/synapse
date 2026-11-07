with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.OS_Lib;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.File_Bytes;
with Synapse.Commands.Cli_Args;
with Synapse.Core.JSON;
with Synapse.Core.JSON_Indent;
with Synapse.Core.Text_Lists;

package body Synapse.Commands.Configure is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;
   use type Ada.Directories.File_Kind;
   use type GNAT.OS_Lib.String_Access;

   package Conf_Files renames Synapse.Adapters.Conf_Files;
   package File_Bytes renames Synapse.Adapters.File_Bytes;
   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   Usage_Text : constant String :=
     "usage: synapse configure <claude|codex|opencode>" & LF;

   Help_Text : constant String :=
     Usage_Text & LF
     & "Installs Synapse for a harness: its skills and commands, and its hooks, "
     & "which" & LF
     & "run the synapse-hook beside this program. A hooks file that holds more "
     & "than" & LF
     & "Synapse's own is merged into, and a copy is kept beside it as .bak." & LF
     & "A synapse.conf is made from its template when there is none." & LF & LF
     & "Environment:" & LF
     & "  SYNAPSE_CONTENT_ROOT  the folder that holds skills/, commands/, "
     & "harness/ and" & LF
     & "                        synapse.conf.template; the folder above this "
     & "program's" & LF
     & "                        own when not set" & LF;

   Prog : constant String := "synapse-configure: ";

   Largest_File : constant := 1_024 * 1_024;

   Hook_Name : constant String := "synapse-hook";

   Manifest : constant String := ".synapse-managed.json";

   --  Raised with the sentence that says what went wrong.
   Failed : exception;

   On_Windows : constant Boolean := GNAT.OS_Lib.Directory_Separator = '\';

   Exe : constant String := (if On_Windows then ".exe" else "");

   -------------------------------------------------------------------------
   --  Paths
   -------------------------------------------------------------------------

   function Is_Separator (C : Character) return Boolean is (C in '/' | '\');

   --  Everything before the last separator, or nothing.
   function Dirname (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Is_Separator (Path (I)) then
            return Path (Path'First .. I - 1);
         end if;
      end loop;
      return "";
   end Dirname;

   function Has_Separator (Path : String) return Boolean is
     (for some C of Path => Is_Separator (C));

   --  The folder this program runs from: its own path's, or when it was found
   --  on PATH by its name, the folder it was found in.
   function Own_Directory (Argv0 : String) return String is
   begin
      if Has_Separator (Argv0) then
         return Dirname (Argv0);
      end if;
      declare
         Found : GNAT.OS_Lib.String_Access :=
           GNAT.OS_Lib.Locate_Exec_On_Path (Argv0);
      begin
         if Found = null then
            return "";
         end if;
         return Dir : constant String := Dirname (Found.all) do
            GNAT.OS_Lib.Free (Found);
         end return;
      end;
   end Own_Directory;

   function Is_Directory (Path : String) return Boolean is
     (Ada.Directories.Exists (Path)
      and then Ada.Directories.Kind (Path) = Ada.Directories.Directory);

   function Is_File (Path : String) return Boolean is
     (Ada.Directories.Exists (Path)
      and then Ada.Directories.Kind (Path) = Ada.Directories.Ordinary_File);

   --  Whether a name from a manifest is one entry of the folder it is kept
   --  in, so that a manifest cannot point anywhere else.
   function Is_Plain_Name (Name : String) return Boolean is
     (Name /= "" and then Name /= "." and then Name /= ".."
      and then not Has_Separator (Name));

   -------------------------------------------------------------------------
   --  Files
   -------------------------------------------------------------------------

   function Read_Text (Path : String) return String is
     (File_Bytes.Read (Path, Largest_File));

   procedure Write_Text (Path, Text : String) is
   begin
      Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Path));
      File_Bytes.Write (Path, Text);
   end Write_Text;

   procedure Backup_If_Exists (Path : String) is
   begin
      if Is_File (Path) then
         File_Bytes.Write (Path & ".bak", Read_Text (Path));
      end if;
   end Backup_If_Exists;

   --  The names of the directories, or of the files that end in Suffix,
   --  directly in Directory, sorted.
   function Entries
     (Directory : String; Wanted : Ada.Directories.File_Kind;
      Suffix : String := "") return Lists.Vector
   is
      Names  : Synapse.Core.Text_Lists.Sets.Set;
      Result : Lists.Vector;
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
   begin
      if not Is_Directory (Directory) then
         return Result;
      end if;
      Ada.Directories.Start_Search
        (Search, Directory, "",
         [Ada.Directories.Directory => Wanted = Ada.Directories.Directory,
          Ada.Directories.Ordinary_File =>
            Wanted = Ada.Directories.Ordinary_File,
          others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name not in "." | ".."
              and then Name'Length >= Suffix'Length
              and then Name (Name'Last - Suffix'Length + 1 .. Name'Last) =
                       Suffix
            then
               Names.Include (Name);
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      for Name of Names loop
         Result.Append (To_Unbounded_String (Name));
      end loop;
      return Result;
   end Entries;

   --  Copies the directory From into the directory To over what is there:
   --  every file replaced, nothing else removed.
   procedure Copy_Over (From, To : String) is
   begin
      Ada.Directories.Create_Path (To);
      for Name of Entries (From, Ada.Directories.Directory) loop
         Copy_Over
           (From & "/" & To_String (Name), To & "/" & To_String (Name));
      end loop;
      for Name of Entries (From, Ada.Directories.Ordinary_File) loop
         Ada.Directories.Copy_File
           (From & "/" & To_String (Name), To & "/" & To_String (Name),
            "mode=overwrite");
      end loop;
   end Copy_Over;

   procedure Remove (Path : String) is
   begin
      if not Ada.Directories.Exists (Path) then
         return;
      end if;
      if Is_Directory (Path) then
         Ada.Directories.Delete_Tree (Path);
      else
         Ada.Directories.Delete_File (Path);
      end if;
   end Remove;

   -------------------------------------------------------------------------
   --  Manifests: what an earlier run wrote into a folder
   -------------------------------------------------------------------------

   function Listed (Folder : String) return Lists.Vector is
      Result : Lists.Vector;
      Path   : constant String := Folder & "/" & Manifest;
   begin
      if not Is_File (Path) then
         return Result;
      end if;
      declare
         Parsed : constant JSON.Parse_Result := JSON.Parse (Read_Text (Path));
      begin
         if Parsed.Ok and then JSON.Kind_Of (Parsed.Item) = JSON.JSON_Array then
            for I in 1 .. JSON.Length (Parsed.Item) loop
               declare
                  Item : constant JSON.Value := JSON.Element (Parsed.Item, I);
               begin
                  if JSON.Kind_Of (Item) = JSON.JSON_String
                    and then Is_Plain_Name (JSON.As_String (Item))
                  then
                     Result.Append (To_Unbounded_String (JSON.As_String (Item)));
                  end if;
               end;
            end loop;
         end if;
      end;
      return Result;
   end Listed;

   --  Removes what an earlier run wrote into Folder and Current no longer
   --  has, and records Current.
   procedure Prune (Folder : String; Current : Lists.Vector) is
      Items : JSON.Value_Array (1 .. Natural (Current.Length));
   begin
      for Old of Listed (Folder) loop
         if not Current.Contains (Old) then
            Remove (Folder & "/" & To_String (Old));
         end if;
      end loop;
      for I in Items'Range loop
         Items (I) := JSON.Make_String (To_String (Current (I)));
      end loop;
      Write_Text
        (Folder & "/" & Manifest,
         Synapse.Core.JSON_Indent.Indented (JSON.Make_Array (Items)) & LF);
   end Prune;

   --  Copies every skill of From, with what is in its folder, into Folder, and
   --  returns their names.
   function Copy_Skills (From, Folder : String) return Lists.Vector is
      Names : constant Lists.Vector :=
        Entries (From, Ada.Directories.Directory);
   begin
      for Name of Names loop
         Copy_Over
           (From & "/" & To_String (Name), Folder & "/" & To_String (Name));
      end loop;
      return Names;
   end Copy_Skills;

   function Copy_Commands (From, Folder : String) return Lists.Vector is
      Names : constant Lists.Vector :=
        Entries (From, Ada.Directories.Ordinary_File, ".md");
   begin
      Ada.Directories.Create_Path (Folder);
      for Name of Names loop
         Ada.Directories.Copy_File
           (From & "/" & To_String (Name), Folder & "/" & To_String (Name),
            "mode=overwrite");
      end loop;
      return Names;
   end Copy_Commands;

   -------------------------------------------------------------------------
   --  JSON
   -------------------------------------------------------------------------

   package Member_Vectors is new Ada.Containers.Vectors
     (Positive, JSON.Member, "=" => JSON."=");

   package Value_Vectors is new Ada.Containers.Vectors
     (Positive, JSON.Value, "=" => JSON."=");

   function Empty_Object return JSON.Value is
      None : constant JSON.Member_Array (1 .. 0) := [];
   begin
      return JSON.Make_Object (None);
   end Empty_Object;

   function Members_Of (Object : JSON.Value) return Member_Vectors.Vector is
      Result : Member_Vectors.Vector;
   begin
      for I in 1 .. JSON.Length (Object) loop
         Result.Append
           (JSON.Member'
              (Key  => To_Unbounded_String (JSON.Member_Key (Object, I)),
               Item => JSON.Member_At (Object, I)));
      end loop;
      return Result;
   end Members_Of;

   --  Object with the member Key set to Item, in its place when it has one
   --  and after the others when not.
   function With_Member
     (Object : JSON.Value; Key : String; Item : JSON.Value) return JSON.Value
   is
      All_Of : Member_Vectors.Vector := Members_Of (Object);
   begin
      All_Of.Append
        (JSON.Member'(Key => To_Unbounded_String (Key), Item => Item));
      declare
         Members : JSON.Member_Array (1 .. Natural (All_Of.Length));
      begin
         for I in Members'Range loop
            Members (I) := All_Of (I);
         end loop;
         return JSON.Make_Object (Members);
      end;
   end With_Member;

   function As_Array (Items : Value_Vectors.Vector) return JSON.Value is
      Result : JSON.Value_Array (1 .. Natural (Items.Length));
   begin
      for I in Result'Range loop
         Result (I) := Items (I);
      end loop;
      return JSON.Make_Array (Result);
   end As_Array;

   --  The JSON in the file at Path, which must be an object; Default when
   --  there is no file.
   function Object_In (Path : String; Default : JSON.Value) return JSON.Value
   is
   begin
      if not Is_File (Path) then
         return Default;
      end if;
      declare
         Parsed : constant JSON.Parse_Result := JSON.Parse (Read_Text (Path));
      begin
         if not Parsed.Ok then
            raise Failed with
              Path & " has invalid JSON -- fix or back it up manually "
              & "before re-running";
         elsif JSON.Kind_Of (Parsed.Item) /= JSON.JSON_Object then
            raise Failed with
              Path & " is not a JSON object -- fix or back it up manually "
              & "before re-running";
         end if;
         return Parsed.Item;
      end;
   end Object_In;

   --  Whether a shell would split or read something in a path: a space, a quote,
   --  an escape or any of the characters it gives a meaning to. A `~` is only read
   --  at the start of a word, and a path is absolute, so a short Windows name such
   --  as `RUNNER~1` is left as it is.
   function Needs_Quoting (Path : String) return Boolean is
   begin
      for C of Path loop
         if C in ' ' | ASCII.HT | ''' | '"' | '\' | '$' | '`' | '&' | ';'
                | '|' | '<' | '>' | '(' | ')' | '*' | '?' | '[' | ']' | '{'
                | '}' | '!' | '#' | '^' | '%'
         then
            return True;
         end if;
      end loop;
      return False;
   end Needs_Quoting;

   --  A path as the first word of a shell command: as it is when nothing in it
   --  needs quoting, else in double quotes with `\`, `"`, `$` and the backtick
   --  escaped.
   function Shell_Word (Path : String) return String is
      Result : Unbounded_String;
   begin
      if not Needs_Quoting (Path) then
         return Path;
      end if;
      Append (Result, '"');
      for C of Path loop
         if C in '\' | '"' | '$' | '`' then
            Append (Result, '\');
         end if;
         Append (Result, C);
      end loop;
      Append (Result, '"');
      return To_String (Result);
   end Shell_Word;

   --  The hook template with the hook program's path where the bare name is.
   function Rendered (V : JSON.Value; Hook : String) return JSON.Value is
      Prefix : constant String := Hook_Name & " ";
   begin
      case JSON.Kind_Of (V) is
         when JSON.JSON_Array =>
            declare
               Items : Value_Vectors.Vector;
            begin
               for I in 1 .. JSON.Length (V) loop
                  Items.Append (Rendered (JSON.Element (V, I), Hook));
               end loop;
               return As_Array (Items);
            end;

         when JSON.JSON_Object =>
            declare
               Result : JSON.Value := Empty_Object;
            begin
               for I in 1 .. JSON.Length (V) loop
                  declare
                     Key  : constant String := JSON.Member_Key (V, I);
                     Item : constant JSON.Value := JSON.Member_At (V, I);
                  begin
                     if Key = "command"
                       and then JSON.Kind_Of (Item) = JSON.JSON_String
                       and then Ada.Strings.Fixed.Head
                                  (JSON.As_String (Item), Prefix'Length) =
                                Prefix
                     then
                        Result :=
                          With_Member
                            (Result, Key,
                             JSON.Make_String
                               (Shell_Word (Hook)
                                & JSON.As_String (Item)
                                    (JSON.As_String (Item)'First
                                     + Hook_Name'Length ..
                                     JSON.As_String (Item)'Last)));
                     else
                        Result :=
                          With_Member (Result, Key, Rendered (Item, Hook));
                     end if;
                  end;
               end loop;
               return Result;
            end;

         when others =>
            return V;
      end case;
   end Rendered;

   --  Whether a hook command starts the hook program, wherever it is kept:
   --  its first word's file name is the program's, so that a copy installed
   --  at another path is still recognised as Synapse's own.
   function Is_Our_Command (Command : String) return Boolean is
      Quoted     : constant Boolean :=
        Command'Length > 0 and then Command (Command'First) = '"';
      Word_Start : constant Natural :=
        (if Quoted then Command'First + 1 else Command'First);
      Word_End   : Natural := Command'Last;
      Name_At    : Natural := Word_Start;
      Scan       : Natural := Word_Start;
   begin
      --  A quoted word ends at the first quote that is not escaped, any other
      --  at the first space.
      while Scan <= Command'Last loop
         if Quoted and then Command (Scan) = '\' then
            Scan := Scan + 2;
         elsif (Quoted and then Command (Scan) = '"')
           or else (not Quoted and then Command (Scan) = ' ')
         then
            Word_End := Scan - 1;
            exit;
         else
            Scan := Scan + 1;
         end if;
      end loop;
      for I in Word_Start .. Word_End loop
         if Is_Separator (Command (I)) then
            Name_At := I + 1;
         end if;
      end loop;
      declare
         Name : constant String := Command (Name_At .. Word_End);
      begin
         return Name = Hook_Name
           or else (On_Windows and then Name = Hook_Name & ".exe");
      end;
   end Is_Our_Command;

   --  A group of hooks, all of which start the hook program: what an earlier
   --  run wrote.
   function Is_Our_Group (Group : JSON.Value) return Boolean is
   begin
      if JSON.Kind_Of (Group) /= JSON.JSON_Object
        or else not JSON.Has_Member (Group, "hooks")
        or else JSON.Kind_Of (JSON.Member_Value (Group, "hooks")) /=
                JSON.JSON_Array
      then
         return False;
      end if;
      declare
         Hooks : constant JSON.Value := JSON.Member_Value (Group, "hooks");
      begin
         for I in 1 .. JSON.Length (Hooks) loop
            declare
               Hook : constant JSON.Value := JSON.Element (Hooks, I);
            begin
               if JSON.Kind_Of (Hook) /= JSON.JSON_Object
                 or else not JSON.Has_Member (Hook, "command")
                 or else JSON.Kind_Of (JSON.Member_Value (Hook, "command")) /=
                         JSON.JSON_String
                 or else not Is_Our_Command
                               (JSON.As_String
                                  (JSON.Member_Value (Hook, "command")))
               then
                  return False;
               end if;
            end;
         end loop;
      end;
      return True;
   end Is_Our_Group;

   --  The hooks Existing has, with those of an earlier run replaced by
   --  Fresh's and the rest left as they are.
   function Merged (Existing, Fresh : JSON.Value) return JSON.Value is
      Result : JSON.Value := Existing;
   begin
      for I in 1 .. JSON.Length (Fresh) loop
         declare
            Event  : constant String := JSON.Member_Key (Fresh, I);
            Groups : Value_Vectors.Vector;
            Added  : constant JSON.Value := JSON.Member_At (Fresh, I);
         begin
            if JSON.Has_Member (Result, Event) then
               declare
                  Before : constant JSON.Value :=
                    JSON.Member_Value (Result, Event);
               begin
                  if JSON.Kind_Of (Before) /= JSON.JSON_Array then
                     raise Failed with
                       "the hooks of " & Event & " are not a list -- fix or "
                       & "back it up manually before re-running";
                  end if;
                  for J in 1 .. JSON.Length (Before) loop
                     if not Is_Our_Group (JSON.Element (Before, J)) then
                        Groups.Append (JSON.Element (Before, J));
                     end if;
                  end loop;
               end;
            end if;
            for J in 1 .. JSON.Length (Added) loop
               Groups.Append (JSON.Element (Added, J));
            end loop;
            Result := With_Member (Result, Event, As_Array (Groups));
         end;
      end loop;
      return Result;
   end Merged;

   --  The hooks of Settings' "hooks" member, which is an object when there is
   --  one.
   function Hooks_Of (Settings : JSON.Value; Path : String) return JSON.Value is
   begin
      if not JSON.Has_Member (Settings, "hooks")
        or else JSON.Kind_Of (JSON.Member_Value (Settings, "hooks")) =
                JSON.JSON_Null
      then
         return Empty_Object;
      elsif JSON.Kind_Of (JSON.Member_Value (Settings, "hooks")) /=
            JSON.JSON_Object
      then
         raise Failed with
           Path & " has a hooks entry that is not an object -- fix or back "
           & "it up manually before re-running";
      end if;
      return JSON.Member_Value (Settings, "hooks");
   end Hooks_Of;

   function Parsed_Template (Path : String) return JSON.Value is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Read_Text (Path));
   begin
      if not Parsed.Ok or else JSON.Kind_Of (Parsed.Item) /= JSON.JSON_Object
        or else not JSON.Has_Member (Parsed.Item, "hooks")
      then
         raise Failed with Path & " is not a hooks template";
      end if;
      return JSON.Member_Value (Parsed.Item, "hooks");
   end Parsed_Template;

   -------------------------------------------------------------------------
   --  What is installed, and from where
   -------------------------------------------------------------------------

   type Source is record
      Home    : Unbounded_String;
      Root    : Unbounded_String;
      Hook    : Unbounded_String;
   end record;

   function Home_Of (S : Source) return String is (To_String (S.Home));
   function Root_Of (S : Source) return String is (To_String (S.Root));

   --  A `synapse.conf` from its template when none of its places has one.
   procedure Bootstrap_Conf (Env : Environment; From : Source) is
      Where    : constant String :=
        Conf_Files.Resolve_Write_Path (Env.Vars.all, Conf_Files.Primary_Name);
      Template : constant String :=
        Root_Of (From) & "/synapse.conf.template";
   begin
      if Is_File (Where) then
         return;
      end if;
      if not Is_File (Template) then
         raise Failed with Template & " is missing";
      end if;
      Write_Text (Where, Read_Text (Template));
      Say
        (Env,
         "wrote " & Where & " -- edit SYNAPSE_VAULT_DIR in it before your "
         & "next session" & LF);
   end Bootstrap_Conf;

   function Count (Items : Lists.Vector) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Natural (Items.Length)),
                              Ada.Strings.Left));

   --  What ~/.claude/settings.json says once Synapse's hooks are merged into
   --  it and the content root is set in its env. Raises Failed when what is
   --  there cannot be merged into.
   function Claude_Settings (From : Source; Settings : String) return String is
      Existing   : constant JSON.Value := Object_In (Settings, Empty_Object);
      Fresh      : constant JSON.Value :=
        Rendered
          (Parsed_Template (Root_Of (From) & "/harness/claude/hooks.json"),
           To_String (From.Hook));
      With_Hooks : constant JSON.Value :=
        With_Member
          (Existing, "hooks", Merged (Hooks_Of (Existing, Settings), Fresh));
      Env_Entry  : JSON.Value := Empty_Object;
   begin
      if JSON.Has_Member (With_Hooks, "env") then
         Env_Entry := JSON.Member_Value (With_Hooks, "env");
         if JSON.Kind_Of (Env_Entry) = JSON.JSON_Null then
            Env_Entry := Empty_Object;
         elsif JSON.Kind_Of (Env_Entry) /= JSON.JSON_Object then
            raise Failed with
              Settings & " has an env entry that is not an object -- fix or "
              & "back it up manually before re-running";
         end if;
      end if;
      return
        Synapse.Core.JSON_Indent.Indented
          (With_Member
             (With_Hooks, "env",
              With_Member
                (Env_Entry, "SYNAPSE_CONTENT_ROOT",
                 JSON.Make_String (Root_Of (From)))))
        & LF;
   end Claude_Settings;

   procedure Configure_Claude (Env : Environment; From : Source) is
      Folder   : constant String := Home_Of (From) & "/.claude";
      Settings : constant String := Folder & "/settings.json";
      Text     : constant String := Claude_Settings (From, Settings);
      Skills   : constant Lists.Vector :=
        Copy_Skills (Root_Of (From) & "/skills", Folder & "/skills");
      Commands : Lists.Vector;
   begin
      Prune (Folder & "/skills", Skills);
      Commands :=
        Copy_Commands (Root_Of (From) & "/commands", Folder & "/commands");
      Prune (Folder & "/commands", Commands);
      Say
        (Env,
         "installed " & Count (Skills) & " skills, " & Count (Commands)
         & " commands to ~/.claude" & LF);
      Backup_If_Exists (Settings);
      Write_Text (Settings, Text);
      Say (Env, "configured " & Settings & LF & LF);
      Say
        (Env,
         "No manual steps -- restart Claude Code so the new hooks/settings "
         & "take effect" & LF & "for the running session." & LF);
   end Configure_Claude;

   procedure Configure_Codex (Env : Environment; From : Source) is
      Hooks_File : constant String := Home_Of (From) & "/.codex/hooks.json";
      Folder     : constant String := Home_Of (From) & "/.codex/skills";
      Existing   : constant JSON.Value :=
        Object_In (Hooks_File, Empty_Object);
      Fresh      : constant JSON.Value :=
        Rendered
          (Parsed_Template (Root_Of (From) & "/harness/codex/hooks.json"),
           To_String (From.Hook));
   begin
      Backup_If_Exists (Hooks_File);
      Write_Text
        (Hooks_File,
         Synapse.Core.JSON_Indent.Indented
           (With_Member
              (Existing, "hooks",
               Merged (Hooks_Of (Existing, Hooks_File), Fresh)))
         & LF);
      Say (Env, "configured " & Hooks_File & LF);

      declare
         Shared : Lists.Vector :=
           Copy_Skills (Root_Of (From) & "/skills", Folder);
         Own    : constant Lists.Vector :=
           Copy_Skills (Root_Of (From) & "/harness/codex/skills", Folder);
      begin
         Shared.Append_Vector (Own);
         Prune (Folder, Shared);
         Say
           (Env, "installed " & Count (Shared) & " skills to " & Folder & LF);
      end;
      Say
        (Env,
         LF & "No manual steps -- the next real `codex` session will prompt "
         & "to trust the" & LF & "hooks this just wrote, approve it "
         & "interactively." & LF);
   end Configure_Codex;

   procedure Configure_Opencode (Env : Environment; From : Source) is
      Folder      : constant String := Home_Of (From) & "/.config/opencode";
      Template    : constant String :=
        Root_Of (From) & "/harness/opencode/plugin/synapse.js";
      Placeholder : constant String := """__SYNAPSE_HOOK_BIN__""";
   begin
      if not Is_File (Template) then
         raise Failed with Template & " is missing";
      end if;
      declare
         Text  : constant String := Read_Text (Template);
         Place : constant Natural := Ada.Strings.Fixed.Index (Text, Placeholder);
      begin
         if Place = 0 then
            raise Failed with Template & " has no " & Placeholder;
         end if;
         Write_Text
           (Folder & "/plugin/synapse.js",
            Text (Text'First .. Place - 1)
            & JSON.To_String (JSON.Make_String (To_String (From.Hook)))
            & Text (Place + Placeholder'Length .. Text'Last));
      end;
      Say (Env, "installed " & Folder & "/plugin/synapse.js" & LF);

      declare
         Skills   : constant Lists.Vector :=
           Copy_Skills (Root_Of (From) & "/skills", Folder & "/skill");
         Commands : constant Lists.Vector :=
           Copy_Commands (Root_Of (From) & "/commands", Folder & "/command");
      begin
         Prune (Folder & "/skill", Skills);
         Prune (Folder & "/command", Commands);
         Say
           (Env,
            "installed " & Count (Skills) & " skills, " & Count (Commands)
            & " commands to ~/.config/opencode" & LF);
      end;
      Say
        (Env,
         LF & "No manual steps -- the plugin resolves its synapse-hook binary "
         & "from the shared" & LF & "install location ("
         & To_String (From.Hook) & ") automatically." & LF);
   end Configure_Opencode;

   --  Where what is installed comes from and goes to; raises Failed with the
   --  sentence that says why when it cannot be found.
   function Locate (Env : Environment) return Source is
      Home    : constant Synapse.Ports.Variables.Maybe_Value :=
        Env.Vars.Get ("HOME");
      Content : constant Synapse.Ports.Variables.Maybe_Value :=
        Env.Vars.Get ("SYNAPSE_CONTENT_ROOT");
      Own     : constant String := Own_Directory (To_String (Env.Argv0));
      Result  : Source;
   begin
      if not Home.Found or else Length (Home.Value) = 0 then
         raise Failed with "there is no home directory to install into";
      end if;
      Result.Home := Home.Value;

      if Content.Found and then Length (Content.Value) > 0 then
         Result.Root := Content.Value;
      elsif Own /= "" then
         Result.Root := To_Unbounded_String (Own & "/..");
      end if;
      if Length (Result.Root) = 0
        or else not Is_Directory (Root_Of (Result) & "/skills")
      then
         raise Failed with
           "SYNAPSE_CONTENT_ROOT must name the folder that holds skills/";
      end if;

      if Own = "" or else not Is_File (Own & "/" & Hook_Name & Exe) then
         raise Failed with
           Hook_Name & Exe & " was not found beside this program"
           & (if Own = "" then "" else " (" & Own & ")");
      end if;
      --  `/` between the parts on Windows: the command runs through whichever
      --  shell the harness uses, and a shell that reads `\` as an escape
      --  would lose every one of them, while every Windows API accepts `/`.
      declare
         Hook : String := Own & "/" & Hook_Name & Exe;
      begin
         for C of Hook loop
            if C = '\' then
               C := '/';
            end if;
         end loop;
         Result.Hook := To_Unbounded_String (Hook);
      end;
      return Result;
   end Locate;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      if Natural (Args.Length) = 1 and then Cli_Args.Is_Help (To_String (Args.First_Element)) then
         Say (Env, Help_Text);
         return 0;
      end if;
      if Natural (Args.Length) /= 1
        or else To_String (Args.First_Element) not in
                "claude" | "codex" | "opencode"
      then
         return Usage_Error (Env, Usage_Text);
      end if;
      declare
         Harness : constant String := To_String (Args.First_Element);
         From    : constant Source := Locate (Env);
      begin
         Bootstrap_Conf (Env, From);
         if Harness = "claude" then
            Configure_Claude (Env, From);
         elsif Harness = "codex" then
            Configure_Codex (Env, From);
         else
            Configure_Opencode (Env, From);
         end if;
         return 0;
      end;
   exception
      when Failure : Failed =>
         Complain (Env, Prog & Ada.Exceptions.Exception_Message (Failure) & LF);
         return 1;
      when Conf_Files.No_Home =>
         Complain (Env, Prog & "there is no home directory to install into" & LF);
         return 1;
      when Problem : File_Bytes.Too_Large | Ada.Directories.Name_Error
         | Ada.Directories.Use_Error | Ada.Directories.Status_Error
         | Ada.Text_IO.Data_Error | Ada.Text_IO.Use_Error
         | Ada.Text_IO.Name_Error =>
         Complain
           (Env, Prog & "a file could not be read or written: "
            & Ada.Exceptions.Exception_Message (Problem) & LF);
         return 1;
   end Run;

end Synapse.Commands.Configure;
