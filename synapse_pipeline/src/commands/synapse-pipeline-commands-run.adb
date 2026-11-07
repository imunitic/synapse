with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Contexts;
with Synapse.Pipeline.Definition_Copies;
with Synapse.Pipeline.Descriptions;
with Synapse.Pipeline.Engine;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Id_Claims;
with Synapse.Pipeline.Inspectors;
with Synapse.Pipeline.Process_Runners;
with Synapse.Pipeline.Recorders;
with Synapse.Pipeline.Recording_Runners;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Scripted_Runners;
with Synapse.Pipeline.Search_Paths;
with Synapse.Pipeline.Session_Runner;
with Synapse.Pipeline.States;
with Synapse.Pipeline.Commands.Loading;
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

   --  The id the run takes, made a directory of the registry when the work
   --  directory is known and there is a free id to be had. Wanted is the id
   --  that was asked for, or empty to have one drawn; an id that was asked for
   --  is never replaced by another, and Refusal says why the run cannot go on
   --  when it could not be had.
   type Claiming is record
      Claimed : Id_Claims.Claim;
      Refusal : Unbounded_String;
   end record;

   function Claim_Id
     (Env : Environment; Settings : Configs.Config; Wanted : String)
      return Claiming
   is
      Work : constant Configs.Environment_Maps.Cursor :=
        Settings.Environment.Find (Configs.Work_Dir_Key);
   begin
      if not Configs.Environment_Maps.Has_Element (Work) then
         if Wanted /= "" then
            return
              (Claimed => <>,
               Refusal =>
                 To_Unbounded_String
                   ("--id needs a work directory; set "
                    & Configs.Work_Dir_Key));
         end if;
         return
           (Claimed =>
              (Id => To_Unbounded_String (Inspectors.New_Id),
               Registered => False),
            Refusal => Null_Unbounded_String);
      end if;
      Env.Registry.Open (Configs.Environment_Maps.Element (Work));
      if Wanted = "" then
         return
           (Claimed =>
              Id_Claims.Take (Env.Registry.all, Inspectors.New_Id'Access),
            Refusal => Null_Unbounded_String);
      end if;
      case Id_Claims.Take_Named (Env.Registry.all, Wanted) is
         when Id_Claims.Named_Claimed =>
            return
              (Claimed =>
                 (Id => To_Unbounded_String (Wanted), Registered => True),
               Refusal => Null_Unbounded_String);

         when Id_Claims.Named_Taken =>
            return
              (Claimed => <>,
               Refusal =>
                 To_Unbounded_String
                   ("execution " & Wanted & " already exists"));

         when Id_Claims.Named_Failed =>
            return
              (Claimed => <>,
               Refusal =>
                 To_Unbounded_String
                   ("the record of execution " & Wanted
                    & " could not be made"));
      end case;
   end Claim_Id;

   --  Runs the pipeline from its first step with Runner, and says how it
   --  ended. While it goes on, the run can be asked about from outside, where
   --  the transport can listen; whether it can never changes the run.
   function Run_Claimed
     (Env      : Environment;
      Pipeline : Resolved.Pipeline;
      Settings : Configs.Config;
      Input    : JSON.Value;
      Copies   : Definition_Copies.Copy_Vectors.Vector;
      Claimed  : Id_Claims.Claim;
      Runner   : in out Session_Runner.Runner'Class) return Exit_Code
   is
      Run     : States.State := States.Initial (Pipeline, Input);
      Context : aliased Contexts.Execution_Context;
      Id      : constant String := To_String (Claimed.Id);
      Recorder : aliased Recorders.Recorder
        (Context'Access, Env.Registry, Env.Clock);
      Recording : Recording_Runners.Recording_Runner
        (Runner'Access, Recorder'Access);

      --  The run itself: every step, with what happens recorded for whoever
      --  asks and a line for whoever is watching.
      procedure Go (Listening : Boolean; Reason : String) is
      begin
         if not Listening and then Reason /= "" then
            Complain
              (Env,
               "warning: introspection is unavailable: " & Reason & LF);
         end if;
         Recorder.Record_Event
           ("run.started", To_String (Run.Current_Step),
            JSON.Make_Object
              ([Member
                  ("pipeline",
                   JSON.Make_String (To_String (Pipeline.Name)))]));
         while not States.Is_Terminal (Run) loop
            declare
               Step : constant String := To_String (Run.Current_Step);
            begin
               Recorder.Record_Event ("step.started", Step, JSON.Null_Value);
               Run := Engine.Execute_Step (Pipeline, Run, Settings, Recording);
               Recorder.Publish (Run);
               if Run.Status = States.Failed then
                  Recorder.Record_Event
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
                  Recorder.Record_Event
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
                     Recorder.Record_Event
                       ("run.completed", Step, JSON.Null_Value);
                  end if;
               end if;
            end;
         end loop;
      end Go;

      Work : constant Configs.Environment_Maps.Cursor :=
        Settings.Environment.Find (Configs.Work_Dir_Key);
   begin
      Recording.Id := To_Unbounded_String (Id);
      Recorder.Start
        (Id, Claimed.Registered, Descriptions.Describe (Pipeline, Settings),
         Run);
      for Item of Copies loop
         Recorder.Record_Definition
           (To_String (Item.Path), To_String (Item.Content));
      end loop;
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
   end Run_Claimed;

   --  Takes the id of the run, and runs it, or says why it cannot.
   function Run_To_The_End
     (Env      : Environment;
      Pipeline : Resolved.Pipeline;
      Settings : Configs.Config;
      Input    : JSON.Value;
      Copies   : Definition_Copies.Copy_Vectors.Vector;
      Wanted   : String;
      Runner   : in out Session_Runner.Runner'Class) return Exit_Code
   is
      Taken : constant Claiming := Claim_Id (Env, Settings, Wanted);
   begin
      if Length (Taken.Refusal) > 0 then
         Complain (Env, "error: " & To_String (Taken.Refusal) & LF);
         return 1;
      end if;
      return Run_Claimed
        (Env, Pipeline, Settings, Input, Copies, Taken.Claimed, Runner);
   end Run_To_The_End;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Name       : Unbounded_String;
      Input_Path : Unbounded_String;
      Has_Input  : Boolean := False;
      Wanted_Id  : Unbounded_String;
      Has_Id     : Boolean := False;
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
            elsif Arg = "--id" then
               if Has_Id or else I = Args.Last_Index then
                  return Usage_Error (Env, Usage);
               end if;
               Has_Id := True;
               I := I + 1;
               Wanted_Id := Args (I);
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
      if Has_Id and then not Id_Claims.Is_Valid (To_String (Wanted_Id)) then
         Complain
           (Env,
            "error: --id must be 1 to 64 letters, digits, '_' or '-'" & LF);
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
               Loaded   : Boolean;
               Pipeline : Resolved.Pipeline;
               File     : Unbounded_String;
               Roots    : Search_Paths.Root_Vectors.Vector;
            begin
               Loading.Load (Env, Wanted, Loaded, Pipeline, File, Roots);
               if not Loaded then
                  return 1;
               end if;
               declare
                  Copies : constant Definition_Copies.Copy_Vectors.Vector :=
                    Definition_Copies.Collect
                      (Env.Files.all, Pipeline, To_String (File), Roots);
               begin
                  if Settings.Runner = Configs.Process_Runner then
                     declare
                        Runner : Process_Runners.Process_Runner
                          (Env.Sessions, Env.Files, Env.Registry);
                     begin
                        Runner.Skill_Roots := Roots;
                        return Run_To_The_End
                          (Env, Pipeline, Settings, Input, Copies,
                             To_String (Wanted_Id), Runner);
                     end;
                  end if;
                  declare
                     Script :
                       constant Scripted_Runners.Script_Results.Result :=
                       Scripted_Runners.Load
                         (Env.Files.all, To_String (Settings.Script));
                  begin
                     if not Scripted_Runners.Script_Results.Is_Success (Script)
                     then
                        Complain
                          (Env,
                           "error: "
                           & To_String
                               (Scripted_Runners.Script_Results.Error (Script))
                           & LF);
                        return 1;
                     end if;
                     declare
                        Runner : Scripted_Runners.Scripted_Runner :=
                          Scripted_Runners.Create
                            (Scripted_Runners.Script_Results.Value (Script));
                     begin
                        return Run_To_The_End
                          (Env, Pipeline, Settings, Input, Copies,
                             To_String (Wanted_Id), Runner);
                     end;
                  end;
               end;
            end;
         end;
      end;
   end Run;

end Synapse.Pipeline.Commands.Run;
