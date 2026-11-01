with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Run;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Next.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Done (Outcome, Summary : String) return String is
     ("{""outcome"":""" & Outcome & """,""summary"":""" & Summary
      & """,""data"":{}}");

   --  A development pipeline that loops from Review back to Develop, and
   --  another pipeline beside it.
   procedure Set_Up (F : in out Fixture) is
   begin
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_PATH", "/defs");
      F.Files.Add_File
        ("/defs/Dev.synapse",
         "Pipeline Dev {"
         & " Develop [Harness => Claude, Prompt => ""Implement.""];"
         & " Review [Harness => Codex, Prompt => ""Review.""];"
         & " Review -> Develop [When => Changes_Requested, "
         & "Max_Iterations => 3]; }");
      F.Files.Add_File
        ("/defs/Other.synapse",
         "Pipeline Other { Only [Harness => Claude, Prompt => ""Do.""]; }");
   end Set_Up;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Parsed (Text : String) return JSON.Value is
      Result : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Result.Ok, "standard output is one JSON document: " & Text);
      return Result.Item;
   end Parsed;

   --  The state `next` prints for the given state and result, as the text
   --  and the code. A fresh environment each time, as each call is a new
   --  process.
   procedure Advance_By
     (Pipeline : String; State, Result : String; Max_Steps : String;
      Printed  : out Ada.Strings.Unbounded.Unbounded_String;
      Code     : out Exit_Code)
   is
      F : aliased Fixture;
   begin
      Set_Up (F);
      if Max_Steps /= "" then
         F.Base.Vars.Set ("SYNAPSE_PIPELINE_MAX_STEPS", Max_Steps);
      end if;
      F.Files.Add_File ("/state.json", State);
      F.Files.Add_File ("/result.json", Result);
      Code :=
        Run
          (Env (F),
           Args (Pipeline, "--state", "/state.json", "--result",
                 "/result.json"));
      Printed :=
        Ada.Strings.Unbounded.To_Unbounded_String (F.Base.Console.Out_Text);
   end Advance_By;

   function Started return String is
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("Dev")) = 0, "a run starts: "
         & F.Base.Console.Err_Text);
      return F.Base.Console.Out_Text;
   end Started;

   procedure It_Takes_An_Input_Or_A_State_And_Result
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args) = 2, "none");
      Assert
        (Has (F.Base.Console.Err_Text, "usage: synapse-pipeline next "),
         "says how");
      Assert (Run (Env (F), Args ("Dev", "Other")) = 2, "two pipelines");
      Assert
        (Run (Env (F), Args ("Dev", "--state", "/s")) = 2,
         "a state with no result");
      Assert
        (Run (Env (F), Args ("Dev", "--result", "/r")) = 2,
         "a result with no state");
      Assert
        (Run (Env (F), Args ("Dev", "--input", "/i", "--state", "/s",
                             "--result", "/r")) = 2,
         "an input beside a state");
      Assert
        (Run (Env (F), Args ("Dev", "--state", "-", "--result", "-")) = 2,
         "both read from standard input");
      Assert (Run (Env (F), Args ("Dev", "--bogus")) = 2, "an option");
   end It_Takes_An_Input_Or_A_State_And_Result;

   procedure A_Run_Starts_At_The_First_Step_With_Its_Input
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File ("/in.json", "{""task"":""x""}");
      Assert
        (Run (Env (F), Args ("Dev", "--input", "/in.json")) = 0,
         "it starts: " & F.Base.Console.Err_Text);
      declare
         State : constant JSON.Value := Parsed (F.Base.Console.Out_Text);
      begin
         Assert
           (JSON.As_String (JSON.Member_Value (State, "format")) =
            "synapse-pipeline-state/v1"
            and then JSON.As_String (JSON.Member_Value (State, "status")) =
                     "running"
            and then JSON.As_String
                       (JSON.Member_Value (State, "current_step")) =
                     "Develop"
            and then JSON.As_String
                       (JSON.Member_Value
                          (JSON.Member_Value (State, "initial_input"),
                           "task")) = "x",
            "the first step, running, with the input: "
            & F.Base.Console.Out_Text);
      end;
   end A_Run_Starts_At_The_First_Step_With_Its_Input;

   procedure Going_Round_The_Loop_Ends_As_A_Run_Does
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      use Ada.Strings.Unbounded;
      Answers : constant array (1 .. 4) of Unbounded_String :=
        [To_Unbounded_String (Done ("Done", "first")),
         To_Unbounded_String (Done ("Changes_Requested", "two issues")),
         To_Unbounded_String (Done ("Done", "second")),
         To_Unbounded_String (Done ("Approved", "looks good"))];
      State   : Unbounded_String := To_Unbounded_String (Started);
      Printed : Unbounded_String;
      Code    : Exit_Code;
   begin
      for Answer of Answers loop
         Advance_By
           ("Dev", To_String (State), To_String (Answer), "", Printed, Code);
         Assert (Code = 0, "a step is advanced");
         State := Printed;
      end loop;
      declare
         Final : constant JSON.Value := Parsed (To_String (State));
      begin
         Assert
           (JSON.As_String (JSON.Member_Value (Final, "status")) = "completed"
            and then JSON.As_Integer
                       (JSON.Member_Value (Final, "steps_run")) = 4
            and then JSON.To_String (JSON.Member_Value (Final, "fired")) =
                     "[1]",
            "four steps, the loop edge fired once, and the run is over: "
            & To_String (State));
         declare
            F : aliased Fixture;
         begin
            Set_Up (F);
            F.Base.Vars.Set ("SYNAPSE_PIPELINE_RUNNER", "scripted");
            F.Base.Vars.Set ("SYNAPSE_PIPELINE_SCRIPT", "/answers.json");
            F.Files.Add_File
              ("/answers.json",
               "{""Develop"":[" & Done ("Done", "first") & ","
               & Done ("Done", "second") & "],""Review"":["
               & Done ("Changes_Requested", "two issues") & ","
               & Done ("Approved", "looks good") & "]}");
            Assert
              (Synapse.Pipeline.Commands.Run.Run (Env (F), Args ("Dev")) = 0,
               "the same answers through run complete");
            Assert
              (F.Base.Console.Out_Text =
               JSON.To_String (JSON.Member_Value (Final, "previous_output"))
               & LF,
               "run's result is the result in the state next ended with");
         end;
      end;
   end Going_Round_The_Loop_Ends_As_A_Run_Does;

   procedure Anything_It_Cannot_Use_Is_One_Error_And_No_Output
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      use Ada.Strings.Unbounded;
      Begun   : constant String := Started;
      Good    : constant String := Done ("Done", "x");
      Printed : Unbounded_String;
      Code    : Exit_Code;
   begin
      Advance_By ("Dev", Begun, "{""outcome"":""Done""}", "", Printed, Code);
      Assert
        (Code = 1 and then Length (Printed) = 0, "a result that is short");
      Advance_By ("Dev", Begun, "not json", "", Printed, Code);
      Assert (Code = 1 and then Length (Printed) = 0, "a result that is text");
      Advance_By ("Dev", "not json", Good, "", Printed, Code);
      Assert (Code = 1 and then Length (Printed) = 0, "a state that is text");
      Advance_By ("Other", Begun, Good, "", Printed, Code);
      Assert
        (Code = 1 and then Length (Printed) = 0,
         "a state of another pipeline");
      Advance_By ("Nothing_Like_It", Begun, Good, "", Printed, Code);
      Assert (Code = 1 and then Length (Printed) = 0, "a pipeline not found");
      declare
         Over : Unbounded_String;
      begin
         Advance_By ("Dev", Begun, Good, "", Over, Code);
         Advance_By
           ("Dev", To_String (Over), Done ("Approved", "z"), "", Printed,
            Code);
         Assert
           (Code = 0 and then Has (To_String (Printed), """completed"""),
            "two steps complete the run");
         Advance_By
           ("Dev", To_String (Printed), Good, "", Over, Code);
         Assert
           (Code = 1 and then Length (Over) = 0, "a run that is over");
      end;
   end Anything_It_Cannot_Use_Is_One_Error_And_No_Output;

   procedure A_Run_That_Reaches_The_Ceiling_Is_A_Failed_State
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      use Ada.Strings.Unbounded;
      State   : Unbounded_String := To_Unbounded_String (Started);
      Printed : Unbounded_String;
      Code    : Exit_Code;
   begin
      Advance_By
        ("Dev", To_String (State), Done ("Done", "a"), "2", Printed, Code);
      Assert
        (Code = 0
         and then Has (To_String (Printed), """status"":""running"""),
         "one step below the ceiling of two");
      Advance_By
        ("Dev", To_String (Printed), Done ("Changes_Requested", "b"), "2",
         State, Code);
      Assert (Code = 0, "a failed run is a state, not an error");
      declare
         Failed : constant JSON.Value := Parsed (To_String (State));
      begin
         Assert
           (JSON.As_String (JSON.Member_Value (Failed, "status")) = "failed"
            and then JSON.As_String
                       (JSON.Member_Value
                          (JSON.Member_Value (Failed, "failure"), "kind")) =
                     "ceiling_reached",
            "at the ceiling the run fails, as run's does: "
            & To_String (State));
      end;
   end A_Run_That_Reaches_The_Ceiling_Is_A_Failed_State;

   procedure Next_Is_In_The_Usage (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Has (Usage.Text, LF & "  next <pipeline>"), "listed");
   end Next_Is_In_The_Usage;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Next");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, It_Takes_An_Input_Or_A_State_And_Result'Access,
         "It takes a pipeline and either an input or a state and result");
      Register_Routine
        (T, A_Run_Starts_At_The_First_Step_With_Its_Input'Access,
         "A run starts at the first step with its input");
      Register_Routine
        (T, Going_Round_The_Loop_Ends_As_A_Run_Does'Access,
         "Going round the loop ends as a run does");
      Register_Routine
        (T, Anything_It_Cannot_Use_Is_One_Error_And_No_Output'Access,
         "Anything it cannot use is one error and no output");
      Register_Routine
        (T, A_Run_That_Reaches_The_Ceiling_Is_A_Failed_State'Access,
         "A run that reaches the ceiling is a failed state");
      Register_Routine
        (T, Next_Is_In_The_Usage'Access, "Next is in the usage");
   end Register_Tests;

end Synapse.Pipeline.Commands.Next.Tests;
