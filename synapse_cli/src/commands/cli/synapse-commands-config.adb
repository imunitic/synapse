with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Store_Resolve;
with Synapse.Commands.Cli_Args;
with Synapse.Core.Conf;
with Synapse.Core.JSON;
with Synapse.Core.Settings;

package body Synapse.Commands.Config is

   use Ada.Strings.Unbounded;
   use type Synapse.Adapters.Conf_Files.Origin;

   package Conf_Files renames Synapse.Adapters.Conf_Files;
   package JSON renames Synapse.Core.JSON;
   package Settings renames Synapse.Core.Settings;

   LF : constant Character := Character'Val (10);

   Prog : constant String := "synapse-config";

   Largest_File : constant := 1_024 * 1_024;

   Usage_Text : constant String :=
     "usage: synapse config list [--format json|text]" & LF &
     "       synapse config set <KEY> <value>" & LF &
     "       synapse config unset <KEY>" & LF;

   function Key (Name : String) return Unbounded_String renames
     To_Unbounded_String;

   --  JSON null, which is what a value with nothing in it is.
   function Null_Json return JSON.Value is
      Nothing : JSON.Value;
   begin
      return Nothing;
   end Null_Json;

   function Text_Or_Null (Found : Conf_Files.Maybe_Path) return JSON.Value is
     (if Found.Found then JSON.Make_String (To_String (Found.Value))
      else Null_Json);

   function Maybe_String (Text : String) return JSON.Value is
     (if Text = "" then Null_Json else JSON.Make_String (Text));

   function Kind_Name (What : Settings.Kind) return String is
     (case What is
        when Settings.Path_Kind   => "path",
        when Settings.List_Kind   => "list",
        when Settings.Number_Kind => "number",
        when Settings.Toggle_Kind => "toggle");

   function Is_Template (Path : String) return Boolean is
     (Path'Length > 9
      and then Path (Path'Last - 8 .. Path'Last) = ".template");

   --  What one setting is, as the file and the environment have it.
   type Shown is record
      Item   : Settings.Setting;
      Detail : Conf_Files.Detail;
      Value  : Unbounded_String;
      Source : Unbounded_String;
   end record;

   function Show
     (Env : Environment; Item : Settings.Setting) return Shown
   is
      Found : constant Conf_Files.Detail :=
        Conf_Files.Describe (Env.Vars.all, Item.Name.all, Item.Environment);
      Result : Shown :=
        (Item, Found, Null_Unbounded_String, Null_Unbounded_String);
   begin
      case Found.From is
         when Conf_Files.From_Variable =>
            Result.Value  := Found.Value.Value;
            Result.Source := To_Unbounded_String ("environment");
         when Conf_Files.From_File =>
            Result.Value  := Found.Value.Value;
            Result.Source := To_Unbounded_String ("file");
         when Conf_Files.Nowhere =>
            if Item.Default.all /= "" then
               Result.Value  := To_Unbounded_String (Item.Default.all);
               Result.Source := To_Unbounded_String ("default");
            else
               Result.Source := To_Unbounded_String ("unset");
            end if;
      end case;
      return Result;
   end Show;

   function Write_Path (Env : Environment) return Conf_Files.Maybe_Path is
   begin
      return
        (Found => True,
         Value =>
           To_Unbounded_String
             (Conf_Files.Resolve_Write_Path
                (Env.Vars.all, Conf_Files.Primary_Name)));
   exception
      when Conf_Files.No_Home =>
         return (Found => False);
   end Write_Path;

   function Setting_Json (Entry_Shown : Shown) return JSON.Value is
      Item : Settings.Setting renames Entry_Shown.Item;
      Info : Conf_Files.Detail renames Entry_Shown.Detail;
   begin
      return
        JSON.Make_Object
          ([(Key ("key"), JSON.Make_String (Item.Name.all)),
            (Key ("kind"), JSON.Make_String (Kind_Name (Item.What))),
            (Key ("description"), JSON.Make_String (Item.Description.all)),
            (Key ("default"), Maybe_String (Item.Default.all)),
            (Key ("required"), JSON.Make_Boolean (Item.Required)),
            (Key ("environment"), JSON.Make_Boolean (Item.Environment)),
            (Key ("value"), Maybe_String (To_String (Entry_Shown.Value))),
            (Key ("source"),
             JSON.Make_String (To_String (Entry_Shown.Source))),
            (Key ("file"), Text_Or_Null (Info.File)),
            (Key ("file_value"), Text_Or_Null (Info.Raw)),
            (Key ("shadowed"), JSON.Make_Boolean (Info.Shadowed))]);
   end Setting_Json;

   function List_Json (Env : Environment) return String is
      Items : JSON.Value_Array (1 .. Settings.Count);
   begin
      for I in Settings.Index loop
         Items (I) := Setting_Json (Show (Env, Settings.Item (I)));
      end loop;
      return
        JSON.To_String
          (JSON.Make_Object
             ([(Key ("format"), JSON.Make_String ("synapse-config/v1")),
               (Key ("conf"),
                JSON.Make_Object
                  ([(Key ("read"),
                     Text_Or_Null
                       (Conf_Files.Resolve_Conf_Path
                          (Env.Vars.all, Conf_Files.Primary_Name))),
                    (Key ("write"), Text_Or_Null (Write_Path (Env)))])),
               (Key ("settings"), JSON.Make_Array (Items))])) & LF;
   end List_Json;

   function List_Text (Env : Environment) return String is
      Result : Unbounded_String;
   begin
      for I in Settings.Index loop
         declare
            Entry_Shown : constant Shown := Show (Env, Settings.Item (I));
            Where       : constant String :=
              (if Entry_Shown.Detail.File.Found
               then " in " & To_String (Entry_Shown.Detail.File.Value)
               else "");
         begin
            Append
              (Result,
               Entry_Shown.Item.Name.all & " = " &
               (if Length (Entry_Shown.Value) = 0 then "(none)"
                else To_String (Entry_Shown.Value)) &
               "  [" & To_String (Entry_Shown.Source) &
               (if Entry_Shown.Source = "file" then Where else "") &
               (if Entry_Shown.Detail.Shadowed
                then "; the file's " & To_String (Entry_Shown.Detail.Raw.Value)
                     & " is shadowed"
                else "") & "]" & LF);
         end;
      end loop;
      return To_String (Result);
   end List_Text;

   function Run_List (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Format : Unbounded_String := To_Unbounded_String ("text");
      I      : Positive := 2;
   begin
      while I <= Natural (Args.Length) loop
         if To_String (Args (I)) = "--format" then
            declare
               Found : Boolean;
            begin
               Cli_Args.Take_Value (Args, I, Format, Found);
               if not Found then
                  return Usage_Error (Env, Usage_Text);
               end if;
            end;
         else
            return Usage_Error (Env, Usage_Text);
         end if;
         I := I + 1;
      end loop;
      if Format = "json" then
         Say (Env, List_Json (Env));
      elsif Format = "text" then
         Say (Env, List_Text (Env));
      else
         return Usage_Error (Env, Usage_Text);
      end if;
      return 0;
   end Run_List;

   --  Why a value does not fit the setting, or nothing when it does.
   function Why_Not (Item : Settings.Setting; Value : String) return String is
   begin
      case Item.What is
         when Settings.Number_Kind =>
            if Value'Length = 0 or else Value'Length > 9
              or else not (for all C of Value => C in '0' .. '9')
            then
               return
                 Item.Name.all & " takes a whole number of at most 9 digits";
            end if;
         when Settings.List_Kind =>
            declare
               package Parsing renames
                 Synapse.Adapters.Store_Resolve.Parse_Results;
               Parsed : constant Parsing.Result :=
                 Synapse.Adapters.Store_Resolve.Parse_Integrations (Value);
            begin
               if not Parsing.Is_Success (Parsed) then
                  return To_String (Parsing.Error (Parsed));
               end if;
            end;
         when Settings.Toggle_Kind =>
            if Value = "" then
               return
                 Item.Name.all &
                 " takes a value; remove the setting to turn it off";
            end if;
         when Settings.Path_Kind =>
            if Value = "" then
               return
                 Item.Name.all &
                 " takes a path; remove the setting to clear it";
            end if;
      end case;
      return "";
   end Why_Not;

   --  The file a change to the key belongs in: the one that holds the key
   --  now, else the one a new setting goes in. Empty without a home.
   function Target (Env : Environment; Name : String) return String is
      Held : constant Conf_Files.Detail :=
        Conf_Files.Describe (Env.Vars.all, Name, Use_Variable => False);
   begin
      if Held.File.Found and then not Is_Template (To_String (Held.File.Value))
      then
         return To_String (Held.File.Value);
      end if;
      return
        Conf_Files.Resolve_Write_Path (Env.Vars.all, Conf_Files.Primary_Name);
   exception
      when Conf_Files.No_Home =>
         return "";
   end Target;

   function Current_Text (Path : String) return String is
   begin
      return
        (if Ada.Directories.Exists (Path)
         then Synapse.Adapters.File_Bytes.Read (Path, Largest_File) else "");
   end Current_Text;

   procedure Store (Path, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path));
      Synapse.Adapters.File_Bytes.Write (Path, Text);
   end Store;

   function Run_Set
     (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Name  : constant String := To_String (Args (2));
      Value : constant String := To_String (Args (3));
      Index : constant Natural := Settings.Find (Name);
   begin
      if Index = 0 then
         Complain (Env, Prog & ": unknown setting '" & Name & "'" & LF);
         return 1;
      end if;
      declare
         Item   : constant Settings.Setting := Settings.Item (Index);
         Reason : constant String := Why_Not (Item, Value);
         Path   : constant String := Target (Env, Name);
      begin
         if Reason /= "" then
            Complain (Env, Prog & ": " & Reason & LF);
            return 1;
         end if;
         if Path = "" then
            Complain
              (Env, Prog & ": there is no home directory to put " &
                    Conf_Files.Primary_Name & " in" & LF);
            return 1;
         end if;
         Store
           (Path, Synapse.Core.Conf.Set (Current_Text (Path), Name, Value));
         if Item.Environment
           and then Conf_Files.Describe (Env.Vars.all, Name).From =
                    Conf_Files.From_Variable
         then
            Complain
              (Env, Prog & ": the environment variable " & Name &
                    " is set and wins over the file" & LF);
         end if;
         Say (Env, Path & LF);
         return 0;
      exception
         when Synapse.Core.Conf.Unrepresentable =>
            Complain
              (Env, Prog & ": that value cannot be written on one line" & LF);
            return 1;
         when others =>
            Complain (Env, Prog & ": cannot write " & Path & LF);
            return 1;
      end;
   end Run_Set;

   function Run_Unset
     (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Name  : constant String := To_String (Args (2));
      Index : constant Natural := Settings.Find (Name);
   begin
      if Index = 0 then
         Complain (Env, Prog & ": unknown setting '" & Name & "'" & LF);
         return 1;
      end if;
      declare
         Held : constant Conf_Files.Detail :=
           Conf_Files.Describe (Env.Vars.all, Name, Use_Variable => False);
      begin
         if not Held.File.Found
           or else Is_Template (To_String (Held.File.Value))
         then
            return 0;
         end if;
         declare
            Path : constant String := To_String (Held.File.Value);
         begin
            Store (Path, Synapse.Core.Conf.Unset (Current_Text (Path), Name));
            Say (Env, Path & LF);
            return 0;
         exception
            when others =>
               Complain (Env, Prog & ": cannot write " & Path & LF);
               return 1;
         end;
      end;
   end Run_Unset;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      if Args.Is_Empty then
         return Usage_Error (Env, Usage_Text);
      end if;
      declare
         First : constant String := To_String (Args (1));
         Count : constant Natural := Natural (Args.Length);
      begin
         if Cli_Args.Is_Help (First) then
            Complain (Env, Usage_Text);
            return 0;
         elsif First = "list" then
            return Run_List (Env, Args);
         elsif First = "set" and then Count = 3 then
            return Run_Set (Env, Args);
         elsif First = "unset" and then Count = 2 then
            return Run_Unset (Env, Args);
         end if;
         return Usage_Error (Env, Usage_Text);
      end;
   end Run;

end Synapse.Commands.Config;
