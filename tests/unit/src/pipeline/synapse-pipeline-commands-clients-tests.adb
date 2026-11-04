with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Info;
with Synapse.Pipeline.Commands.List;
with Synapse.Pipeline.Fake_Registry;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Inspection;
with Synapse.Pipeline.Recorders;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.States;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Clients.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;
   use type States.Run_Status;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   --  A run of pipeline Name at its second step, one step behind it.
   function Run_Of (Id, Name : String) return Inspection.Snapshot is
      Pipeline : Resolved.Pipeline;
      Result   : Inspection.Snapshot;
      Input    : constant JSON.Parse_Result := JSON.Parse ("{""task"":""x""}");

      procedure Add_Step (Step : String) is
      begin
         Pipeline.Steps.Append
           (Resolved.Step'
              (Name    => To_Unbounded_String (Step),
               Harness => Harnesses.Claude, others => <>));
      end Add_Step;
   begin
      Pipeline.Name := To_Unbounded_String (Name);
      Add_Step ("A");
      Add_Step ("B");
      Result.Execution_Id := To_Unbounded_String (Id);
      Result.Run := States.Initial (Pipeline, Input.Item);
      Result.Run.Current_Step := To_Unbounded_String ("B");
      Result.Run.Steps_Run := 1;
      return Result;
   end Run_Of;

   procedure Listen (F : in out Fixture) is
   begin
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      F.Inspector.Runs.Include ("exec-2", Run_Of ("exec-2", "Release"));
      F.Inspector.Runs.Include ("exec-1", Run_Of ("exec-1", "Dev"));
   end Listen;

   procedure A_Live_Run_Is_Listed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Listen (F);
      Assert (List.Run (Env (F), Args) = 0, "it succeeds");
      Assert
        (F.Base.Console.Out_Text =
         "EXECUTION  PIPELINE  STATUS   STEP" & LF
         & "exec-1     Dev       running  B" & LF
         & "exec-2     Release   running  B" & LF,
         "each run, in order, with its step: " & F.Base.Console.Out_Text);
   end A_Live_Run_Is_Listed;

   procedure A_Stale_Endpoint_Is_Not_A_Run (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Listen (F);
      F.Inspector.Stale.Include ("exec-0");
      Assert (List.Run (Env (F), Args) = 0, "it succeeds");
      Assert
        (not Has (F.Base.Console.Out_Text, "exec-0")
         and then Has (F.Base.Console.Out_Text, "exec-1"),
         "the file nobody listens at is left out: "
         & F.Base.Console.Out_Text);
   end A_Stale_Endpoint_Is_Not_A_Run;

   procedure With_No_Runs_There_Is_Nothing_To_Print
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert (List.Run (Env (F), Args) = 0, "it succeeds");
      Assert
        (F.Base.Console.Out_Text = "" and then F.Base.Console.Err_Text = "",
         "and says nothing");
   end With_No_Runs_There_Is_Nothing_To_Print;

   procedure Without_A_Work_Directory_There_Is_Nowhere_To_Look
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (List.Run (Env (F), Args) = 1, "list fails");
      Assert
        (Has (F.Base.Console.Err_Text, "no work directory")
         and then F.Base.Console.Out_Text = "",
         "and says why: " & F.Base.Console.Err_Text);
      Assert (Info.Run (Env (F), Args ("exec-1")) = 1, "info fails");
   end Without_A_Work_Directory_There_Is_Nowhere_To_Look;

   --  Keeps the record of execution Id of pipeline Name in State's status:
   --  its directory, its summary and, when Events is not empty, its events.
   procedure Keep
     (F      : in out Fixture;
      Id     : String;
      Status : States.Run_Status;
      Events : String := "")
   is
      Item  : States.State := Run_Of (Id, "Dev").Run;
      Wrote : Boolean;
      Made  : constant Registry_Store.Create_Result := F.Registry.Create (Id);
      pragma Unreferenced (Made);
      Closed : constant Boolean := Status /= States.Running;
   begin
      Item.Status := Status;
      if Closed then
         Item.Current_Step := Null_Unbounded_String;
      end if;
      Wrote :=
        F.Registry.Replace_Summary
          (Id,
           JSON.To_String
             (Recorders.Summary
                (Id, "2026-11-04T10:00:00+00:00",
                 (if Closed then "2026-11-04T10:05:00+00:00" else ""), Item)));
      if Events /= "" then
         Wrote := F.Registry.Append_Event (Id, Events);
      end if;
      pragma Unreferenced (Wrote);
   end Keep;

   procedure List_All_Adds_What_Is_Recorded (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Listen (F);
      Keep (F, "exec-1", States.Running);
      Keep (F, "exec-0", States.Completed);
      Keep (F, "exec-3", States.Failed);
      Keep (F, "exec-4", States.Running);
      Assert (F.Registry.Create ("exec-5") = Registry_Store.Created, "made");
      Assert (List.Run (Env (F), Args ("--all")) = 0, "it succeeds");
      Assert
        (F.Base.Console.Out_Text =
         "EXECUTION  PIPELINE  STATUS       STEP" & LF
         & "exec-0     Dev       completed    " & LF
         & "exec-1     Dev       running      B" & LF
         & "exec-2     Release   running      B" & LF
         & "exec-3     Dev       failed       " & LF
         & "exec-4     Dev       interrupted  B" & LF
         & "exec-5               incomplete   " & LF,
         "live and recorded, each with the status it has: "
         & F.Base.Console.Out_Text);
   end List_All_Adds_What_Is_Recorded;

   procedure List_Without_All_Is_Still_Only_What_Is_Live
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Listen (F);
      Keep (F, "exec-0", States.Completed);
      Assert (List.Run (Env (F), Args) = 0, "it succeeds");
      Assert
        (not Has (F.Base.Console.Out_Text, "exec-0"),
         "a record is not a run in progress");
      Assert
        (List.Run (Env (F), Args ("--everything")) = 2
         and then List.Run (Env (F), Args ("--all", "--all")) = 2,
         "and what list does not know is a usage error");
   end List_Without_All_Is_Still_Only_What_Is_Live;

   procedure An_Execution_That_Is_Over_Is_Described_From_Its_Record
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Keep (F, "exec-0", States.Completed);
      Assert (Info.Run (Env (F), Args ("exec-0")) = 0, "it succeeds");
      Assert
        (Has (F.Base.Console.Out_Text, "pipeline   Dev")
         and then Has (F.Base.Console.Out_Text, "status     completed")
         and then Has (F.Base.Console.Out_Text, "steps run  1"),
         "as a run in progress is: " & F.Base.Console.Out_Text);
      F.Base.Console.Clear;
      Keep (F, "exec-1", States.Running);
      Assert
        (Info.Run (Env (F), Args ("exec-1", "--format", "json")) = 0
         and then Has (F.Base.Console.Out_Text, """status"":""interrupted"""),
         "a record that says running, with nothing listening, is "
         & "interrupted: " & F.Base.Console.Out_Text);
      F.Base.Console.Clear;
      Assert
        (Info.Run (Env (F), Args ("exec-0", "--query", "{""var"":""status""}"))
         = 1
         and then Has
                    (F.Base.Console.Err_Text, "needs a run that is listening"),
         "a query needs a run to ask: " & F.Base.Console.Err_Text);
      F.Base.Console.Clear;
      Assert
        (Info.Run (Env (F), Args ("exec-9")) = 1
         and then Has (F.Base.Console.Err_Text, "no run named 'exec-9'"),
         "and an execution that is not recorded is not found");
   end An_Execution_That_Is_Over_Is_Described_From_Its_Record;

   procedure Events_Are_Read_From_The_Record (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Keep (F, "exec-0", States.Completed, "{""sequence"":1}");
      Assert
        (F.Registry.Append_Event ("exec-0", "{""sequence"":2}"), "appended");
      Assert (Info.Run (Env (F), Args ("exec-0", "--events")) = 0, "it works");
      Assert
        (F.Base.Console.Out_Text = "{""sequence"":1}" & LF
         & "{""sequence"":2}" & LF,
         "one event a line, as they were recorded: "
         & F.Base.Console.Out_Text);
      F.Base.Console.Clear;
      Keep (F, "exec-1", States.Completed);
      Assert
        (Info.Run (Env (F), Args ("exec-1", "--events")) = 1
         and then Has (F.Base.Console.Err_Text, "no events are recorded"),
         "an execution with none says so");
      Assert
        (Info.Run (Env (F), Args ("exec-0", "--events", "--query", "{}")) = 2
         and then Info.Run
                    (Env (F), Args ("exec-0", "--events", "--format", "json"))
                  = 2,
         "and --events takes neither a query nor a format");
   end Events_Are_Read_From_The_Record;

   procedure A_Run_Is_Described (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Listen (F);
      Assert (Info.Run (Env (F), Args ("exec-1")) = 0, "it succeeds");
      Assert
        (F.Base.Console.Out_Text =
         "execution  exec-1" & LF & "pipeline   Dev" & LF
         & "status     running" & LF & "step       B" & LF
         & "steps run  1" & LF,
         "for a person: " & F.Base.Console.Out_Text);
   end A_Run_Is_Described;

   procedure A_Program_Can_Ask_For_Json (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Listen (F);
      Assert
        (Info.Run (Env (F), Args ("exec-1", "--format", "json")) = 0,
         "it succeeds");
      Assert
        (Has (F.Base.Console.Out_Text, """pipeline"":""Dev""")
         and then Has (F.Base.Console.Out_Text, """steps_run"":1")
         and then not Has (F.Base.Console.Out_Text, """ok"""),
         "the result is the whole answer: " & F.Base.Console.Out_Text);
   end A_Program_Can_Ask_For_Json;

   procedure A_Query_Is_Answered_By_The_Run (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Text, Json_Form, Number : aliased Fixture;
   begin
      Listen (Text);
      Listen (Json_Form);
      Listen (Number);
      Assert
        (Info.Run
           (Env (Text),
            Args ("exec-1", "--query", "{""var"":""current_step""}")) = 0,
         "a text query succeeds");
      Assert
        (Text.Base.Console.Out_Text = "B" & LF,
         "a string is printed as it is: " & Text.Base.Console.Out_Text);
      Assert
        (Info.Run
           (Env (Json_Form),
            Args ("exec-1", "--query", "{""var"":""current_step""}",
                  "--format", "json")) = 0,
         "a json query succeeds");
      Assert
        (Json_Form.Base.Console.Out_Text = """B""" & LF,
         "or as JSON when asked: " & Json_Form.Base.Console.Out_Text);
      Assert
        (Info.Run
           (Env (Number),
            Args
              ("exec-2", "--query",
               "{""=="":[{""var"":""steps_run""},1]}")) = 0,
         "a comparing query succeeds");
      Assert
        (Number.Base.Console.Out_Text = "true" & LF,
         "a boolean is printed as one: " & Number.Base.Console.Out_Text);
   end A_Query_Is_Answered_By_The_Run;

   procedure A_Run_That_Is_Not_There_Is_Said_To_Be_Missing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Listen (F);
      Assert (Info.Run (Env (F), Args ("exec-9")) = 1, "it fails");
      Assert
        (Has (F.Base.Console.Err_Text, "no run named 'exec-9' is listening")
         and then F.Base.Console.Out_Text = "",
         "and says which: " & F.Base.Console.Err_Text);
   end A_Run_That_Is_Not_There_Is_Said_To_Be_Missing;

   procedure A_Run_Refusing_The_Question_Is_Reported
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Listen (F);
      Assert
        (Info.Run (Env (F), Args ("exec-1", "--query", "{""nope"":[1]}")) = 1,
         "it fails");
      Assert
        (Has (F.Base.Console.Err_Text, "error: ")
         and then F.Base.Console.Out_Text = "",
         "with what the run said: " & F.Base.Console.Err_Text);
   end A_Run_Refusing_The_Question_Is_Reported;

   procedure The_Arguments_Are_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      procedure Refused (Label : String; Call : Exit_Code) is
      begin
         Assert (Call = 2, Label & " is a usage error");
      end Refused;

      F : aliased Fixture;
   begin
      Listen (F);
      Refused ("list with an argument", List.Run (Env (F), Args ("x")));
      Refused ("info with nothing", Info.Run (Env (F), Args));
      Refused
        ("info with two ids", Info.Run (Env (F), Args ("exec-1", "exec-2")));
      Refused
        ("info with an unknown format",
         Info.Run (Env (F), Args ("exec-1", "--format", "xml")));
      Refused
        ("info with a format and no value",
         Info.Run (Env (F), Args ("exec-1", "--format")));
      Refused
        ("info with an unknown option",
         Info.Run (Env (F), Args ("exec-1", "--verbose")));
      Refused
        ("info with the same option twice",
         Info.Run
           (Env (F), Args ("exec-1", "--format", "json", "--format", "text")));
      Assert
        (Info.Run (Env (F), Args ("exec-1", "--query", "not json")) = 1,
         "a query that is not JSON is an error, not a usage error");
   end The_Arguments_Are_Checked;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Clients");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Live_Run_Is_Listed'Access, "A live run is listed");
      Register_Routine
        (T, A_Stale_Endpoint_Is_Not_A_Run'Access,
         "A stale endpoint is not a run");
      Register_Routine
        (T, With_No_Runs_There_Is_Nothing_To_Print'Access,
         "With no runs there is nothing to print");
      Register_Routine
        (T, Without_A_Work_Directory_There_Is_Nowhere_To_Look'Access,
         "Without a work directory there is nowhere to look");
      Register_Routine (T, A_Run_Is_Described'Access, "A run is described");
      Register_Routine
        (T, A_Program_Can_Ask_For_Json'Access, "A program can ask for JSON");
      Register_Routine
        (T, A_Query_Is_Answered_By_The_Run'Access,
         "A query is answered by the run");
      Register_Routine
        (T, A_Run_That_Is_Not_There_Is_Said_To_Be_Missing'Access,
         "A run that is not there is said to be missing");
      Register_Routine
        (T, A_Run_Refusing_The_Question_Is_Reported'Access,
         "A run refusing the question is reported");
      Register_Routine
        (T, The_Arguments_Are_Checked'Access, "The arguments are checked");
      Register_Routine
        (T, List_All_Adds_What_Is_Recorded'Access,
         "list --all adds what is recorded");
      Register_Routine
        (T, List_Without_All_Is_Still_Only_What_Is_Live'Access,
         "list without --all is still only what is live");
      Register_Routine
        (T, An_Execution_That_Is_Over_Is_Described_From_Its_Record'Access,
         "An execution that is over is described from its record");
      Register_Routine
        (T, Events_Are_Read_From_The_Record'Access,
         "Events are read from the record");
   end Register_Tests;

end Synapse.Pipeline.Commands.Clients.Tests;
