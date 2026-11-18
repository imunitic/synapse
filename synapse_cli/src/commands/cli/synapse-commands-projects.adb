with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.File_Bytes;
with Synapse.Commands.Cli_Args;
with Synapse.Core.JSON;
with Synapse.Core.Projects;

package body Synapse.Commands.Projects is

   use Ada.Strings.Unbounded;

   package Conf_Files renames Synapse.Adapters.Conf_Files;
   package JSON renames Synapse.Core.JSON;
   package Registry renames Synapse.Core.Projects;

   LF : constant Character := Character'Val (10);

   Prog : constant String := "synapse-projects";

   File_Name : constant String := "synapse-projects.conf";

   Largest_File : constant := 1_024 * 1_024;

   Usage_Text : constant String :=
     "usage: synapse projects [list] [--format json|text]" & LF &
     "       synapse projects add <name> <prefix>" & LF;

   --  The file that is read, else the place one is made. Empty without a
   --  home directory to put it in.
   function File_Of (Env : Environment) return String is
   begin
      return Conf_Files.Resolve_Write_Path (Env.Vars.all, File_Name);
   exception
      when Conf_Files.No_Home =>
         return "";
   end File_Of;

   function Current_Text (Path : String) return String is
   begin
      return
        (if Path /= "" and then Ada.Directories.Exists (Path)
         then Synapse.Adapters.File_Bytes.Read (Path, Largest_File) else "");
   end Current_Text;

   function Key (Name : String) return Unbounded_String renames
     To_Unbounded_String;

   function List_Json (Path : String; Found : Registry.Project_List)
     return String
   is
      Items   : JSON.Value_Array (1 .. Natural (Found.Length));
      Nothing : JSON.Value;
   begin
      for I in Items'Range loop
         Items (I) :=
           JSON.Make_Object
             ([(Key ("name"),
                JSON.Make_String (To_String (Found (I).Name))),
               (Key ("prefix"),
                JSON.Make_String (To_String (Found (I).Prefix)))]);
      end loop;
      return
        JSON.To_String
          (JSON.Make_Object
             ([(Key ("format"), JSON.Make_String ("synapse-projects/v1")),
               (Key ("file"),
                (if Path = "" then Nothing else JSON.Make_String (Path))),
               (Key ("projects"), JSON.Make_Array (Items))])) & LF;
   end List_Json;

   function List_Text (Found : Registry.Project_List) return String is
      Result : Unbounded_String;
   begin
      for Item of Found loop
         Append
           (Result,
            To_String (Item.Name) & "=" & To_String (Item.Prefix) & LF);
      end loop;
      return To_String (Result);
   end List_Text;

   --  The flags of a listing are the arguments from From on.
   function Run_List
     (Env : Environment; Args : Lists.Vector; From : Positive)
      return Exit_Code
   is
      Format : Unbounded_String := To_Unbounded_String ("text");
      I      : Positive := From;
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
      declare
         Path  : constant String := File_Of (Env);
         Found : constant Registry.Project_List :=
           Registry.Parse (Current_Text (Path));
      begin
         if Format = "json" then
            Say (Env, List_Json (Path, Found));
         elsif Format = "text" then
            Say (Env, List_Text (Found));
         else
            return Usage_Error (Env, Usage_Text);
         end if;
         return 0;
      end;
   end Run_List;

   function Run_Add (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
      Name   : constant String := To_String (Args (2));
      Prefix : constant String := To_String (Args (3));
      Path   : constant String := File_Of (Env);
   begin
      if Path = "" then
         Complain
           (Env,
            Prog & ": there is no home directory to put " & File_Name &
            " in" & LF);
         return 1;
      end if;
      declare
         Before : constant String := Current_Text (Path);
         Reason : constant String :=
           Registry.Refusal (Name, Prefix, Registry.Parse (Before));
      begin
         if Reason /= "" then
            Complain (Env, Prog & ": " & Reason & LF);
            return 1;
         end if;
         Ada.Directories.Create_Path
           (Ada.Directories.Containing_Directory (Path));
         Synapse.Adapters.File_Bytes.Write
           (Path, Registry.With_Added (Before, Name, Prefix));
         Say (Env, Path & LF);
         return 0;
      exception
         when others =>
            Complain (Env, Prog & ": cannot write " & Path & LF);
            return 1;
      end;
   end Run_Add;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      if Args.Is_Empty then
         return Run_List (Env, Args, 1);
      end if;
      declare
         First : constant String := To_String (Args (1));
         Count : constant Natural := Natural (Args.Length);
      begin
         if Cli_Args.Is_Help (First) then
            Complain (Env, Usage_Text);
            return 0;
         elsif First = "list" then
            return Run_List (Env, Args, 2);
         elsif First = "--format" then
            return Run_List (Env, Args, 1);
         elsif First = "add" and then Count = 3 then
            return Run_Add (Env, Args);
         end if;
         return Usage_Error (Env, Usage_Text);
      end;
   end Run;

end Synapse.Commands.Projects;
