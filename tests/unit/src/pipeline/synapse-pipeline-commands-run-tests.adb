with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Pipeline.Fake_Registry;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Run.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;

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

   procedure Interactive_Starts_Each_Harness_On_The_Terminal
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_RUNNER", "process");
      F.Base.Vars.Set ("HOME", "/home/u");
      F.Terminal.Refusal := To_Unbounded_String ("'claude' was not found");
      Assert
        (Run (Env (F), Args ("Dev", "--interactive")) = 1,
         "no harness answers");
      Assert
        (Natural (F.Terminal.Requests.Length) = 1
         and then F.Sessions.Requests.Is_Empty
         and then Has (F.Base.Console.Err_Text, "cannot run Claude"),
         "the first step was started on the terminal, not as a process: "
         & F.Base.Console.Err_Text);
      Assert
        (Run (Env (F), Args ("Dev", "--interactive", "--interactive")) = 2
         and then Run (Env (F), Args ("--interactive")) = 2,
         "the flag is given once, with a pipeline");
   end Interactive_Starts_Each_Harness_On_The_Terminal;

   procedure Interactive_Needs_The_Process_Runner
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      Assert
        (Run (Env (F), Args ("Dev", "--interactive")) = 1
         and then Has
                    (F.Base.Console.Err_Text,
                     "--interactive needs the process runner")
         and then F.Terminal.Requests.Is_Empty,
         "a scripted run has no terminal to use: " & F.Base.Console.Err_Text);
   end Interactive_Needs_The_Process_Runner;

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

   --  A pipeline that declares its input: a required task id in a set
   --  shape, and optional instructions.
   procedure Add_Declared (F : in out Fixture) is
   begin
      F.Files.Add_File
        ("/defs/Declared.synapse",
         "Pipeline Declared [Input => {""fields"": {"
         & """task_id"": {""type"": ""string"", ""required"": true, "
         & """pattern"": ""^[a-z]+-[0-9]+$"", "
         & """description"": ""The task to implement.""}, "
         & """instructions"": {""type"": ""string"", "
         & """description"": ""Extra requirements.""}}}] "
         & "{ Develop [Harness => Claude, Prompt => ""Implement.""]; }");
   end Add_Declared;

   procedure A_Missing_Required_Field_Is_Refused_With_No_Record
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      Add_Declared (F);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_RUNNER", "process");
      F.Files.Add_File ("/in.json", "{""instructions"": ""be quick""}");
      Assert
        (Run (Env (F), Args ("Declared", "--input", "/in.json")) = 2,
         "refused with code 2: " & F.Base.Console.Err_Text);
      Assert
        (F.Base.Console.Err_Text =
         "error: input.task_id: required field is missing" & LF,
         "the problem, and nothing else: " & F.Base.Console.Err_Text);
      Assert (F.Base.Console.Out_Text = "", "nothing on standard output");
      Assert
        (F.Registry.Held.Is_Empty and then F.Sessions.Requests.Is_Empty,
         "no record and no session");
      F.Base.Console.Clear;
      Assert
        (Run (Env (F), Args ("Declared")) = 2
         and then Has
                    (F.Base.Console.Err_Text,
                     "error: input.task_id: required field is missing"),
         "no input at all is checked as {}: " & F.Base.Console.Err_Text);
   end A_Missing_Required_Field_Is_Refused_With_No_Record;

   procedure An_Unknown_Field_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      Add_Declared (F);
      F.Files.Add_File
        ("/in.json", "{""task_id"": ""synapse-1"", ""task"": ""x""}");
      Assert
        (Run (Env (F), Args ("Declared", "--input", "/in.json")) = 2,
         "refused");
      Assert
        (F.Base.Console.Err_Text = "error: input.task: unknown field" & LF,
         "names the field: " & F.Base.Console.Err_Text);
   end An_Unknown_Field_Is_Refused;

   procedure A_Plain_String_Becomes_The_One_Required_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      Add_Declared (F);
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_RUNNER", "process");
      F.Files.Add_File ("/in.json", """synapse-70""");
      Assert
        (Run (Env (F), Args ("Declared", "--input", "/in.json")) = 1,
         "accepted, then fails as no harness answers: "
         & F.Base.Console.Err_Text);
      Assert
        (Natural (F.Sessions.Requests.Length) = 1
         and then Has
                    (To_String (F.Sessions.Requests (1).Standard_Input),
                     "- task_id: synapse-70" & LF
                     & "  The task to implement." & LF
                     & "- instructions: (not given)"),
         "the step is started with the string as task_id: "
         & To_String (F.Sessions.Requests (1).Standard_Input));
   end A_Plain_String_Becomes_The_One_Required_Field;

   procedure Every_Input_Problem_Is_Reported (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      Add_Declared (F);
      F.Files.Add_File
        ("/in.json",
         "{""task_id"": ""Not A Task"", ""instructions"": 3, ""x"": 1}");
      Assert
        (Run (Env (F), Args ("Declared", "--input", "/in.json")) = 2,
         "refused");
      Assert
        (Has (F.Base.Console.Err_Text, "error: input.x: unknown field" & LF)
         and then Has
                    (F.Base.Console.Err_Text,
                     "error: input.task_id: does not match required pattern"
                     & LF)
         and then Has
                    (F.Base.Console.Err_Text,
                     "error: input.instructions: expected string" & LF)
         and then Progress_Lines (F.Base.Console.Err_Text) = 3,
         "one line a problem: " & F.Base.Console.Err_Text);
   end Every_Input_Problem_Is_Reported;

   procedure A_Pipeline_Without_Input_Runs_Any_Input
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_RUNNER", "process");
      F.Files.Add_File ("/in.json", "[1, ""two""]");
      Assert
        (Run (Env (F), Args ("Dev", "--input", "/in.json")) = 1,
         "it is not refused, it fails as no harness answers: "
         & F.Base.Console.Err_Text);
      Assert
        (Natural (F.Sessions.Requests.Length) = 1
         and then Has
                    (To_String (F.Sessions.Requests (1).Standard_Input),
                     "[1,""two""]"),
         "the step gets the input as it is: "
         & To_String (F.Sessions.Requests (1).Standard_Input));
   end A_Pipeline_Without_Input_Runs_Any_Input;

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

   procedure A_Run_With_Only_A_Home_Is_Recorded_In_The_Default_Root
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("HOME", "/home/u");
      Assert (Run (Env (F), Args ("Dev")) = 0, "it completes");
      Assert
        (To_String (F.Registry.Work) = "/home/u/.cache/synapse/work",
         "it is recorded under the default root: "
         & To_String (F.Registry.Work));
      Assert
        (Has
           (To_String (F.Inspector.Endpoint),
            "/home/u/.cache/synapse/work/pipelines/exec-"),
         "and listens where the transport puts a run there");
   end A_Run_With_Only_A_Home_Is_Recorded_In_The_Default_Root;

   procedure A_Run_Is_Recorded_In_The_Registry (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert (Run (Env (F), Args ("Dev")) = 0, "it completes");
      Assert
        (To_String (F.Registry.Work) = "/work",
         "the registry was told where the work is kept");
      Assert
        (Natural (F.Registry.Held.Length) = 1,
         "one execution was recorded");
      declare
         Id      : constant String := To_String (F.Registry.Ids.First_Element);
         Summary : constant Registry_Store.Maybe_Content :=
           F.Registry.Read_Summary (Id);
         Events  : constant Registry_Store.Maybe_Content :=
           F.Registry.Read_Events (Id);
      begin
         Assert
           (Summary.Found
            and then Has
                       (To_String (Summary.Value), """status"":""completed"""),
            "its summary says it completed");
         Assert
           (Events.Found
            and then Has (To_String (Events.Value), """kind"":""run.started""")
            and then Has
              (To_String (Events.Value), """kind"":""run.completed"""),
            "and its events run from the start to the end");
         Assert
           (F.Registry.Read_Description (Id).Found
            and then Has
              (To_String (F.Registry.Read_Description (Id).Value),
               """name"":""Dev"""),
            "and the pipeline it ran is described");
         Assert
           (F.Registry.Read_Definition (Id, "synapse-pipeline/Dev.synapse")
              .Found
            and then Has
              (To_String
                 (F.Registry.Read_Definition
                    (Id, "synapse-pipeline/Dev.synapse").Value),
               "Pipeline Dev {"),
            "and the file it was loaded from is kept as it was");
      end;
   end A_Run_Is_Recorded_In_The_Registry;

   --  Runs Two, a pipeline of Develop then Review, in /repo, with Review
   --  answering Review_Answer and the working trees handing out t1 .. t5.
   --  Says whether the summary has start t1 and end t5 and both are pinned.
   function Two_Steps_Leave_Their_Snapshots
     (Review_Answer : String; Code : Integer) return Boolean
   is
      F : aliased Fixture;
   begin
      Set_Up
        (F,
         "{""Develop"":[" & Done ("Done", "built") & "],""Review"":["
         & Review_Answer & "]}");
      F.Files.Add_File
        ("/defs/Two.synapse",
         "Pipeline Two {"
         & " Develop [Harness => Claude, Prompt => ""Implement.""];"
         & " Review [Harness => Codex, Prompt => ""Review.""]; }");
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      for I in 1 .. 5 loop
         F.Trees.Snapshots.Append
           (To_Unbounded_String
              ("t" & Ada.Strings.Fixed.Trim (I'Image, Ada.Strings.Both)));
      end loop;
      Assert (Run (Env (F), Args ("Two")) = Code, "it ends as it should");
      declare
         Id      : constant String := To_String (F.Registry.Ids.First_Element);
         Summary : constant String :=
           To_String (F.Registry.Read_Summary (Id).Value);
         Pinned  : Unbounded_String;
      begin
         for Item of F.Trees.Pinned loop
            Append (Pinned, Item & "|");
         end loop;
         Assert
           (To_String (Pinned)
            = "refs/synapse/runs/" & Id & "/start=t1|"
              & "refs/synapse/runs/" & Id & "/end=t5|",
            "the first before and the snapshot at the end are pinned: "
            & To_String (Pinned));
         return
           Has (Summary, """snapshots"":{""start"":""t1"",""end"":""t5""}");
      end;
   end Two_Steps_Leave_Their_Snapshots;

   procedure A_Completed_Run_Keeps_Its_Start_And_End
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Two_Steps_Leave_Their_Snapshots (Done ("Approved", "ok"), 0),
         "the summary has both snapshots");
   end A_Completed_Run_Keeps_Its_Start_And_End;

   procedure A_Failed_Run_Keeps_Its_Start_And_End
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Two_Steps_Leave_Their_Snapshots
           ("{""fail"":""quota_exhausted"",""message"":""limit""}", 1),
         "a run that fails at its second step has both too");
   end A_Failed_Run_Keeps_Its_Start_And_End;

   --  The output the only recorded execution of F keeps as Name, empty when
   --  it keeps none.
   function Output_Of (F : Fixture; Name : String) return String is
      Id   : constant String := To_String (F.Registry.Ids.First_Element);
      Kept : constant Registry_Store.Maybe_Content :=
        F.Registry.Read_Output (Id, Name);
   begin
      return (if Kept.Found then To_String (Kept.Value) else "");
   end Output_Of;

   function Outputs_Kept (F : Fixture) return Natural is
     (Natural
        (F.Registry.Held (To_String (F.Registry.Ids.First_Element))
           .Outputs.Length));

   procedure Each_Visit_Keeps_Its_Output (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up
        (F,
         "{""Develop"":[" & Done ("Done", "built") & "],""Review"":["
         & Done ("Approved", "looks good") & "]}");
      F.Files.Add_File
        ("/defs/Two.synapse",
         "Pipeline Two {"
         & " Develop [Harness => Claude, Prompt => ""Implement.""];"
         & " Review [Harness => Codex, Prompt => ""Review.""]; }");
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert (Run (Env (F), Args ("Two")) = 0, "it completes");
      Assert
        (Output_Of (F, "1-Develop-1.json") = Done ("Done", "built"),
         "the first visit keeps what it reported: "
         & Output_Of (F, "1-Develop-1.json"));
      Assert
        (Output_Of (F, "2-Review-1.json") = Done ("Approved", "looks good"),
         "and so does the second: " & Output_Of (F, "2-Review-1.json"));
      Assert (Outputs_Kept (F) = 2, "and nothing else is kept");
      declare
         Events : constant String :=
           To_String
             (F.Registry.Read_Events
                (To_String (F.Registry.Ids.First_Element)).Value);
      begin
         Assert
           (Has
              (Events, """detail"":{""outcome"":""Done"",""next"":""Review""}")
            and then Has
              (Events, """detail"":{""outcome"":""Approved"",""next"":""""}"),
            "the step.finished events still hold only outcome and next: "
            & Events);
      end;
   end Each_Visit_Keeps_Its_Output;

   procedure Only_The_Accepted_Try_Keeps_Its_Output
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up
        (F,
         "{""Develop"":[" & Done ("Nope", "wrong word") & ","
         & Done ("Done", "right word") & "]}");
      F.Files.Add_File
        ("/defs/Retry.synapse",
         "Pipeline Retry {"
         & " Develop [Harness => Claude, Prompt => ""Implement."","
         & " Outcomes => {""Done"": ""It is done.""}, Retries => 1]; }");
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert (Run (Env (F), Args ("Retry")) = 0, "the retry completes it");
      Assert
        (Output_Of (F, "1-Develop-2.json") = Done ("Done", "right word"),
         "the try the run routed on is kept: "
         & Output_Of (F, "1-Develop-2.json"));
      Assert (Outputs_Kept (F) = 1, "and the refused try is not");
   end Only_The_Accepted_Try_Keeps_Its_Output;

   procedure A_Failed_Step_Keeps_No_Output (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up
        (F,
         "{""Develop"":[{""fail"":""quota_exhausted"","
         & """message"":""limit reached""}]}");
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert (Run (Env (F), Args ("Dev")) = 1, "it fails");
      Assert (Outputs_Kept (F) = 0, "and keeps no output");
   end A_Failed_Step_Keeps_No_Output;

   procedure A_Registry_That_Fails_Leaves_The_Run_As_It_Was
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Expected : constant String :=
        "step Develop: Done -> Review" & LF
        & "step Review: Changes_Requested -> Develop" & LF
        & "step Develop: Done -> Review" & LF
        & "step Review: Approved -> done" & LF;
   begin
      declare
         F : aliased Fixture;
      begin
         Set_Up (F, Round_Once);
         F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
         F.Registry.Fail (Fake_Registry.Create_Op);
         Assert
           (Run (Env (F), Args ("Dev")) = 0
            and then F.Base.Console.Err_Text = Expected,
            "a directory that cannot be made changes nothing");
         Assert (F.Registry.Held.Is_Empty, "and nothing was recorded");
      end;
      declare
         F : aliased Fixture;
      begin
         Set_Up (F, Round_Once);
         F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
         F.Registry.Fail (Fake_Registry.Replace_Op);
         F.Registry.Fail (Fake_Registry.Append_Op);
         F.Registry.Fail (Fake_Registry.Transcript_Op);
         Assert
           (Run (Env (F), Args ("Dev")) = 0
            and then F.Base.Console.Err_Text = Expected,
            "writes that cannot be made change nothing");
      end;
   end A_Registry_That_Fails_Leaves_The_Run_As_It_Was;

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
         "usage: synapse-pipeline run <pipeline> [--input <file>|-] "
         & "[--id <execution-id>] [--name <text>] [--interactive]" & LF,
         "says how");
      Assert (Run (Env (F), Args ("A", "B")) = 2, "two pipelines");
      Assert (Run (Env (F), Args ("Dev", "--input")) = 2, "--input alone");
      Assert
        (Run (Env (F), Args ("Dev", "--input", "a", "--input", "b")) = 2,
         "--input twice");
      Assert (Run (Env (F), Args ("Dev", "--quiet")) = 2, "another option");
   end The_Arguments_Are_Checked;

   procedure A_Run_Takes_The_Id_It_Is_Given (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert
        (Run (Env (F), Args ("Dev", "--id", "nightly-1")) = 0,
         "it completes");
      Assert
        (Natural (F.Registry.Held.Length) = 1
         and then F.Registry.Held.Contains ("nightly-1"),
         "and is recorded under that id and no other");
      Assert
        (Has
           (To_String (F.Registry.Read_Summary ("nightly-1").Value),
            """id"":""nightly-1"""),
         "its summary names it");
   end A_Run_Takes_The_Id_It_Is_Given;

   procedure An_Id_That_Is_Taken_Is_An_Error_And_Nothing_Runs
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert
        (F.Registry.Create ("nightly-1") = Registry_Store.Created, "taken");
      Assert
        (Run (Env (F), Args ("Dev", "--id", "nightly-1")) = 1,
         "the run is refused");
      Assert
        (F.Base.Console.Err_Text =
         "error: execution nightly-1 already exists" & LF,
         "and says why: " & F.Base.Console.Err_Text);
      Assert
        (F.Base.Console.Out_Text = ""
         and then not F.Registry.Read_Summary ("nightly-1").Found
         and then Natural (F.Registry.Held.Length) = 1,
         "no session ran and the taken id was left as it was");
   end An_Id_That_Is_Taken_Is_An_Error_And_Nothing_Runs;

   procedure An_Id_Needs_A_Work_Directory (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      Assert
        (Run (Env (F), Args ("Dev", "--id", "nightly-1")) = 1,
         "the run is refused");
      Assert
        (F.Base.Console.Err_Text =
         "error: --id needs a work directory; set SYNAPSE_WORK_DIR" & LF
         and then F.Base.Console.Out_Text = "",
         "and says why: " & F.Base.Console.Err_Text);
   end An_Id_Needs_A_Work_Directory;

   procedure A_Directory_That_Cannot_Be_Made_Refuses_The_Id
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      F.Registry.Fail (Fake_Registry.Create_Op);
      Assert
        (Run (Env (F), Args ("Dev", "--id", "nightly-1")) = 1,
         "the run is refused, since it was asked to be recorded by name");
      Assert
        (Has
           (F.Base.Console.Err_Text,
            "the record of execution nightly-1 could not be made")
         and then F.Base.Console.Out_Text = "",
         "and says why: " & F.Base.Console.Err_Text);
   end A_Directory_That_Cannot_Be_Made_Refuses_The_Id;

   procedure An_Id_That_Is_Not_Plain_Is_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
      --  Whether the run is turned away as a usage error for this id.
      procedure Refuse (Id : String) is
      begin
         Assert
           (Run (Env (F), Args ("Dev", "--id", Id)) = 2,
            "an id that is not plain is a usage error: " & Id);
      end Refuse;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Refuse ("");
      Refuse ("../x");
      Refuse ("a b");
      Refuse ("a/b");
      Refuse ("a:b");
      Refuse ([1 .. 65 => 'a']);
      Assert
        (Has (F.Base.Console.Err_Text, "error: --id must be 1 to 64 letters")
         and then F.Registry.Held.Is_Empty,
         "it says what an id may be and nothing is recorded");
      Assert (Run (Env (F), Args ("Dev", "--id")) = 2, "--id alone");
      Assert
        (Run (Env (F), Args ("Dev", "--id", "a", "--id", "b")) = 2,
         "--id twice");
      Assert
        (Run (Env (F), Args ("Dev", "--id", [1 .. 64 => 'a'])) = 0,
         "64 characters are allowed");
   end An_Id_That_Is_Not_Plain_Is_A_Usage_Error;

   procedure A_Run_Given_A_Name_Records_It (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert
        (Run
           (Env (F),
            Args ("Dev", "--id", "nightly-1", "--name", "Fix login")) = 0,
         "it completes");
      Assert
        (F.Registry.Read_Name ("nightly-1").Found
         and then To_String (F.Registry.Read_Name ("nightly-1").Value)
                  = "Fix login",
         "the name is kept for the run's id");
      Assert
        (not Has (F.Base.Console.Err_Text, "warning: cannot record the name"),
         "with no warning: " & F.Base.Console.Err_Text);
   end A_Run_Given_A_Name_Records_It;

   procedure A_Run_Without_A_Name_Records_None (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert (Run (Env (F), Args ("Dev")) = 0, "it completes");
      Assert
        (Natural (F.Registry.Held.Length) = 1
         and then not F.Registry.Read_Name
                        (To_String (F.Registry.Ids.First_Element)).Found,
         "and has no name");
   end A_Run_Without_A_Name_Records_None;

   procedure A_Name_That_Is_Too_Long_Is_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert
        (Run (Env (F), Args ("Dev", "--name", [1 .. 121 => 'a'])) = 2,
         "121 characters are a usage error");
      Assert
        (Has (F.Base.Console.Err_Text, "error: --name must be one line")
         and then F.Base.Console.Out_Text = ""
         and then F.Registry.Held.Is_Empty,
         "it says what a name may be, and nothing ran or was recorded: "
         & F.Base.Console.Err_Text);
   end A_Name_That_Is_Too_Long_Is_A_Usage_Error;

   procedure A_Name_Given_Twice_Is_A_Usage_Error (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F, Round_Once);
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert
        (Run (Env (F), Args ("Dev", "--name", "a", "--name", "b")) = 2,
         "--name twice");
      Assert (Run (Env (F), Args ("Dev", "--name")) = 2, "--name alone");
      Assert
        (F.Registry.Held.Is_Empty and then F.Base.Console.Out_Text = "",
         "nothing ran");
   end A_Name_Given_Twice_Is_A_Usage_Error;

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
        (T, Interactive_Starts_Each_Harness_On_The_Terminal'Access,
         "Interactive starts each harness on the terminal");
      Register_Routine
        (T, Interactive_Needs_The_Process_Runner'Access,
         "Interactive needs the process runner");
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
        (T, A_Run_With_Only_A_Home_Is_Recorded_In_The_Default_Root'Access,
         "A run with only a home is recorded in the default root");
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
        (T, A_Run_Is_Recorded_In_The_Registry'Access,
         "A run is recorded in the registry");
      Register_Routine
        (T, Each_Visit_Keeps_Its_Output'Access,
         "Each visit keeps its output");
      Register_Routine
        (T, Only_The_Accepted_Try_Keeps_Its_Output'Access,
         "Only the accepted try keeps its output");
      Register_Routine
        (T, A_Failed_Step_Keeps_No_Output'Access,
         "A failed step keeps no output");
      Register_Routine
        (T, A_Registry_That_Fails_Leaves_The_Run_As_It_Was'Access,
         "A registry that fails leaves the run as it was");
      Register_Routine
        (T, The_Arguments_Are_Checked'Access, "The arguments are checked");
      Register_Routine
        (T, A_Gate_Can_End_The_Run_Early'Access,
         "A gate can end the run early");
      Register_Routine
        (T, A_Run_Takes_The_Id_It_Is_Given'Access,
         "A run takes the id it is given");
      Register_Routine
        (T, An_Id_That_Is_Taken_Is_An_Error_And_Nothing_Runs'Access,
         "An id that is taken is an error and nothing runs");
      Register_Routine
        (T, An_Id_Needs_A_Work_Directory'Access,
         "An id needs a work directory");
      Register_Routine
        (T, A_Directory_That_Cannot_Be_Made_Refuses_The_Id'Access,
         "A directory that cannot be made refuses the id");
      Register_Routine
        (T, An_Id_That_Is_Not_Plain_Is_A_Usage_Error'Access,
         "An id that is not plain is a usage error");
      Register_Routine
        (T, A_Run_Given_A_Name_Records_It'Access,
         "A run given a name records it");
      Register_Routine
        (T, A_Run_Without_A_Name_Records_None'Access,
         "A run without a name records none");
      Register_Routine
        (T, A_Name_That_Is_Too_Long_Is_A_Usage_Error'Access,
         "A name that is too long is a usage error and nothing runs");
      Register_Routine
        (T, A_Name_Given_Twice_Is_A_Usage_Error'Access,
         "--name given twice is a usage error");
      Register_Routine
        (T, A_Completed_Run_Keeps_Its_Start_And_End'Access,
         "A completed run keeps its start and end");
      Register_Routine
        (T, A_Failed_Run_Keeps_Its_Start_And_End'Access,
         "A failed run keeps its start and end");
      Register_Routine
        (T, A_Missing_Required_Field_Is_Refused_With_No_Record'Access,
         "An input missing a required field is refused with code 2 and no "
         & "record");
      Register_Routine
        (T, An_Unknown_Field_Is_Refused'Access,
         "An unknown field is refused");
      Register_Routine
        (T, A_Plain_String_Becomes_The_One_Required_Field'Access,
         "A plain string becomes the one required field");
      Register_Routine
        (T, Every_Input_Problem_Is_Reported'Access,
         "Every problem is reported");
      Register_Routine
        (T, A_Pipeline_Without_Input_Runs_Any_Input'Access,
         "A pipeline without Input runs any input as before");
   end Register_Tests;

end Synapse.Pipeline.Commands.Run.Tests;
