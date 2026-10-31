with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Info;
with Synapse.Pipeline.Commands.List;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Inspection;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.States;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Clients.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;
   use Ada.Strings.Unbounded;

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
   end Register_Tests;

end Synapse.Pipeline.Commands.Clients.Tests;
