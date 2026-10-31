with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Fake_Process;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Search_Paths;

package body Synapse.Pipeline.Process_Runners.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
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
     (J ("{'is_error':false,'structured_output':{'outcome':'" & Outcome
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
        (Present => True, Kind => Resolved.Prompt_Text,
         Text => To_Unbounded_String ("You are a developer."));
      Result.Assignment :=
        (Present => True, Kind => Resolved.Prompt_Text,
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
      Runner   : Process_Runner (Process'Access, Files'Access);
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
           (Has (Prompt, "You are a developer.")
            and then Has (Prompt, "Implement the feature.")
            and then Has (Prompt, "step Develop")
            and then Has (Prompt, J ("{'task':'x'}"))
            and then Has (Prompt, J ("'outcome':'Earlier'")),
            "the prompt has the role, task, step and what came before");
      end;
   end A_Session_Is_Run_As_A_Process_Of_The_Harness;

   procedure A_Skill_Is_Read_Into_The_Prompt (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Process : aliased Fake_Process.Fake_Process;
      Files   : aliased Fake_Files.Fake_Files;
      Runner  : Process_Runner (Process'Access, Files'Access);
      Step    : Resolved.Step := Prompt_Step;
      Root    : Search_Paths.Root;
   begin
      Root.Path := To_Unbounded_String ("/skills");
      Runner.Skill_Roots.Append (Root);
      Files.Add_File ("/skills/review-code/SKILL.md", "Review it carefully.");
      Step.Assignment :=
        (Present => True, Kind => Resolved.Skill_Name,
         Text => To_Unbounded_String ("review-code"));
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
           (Has (Text, "Review it carefully.")
            and then Has (Text, "/skills/review-code"),
            "the skill's text, and where its files are, are in the prompt");
         Assert
           (Has (To_String (Args), "--add-dir /skills/review-code"),
            "Claude can reach the skill's files");
      end;
   end A_Skill_Is_Read_Into_The_Prompt;

   procedure A_Skill_That_Cannot_Be_Found_Fails_Without_A_Process
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process : aliased Fake_Process.Fake_Process;
      Files   : aliased Fake_Files.Fake_Files;
      Runner  : Process_Runner (Process'Access, Files'Access);
      Step    : Resolved.Step := Prompt_Step;
      Root    : Search_Paths.Root;
   begin
      Root.Path := To_Unbounded_String ("/skills");
      Runner.Skill_Roots.Append (Root);
      Step.Assignment :=
        (Present => True, Kind => Resolved.Skill_Name,
         Text => To_Unbounded_String ("nowhere"));
      declare
         Got : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step));
      begin
         Assert
           (not Got.Succeeded
            and then Got.Failure.Kind = Failures.Execution_Error
            and then Has
              (To_String (Got.Failure.Message),
               "skill 'nowhere' was not found")
            and then Has (To_String (Got.Failure.Message), "/skills"),
            "it says which skill and where it looked: "
            & (if Got.Succeeded then "" else To_String (Got.Failure.Message)));
         Assert
           (To_String (Got.Failure.Step) = "Develop",
            "and in which step");
      end;
      Assert (Process.Requests.Is_Empty, "no process was run");
   end A_Skill_That_Cannot_Be_Found_Fails_Without_A_Process;

   function Fails
     (Outcome : Session_Process.Process_Outcome;
      Harness : Harnesses.Harness_Kind := Harnesses.Claude)
      return Sessions.Session_Result
   is
      Process : aliased Fake_Process.Fake_Process;
      Files   : aliased Fake_Files.Fake_Files;
      Runner  : Process_Runner (Process'Access, Files'Access);
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
             (J ("{'is_error':true,'result':'You have hit your limit. "
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
          (Fake_Process.Exited (J ("{'is_error':false,'result':'Sure!'}")));
      Extra : constant Sessions.Session_Result :=
        Fails
          (Fake_Process.Exited
             (J ("{'is_error':false,'structured_output':{'outcome':'D',"
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
             (J ("{'is_error':false,'result':'")
              & Fence & "json\n"
              & J ("{\'outcome\':\'Done\',\'summary\':\'s\',\'data\':{}}")
              & "\n" & Fence & J ("'}")));
   begin
      Assert
        (Got.Succeeded and then To_String (Got.Result.Outcome) = "Done",
         "the fence is taken off");
   end A_Result_Wrapped_In_A_Code_Fence_Is_Accepted;

   procedure A_Request_The_Harness_Cannot_Honour_Does_Not_Start_A_Process
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process : aliased Fake_Process.Fake_Process;
      Files   : aliased Fake_Files.Fake_Files;
      Runner  : Process_Runner (Process'Access, Files'Access);
      Step    : Resolved.Step := Prompt_Step (Harnesses.Codex);
   begin
      Step.Tools :=
        Resolved.Json_Options.Of_Value (JSON.Parse (J ("['Edit']")).Item);
      declare
         Got : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step));
      begin
         Assert
           (not Got.Succeeded
            and then Has
              (To_String (Got.Failure.Message), "Codex cannot restrict"),
            "it says what cannot be done");
      end;
      Assert (Process.Requests.Is_Empty, "and nothing was run");
   end A_Request_The_Harness_Cannot_Honour_Does_Not_Start_A_Process;

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
        (T, A_Skill_Is_Read_Into_The_Prompt'Access,
         "A skill is read into the prompt");
      Register_Routine
        (T, A_Skill_That_Cannot_Be_Found_Fails_Without_A_Process'Access,
         "A skill that cannot be found fails without a process");
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
        (T,
         A_Request_The_Harness_Cannot_Honour_Does_Not_Start_A_Process'Access,
         "A request the harness cannot honour does not start a process");
   end Register_Tests;

end Synapse.Pipeline.Process_Runners.Tests;
