with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Definitions;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Namespaces;
with Synapse.Pipeline.Resolution;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Search_Paths;
with Synapse.Pipeline.Skills;
with Synapse.Pipeline.Source_Errors;
with Synapse.Pipeline.Validation;
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
      LF : constant Character := Character'Val (10);
   begin
      if Natural (Args.Length) /= 1 then
         return Usage_Error (Env, Usage);
      end if;
      declare
         Name    : constant String := To_String (Args.First_Element);
         Default : constant Harnesses.Default_Results.Result :=
           Harnesses.Default (Env.Vars.all);
      begin
         if not Harnesses.Default_Results.Is_Success (Default) then
            Complain
              (Env,
               "error: "
               & To_String (Harnesses.Default_Results.Error (Default)) & LF);
            return 1;
         end if;
         declare
            Report      : constant Definitions.Load_Report :=
              Definitions.Load
                (Env.Files.all, Search_Paths.Definition_Roots (Env.Vars.all));
            Skill_Roots : constant Search_Paths.Root_Vectors.Vector :=
              Search_Paths.Skill_Roots (Env.Vars.all);
            Problems    : constant Definitions.Problem_Vectors.Vector :=
              Validation.Validate
                (Report.Definitions, Env.Files.all, Skill_Roots, Name,
                 Harnesses.Default_Results.Value (Default));
         begin
            for P of Report.Problems loop
               Complain (Env, Definitions.Warning (P) & LF);
            end loop;
            if not Problems.Is_Empty then
               for P of Problems loop
                  Complain (Env, "error: " & Source_Errors.Image (P) & LF);
               end loop;
               return 1;
            end if;
            declare
               Made : constant Resolution.Resolve_Results.Result :=
                 Resolution.Resolve
                   (Report.Definitions, Name,
                    Harnesses.Default_Results.Value (Default));
            begin
               if not Resolution.Resolve_Results.Is_Success (Made) then
                  Complain
                    (Env,
                     "error: "
                     & Source_Errors.Image
                         (Resolution.Resolve_Results.Error (Made))
                     & LF);
                  return 1;
               end if;
               Say
                 (Env,
                  Describe
                    (Resolution.Resolve_Results.Value (Made),
                     To_String
                       (Namespaces.Element (Report.Definitions, Name).Path),
                     Env.Files.all, Skill_Roots));
               return 0;
            end;
         end;
      end;
   end Run;

end Synapse.Pipeline.Commands.Check;
