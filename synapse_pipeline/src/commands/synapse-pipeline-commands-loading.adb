with Synapse.Pipeline.Definitions;
with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Namespaces;
with Synapse.Pipeline.Resolution;
with Synapse.Pipeline.Source_Errors;
with Synapse.Pipeline.Validation;

package body Synapse.Pipeline.Commands.Loading is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   procedure Load
     (Env         : Environment;
      Name        : String;
      Ok          : out Boolean;
      Item        : out Resolved.Pipeline;
      File        : out Unbounded_String;
      Skill_Roots : out Search_Paths.Root_Vectors.Vector;
      Advise      : Boolean := False)
   is
      Default : constant Harnesses.Default_Results.Result :=
        Harnesses.Default (Env.Vars.all);
   begin
      Ok := False;
      if not Harnesses.Default_Results.Is_Success (Default) then
         Complain
           (Env,
            "error: " & To_String (Harnesses.Default_Results.Error (Default))
            & LF);
         return;
      end if;
      declare
         Report   : constant Definitions.Load_Report :=
           Definitions.Load
             (Env.Files.all, Search_Paths.Definition_Roots (Env.Vars.all));
         Roots    : constant Search_Paths.Root_Vectors.Vector :=
           Search_Paths.Skill_Roots (Env.Vars.all);
         Problems : constant Definitions.Problem_Vectors.Vector :=
           Validation.Validate
             (Report.Definitions, Env.Files.all, Roots, Name,
              Harnesses.Default_Results.Value (Default));
      begin
         for P of Report.Problems loop
            Complain (Env, Definitions.Warning (P) & LF);
         end loop;
         if not Problems.Is_Empty then
            for P of Problems loop
               Complain (Env, "error: " & Source_Errors.Image (P) & LF);
            end loop;
            return;
         end if;
         if Advise then
            for P of Validation.Advise (Report.Definitions, Name) loop
               Complain (Env, Definitions.Warning (P) & LF);
            end loop;
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
                      (Resolution.Resolve_Results.Error (Made)) & LF);
               return;
            end if;
            Item := Resolution.Resolve_Results.Value (Made);
            File := Namespaces.Element (Report.Definitions, Name).Path;
            Skill_Roots := Roots;
            Ok := True;
         end;
      end;
   end Load;

   procedure Read_Input
     (Env   : Environment;
      Path  : String;
      Input : out Synapse.Core.JSON.Value;
      Ok    : out Boolean)
   is
      Found : constant File_System.Maybe_Content :=
        (if Path = "-"
         then (Found => True,
               Value => To_Unbounded_String (Env.Console.Read_Stdin))
         else Env.Files.Read (Path));
   begin
      Input := Synapse.Core.JSON.Null_Value;
      Ok := False;
      if not Found.Found then
         Complain (Env, "error: --input " & Path & " cannot be read" & LF);
         return;
      end if;
      declare
         Parsed : constant Synapse.Core.JSON.Parse_Result :=
           Synapse.Core.JSON.Parse (To_String (Found.Value));
      begin
         if not Parsed.Ok then
            Complain
              (Env,
               "error: --input " & Path & " is not JSON: "
               & Synapse.Core.JSON.Parse_Error_Kind'Image (Parsed.Error)
               & " at byte" & Natural'Image (Parsed.Offset) & LF);
            return;
         end if;
         Input := Parsed.Item;
         Ok := True;
      end;
   end Read_Input;

end Synapse.Pipeline.Commands.Loading;
