with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Run.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Done (Outcome, Summary : String) return String is
     ("{""outcome"":""" & Outcome & """,""summary"":""" & Summary
      & """,""data"":{}}");

   --  A development pipeline, and a script that goes round it once.
   procedure Set_Up (F : in out Fixture; Script : String) is
   begin
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_PATH", "/defs");
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_RUNNER", "scripted");
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_SCRIPT", "/answers.json");
      F.Files.Add_File
        ("/defs/Dev.synapse",
         "Pipeline Dev {"
         & " Develop [Harness => Claude, Prompt => ""Implement.""];"
         & " Review [Harness => Codex, Prompt => ""Review.""];"
         & " Review -> Develop [When => Changes_Requested, "
         & "Max_Iterations => 3]; }");
      F.Files.Add_File ("/answers.json", Script);
   end Set_Up;

   Round_Once : constant String :=
     "{""Develop"":[" & Done ("Done", "first") & "," & Done ("Done", "second")
     & "],""Review"":[" & Done ("Changes_Requested", "two issues") & ","
     & Done ("Approved", "looks good") & "]}";

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Progress_Lines (Text : String) return Natural is
      Count : Natural := 0;
   begin
      for C of Text loop
         if C = Character'Val (10) then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Progress_Lines;

   LF : constant Character := Character'Val (10);

   procedure A_Pipeline_Is_Run_To_Its_End (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      Assert (Run (Env (F), Args ("Dev")) = 0, "it completes");
      Assert
        (F.Base.Console.Out_Text =
         "{""outcome"":""Approved"",""summary"":""looks good"",""data"":{}}"
         & LF,
         "the last step's result is the output: " & F.Base.Console.Out_Text);
      Assert
        (F.Base.Console.Err_Text =
         "step Develop: Done -> Review" & LF
         & "step Review: Changes_Requested -> Develop" & LF
         & "step Develop: Done -> Review" & LF
         & "step Review: Approved -> done" & LF,
         "one line a step, going round the loop once: "
         & F.Base.Console.Err_Text);
   end A_Pipeline_Is_Run_To_Its_End;

   procedure A_Failed_Run_Says_Where_And_Why (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up
        (F,
         "{""Develop"":[" & Done ("Done", "ok") & "],""Review"":["
         & "{""fail"":""quota_exhausted"",""message"":""limit reached"","
         & """reset"":""09:00""}]}");
      Assert (Run (Env (F), Args ("Dev")) = 1, "it fails");
      Assert (F.Base.Console.Out_Text = "", "with nothing on standard output");
      Assert
        (Has (F.Base.Console.Err_Text, "step Develop: Done -> Review" & LF)
         and then Has
                    (F.Base.Console.Err_Text,
                     "error: step Review failed: quota_exhausted: limit "
                     & "reached (resets at 09:00)"),
         "the step that finished, then why the next failed: "
         & F.Base.Console.Err_Text);
   end A_Failed_Run_Says_Where_And_Why;

   procedure A_Script_That_Runs_Out_Fails_The_Run (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up
        (F,
         "{""Develop"":[" & Done ("Done", "ok") & "],""Review"":["
         & Done ("Changes_Requested", "again") & "]}");
      Assert (Run (Env (F), Args ("Dev")) = 1, "it fails");
      Assert
        (Has
           (F.Base.Console.Err_Text,
            "error: step Develop failed: execution_error: the script has no "
            & "more answers for step 'Develop'"),
         "going back to Develop finds its answers used up: "
         & F.Base.Console.Err_Text);
   end A_Script_That_Runs_Out_Fails_The_Run;

   procedure A_Pipeline_That_Cannot_Run_Is_Refused_Before_Any_Session
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Files.Add_File
        ("/defs/Bad.synapse",
         "Pipeline Bad { A [Harness => Claude, Colour => Red]; }");
      Assert (Run (Env (F), Args ("Bad")) = 1, "refused");
      Assert
        (Has (F.Base.Console.Err_Text, "unknown attribute 'Colour'")
         and then Has (F.Base.Console.Err_Text, "no instructions")
         and then not Has (F.Base.Console.Err_Text, "step A:")
         and then F.Base.Console.Out_Text = "",
         "every problem, and no step run: " & F.Base.Console.Err_Text);
      Assert (Run (Env (F), Args ("Nope")) = 1, "an unknown pipeline");
   end A_Pipeline_That_Cannot_Run_Is_Refused_Before_Any_Session;

   procedure A_Broken_Definition_Elsewhere_Is_Only_A_Warning
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Files.Add_File ("/defs/Broken.synapse", "Agent Broken [Prompt => ];");
      Assert (Run (Env (F), Args ("Dev")) = 0, "the run goes ahead");
      Assert
        (Has
           (F.Base.Console.Err_Text,
            "warning: /defs/Broken.synapse:1:25: expected a value"),
         "and the warning is given");
   end A_Broken_Definition_Elsewhere_Is_Only_A_Warning;

   procedure The_Runner_Must_Be_Available (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_RUNNER", "process");
      Assert (Run (Env (F), Args ("Dev")) = 1, "no harness answers");
      Assert
        (Natural (F.Sessions.Requests.Length) = 1
         and then To_String (F.Sessions.Requests (1).Program) = "claude"
         and then Has (F.Base.Console.Err_Text, "cannot run Claude"),
         "the first step was started as its harness: "
         & F.Base.Console.Err_Text);
      F.Base.Console.Clear;
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_RUNNER", "scripted");
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_SCRIPT", "/missing.json");
      Assert (Run (Env (F), Args ("Dev")) = 1, "a script that is not there");
      Assert
        (Has
           (F.Base.Console.Err_Text,
            "script /missing.json cannot be read"),
         "is named");
      F.Base.Console.Clear;
      F.Files.Add_File ("/bad.json", "{""Develop"": 3}");
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_SCRIPT", "/bad.json");
      Assert (Run (Env (F), Args ("Dev")) = 1, "a script that is wrong");
      Assert
        (Has
           (F.Base.Console.Err_Text,
            "script.Develop: expected a list of answers"),
         "says where");
   end The_Runner_Must_Be_Available;

   procedure A_Setting_That_Is_Wrong_Stops_The_Run_At_Once
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_TIMEOUT", "soon");
      Assert (Run (Env (F), Args ("Dev")) = 1, "it stops");
      Assert
        (Has (F.Base.Console.Err_Text, "SYNAPSE_PIPELINE_TIMEOUT is 'soon'")
         and then Progress_Lines (F.Base.Console.Err_Text) = 1,
         "with only that said: " & F.Base.Console.Err_Text);
   end A_Setting_That_Is_Wrong_Stops_The_Run_At_Once;

   procedure The_Input_Is_Read_From_A_File_Or_Standard_Input
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Files.Add_File ("/in.json", "{""task"": ""x""}");
      Assert
        (Run (Env (F), Args ("Dev", "--input", "/in.json")) = 0,
         "from a file");
      Assert
        (Run (Env (F), Args ("--input", "/in.json", "Dev")) = 0,
         "the option may come first");
      declare
         G : aliased Fixture;
      begin
         Set_Up (G, Round_Once);
         G.Base.Console.Set_Stdin ("{""task"": ""y""}");
         Assert
           (Run (Env (G), Args ("Dev", "--input", "-")) = 0,
            "from standard input");
      end;
      F.Base.Console.Clear;
      Assert
        (Run (Env (F), Args ("Dev", "--input", "/nope.json")) = 1
         and then Has
                    (F.Base.Console.Err_Text,
                     "--input /nope.json cannot be read"),
         "a file that is not there");
      F.Base.Console.Clear;
      F.Files.Add_File ("/junk.json", "{""task"":");
      Assert
        (Run (Env (F), Args ("Dev", "--input", "/junk.json")) = 1
         and then Has (F.Base.Console.Err_Text, "is not JSON"),
         "a file that is not JSON");
   end The_Input_Is_Read_From_A_File_Or_Standard_Input;

   procedure A_Run_Is_Offered_To_Introspection (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert (Run (Env (F), Args ("Dev")) = 0, "it completes");
      Assert
        (Has (To_String (F.Inspector.Endpoint), "/work/pipelines/exec-")
         and then Has (To_String (F.Inspector.Endpoint), ".fake"),
         "it listened where the transport puts a run: "
         & To_String (F.Inspector.Endpoint));
      Assert (F.Inspector.Closed, "and stopped when the run was done");
      Assert
        (F.Base.Console.Err_Text =
         "step Develop: Done -> Review" & LF
         & "step Review: Changes_Requested -> Develop" & LF
         & "step Develop: Done -> Review" & LF
         & "step Review: Approved -> done" & LF,
         "with the run's output as it always is");
   end A_Run_Is_Offered_To_Introspection;

   procedure Without_A_Work_Directory_There_Is_Nowhere_To_Listen
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      Assert (Run (Env (F), Args ("Dev")) = 0, "it completes");
      Assert
        (Length (F.Inspector.Endpoint) = 0 and then not F.Inspector.Closed,
         "nothing was listened on");
   end Without_A_Work_Directory_There_Is_Nowhere_To_Listen;

   procedure Introspection_That_Fails_Leaves_The_Run_As_It_Was
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Plain : aliased Fixture;
      Cannot : aliased Fixture;
      Crashes : aliased Fixture;
   begin
      Set_Up (Plain, Round_Once);
      Set_Up (Cannot, Round_Once);
      Set_Up (Crashes, Round_Once);
      Plain.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Cannot.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Crashes.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Cannot.Inspector.Refuse := True;
      Crashes.Inspector.Crash := True;
      Assert (Run (Env (Plain), Args ("Dev")) = 0, "with an inspector");
      Assert (Run (Env (Cannot), Args ("Dev")) = 0, "one that cannot listen");
      Assert (Run (Env (Crashes), Args ("Dev")) = 0, "one that crashes");
      Assert
        (Cannot.Base.Console.Out_Text = Plain.Base.Console.Out_Text
         and then Crashes.Base.Console.Out_Text = Plain.Base.Console.Out_Text,
         "the result is the same in all three");
      Assert
        (Has
           (Cannot.Base.Console.Err_Text,
            "warning: introspection is unavailable: the fake refuses")
         and then Crashes.Base.Console.Err_Text = Plain.Base.Console.Err_Text,
         "and only a place that cannot be had is said to be so: "
         & Cannot.Base.Console.Err_Text);
   end Introspection_That_Fails_Leaves_The_Run_As_It_Was;

   procedure The_Arguments_Are_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      Assert (Run (Env (F), Args) = 2, "no pipeline");
      Assert
        (F.Base.Console.Err_Text =
         "usage: synapse-pipeline run <pipeline> [--input <file>|-]" & LF,
         "says how");
      Assert (Run (Env (F), Args ("A", "B")) = 2, "two pipelines");
      Assert (Run (Env (F), Args ("Dev", "--input")) = 2, "--input alone");
      Assert
        (Run (Env (F), Args ("Dev", "--input", "a", "--input", "b")) = 2,
         "--input twice");
      Assert (Run (Env (F), Args ("Dev", "--quiet")) = 2, "another option");
   end The_Arguments_Are_Checked;

   procedure A_Gate_Can_End_The_Run_Early (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, "{""Check"":[" & Done ("Discussing", "not yet") & "]}");
      F.Files.Add_File
        ("/defs/Gate.synapse",
         "Pipeline Gate {"
         & " Check [Harness => Claude, Prompt => ""Is it ready?""];"
         & " Build [Harness => Claude, Prompt => ""Build it.""];"
         & " Check -> End [When => Discussing]; }");
      Assert (Run (Env (F), Args ("Gate")) = 0, "ending early is a success");
      Assert
        (F.Base.Console.Out_Text =
         "{""outcome"":""Discussing"",""summary"":""not yet"",""data"":{}}"
         & LF,
         "the result of the step that ended it: " & F.Base.Console.Out_Text);
      Assert
        (F.Base.Console.Err_Text = "step Check: Discussing -> done" & LF,
         "one line, and Build never ran: " & F.Base.Console.Err_Text);
   end A_Gate_Can_End_The_Run_Early;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Run");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Pipeline_Is_Run_To_Its_End'Access,
         "A pipeline is run to its end");
      Register_Routine
        (T, A_Failed_Run_Says_Where_And_Why'Access,
         "A failed run says where and why");
      Register_Routine
        (T, A_Script_That_Runs_Out_Fails_The_Run'Access,
         "A script that runs out fails the run");
      Register_Routine
        (T, A_Pipeline_That_Cannot_Run_Is_Refused_Before_Any_Session'Access,
         "A pipeline that cannot run is refused before any session");
      Register_Routine
        (T, A_Broken_Definition_Elsewhere_Is_Only_A_Warning'Access,
         "A broken definition elsewhere is only a warning");
      Register_Routine
        (T, The_Runner_Must_Be_Available'Access,
         "The runner must be available");
      Register_Routine
        (T, A_Setting_That_Is_Wrong_Stops_The_Run_At_Once'Access,
         "A setting that is wrong stops the run at once");
      Register_Routine
        (T, The_Input_Is_Read_From_A_File_Or_Standard_Input'Access,
         "The input is read from a file or standard input");
      Register_Routine
        (T, A_Run_Is_Offered_To_Introspection'Access,
         "A run is offered to introspection");
      Register_Routine
        (T, Without_A_Work_Directory_There_Is_Nowhere_To_Listen'Access,
         "Without a work directory there is nowhere to listen");
      Register_Routine
        (T, Introspection_That_Fails_Leaves_The_Run_As_It_Was'Access,
         "Introspection that fails leaves the run as it was");
      Register_Routine
        (T, The_Arguments_Are_Checked'Access, "The arguments are checked");
      Register_Routine
        (T, A_Gate_Can_End_The_Run_Early'Access,
         "A gate can end the run early");
   end Register_Tests;

end Synapse.Pipeline.Commands.Run.Tests;
