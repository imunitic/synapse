with Ada.Calendar;
with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Harnesses;

package body Synapse.Pipeline.Scripted_Runners.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Failures.Failure_Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package JSON renames Synapse.Core.JSON;

   use type JSON.Kind;

   Loop_Script : constant String :=
     "{""Develop"": ["
     & "{""outcome"":""Done"",""summary"":""first"",""data"":{}},"
     & "{""outcome"":""Done"",""summary"":""second"",""data"":{""n"":2}}],"
     & """Review"": ["
     & "{""outcome"":""Changes_Requested"",""summary"":""no"",""data"":{}},"
     & "{""outcome"":""Approved"",""summary"":""yes"",""data"":{}}]}";

   --  The request to run the named step.
   function Request_Of (Step : String) return Sessions.Session_Request is
     (Step =>
        (Name => To_Unbounded_String (Step), Harness => Harnesses.Claude,
         others => <>),
      others => <>);

   --  A runner for the script, which must parse.
   function Runner_For (Text : String) return Scripted_Runner is
      R : constant Script_Results.Result := Parse (Text);
   begin
      Assert
        (Script_Results.Is_Success (R),
         "the script parses: "
         & (if Script_Results.Is_Success (R) then ""
            else To_String (Script_Results.Error (R))));
      return Create (Script_Results.Value_Or (R, Scripts.Empty));
   end Runner_For;

   function Summary_Of (Got : Sessions.Session_Result) return String is
     (if Got.Succeeded then To_String (Got.Result.Summary) else "<failed>");

   procedure Answers_Are_Used_Up_In_Order_Across_A_Loop
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : Scripted_Runner := Runner_For (Loop_Script);
   begin
      Assert (Remaining (R, "Develop") = 2, "two to start with");
      Assert
        (Summary_Of (R.Run_Session (Request_Of ("Develop"))) = "first",
         "develop, the first time round");
      Assert
        (To_String (R.Run_Session (Request_Of ("Review")).Result.Outcome) =
         "Changes_Requested",
         "review asks for changes");
      Assert
        (Summary_Of (R.Run_Session (Request_Of ("Develop"))) = "second",
         "develop again, the second time round");
      Assert
        (To_String (R.Run_Session (Request_Of ("Review")).Result.Outcome) =
         "Approved",
         "review approves");
      Assert
        (Remaining (R, "Develop") = 0 and then Remaining (R, "Review") = 0,
         "nothing left");
   end Answers_Are_Used_Up_In_Order_Across_A_Loop;

   procedure Each_Step_Has_Its_Own_Answers (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R : Scripted_Runner := Runner_For (Loop_Script);
      Ignored : constant Sessions.Session_Result :=
        R.Run_Session (Request_Of ("Review"));
   begin
      Assert
        (Remaining (R, "Review") = 1 and then Remaining (R, "Develop") = 2,
         "running one step leaves the other's answers");
      Assert
        (Remaining (R, "Nobody") = 0, "a step not in the script has none");
      Assert (Ignored.Succeeded, "the answer was a result");
   end Each_Step_Has_Its_Own_Answers;

   procedure A_Step_Out_Of_Answers_Fails_And_Says_So
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : Scripted_Runner := Runner_For (Loop_Script);
      Ignored_1 : constant Sessions.Session_Result :=
        R.Run_Session (Request_Of ("Review"));
      Ignored_2 : constant Sessions.Session_Result :=
        R.Run_Session (Request_Of ("Review"));
      Third     : constant Sessions.Session_Result :=
        R.Run_Session (Request_Of ("Review"));
      Unknown   : constant Sessions.Session_Result :=
        R.Run_Session (Request_Of ("Ghost"));
   begin
      Assert
        (Ignored_1.Succeeded and then Ignored_2.Succeeded,
         "two answers were given");
      Assert
        (not Third.Succeeded
         and then Third.Failure.Kind = Failures.Execution_Error
         and then To_String (Third.Failure.Step) = "Review"
         and then Ada.Strings.Fixed.Index
                    (To_String (Third.Failure.Message),
                     "no more answers for step 'Review'; it had 2") > 0,
         "a third is an execution error that says why");
      Assert
        (not Unknown.Succeeded
         and then Ada.Strings.Fixed.Index
                    (To_String (Unknown.Failure.Message),
                     "no more answers for step 'Ghost'; it had 0") > 0,
         "and so is a step the script never mentions");
      declare
         Empty_Runner : Scripted_Runner := Create (Scripts.Empty);
      begin
         Assert
           (not Empty_Runner.Run_Session (Request_Of ("A")).Succeeded,
            "an empty script answers nothing");
      end;
   end A_Step_Out_Of_Answers_Fails_And_Says_So;

   procedure Each_Failure_Form_Is_That_Failure (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R : Scripted_Runner :=
        Runner_For
          ("{""A"": ["
           & "{""fail"":""timeout""},"
           & "{""fail"":""timeout"",""message"":""took too long""},"
           & "{""fail"":""execution_error"",""message"":""crashed""},"
           & "{""fail"":""result_contract_failure""},"
           & "{""fail"":""quota_exhausted"",""reset"":""09:00""},"
           & "{""fail"":""quota_exhausted""}]}");
      Got : array (1 .. 6) of Sessions.Session_Result;
   begin
      for I in Got'Range loop
         Got (I) := R.Run_Session (Request_Of ("A"));
         Assert
           (not Got (I).Succeeded
            and then To_String (Got (I).Failure.Step) = "A",
            "failure" & Integer'Image (I) & " names its step");
      end loop;
      Assert
        (Got (1).Failure.Kind = Failures.Execution_Error
         and then Ada.Strings.Fixed.Index
                    (To_String (Got (1).Failure.Message),
                     "ran past its timeout") > 0,
         "a timeout is an execution error");
      Assert
        (To_String (Got (2).Failure.Message) = "took too long",
         "with a message of its own");
      Assert
        (Got (3).Failure.Kind = Failures.Execution_Error
         and then To_String (Got (3).Failure.Message) = "crashed",
         "an execution error");
      Assert
        (Got (4).Failure.Kind = Failures.Result_Contract_Failure,
         "a result-contract failure");
      Assert
        (Got (5).Failure.Kind = Failures.Quota_Exhausted
         and then Got (5).Failure.Reset.Found
         and then To_String (Got (5).Failure.Reset.Value) = "09:00",
         "a quota with the time it resets");
      Assert
        (Got (6).Failure.Kind = Failures.Quota_Exhausted
         and then not Got (6).Failure.Reset.Found,
         "and one with no time");
   end Each_Failure_Form_Is_That_Failure;

   procedure A_Result_Entry_Is_A_Checked_Envelope (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R   : Scripted_Runner := Runner_For (Loop_Script);
      Got : constant Sessions.Session_Result :=
        R.Run_Session (Request_Of ("Develop"));
      Ignored : constant Sessions.Session_Result :=
        R.Run_Session (Request_Of ("Develop"));
   begin
      Assert
        (Got.Succeeded and then To_String (Got.Result.Outcome) = "Done"
         and then JSON.Kind_Of (Got.Result.Data) = JSON.JSON_Object,
         "outcome, summary and data");
      Assert
        (JSON.Has_Member (Ignored.Result.Data, "n"),
         "the data of the second is its own");
   end A_Result_Entry_Is_A_Checked_Envelope;

   --  Text must be refused, saying Message.
   procedure Assert_Refused (Text, Message, Label : String) is
      R : constant Script_Results.Result := Parse (Text);
   begin
      Assert (not Script_Results.Is_Success (R), Label & ": refused");
      if not Script_Results.Is_Success (R) then
         Assert
           (Ada.Strings.Fixed.Index
              (To_String (Script_Results.Error (R)), Message) > 0,
            Label & ": says '" & Message & "', says "
            & To_String (Script_Results.Error (R)));
      end if;
   end Assert_Refused;

   procedure A_Script_That_Is_Wrong_Is_Refused_Where
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Script_Results.Is_Success (Parse ("{}")), "an empty script");
      Assert_Refused ("{""A"":", "script: not JSON", "not JSON");
      Assert_Refused ("[]", "script: expected an object", "a list");
      Assert_Refused
        ("{""A"": {}}", "script.A: expected a list of answers",
         "a step's answers that are no list");
      Assert_Refused
        ("{""A"": [3]}", "script.A[1]: expected an object", "a number entry");
      Assert_Refused
        ("{""A"": [{""fail"":""melted""}]}",
         "script.A[1].fail: 'melted' is not a failure a script can give",
         "an unknown failure");
      Assert_Refused
        ("{""A"": [{""fail"":""ceiling_reached""}]}",
         "'ceiling_reached' cannot be scripted", "the ceiling");
      Assert_Refused
        ("{""A"": [{""fail"":""timeout"",""outcome"":""x""}]}",
         "script.A[1]: 'outcome' is not allowed in a failure",
         "a failure that is also a result");
      Assert_Refused
        ("{""A"": [{""fail"":3}]}", "script.A[1].fail: expected a string",
         "a failure that is not a name");
      Assert_Refused
        ("{""A"": [{""outcome"":""Done"",""summary"":""s""}]}",
         "script.A[1]: result: 'data' is missing", "a result without data");
      Assert_Refused
        ("{""A"": [{""outcome"":"""",""summary"":""s"",""data"":{}}]}",
         "script.A[1]: outcome: must not be empty", "an empty outcome");
      Assert_Refused
        ("{""A"": [{""outcome"":""D"",""summary"":""s"",""data"":{},"
         & """x"":1}]}",
         "script.A[1]: result: 'x' is not allowed", "a result with an extra");
      Assert_Refused
        ("{""A"": [{""outcome"":""D"",""summary"":""s"",""data"":{}}, 5]}",
         "script.A[2]: expected an object", "the second entry is the bad one");
   end A_Script_That_Is_Wrong_Is_Refused_Where;

   procedure An_Answer_May_Take_A_While (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Slow    : Scripted_Runner :=
        Runner_For
          ("{""A"": [{""outcome"":""Done"",""summary"":""s"",""data"":{},"
           & """delay_seconds"":0.06},{""fail"":""timeout"","
           & """delay_seconds"":1}]}");
      Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      First   : constant Sessions.Session_Result :=
        Slow.Run_Session (Request_Of ("A"));
      Taken   : constant Duration :=
        Ada.Calendar."-" (Ada.Calendar.Clock, Started);
      Parsed  : constant Script_Results.Result :=
        Parse
          ("{""A"":[{""fail"":""timeout"",""delay_seconds"":1}]}");
   begin
      Assert
        (First.Succeeded and then Taken >= 0.05,
         "the session comes back after its delay: " & Duration'Image (Taken));
      Assert
        (Script_Results.Is_Success (Parsed)
         and then Scripts.Pause (Script_Results.Value (Parsed), "A", 1) = 1.0,
         "a failure has one too, as given");
   end An_Answer_May_Take_A_While;

   procedure A_Delay_Must_Be_A_Sensible_Number (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert_Refused
        ("{""A"": [{""outcome"":""D"",""summary"":""s"",""data"":{},"
         & """delay_seconds"":""x""}]}",
         "script.A[1].delay_seconds: expected a number from 0 to 3600",
         "text");
      Assert_Refused
        ("{""A"": [{""fail"":""timeout"",""delay_seconds"":-1}]}",
         "script.A[1].delay_seconds", "below zero");
      Assert_Refused
        ("{""A"": [{""fail"":""timeout"",""delay_seconds"":3601}]}",
         "script.A[1].delay_seconds", "above the longest");
      Assert_Refused
        ("{""A"": [{""outcome"":""D"",""summary"":""s"",""data"":{},"
         & """delay_seconds"":1,""x"":1}]}",
         "script.A[1]: result: 'x' is not allowed",
         "a delay does not make an extra member allowed");
   end A_Delay_Must_Be_A_Sensible_Number;

   procedure A_Script_Is_Read_From_A_File (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/tests/answers.json", Loop_Script);
      F.Add_File ("/tests/bad.json", "{""A"": 3}");
      declare
         Good : constant Script_Results.Result :=
           Load (F, "/tests/answers.json");
      begin
         Assert
           (Script_Results.Is_Success (Good)
            and then Scripts.Count (Script_Results.Value (Good), "Review") = 2,
            "the answers in the file");
      end;
      declare
         Missing : constant Script_Results.Result :=
           Load (F, "/tests/none.json");
         Bad     : constant Script_Results.Result :=
           Load (F, "/tests/bad.json");
      begin
         Assert
           (not Script_Results.Is_Success (Missing)
            and then Ada.Strings.Fixed.Index
                       (To_String (Script_Results.Error (Missing)),
                        "script /tests/none.json cannot be read") > 0,
            "a file that is not there");
         Assert
           (not Script_Results.Is_Success (Bad)
            and then Ada.Strings.Fixed.Index
                       (To_String (Script_Results.Error (Bad)),
                        "script.A: expected a list of answers") > 0,
            "a file that is wrong");
      end;
   end A_Script_Is_Read_From_A_File;

   procedure A_Script_Built_In_Memory_Works_Too (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Script : Scripts.Script;
      Item   : Envelopes.Envelope;
   begin
      Item.Outcome := To_Unbounded_String ("Done");
      Scripts.Add (Script, "A", Sessions.Success (Item));
      Scripts.Add
        (Script, "A",
         Sessions.Failed
           ((Kind => Failures.Quota_Exhausted, others => <>)));
      declare
         R : Scripted_Runner := Create (Script);
      begin
         Assert
           (R.Run_Session (Request_Of ("A")).Succeeded
            and then not R.Run_Session (Request_Of ("A")).Succeeded
            and then Remaining (R, "A") = 0,
            "a result and then a failure, in that order");
      end;
   end A_Script_Built_In_Memory_Works_Too;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Scripted_Runners");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Answers_Are_Used_Up_In_Order_Across_A_Loop'Access,
         "Answers are used up in order across a loop");
      Register_Routine
        (T, Each_Step_Has_Its_Own_Answers'Access,
         "Each step has its own answers");
      Register_Routine
        (T, A_Step_Out_Of_Answers_Fails_And_Says_So'Access,
         "A step out of answers fails and says so");
      Register_Routine
        (T, Each_Failure_Form_Is_That_Failure'Access,
         "Each failure form is that failure");
      Register_Routine
        (T, A_Result_Entry_Is_A_Checked_Envelope'Access,
         "A result entry is a checked envelope");
      Register_Routine
        (T, A_Script_That_Is_Wrong_Is_Refused_Where'Access,
         "A script that is wrong is refused, saying where");
      Register_Routine
        (T, An_Answer_May_Take_A_While'Access,
         "An answer may take a while");
      Register_Routine
        (T, A_Delay_Must_Be_A_Sensible_Number'Access,
         "A delay must be a sensible number");
      Register_Routine
        (T, A_Script_Is_Read_From_A_File'Access,
         "A script is read from a file");
      Register_Routine
        (T, A_Script_Built_In_Memory_Works_Too'Access,
         "A script built in memory works too");
   end Register_Tests;

end Synapse.Pipeline.Scripted_Runners.Tests;
