with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Contexts;
with Synapse.Pipeline.Definitions;
with Synapse.Pipeline.Descriptions;
with Synapse.Pipeline.Engine;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Inspectors;
with Synapse.Pipeline.Resolution;
with Synapse.Pipeline.Process_Runners;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Scripted_Runners;
with Synapse.Pipeline.Search_Paths;
with Synapse.Pipeline.Session_Runner;
with Synapse.Pipeline.Source_Errors;
with Synapse.Pipeline.States;
with Synapse.Pipeline.Validation;
with Synapse.Pipeline.Commands.Usage;

package body Synapse.Pipeline.Commands.Run is

   use Ada.Strings.Unbounded;
   use type Configs.Runner_Kind;
   use type States.Run_Status;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   Usage : constant String :=
     Commands.Usage.Synopsis (Commands.Usage.Run_Help);

   --  What a finished step's result says its outcome was.
   function Outcome_Of (Item : States.State) return String is
     (if JSON.Kind_Of (Item.Previous_Output) = JSON.JSON_Object
        and then JSON.Has_Member (Item.Previous_Output, "outcome")
      then JSON.As_String (JSON.Member_Value (Item.Previous_Output, "outcome"))
      else "");

   function Cause_Of (Item : States.State) return String is
     ("step " & To_String (Item.Failure.Step) & " failed: "
      & Failures.Name_Of (Item.Failure.Kind) & ": "
      & To_String (Item.Failure.Message)
      & (if Item.Failure.Reset.Found
         then " (resets at " & To_String (Item.Failure.Reset.Value) & ")"
         else ""));

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   --  Runs the pipeline from its first step with Runner, and says how it
   --  ended. While it goes on, the run can be asked about from outside, where
   --  the transport can listen; whether it can never changes the run.
   function Run_To_The_End
     (Env      : Environment;
      Pipeline : Resolved.Pipeline;
      Settings : Configs.Config;
      Input    : JSON.Value;
      Runner   : in out Session_Runner.Runner'Class) return Exit_Code
   is
      Run     : States.State := States.Initial (Pipeline, Input);
      Context : aliased Contexts.Execution_Context;
      Id      : constant String := Inspectors.New_Id;

      --  The run itself: every step, with what happens recorded for whoever
      --  asks and a line for whoever is watching.
      procedure Go (Listening : Boolean; Reason : String) is
      begin
         if not Listening and then Reason /= "" then
            Complain
              (Env,
               "warning: introspection is unavailable: " & Reason & LF);
         end if;
         Context.Record_Event
           ("run.started", To_String (Run.Current_Step),
            JSON.Make_Object
              ([Member
                  ("pipeline",
                   JSON.Make_String (To_String (Pipeline.Name)))]));
         while not States.Is_Terminal (Run) loop
            declare
               Step : constant String := To_String (Run.Current_Step);
            begin
               Context.Record_Event ("step.started", Step, JSON.Null_Value);
               Run := Engine.Execute_Step (Pipeline, Run, Settings, Runner);
               Context.Publish (Run);
               if Run.Status = States.Failed then
                  Context.Record_Event
                    ("run.failed", Step,
                     JSON.Make_Object
                       ([Member
                           ("kind",
                            JSON.Make_String
                              (Failures.Name_Of (Run.Failure.Kind))),
                         Member
                           ("message",
                            JSON.Make_String
                              (To_String (Run.Failure.Message)))]));
               else
                  Context.Record_Event
                    ("step.finished", Step,
                     JSON.Make_Object
                       ([Member
                           ("outcome", JSON.Make_String (Outcome_Of (Run))),
                         Member
                           ("next",
                            JSON.Make_String
                              (To_String (Run.Current_Step)))]));
                  Complain
                    (Env,
                     "step " & Step & ": " & Outcome_Of (Run) & " -> "
                     & (if Run.Status = States.Completed then "done"
                        else To_String (Run.Current_Step)) & LF);
                  if Run.Status = States.Completed then
                     Context.Record_Event
                       ("run.completed", Step, JSON.Null_Value);
                  end if;
               end if;
            end;
         end loop;
      end Go;

      Work : constant Configs.Environment_Maps.Cursor :=
        Settings.Environment.Find (Configs.Work_Dir_Key);
   begin
      Context.Start (Id, Descriptions.Describe (Pipeline, Settings), Run);
      if Configs.Environment_Maps.Has_Element (Work) then
         Inspectors.Serve_While
           (Env.Inspector.all,
            Env.Inspector.Endpoint_For
              (Configs.Environment_Maps.Element (Work), Id),
            Context, Go'Access);
      else
         Go (False, "");
      end if;
      if Run.Status = States.Failed then
         Complain (Env, "error: " & Cause_Of (Run) & LF);
         return 1;
      end if;
      Say (Env, JSON.To_String (Run.Previous_Output) & LF);
      return 0;
   end Run_To_The_End;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Name       : Unbounded_String;
      Input_Path : Unbounded_String;
      Has_Input  : Boolean := False;
      I          : Positive := Args.First_Index;
   begin
      while I <= Args.Last_Index loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Arg = "--input" then
               if Has_Input or else I = Args.Last_Index then
                  return Usage_Error (Env, Usage);
               end if;
               Has_Input := True;
               I := I + 1;
               Input_Path := Args (I);
            elsif Arg'Length >= 2 and then Arg (Arg'First .. Arg'First + 1) =
                  "--"
            then
               return Usage_Error (Env, Usage);
            elsif Length (Name) > 0 then
               return Usage_Error (Env, Usage);
            else
               Name := To_Unbounded_String (Arg);
            end if;
         end;
         I := I + 1;
      end loop;
      if Length (Name) = 0 then
         return Usage_Error (Env, Usage);
      end if;

      declare
         Wanted   : constant String := To_String (Name);
         Settled  : constant Configs.Config_Results.Result :=
           Configs.Resolve (Env.Vars.all, Env.Files.Current_Directory);
      begin
         if not Configs.Config_Results.Is_Success (Settled) then
            Complain
              (Env,
               "error: " & To_String (Configs.Config_Results.Error (Settled))
               & LF);
            return 1;
         end if;
         declare
            Settings : constant Configs.Config :=
              Configs.Config_Results.Value (Settled);
            Input    : JSON.Value := JSON.Null_Value;
         begin
            if Has_Input then
               declare
                  Path   : constant String := To_String (Input_Path);
                  Text   : constant String :=
                    (if Path = "-" then Env.Console.Read_Stdin else "");
                  Found  : constant File_System.Maybe_Content :=
                    (if Path = "-"
                     then (Found => True,
                           Value => To_Unbounded_String (Text))
                     else Env.Files.Read (Path));
               begin
                  if not Found.Found then
                     Complain
                       (Env,
                        "error: --input " & Path & " cannot be read" & LF);
                     return 1;
                  end if;
                  declare
                     Parsed : constant JSON.Parse_Result :=
                       JSON.Parse (To_String (Found.Value));
                  begin
                     if not Parsed.Ok then
                        Complain
                          (Env,
                           "error: --input " & Path & " is not JSON: "
                           & JSON.Parse_Error_Kind'Image (Parsed.Error)
                           & " at byte" & Natural'Image (Parsed.Offset) & LF);
                        return 1;
                     end if;
                     Input := Parsed.Item;
                  end;
               end;
            end if;

            declare
               Report   : constant Definitions.Load_Report :=
                 Definitions.Load
                   (Env.Files.all,
                    Search_Paths.Definition_Roots (Env.Vars.all));
               Problems : constant Definitions.Problem_Vectors.Vector :=
                 Validation.Validate
                   (Report.Definitions, Env.Files.all,
                    Search_Paths.Skill_Roots (Env.Vars.all), Wanted,
                    Settings.Default_Harness);
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
                      (Report.Definitions, Wanted, Settings.Default_Harness);
               begin
                  if not Resolution.Resolve_Results.Is_Success (Made) then
                     Complain
                       (Env,
                        "error: "
                        & Source_Errors.Image
                            (Resolution.Resolve_Results.Error (Made)) & LF);
                     return 1;
                  end if;
                  if Settings.Runner = Configs.Process_Runner then
                     declare
                        Runner : Process_Runners.Process_Runner
                          (Env.Sessions, Env.Files);
                     begin
                        Runner.Skill_Roots :=
                          Search_Paths.Skill_Roots (Env.Vars.all);
                        return Run_To_The_End
                          (Env,
                           Resolution.Resolve_Results.Value (Made), Settings,
                           Input, Runner);
                     end;
                  end if;
                  declare
                     Script :
                       constant Scripted_Runners.Script_Results.Result :=
                       Scripted_Runners.Load
                         (Env.Files.all, To_String (Settings.Script));
                  begin
                     if not Scripted_Runners.Script_Results.Is_Success
                              (Script)
                     then
                        Complain
                          (Env,
                           "error: "
                           & To_String
                               (Scripted_Runners.Script_Results.Error
                                  (Script)) & LF);
                        return 1;
                     end if;
                     declare
                        Runner : Scripted_Runners.Scripted_Runner :=
                          Scripted_Runners.Create
                            (Scripted_Runners.Script_Results.Value (Script));
                     begin
                        return Run_To_The_End
                          (Env,
                           Resolution.Resolve_Results.Value (Made), Settings,
                           Input, Runner);
                     end;
                  end;
               end;
            end;
         end;
      end;
   end Run;

end Synapse.Pipeline.Commands.Run;
