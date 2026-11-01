with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Search_Paths;
with Synapse.Pipeline.Skills;
with Synapse.Pipeline.Commands.Loading;
with Synapse.Pipeline.Commands.Usage;

package body Synapse.Pipeline.Commands.Check is

   use Ada.Strings.Unbounded;
   use type Resolved.Instruction_Kind;

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Check_Help);

   --  What the pipeline would run with, one step after another.
   function Describe
     (Item          : Resolved.Pipeline; Pipeline_File : String;
      Files         : File_System.File_System'Class;
      Skill_Roots   : Search_Paths.Root_Vectors.Vector) return String
   is
      LF     : constant Character := Character'Val (10);
      Result : Unbounded_String;

      procedure Skill_Line (Item : Resolved.Instruction) is
      begin
         if Item.Present and then Item.Kind = Resolved.Skill_Name then
            declare
               Found : constant Synapse.Core.Optional_Text.Option :=
                 Skills.Find (Files, Skill_Roots, To_String (Item.Text));
            begin
               Append
                 (Result,
                  "    skill " & To_String (Item.Text) & "  "
                  & (if Found.Found then To_String (Found.Value)
                     else "(not found)") & LF);
            end;
         end if;
      end Skill_Line;
   begin
      Append
        (Result,
         "pipeline " & To_String (Item.Name) & "  " & Pipeline_File & LF);
      for S of Item.Steps loop
         Append
           (Result,
            "  step " & To_String (S.Name) & "  harness "
            & Harnesses.Name_Of (S.Harness) & LF);
         for O of S.Origins loop
            Append
              (Result,
               "    "
               & (case O.Kind is
                    when Resolved.System_Origin => "system ",
                    when Resolved.Agent_Origin  => "agent ")
               & To_String (O.Name) & "  " & To_String (O.File) & LF);
         end loop;
         Skill_Line (S.Role);
         Skill_Line (S.Assignment);
      end loop;
      return To_String (Result);
   end Describe;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Ok          : Boolean;
      Item        : Resolved.Pipeline;
      File        : Unbounded_String;
      Skill_Roots : Search_Paths.Root_Vectors.Vector;
   begin
      if Natural (Args.Length) /= 1 then
         return Usage_Error (Env, Usage);
      end if;
      Loading.Load
        (Env, To_String (Args.First_Element), Ok, Item, File, Skill_Roots);
      if not Ok then
         return 1;
      end if;
      Say (Env, Describe (Item, To_String (File), Env.Files.all, Skill_Roots));
      return 0;
   end Run;

end Synapse.Pipeline.Commands.Check;
