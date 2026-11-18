with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.JSON_Indent;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.File_System;

package body Synapse.Pipeline.Commands.Configure is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;
   package JSON_Indent renames Synapse.Core.JSON_Indent;

   LF : constant Character := Character'Val (10);

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Configure_Help);

   Manifest : constant String := ".synapse-pipeline-managed.json";

   --  The folder a harness reads skills from, under the home directory.
   function Skills_Folder (Home, Harness : String) return String is
     (if Harness = "claude" then Home & "/.claude/skills"
      elsif Harness = "codex" then Home & "/.codex/skills"
      else Home & "/.config/opencode/skill");

   --  Whether a name from a manifest is one directory directly in the skills
   --  folder, so that a manifest cannot point anywhere else.
   function Is_Plain_Name (Name : String) return Boolean is
     (Name /= "" and then Name /= "." and then Name /= ".."
      and then (for all C of Name => C not in '/' | '\'));

   --  The names a manifest lists; none when it is missing or is not a list.
   function Listed
     (Files : in out File_System.File_System'Class; Path : String)
      return Lists.Vector
   is
      Result  : Lists.Vector;
      Content : constant File_System.Maybe_Content := Files.Read (Path);
   begin
      if not Content.Found then
         return Result;
      end if;
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (To_String (Content.Value));
      begin
         if Parsed.Ok and then JSON.Kind_Of (Parsed.Item) = JSON.JSON_Array
         then
            for I in 1 .. JSON.Length (Parsed.Item) loop
               declare
                  Item : constant JSON.Value := JSON.Element (Parsed.Item, I);
               begin
                  if JSON.Kind_Of (Item) = JSON.JSON_String
                    and then Is_Plain_Name (JSON.As_String (Item))
                  then
                     Result.Append
                       (To_Unbounded_String (JSON.As_String (Item)));
                  end if;
               end;
            end loop;
         end if;
      end;
      return Result;
   end Listed;

   --  The manifest text: the names as a list, a line to each.
   function Manifest_Text (Names : Lists.Vector) return String is
      Items : JSON.Value_Array (1 .. Natural (Names.Length));
   begin
      for I in Items'Range loop
         Items (I) := JSON.Make_String (To_String (Names (I)));
      end loop;
      return JSON_Indent.Indented (JSON.Make_Array (Items)) & LF;
   end Manifest_Text;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
   begin
      if Natural (Args.Length) /= 1
        or else To_String (Args.First_Element) not in
                "claude" | "codex" | "opencode"
      then
         return Usage_Error (Env, Usage);
      end if;
      declare
         Harness : constant String := To_String (Args.First_Element);
         Home    : constant Synapse.Ports.Variables.Maybe_Value :=
           Env.Vars.Get ("HOME");
         Root    : constant Synapse.Ports.Variables.Maybe_Value :=
           Env.Vars.Get ("SYNAPSE_CONTENT_ROOT");
      begin
         if not Home.Found or else Length (Home.Value) = 0 then
            Complain
              (Env, "synapse-pipeline: there is no home directory to "
               & "install into" & LF);
            return 1;
         end if;
         if not Root.Found
           or else not Env.Files.Is_Directory
                         (To_String (Root.Value) & "/skills")
         then
            Complain
              (Env, "synapse-pipeline: SYNAPSE_CONTENT_ROOT must name the "
               & "folder that holds skills/" & LF);
            return 1;
         end if;
         declare
            Source : constant String := To_String (Root.Value) & "/skills";
            Dest   : constant String :=
              Skills_Folder (To_String (Home.Value), Harness);
            Names  : constant Lists.Vector :=
              Env.Files.Subdirectories (Source);
            Before : constant Lists.Vector :=
              Listed (Env.Files.all, Dest & "/" & Manifest);
            Done   : Boolean;
         begin
            for Name of Names loop
               Env.Files.Replace_Tree
                 (Source & "/" & To_String (Name),
                  Dest & "/" & To_String (Name), Done);
               if not Done then
                  Complain
                    (Env, "synapse-pipeline: could not install "
                     & To_String (Name) & " into " & Dest & LF);
                  return 1;
               end if;
            end loop;
            for Old of Before loop
               if not Names.Contains (Old) then
                  Env.Files.Remove_Tree (Dest & "/" & To_String (Old));
               end if;
            end loop;
            Env.Files.Write
              (Dest & "/" & Manifest, Manifest_Text (Names), Done);
            if not Done then
               Complain
                 (Env, "synapse-pipeline: could not write " & Dest & "/"
                  & Manifest & LF);
               return 1;
            end if;
            Say
              (Env,
               "installed" & Names.Length'Image & " skill"
               & (if Natural (Names.Length) = 1 then "" else "s") & " to "
               & Dest & LF);
            return 0;
         end;
      end;
   end Run;

end Synapse.Pipeline.Commands.Configure;
