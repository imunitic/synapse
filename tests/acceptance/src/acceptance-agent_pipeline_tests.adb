with Ada.Calendar;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Acceptance.Fixtures;

package body Acceptance.Agent_Pipeline_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Out_Of (R : Result) return String is (To_String (R.Output));

   function Err_Of (R : Result) return String is (To_String (R.Errors));

   ---------------------------------------------------------------------------
   --  A scratch tree to run in
   ---------------------------------------------------------------------------

   procedure Set_Up (F : in out Fixture) is
   begin
      Unset_Env (F, "SYNAPSE_PIPELINE_HARNESS");
      Unset_Env (F, "SYNAPSE_PIPELINE_TIMEOUT");
      Unset_Env (F, "SYNAPSE_PIPELINE_MAX_STEPS");
      Unset_Env (F, "SYNAPSE_PIPELINE_RUNNER");
      Unset_Env (F, "SYNAPSE_PIPELINE_SCRIPT");
      Set_Env (F, "SYNAPSE_PIPELINE_PATH", Root (F) & "/defs");
      Set_Env (F, "SYNAPSE_WORK_DIR", Work (F));
   end Set_Up;

   procedure Define (F : Fixture; Name, Text : String) is
   begin
      Write_File (Root (F) & "/defs/" & Name & ".synapse", Text);
   end Define;

   --  A development pipeline whose review can send work back.
   procedure Define_Dev (F : Fixture) is
   begin
      Define
        (F, "Dev",
         "Pipeline Dev {" & LF
         & "   Develop [Harness => Claude, Prompt => ""Implement the "
         & "feature.""];" & LF
         & "   Review  [Harness => Claude, Prompt => ""Review it.""];" & LF
         & "   Review -> Develop [When => Changes_Requested, "
         & "Max_Iterations => 3];" & LF & "}" & LF);
   end Define_Dev;

   procedure Use_Script (F : in out Fixture; Text : String) is
   begin
      Write_File (Root (F) & "/answers.json", Text);
      Set_Env (F, "SYNAPSE_PIPELINE_RUNNER", "scripted");
      Set_Env (F, "SYNAPSE_PIPELINE_SCRIPT", Root (F) & "/answers.json");
   end Use_Script;

   function Answer
     (Outcome, Summary : String; Delay_Seconds : String := "") return String is
     ("{""outcome"":""" & Outcome & """,""summary"":""" & Summary
      & """,""data"":{}"
      & (if Delay_Seconds = "" then ""
         else ",""delay_seconds"":" & Delay_Seconds) & "}");

   Review_Loop : constant String :=
     "{""Develop"":[" & Answer ("Done", "first") & ","
     & Answer ("Done", "second") & "],""Review"":["
     & Answer ("Changes_Requested", "two issues") & ","
     & Answer ("Approved", "looks good") & "]}";

   --  A `claude` that answers as the real one prints, ahead of any other on
   --  PATH, with Body as the rest of its script after the prompt is read.
   procedure Install_Claude (F : in out Fixture; Script_Body : String) is
      Path : constant String := Root (F) & "/bin/claude";
   begin
      Write_File
        (Path,
         "#!/bin/sh" & LF & "prompt=$(cat)" & LF & Script_Body & LF);
      Make_Executable (Path);
      Set_Env (F, "PATH", Root (F) & "/bin:/usr/bin:/bin");
   end Install_Claude;

   Says_Done : constant String :=
     "printf '%s' '{""is_error"":false,""structured_output"":"
     & "{""outcome"":""Done"",""summary"":""did it"",""data"":{}},"
     & """usage"":{""input_tokens"":1,""output_tokens"":1}}'";

   ---------------------------------------------------------------------------
   --  check
   ---------------------------------------------------------------------------

   procedure Check_Shows_What_A_Pipeline_Would_Run
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Define
        (F, "Tester",
         "Agent Tester [Prompt => ""You are a tester.""];" & LF);
      Define
        (F, "Careful",
         "System Careful [Harness => Codex, Permissions => Read_Only];" & LF);
      Define
        (F, "Gate",
         "Pipeline Gate {" & LF
         & "   Test [Agent => Tester, System => Careful, Prompt => ""Test "
         & "it.""];" & LF & "}" & LF);
      declare
         R : constant Result := Run_Pipeline (F, "check", "Gate");
      begin
         Assert_Exit (R, 0, "check");
         Assert_Contains
           (Out_Of (R), "pipeline Gate  " & Root (F) & "/defs/Gate.synapse",
            "the pipeline and its file");
         Assert_Contains
           (Out_Of (R), "step Test  harness Codex", "the harness");
         Assert_Contains
           (Out_Of (R), Root (F) & "/defs/Careful.synapse",
            "where the system came from");
         Assert_Contains
           (Out_Of (R), Root (F) & "/defs/Tester.synapse",
            "where the agent came from");
      end;
   end Check_Shows_What_A_Pipeline_Would_Run;

   procedure Check_Reports_Every_Problem_Where_It_Is
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Define
        (F, "Bad",
         "Pipeline Bad {" & LF
         & "   One [Harness => Claude, Permissions => Anything, "
         & "Prompt => ""x""];" & LF
         & "   One -> Nowhere;" & LF & "}" & LF);
      declare
         R : constant Result := Run_Pipeline (F, "check", "Bad");
      begin
         Assert_Exit (R, 1, "check");
         Assert_Contains
           (Err_Of (R), Root (F) & "/defs/Bad.synapse:2:",
            "the first problem has its file and line");
         Assert_Contains
           (Err_Of (R), "'Anything' is not a permission level",
            "and says what is wrong");
         Assert_Contains
           (Err_Of (R), "Nowhere", "the second problem is reported too");
         Assert_Equal (Out_Of (R), "", "nothing is printed as if all is well");
      end;
   end Check_Reports_Every_Problem_Where_It_Is;

   ---------------------------------------------------------------------------
   --  run, from a script
   ---------------------------------------------------------------------------

   procedure A_Scripted_Run_Follows_Its_Guards (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Define_Dev (F);
      Use_Script (F, Review_Loop);
      declare
         R : constant Result := Run_Pipeline (F, "run", "Dev");
      begin
         Assert_Exit (R, 0, "run");
         Assert_Equal
           (Err_Of (R),
            "step Develop: Done -> Review" & LF
            & "step Review: Changes_Requested -> Develop" & LF
            & "step Develop: Done -> Review" & LF
            & "step Review: Approved -> done" & LF,
            "a line for each step, on standard error");
         Assert_Equal
           (Out_Of (R),
            "{""outcome"":""Approved"",""summary"":""looks good"","
            & """data"":{}}" & LF,
            "the last result, on standard output");
      end;
   end A_Scripted_Run_Follows_Its_Guards;

   procedure A_Step_That_Fails_Stops_The_Run (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Define_Dev (F);
      Use_Script
        (F, "{""Develop"":[" & Answer ("Done", "first") & "],""Review"":[]}");
      declare
         R : constant Result := Run_Pipeline (F, "run", "Dev");
      begin
         Assert_Exit (R, 1, "run");
         Assert_Contains
           (Err_Of (R), "error: step Review failed: execution_error:",
            "the step and the kind of failure");
         Assert_Equal (Out_Of (R), "", "no result is printed");
      end;
   end A_Step_That_Fails_Stops_The_Run;

   procedure A_Pipeline_That_Cannot_Run_Starts_No_Session
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Use_Script (F, Review_Loop);
      declare
         R : constant Result := Run_Pipeline (F, "run", "Missing");
      begin
         Assert_Exit (R, 1, "run");
         Assert_Contains
           (Err_Of (R), "there is no pipeline named 'Missing'", "it says so");
      end;
   end A_Pipeline_That_Cannot_Run_Starts_No_Session;

   ---------------------------------------------------------------------------
   --  run, through a harness program
   ---------------------------------------------------------------------------

   procedure A_Harness_Is_Run_As_A_Program_With_The_Settings_It_Needs
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Define
        (F, "One",
         "Pipeline One { Work [Harness => Claude, Prompt => ""Do it.""]; }"
         & LF);
      Install_Claude
        (F,
         "{ printf 'args:'; for a in ""$@""; do printf ' %s' ""$a""; done;"
         & " echo; echo ""cwd:$(pwd)""; echo ""work:$SYNAPSE_WORK_DIR"";"
         & " echo ""prompt:$prompt""; } > """ & Root (F) & "/seen.log""" & LF
         & Says_Done);
      declare
         R    : constant Result := Run_Pipeline (F, "run", "One");
         Seen : constant String := Read_File (Root (F) & "/seen.log");
      begin
         Assert_Exit (R, 0, "run");
         Assert_Contains
           (Out_Of (R), """summary"":""did it""", "the harness's result");
         Assert_Contains (Seen, "args: -p ", "headless");
         Assert_Contains
           (Seen, "--permission-mode acceptEdits",
            "a step with no level may edit");
         Assert
           (Contains (Seen, "cwd:" & Repo (F))
            or else Contains (Seen, "cwd:/private" & Repo (F)),
            "in the working directory: " & Seen);
         Assert_Contains
           (Seen, "work:" & Work (F), "with the work directory it was given");
         Assert_Contains (Seen, "Do it.", "the step's prompt");
      end;
   end A_Harness_Is_Run_As_A_Program_With_The_Settings_It_Needs;

   procedure The_Input_Reaches_The_First_Session (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Define
        (F, "One",
         "Pipeline One { Work [Harness => Claude, Prompt => ""Do it.""]; }"
         & LF);
      Install_Claude
        (F,
         "case ""$prompt"" in *'""task"":""build""'*) s=input-seen;;"
         & " *) s=input-missing;; esac" & LF
         & "printf '{""is_error"":false,""structured_output"":"
         & "{""outcome"":""Done"",""summary"":""%s"",""data"":{}}}' ""$s""");
      Write_File (Root (F) & "/input.json", "{""task"":""build""}");
      declare
         From_File  : constant Result :=
           Run_Pipeline (F, "run", "One", "--input", Root (F) & "/input.json");
         From_Stdin : constant Result :=
           Run_Pipeline_Stdin
             (F, "{""task"":""build""}", "run", "One", "--input", "-");
         Without    : constant Result := Run_Pipeline (F, "run", "One");
      begin
         Assert_Contains (Out_Of (From_File), "input-seen", "from a file");
         Assert_Contains (Out_Of (From_Stdin), "input-seen", "from stdin");
         Assert_Contains (Out_Of (Without), "input-missing", "or none");
      end;
   end The_Input_Reaches_The_First_Session;

   procedure A_Session_Past_Its_Limit_Is_Stopped (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F       : Fixture;
      Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
   begin
      Set_Up (F);
      Define
        (F, "Slow",
         "Pipeline Slow { Hang [Harness => Claude, Prompt => ""Wait."", "
         & "Timeout => ""2s""]; }" & LF);
      Install_Claude (F, "sleep 60");
      declare
         R     : constant Result := Run_Pipeline (F, "run", "Slow");
         Taken : constant Duration :=
           Ada.Calendar."-" (Ada.Calendar.Clock, Started);
      begin
         Assert_Exit (R, 1, "run");
         Assert_Contains
            (Err_Of (R),
             "step Hang failed: execution_error: timed out after 2 s",
            "it says which limit");
         Assert
           (Taken < 30.0,
            "and did not wait for the program:" & Taken'Image);
      end;
   end A_Session_Past_Its_Limit_Is_Stopped;

   procedure A_Quota_Is_Reported_With_When_It_Resets
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Define
        (F, "Limited",
         "Pipeline Limited { Work [Harness => Claude, Prompt => ""x""]; }"
         & LF);
      Install_Claude
        (F,
         "printf '%s' '{""is_error"":true,""result"":""You have hit your "
         & "limit. resets 9am""}'; exit 1");
      declare
         R : constant Result := Run_Pipeline (F, "run", "Limited");
      begin
         Assert_Exit (R, 1, "run");
         Assert_Contains
           (Err_Of (R), "quota_exhausted", "told from other errors");
         Assert_Contains (Err_Of (R), "resets at 9am", "with when it resets");
      end;
   end A_Quota_Is_Reported_With_When_It_Resets;

   procedure A_Harness_That_Is_Not_Installed_Is_Named
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Define_Dev (F);
      Set_Env (F, "PATH", "/usr/bin:/bin");
      declare
         R : constant Result := Run_Pipeline (F, "run", "Dev");
      begin
         Assert_Exit (R, 1, "run");
         Assert_Contains
           (Err_Of (R), "cannot run Claude: 'claude' was not found",
            "the harness is named");
      end;
   end A_Harness_That_Is_Not_Installed_Is_Named;

   ---------------------------------------------------------------------------
   --  list and info, against a run in progress
   ---------------------------------------------------------------------------

   --  The execution id of the one run `list` shows, once it shows one.
   function Await_Run (F : Fixture) return String is
   begin
      for Try in 1 .. 100 loop
         declare
            R : constant Result := Run_Pipeline (F, "list");
         begin
            if Contains (Out_Of (R), "exec-") then
               declare
                  Text  : constant String := Out_Of (R);
                  Start : constant Natural :=
                    Ada.Strings.Fixed.Index (Text, "exec-");
               begin
                  return Text (Start .. Start + 12);
               end;
            end if;
         end;
         delay 0.1;
      end loop;
      return "";
   end Await_Run;

   procedure A_Run_Can_Be_Inspected_While_It_Goes (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F    : Fixture;
      Goes : Background;
   begin
      Set_Up (F);
      Define_Dev (F);
      Use_Script
        (F,
         "{""Develop"":[" & Answer ("Done", "first", "3") & "],""Review"":["
         & Answer ("Approved", "looks good", "1") & "]}");
      Start (Goes, Pipeline_Bin, Args ("run", "Dev"), Repo (F));
      declare
         Id : constant String := Await_Run (F);
      begin
         Assert
           (Id'Length = 13, "a run is listed while it goes: '" & Id & "'");
         declare
            Listed  : constant Result := Run_Pipeline (F, "list");
            Brief   : constant Result := Run_Pipeline (F, "info", Id);
            Json    : constant Result :=
              Run_Pipeline (F, "info", Id, "--format", "json");
            Queried : constant Result :=
              Run_Pipeline
                (F, "info", Id, "--query", "{""var"":""current_step""}");
            Refused : constant Result :=
              Run_Pipeline (F, "info", Id, "--query", "{""stop"":[1]}");
            Missing : constant Result := Run_Pipeline (F, "info", "exec-none");
         begin
            Assert_Exit (Listed, 0, "list");
            Assert_Contains
              (Out_Of (Listed), "EXECUTION", "a heading");
            Assert_Contains
              (Out_Of (Listed), "Dev", "the pipeline");
            Assert_Contains (Out_Of (Listed), "running", "its status");
            Assert_Exit (Brief, 0, "info");
            Assert_Contains
              (Out_Of (Brief), "execution  " & Id, "the run in brief");
            Assert_Contains (Out_Of (Brief), "pipeline   Dev", "its pipeline");
            Assert_Exit (Json, 0, "info --format json");
            Assert_Contains
              (Out_Of (Json), """pipeline"":""Dev""", "JSON for a program");
            Assert_Exit (Queried, 0, "info --query");
            Assert_Contains
               (Out_Of (Queried), "Develop", "the first step is current");
            Assert_Exit (Refused, 1, "a rule the run does not know");
            Assert_Equal (Out_Of (Refused), "", "prints no answer");
            Assert_Exit (Missing, 1, "a run that is not there");
            Assert_Contains
              (Err_Of (Missing), "no run named 'exec-none' is listening",
               "is named");
         end;
      end;
      declare
         Done : constant Result := Await (Goes);
      begin
         Assert_Exit (Done, 0, "the run itself is not disturbed");
         Assert_Contains (Out_Of (Done), "looks good", "and finishes");
      end;
      declare
         After : constant Result := Run_Pipeline (F, "list");
      begin
         Assert_Exit (After, 0, "list after");
         Assert_Equal (Out_Of (After), "", "nothing is left listed");
         Assert
           (Files_In (Work (F) & "/pipelines", ".sock").Is_Empty,
            "and the endpoint is gone");
      end;
   end A_Run_Can_Be_Inspected_While_It_Goes;

   procedure A_Dead_Runs_Endpoint_Is_Not_Listed (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Write_File (Work (F) & "/pipelines/exec-deadbeef.sock", "");
      declare
         R : constant Result := Run_Pipeline (F, "list");
      begin
         Assert_Exit (R, 0, "list");
         Assert_Equal (Out_Of (R), "", "a file nobody listens at is no run");
      end;
   end A_Dead_Runs_Endpoint_Is_Not_Listed;

   ---------------------------------------------------------------------------
   --  help
   ---------------------------------------------------------------------------

   procedure Every_Help_Needs_No_Environment (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;

      procedure Says_Its_Usage (Sub : String) is
         R : constant Result := Run_Pipeline (F, Sub, "--help");
      begin
         Assert_Exit (R, 0, Sub & " --help");
         Assert_Contains
           (Out_Of (R), "usage: synapse-pipeline " & Sub, "its own usage");
      end Says_Its_Usage;
   begin
      Keep_Only_Path (F);
      Says_Its_Usage ("check");
      Says_Its_Usage ("run");
      Says_Its_Usage ("list");
      Says_Its_Usage ("info");
      Assert_Exit (Run_Pipeline (F, "--help"), 0, "--help");
      Assert_Exit (Run_Pipeline (F, "frobnicate"), 2, "an unknown subcommand");
   end Every_Help_Needs_No_Environment;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance.Agent_Pipeline");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Check_Shows_What_A_Pipeline_Would_Run'Access,
         "check shows what a pipeline would run");
      Register_Routine
        (T, Check_Reports_Every_Problem_Where_It_Is'Access,
         "check reports every problem where it is");
      Register_Routine
        (T, A_Scripted_Run_Follows_Its_Guards'Access,
         "a scripted run follows its guards");
      Register_Routine
        (T, A_Step_That_Fails_Stops_The_Run'Access,
         "a step that fails stops the run");
      Register_Routine
        (T, A_Pipeline_That_Cannot_Run_Starts_No_Session'Access,
         "a pipeline that cannot run starts no session");
      Register_Routine
        (T,
         A_Harness_Is_Run_As_A_Program_With_The_Settings_It_Needs'Access,
         "a harness is run as a program with the settings it needs");
      Register_Routine
        (T, The_Input_Reaches_The_First_Session'Access,
         "the input reaches the first session");
      Register_Routine
        (T, A_Session_Past_Its_Limit_Is_Stopped'Access,
         "a session past its limit is stopped");
      Register_Routine
        (T, A_Quota_Is_Reported_With_When_It_Resets'Access,
         "a quota is reported with when it resets");
      Register_Routine
        (T, A_Harness_That_Is_Not_Installed_Is_Named'Access,
         "a harness that is not installed is named");
      Register_Routine
        (T, A_Run_Can_Be_Inspected_While_It_Goes'Access,
         "a run can be inspected while it goes");
      Register_Routine
        (T, A_Dead_Runs_Endpoint_Is_Not_Listed'Access,
         "a dead run's endpoint is not listed");
      Register_Routine
        (T, Every_Help_Needs_No_Environment'Access,
         "every help needs no environment");
   end Register_Tests;

end Acceptance.Agent_Pipeline_Tests;
