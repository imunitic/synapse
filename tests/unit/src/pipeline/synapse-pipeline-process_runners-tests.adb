with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Fake_Process;
with Synapse.Pipeline.Fake_Registry;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;

package body Synapse.Pipeline.Process_Runners.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;
   use type Failures.Failure_Kind;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function J (Text : String) return String is
      Result : String := Text;
   begin
      for C of Result loop
         if C = ''' then
            C := '"';
         end if;
      end loop;
      return Result;
   end J;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   --  What Claude prints for a session that ended well with Outcome.
   function Claude_Said (Outcome : String) return String is
     (J ("{'type':'result','is_error':false,"
         & "'structured_output':{'outcome':'" & Outcome
         & "','summary':'did it','data':{'n':1}},'usage':{'input_tokens':1,"
         & "'output_tokens':2}}"));

   function Prompt_Step
     (Harness : Harnesses.Harness_Kind := Harnesses.Claude)
      return Resolved.Step
   is
      Result : Resolved.Step;
   begin
      Result.Name := To_Unbounded_String ("Develop");
      Result.Harness := Harness;
      Result.Role :=
        (Present => True,
         Text => To_Unbounded_String ("You are a developer."));
      Result.Assignment :=
        (Present => True,
         Text => To_Unbounded_String ("Implement the feature."));
      return Result;
   end Prompt_Step;

   function Request_Of
     (Step : Resolved.Step; Settings : Configs.Config := (others => <>))
      return Sessions.Session_Request
   is
      Result : Sessions.Session_Request;
   begin
      Result.Step := Step;
      Result.Settings := Settings;
      Result.Initial_Input := JSON.Parse (J ("{'task':'x'}")).Item;
      Result.Previous_Output :=
        JSON.Parse (J ("{'outcome':'Earlier','summary':'s','data':{}}")).Item;
      Result.Timeout_Seconds := 90;
      return Result;
   end Request_Of;

   procedure A_Session_Is_Run_As_A_Process_Of_The_Harness
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process  : aliased Fake_Process.Fake_Process;
      Files    : aliased Fake_Files.Fake_Files;
      Registry : aliased Fake_Registry.Fake_Registry;
      Runner   : Process_Runner
        (Process'Access, Files'Access, Registry'Access);
      Settings : Configs.Config;
   begin
      Settings.Working_Directory := To_Unbounded_String ("/work/tree");
      Settings.Environment.Insert ("SYNAPSE_WORK_DIR", "/work");
      Process.Outcomes.Append (Fake_Process.Exited (Claude_Said ("Done")));
      declare
         Got : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Prompt_Step, Settings));
      begin
         Assert (Got.Succeeded, "it succeeded");
         Assert
           (To_String (Got.Result.Outcome) = "Done"
            and then To_String (Got.Result.Summary) = "did it"
            and then JSON.To_String (Got.Result.Data) = J ("{'n':1}"),
            "with the result the harness gave");
         Assert
           (Got.Usage.Reported and then Got.Usage.Input_Tokens = 1
            and then Got.Usage.Output_Tokens = 2,
            "and the usage it reported");
      end;
      Assert (Natural (Process.Requests.Length) = 1, "one process was run");
      declare
         Ran    : constant Session_Process.Process_Request :=
           Process.Requests (1);
         Prompt : constant String := To_String (Ran.Standard_Input);
      begin
         Assert (To_String (Ran.Program) = "claude", "the harness's program");
         Assert
           (To_String (Ran.Directory) = "/work/tree"
            and then Ran.Timeout_Seconds = 90,
            "in the working directory, held to the session's limit");
         Assert
           (Ran.Environment.Contains
              (To_Unbounded_String ("SYNAPSE_WORK_DIR=/work")),
            "given the configuration's environment");
         Assert
           (Length (Ran.Output_Path) = 0,
            "no output path without an execution to keep a transcript in");
         Assert
           (Has (Prompt, "You are a developer.")
            and then Has (Prompt, "Implement the feature.")
            and then Has (Prompt, "step Develop")
            and then Has (Prompt, J ("{'task':'x'}"))
            and then Has (Prompt, J ("'outcome':'Earlier'")),
            "the prompt has the role, task, step and what came before");
      end;
   end A_Session_Is_Run_As_A_Process_Of_The_Harness;

   procedure A_Sessions_Output_Is_Kept_As_Its_Transcript
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process  : aliased Fake_Process.Fake_Process;
      Files    : aliased Fake_Files.Fake_Files;
      Registry : aliased Fake_Registry.Fake_Registry;
      Runner   : Process_Runner
        (Process'Access, Files'Access, Registry'Access);
      Asked    : Sessions.Session_Request := Request_Of (Prompt_Step);
   begin
      Assert (Registry.Create ("exec-1") = Registry_Store.Created, "made");
      Asked.Execution_Id := To_Unbounded_String ("exec-1");
      Asked.Attempt := 2;
      Process.Outcomes.Append (Fake_Process.Exited (Claude_Said ("Done")));
      declare
         Got : constant Sessions.Session_Result := Runner.Run_Session (Asked);
      begin
         Assert (Got.Succeeded, "the session succeeded");
         Assert
           (Got.Transcript.Found
            and then To_String (Got.Transcript.Value) =
                     "memory:exec-1/transcripts/1-Develop-2.jsonl",
            "and says where its transcript is");
      end;
      Assert
        (Registry.Held.Element ("exec-1").Transcripts.Element
           ("1-Develop-2.jsonl") = Claude_Said ("Done"),
         "which holds what the harness printed, as it printed it");
      Assert
        (To_String (Process.Requests (1).Output_Path) =
         "memory:exec-1/transcripts/1-Develop-2.jsonl",
         "the process was told to write its output to that transcript");
   end A_Sessions_Output_Is_Kept_As_Its_Transcript;

   procedure A_Session_That_Fails_Keeps_Its_Transcript_Too
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process  : aliased Fake_Process.Fake_Process;
      Files    : aliased Fake_Files.Fake_Files;
      Registry : aliased Fake_Registry.Fake_Registry;
      Runner   : Process_Runner
        (Process'Access, Files'Access, Registry'Access);
      Asked    : Sessions.Session_Request := Request_Of (Prompt_Step);
   begin
      Assert (Registry.Create ("exec-1") = Registry_Store.Created, "made");
      Asked.Execution_Id := To_Unbounded_String ("exec-1");
      Process.Outcomes.Append (Fake_Process.Exited ("not an answer"));
      declare
         Got : constant Sessions.Session_Result := Runner.Run_Session (Asked);
      begin
         Assert (not Got.Succeeded, "the session failed");
         Assert (Got.Transcript.Found, "and its transcript was kept");
      end;
   end A_Session_That_Fails_Keeps_Its_Transcript_Too;

   procedure Nothing_Is_Kept_Without_A_Record_To_Keep_It_In
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process  : aliased Fake_Process.Fake_Process;
      Files    : aliased Fake_Files.Fake_Files;
      Registry : aliased Fake_Registry.Fake_Registry;
      Runner   : Process_Runner
        (Process'Access, Files'Access, Registry'Access);
   begin
      Process.Outcomes.Append (Fake_Process.Exited (Claude_Said ("Done")));
      declare
         Got : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Prompt_Step));
      begin
         Assert (Got.Succeeded and then not Got.Transcript.Found,
                 "a request with no execution has no transcript");
      end;
      Assert (Registry.Held.Is_Empty, "and nothing is written");

      Assert (Registry.Create ("exec-1") = Registry_Store.Created, "made");
      Registry.Fail (Fake_Registry.Transcript_Op);
      Process.Outcomes.Append (Fake_Process.Exited (Claude_Said ("Done")));
      declare
         Asked : Sessions.Session_Request := Request_Of (Prompt_Step);
      begin
         Asked.Execution_Id := To_Unbounded_String ("exec-1");
         declare
            Got : constant Sessions.Session_Result :=
              Runner.Run_Session (Asked);
         begin
            Assert
              (Got.Succeeded and then not Got.Transcript.Found,
               "a transcript that cannot be written is left out and the "
               & "session is as it was");
         end;
      end;
   end Nothing_Is_Kept_Without_A_Record_To_Keep_It_In;

   procedure A_Prompt_Definition_Is_Sent_As_Its_Text
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process  : aliased Fake_Process.Fake_Process;
      Files    : aliased Fake_Files.Fake_Files;
      Registry : aliased Fake_Registry.Fake_Registry;
      Runner   : Process_Runner
        (Process'Access, Files'Access, Registry'Access);
      Step     : Resolved.Step := Prompt_Step;
   begin
      --  What resolution leaves of `Prompt => Review_Code`: the text of the
      --  Prompt definition.
      Step.Assignment :=
        (Present => True,
         Text => To_Unbounded_String ("Review it carefully."));
      Process.Outcomes.Append (Fake_Process.Exited (Claude_Said ("Done")));
      declare
         Got  : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step));
         Ran  : constant Session_Process.Process_Request :=
           Process.Requests (1);
         Text : constant String := To_String (Ran.Standard_Input);
         Args : Unbounded_String;
      begin
         for A of Ran.Arguments loop
            Append (Args, To_String (A) & " ");
         end loop;
         Assert (Got.Succeeded, "it succeeded");
         Assert
           (Has (Text, "Review it carefully."),
            "the prompt's text is in the prompt: " & Text);
         Assert
           (not Has (To_String (Args), "--add-dir"),
            "and no directory is added: " & To_String (Args));
      end;
   end A_Prompt_Definition_Is_Sent_As_Its_Text;

   function Fails
     (Outcome : Session_Process.Process_Outcome;
      Harness : Harnesses.Harness_Kind := Harnesses.Claude)
      return Sessions.Session_Result
   is
      Process : aliased Fake_Process.Fake_Process;
      Files   : aliased Fake_Files.Fake_Files;
      Registry : aliased Fake_Registry.Fake_Registry;
      Runner   : Process_Runner
        (Process'Access, Files'Access, Registry'Access);
   begin
      Process.Outcomes.Append (Outcome);
      return Runner.Run_Session (Request_Of (Prompt_Step (Harness)));
   end Fails;

   procedure A_Harness_That_Is_Not_Installed_Is_An_Execution_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Sessions.Session_Result :=
        Fails
          ((Started => False,
            Problem => To_Unbounded_String ("'codex' was not found"),
            others  => <>),
           Harnesses.Codex);
   begin
      Assert
        (not Got.Succeeded
         and then Got.Failure.Kind = Failures.Execution_Error
         and then To_String (Got.Failure.Message) =
                  "cannot run Codex: 'codex' was not found",
         "it names the harness and why");
   end A_Harness_That_Is_Not_Installed_Is_An_Execution_Error;

   procedure A_Session_Past_Its_Limit_Fails_And_Says_How_Long
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Sessions.Session_Result :=
        Fails ((Started => True, Timed_Out => True, others => <>));
   begin
      Assert
        (not Got.Succeeded
         and then Got.Failure.Kind = Failures.Execution_Error
         and then To_String (Got.Failure.Message) =
                  "timed out after 90 seconds",
         "the limit is the session's");
   end A_Session_Past_Its_Limit_Fails_And_Says_How_Long;

   procedure A_Quota_Is_Reported_As_One_With_When_It_Resets
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Sessions.Session_Result :=
        Fails
          (Fake_Process.Exited
             (J ("{'type':'result',"
               & "'is_error':true,'result':'You have hit your limit. "
                 & "resets 9am'}"),
              Code => 1));
   begin
      Assert
        (not Got.Succeeded
         and then Got.Failure.Kind = Failures.Quota_Exhausted
         and then Got.Failure.Reset.Found
         and then To_String (Got.Failure.Reset.Value) = "9am",
         "a quota, with when it resets");
      Assert
        (To_String (Got.Failure.Step) = "Develop", "in the step it hit it");
   end A_Quota_Is_Reported_As_One_With_When_It_Resets;

   procedure An_Answer_That_Is_Not_A_Result_Is_A_Contract_Failure
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Prose : constant Sessions.Session_Result :=
        Fails
          (Fake_Process.Exited (J ("{'type':'result',"
            & "'is_error':false,'result':'Sure!'}")));
      Extra : constant Sessions.Session_Result :=
        Fails
          (Fake_Process.Exited
             (J ("{'type':'result',"
               & "'is_error':false,'structured_output':{'outcome':'D',"
                 & "'summary':'s','data':{},'x':1}}")));
   begin
      Assert
        (not Prose.Succeeded
         and then Prose.Failure.Kind = Failures.Result_Contract_Failure,
         "prose is not a result");
      Assert
        (not Extra.Succeeded
         and then Extra.Failure.Kind = Failures.Result_Contract_Failure,
         "nor is a result with another member");
   end An_Answer_That_Is_Not_A_Result_Is_A_Contract_Failure;

   procedure A_Result_Wrapped_In_A_Code_Fence_Is_Accepted
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Fence : constant String := "```";
      Got   : constant Sessions.Session_Result :=
        Fails
          (Fake_Process.Exited
             (J ("{'type':'result','is_error':false,'result':'")
              & Fence & "json\n"
              & J ("{\'outcome\':\'Done\',\'summary\':\'s\',\'data\':{}}")
              & "\n" & Fence & J ("'}")));
   begin
      Assert
        (Got.Succeeded and then To_String (Got.Result.Outcome) = "Done",
         "the fence is taken off");
   end A_Result_Wrapped_In_A_Code_Fence_Is_Accepted;

   --  What Claude prints when it refuses a session it was started for.
   function Claude_Refused return Session_Process.Process_Outcome is
     (Fake_Process.Exited
        (J ("{'type':'result','is_error':true,"
            & "'result':'invalid effort'}"),
         Code => 1));

   function Run_Failing (Step : Resolved.Step) return Sessions.Session_Result
   is
      Process  : aliased Fake_Process.Fake_Process;
      Files    : aliased Fake_Files.Fake_Files;
      Registry : aliased Fake_Registry.Fake_Registry;
      Runner   : Process_Runner
        (Process'Access, Files'Access, Registry'Access);
   begin
      Process.Outcomes.Append (Claude_Refused);
      return Runner.Run_Session (Request_Of (Step));
   end Run_Failing;

   procedure A_Failed_Session_With_An_Effort_Names_The_Effort
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Step : Resolved.Step := Prompt_Step;
   begin
      Step.Effort :=
        Synapse.Core.Optional_Text.Of_Value (To_Unbounded_String ("high"));
      declare
         Got : constant Sessions.Session_Result := Run_Failing (Step);
      begin
         Assert
           (not Got.Succeeded
            and then Got.Failure.Kind = Failures.Execution_Error,
            "it is an execution error, which is retried as before");
         Assert
           (To_String (Got.Failure.Message) =
            "invalid effort (effort: high)",
            "the message names the effort asked for: "
            & To_String (Got.Failure.Message));
      end;
   end A_Failed_Session_With_An_Effort_Names_The_Effort;

   procedure A_Failed_Session_Without_An_Effort_Is_As_Before
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Sessions.Session_Result := Run_Failing (Prompt_Step);
   begin
      Assert
        (not Got.Succeeded
         and then Got.Failure.Kind = Failures.Execution_Error
         and then To_String (Got.Failure.Message) = "invalid effort",
         "the message is the harness's own: "
         & To_String (Got.Failure.Message));
   end A_Failed_Session_Without_An_Effort_Is_As_Before;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Process_Runners");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Session_Is_Run_As_A_Process_Of_The_Harness'Access,
         "A session is run as a process of the harness");
      Register_Routine
        (T, A_Sessions_Output_Is_Kept_As_Its_Transcript'Access,
         "A session's output is kept as its transcript");
      Register_Routine
        (T, A_Session_That_Fails_Keeps_Its_Transcript_Too'Access,
         "A session that fails keeps its transcript too");
      Register_Routine
        (T, Nothing_Is_Kept_Without_A_Record_To_Keep_It_In'Access,
         "Nothing is kept without a record to keep it in");
      Register_Routine
        (T, A_Prompt_Definition_Is_Sent_As_Its_Text'Access,
         "A step whose prompt came from a Prompt definition is sent that "
         & "text");
      Register_Routine
        (T, A_Harness_That_Is_Not_Installed_Is_An_Execution_Error'Access,
         "A harness that is not installed is an execution error");
      Register_Routine
        (T, A_Session_Past_Its_Limit_Fails_And_Says_How_Long'Access,
         "A session past its limit fails and says how long");
      Register_Routine
        (T, A_Quota_Is_Reported_As_One_With_When_It_Resets'Access,
         "A quota is reported as one, with when it resets");
      Register_Routine
        (T, An_Answer_That_Is_Not_A_Result_Is_A_Contract_Failure'Access,
         "An answer that is not a result is a contract failure");
      Register_Routine
        (T, A_Result_Wrapped_In_A_Code_Fence_Is_Accepted'Access,
         "A result wrapped in a code fence is accepted");
      Register_Routine
        (T, A_Failed_Session_With_An_Effort_Names_The_Effort'Access,
         "a failed session of a step with an effort names the effort");
      Register_Routine
        (T, A_Failed_Session_Without_An_Effort_Is_As_Before'Access,
         "a failed session of a step without an effort is reported as "
         & "before");
   end Register_Tests;

end Synapse.Pipeline.Process_Runners.Tests;
