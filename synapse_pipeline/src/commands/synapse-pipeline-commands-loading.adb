with Synapse.Pipeline.Definitions;
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
      Skill_Roots : out Search_Paths.Root_Vectors.Vector)
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

end Synapse.Pipeline.Commands.Loading;
