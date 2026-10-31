with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Fake_Process;

package body Synapse.Pipeline.Harness_Commands.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Failures.Failure_Kind;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  JSON written with single quotes, as JSON.
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

   function Joined (List : Synapse.Core.Text_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Item of List loop
         Append (Text, To_String (Item) & " ");
      end loop;
      return To_String (Text);
   end Joined;

   function Step_Of
     (Permissions : String := ""; Model : String := "";
      Tools : String := "") return Resolved.Step
   is
      Result : Resolved.Step;
   begin
      Result.Name := To_Unbounded_String ("S");
      if Permissions /= "" then
         Result.Permissions :=
           Synapse.Core.Optional_Text.Of_Value
             (To_Unbounded_String (Permissions));
      end if;
      if Model /= "" then
         Result.Model :=
           Synapse.Core.Optional_Text.Of_Value (To_Unbounded_String (Model));
      end if;
      if Tools /= "" then
         Result.Tools :=
           Resolved.Json_Options.Of_Value (JSON.Parse (J (Tools)).Item);
      end if;
      return Result;
   end Step_Of;

   function Command_Of
     (Harness : Harnesses.Harness_Kind; Step : Resolved.Step;
      Skill : String := "") return Command
   is
      Made : constant Command_Results.Result :=
        Build (Harness, Step, "PROMPT", Skill);
   begin
      Assert
        (Command_Results.Is_Success (Made),
         "the command is built: "
         & (if Command_Results.Is_Success (Made) then ""
            else To_String (Command_Results.Error (Made))));
      return Command_Results.Value (Made);
   end Command_Of;

   function Ended
     (Output : String; Code : Integer := 0; Errors : String := "")
      return Session_Process.Process_Outcome
   renames Synapse.Pipeline.Fake_Process.Exited;

   ---------------------------------------------------------------------------
   --  Commands
   ---------------------------------------------------------------------------

   procedure Claude_Is_Run_Headless_With_The_Envelope_Schema
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Made : constant Command :=
        Command_Of (Harnesses.Claude, Step_Of (Model => "m1"));
      Args : constant String := Joined (Made.Arguments);
   begin
      Assert (To_String (Made.Program) = "claude", "the program");
      Assert
        (Has (Args, "-p ") and then Has (Args, "--output-format json ")
         and then Has (Args, "--json-schema {""type"":""object""")
         and then Has (Args, "--no-session-persistence")
         and then Has (Args, "--model m1"),
         "headless, structured, nothing kept: " & Args);
      Assert
        (To_String (Made.Standard_Input) = "PROMPT",
         "the prompt goes in on standard input, not in the arguments");
      Assert (not Has (Args, "PROMPT"), "and nowhere else");
   end Claude_Is_Run_Headless_With_The_Envelope_Schema;

   procedure Claude_Permissions_Follow_The_Level (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Default : constant String :=
        Joined (Command_Of (Harnesses.Claude, Step_Of).Arguments);
      Read    : constant String :=
        Joined
          (Command_Of
             (Harnesses.Claude, Step_Of (Permissions => "Read_Only"))
             .Arguments);
      Full    : constant String :=
        Joined
          (Command_Of
             (Harnesses.Claude, Step_Of (Permissions => "Full_Access"))
             .Arguments);
   begin
      Assert
        (Has (Default, "--permission-mode acceptEdits")
         and then not Has (Default, "--tools"),
         "a step with no level may edit files: " & Default);
      Assert
        (Has (Read, "--permission-mode dontAsk")
         and then Has (Read, "--tools Read,Grep,Glob"),
         "a read-only one has only the tools that read: " & Read);
      Assert
        (Has (Full, "--permission-mode bypassPermissions"),
         "a full-access one is not asked: " & Full);
   end Claude_Permissions_Follow_The_Level;

   procedure Claude_Is_Given_Tools_And_The_Skill_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Args : constant String :=
        Joined
          (Command_Of
             (Harnesses.Claude,
              Step_Of (Tools => "['Bash(git *)','Edit']"), "/skills/x")
             .Arguments);
   begin
      Assert
        (Has (Args, "--allowedTools Bash(git *) Edit "),
         "each tool is an allowed tool: " & Args);
      Assert (Has (Args, "--add-dir /skills/x"), "and the skill is reachable");
   end Claude_Is_Given_Tools_And_The_Skill_Directory;

   procedure Codex_Is_Run_In_A_Sandbox_That_Matches_The_Level
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Default : constant Command := Command_Of (Harnesses.Codex, Step_Of);
      Read    : constant String :=
        Joined
          (Command_Of
             (Harnesses.Codex, Step_Of (Permissions => "Read_Only")).Arguments);
      Full    : constant String :=
        Joined
          (Command_Of
             (Harnesses.Codex, Step_Of (Permissions => "Full_Access"))
             .Arguments);
      Args    : constant String := Joined (Default.Arguments);
   begin
      Assert (To_String (Default.Program) = "codex", "the program");
      Assert
        (Has (Args, "exec --json --ephemeral --skip-git-repo-check -s "
              & "workspace-write"),
         "a step with no level may edit the working directory: " & Args);
      Assert (Has (Read, "-s read-only"), "read only");
      Assert (Has (Full, "-s danger-full-access"), "full access");
      Assert (To_String (Default.Standard_Input) = "PROMPT", "prompt on stdin");
   end Codex_Is_Run_In_A_Sandbox_That_Matches_The_Level;

   procedure OpenCode_Is_Run_Alone_With_Its_Permissions_In_The_Environment
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Default : constant Command := Command_Of (Harnesses.Opencode, Step_Of);
      Read    : constant Command :=
        Command_Of
          (Harnesses.Opencode, Step_Of (Permissions => "Read_Only"));
      Full    : constant Command :=
        Command_Of
          (Harnesses.Opencode, Step_Of (Permissions => "Full_Access"));
      Args    : constant String := Joined (Default.Arguments);
   begin
      Assert
        (Has (Args, "run --standalone --format json --auto PROMPT"),
         "a private server that reads this environment: " & Args);
      Assert
        (Joined (Default.Environment) =
         "OPENCODE_CONFIG_CONTENT="
         & J ("{'permission':{'external_directory':'deny'}} "),
         "file tools stay in the working directory: "
         & Joined (Default.Environment));
      Assert
        (Has (Joined (Read.Environment), """edit"":""deny"""),
         "a read-only one may not edit: " & Joined (Read.Environment));
      Assert
        (Has (Joined (Read.Environment), """bash"":""deny""")
         and then Has (Joined (Read.Environment), """webfetch"":""deny"""),
         "or run commands or fetch");
      Assert (Full.Environment.Is_Empty, "full access adds no settings");
   end OpenCode_Is_Run_Alone_With_Its_Permissions_In_The_Environment;

   procedure A_Tool_Allowlist_Is_Refused_Where_It_Cannot_Be_Kept
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Step : constant Resolved.Step := Step_Of (Tools => "['Edit']");
      Code : constant Command_Results.Result :=
        Build (Harnesses.Codex, Step, "P", "");
      Open : constant Command_Results.Result :=
        Build (Harnesses.Opencode, Step, "P", "");
   begin
      Assert
        (not Command_Results.Is_Success (Code)
         and then Has
           (To_String (Command_Results.Error (Code)),
            "Codex cannot restrict the tools"),
         "Codex says so");
      Assert
        (not Command_Results.Is_Success (Open)
         and then Has
           (To_String (Command_Results.Error (Open)),
            "OpenCode cannot restrict the tools"),
         "OpenCode says so");
   end A_Tool_Allowlist_Is_Refused_Where_It_Cannot_Be_Kept;

   ---------------------------------------------------------------------------
   --  Replies
   ---------------------------------------------------------------------------

   Claude_Done : constant String :=
     J ("{'type':'result','subtype':'success','is_error':false,"
        & "'api_error_status':null,'result':'{\'outcome\':\'Done\'}',"
        & "'structured_output':{'outcome':'Done','summary':'hi','data':{}},"
        & "'usage':{'input_tokens':2,'cache_creation_input_tokens':66509,"
        & "'cache_read_input_tokens':1,'output_tokens':99}}");

   procedure A_Claude_Answer_Is_Its_Structured_Output
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Said : constant Reply := Interpret (Harnesses.Claude, Ended (Claude_Done));
   begin
      Assert (Said.Succeeded, "it succeeded");
      Assert
        (To_String (Said.Answer) =
         J ("{'outcome':'Done','summary':'hi','data':{}}"),
         "the answer is the structured output: " & To_String (Said.Answer));
      Assert
        (Said.Usage.Reported and then Said.Usage.Input_Tokens = 66512
         and then Said.Usage.Output_Tokens = 99,
         "the input tokens include what was cached");
   end A_Claude_Answer_Is_Its_Structured_Output;

   procedure Without_Structured_Output_The_Result_Text_Is_The_Answer
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Said : constant Reply :=
        Interpret
          (Harnesses.Claude,
           Ended (J ("{'is_error':false,'result':'the text'}")));
   begin
      Assert
        (Said.Succeeded and then To_String (Said.Answer) = "the text",
         "it is used");
   end Without_Structured_Output_The_Result_Text_Is_The_Answer;

   procedure A_Claude_Error_Is_A_Quota_When_It_Says_So
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Limit  : constant Reply :=
        Interpret
          (Harnesses.Claude,
           Ended
             (J ("{'is_error':true,'subtype':'error_during_execution',"
                 & "'result':'You have hit your limit - resets 3pm "
                 & "(Europe/Zagreb)'}")));
      Status : constant Reply :=
        Interpret
          (Harnesses.Claude,
           Ended (J ("{'is_error':true,'api_error_status':429,'result':'x'}")));
      Other  : constant Reply :=
        Interpret
          (Harnesses.Claude,
           Ended (J ("{'is_error':true,'result':'the model broke'}")));
   begin
      Assert
        (not Limit.Succeeded
         and then Limit.Failure.Kind = Failures.Quota_Exhausted
         and then Limit.Failure.Reset.Found
         and then To_String (Limit.Failure.Reset.Value) =
                  "3pm (Europe/Zagreb)",
         "a limit is a quota, with when it resets");
      Assert
        (Status.Failure.Kind = Failures.Quota_Exhausted,
         "so is a status of 429");
      Assert
        (Other.Failure.Kind = Failures.Execution_Error
         and then To_String (Other.Failure.Message) = "the model broke",
         "anything else is an execution error");
   end A_Claude_Error_Is_A_Quota_When_It_Says_So;

   procedure A_Claude_Process_That_Printed_Nothing_Usable_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Crashed : constant Reply :=
        Interpret
          (Harnesses.Claude, Ended ("", Code => 1, Errors => "boom" & LF));
      Empty   : constant Reply := Interpret (Harnesses.Claude, Ended (""));
   begin
      Assert
        (not Crashed.Succeeded
         and then To_String (Crashed.Failure.Message) =
                  "claude exited with code 1: boom",
         "it says how it ended: " & To_String (Crashed.Failure.Message));
      Assert
        (not Empty.Succeeded
         and then Has
           (To_String (Empty.Failure.Message), "finished without an answer"),
         "or that it ended without an answer");
   end A_Claude_Process_That_Printed_Nothing_Usable_Fails;

   Codex_Done : constant String :=
     J ("{'type':'thread.started','thread_id':'t'}" & LF
        & "{'type':'turn.started'}" & LF
        & "{'type':'item.completed','item':{'id':'item_0',"
        & "'type':'agent_message','text':'{\'outcome\':\'Done\',"
        & "\'summary\':\'hi\',\'data\':{}}'}}" & LF
        & "{'type':'turn.completed','usage':{'input_tokens':16406,"
        & "'output_tokens':24}}" & LF);

   procedure A_Codex_Answer_Is_Its_Last_Agent_Message
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Said : constant Reply := Interpret (Harnesses.Codex, Ended (Codex_Done));
   begin
      Assert (Said.Succeeded, "it succeeded");
      Assert
        (To_String (Said.Answer) =
         J ("{'outcome':'Done','summary':'hi','data':{}}"),
         "the message is the answer: " & To_String (Said.Answer));
      Assert
        (Said.Usage.Reported and then Said.Usage.Input_Tokens = 16406
         and then Said.Usage.Output_Tokens = 24,
         "with the usage it reported");
   end A_Codex_Answer_Is_Its_Last_Agent_Message;

   procedure A_Codex_Failure_Is_Read_From_Its_Events
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Invalid : constant Reply :=
        Interpret
          (Harnesses.Codex,
           Ended
             (J ("{'type':'turn.started'}" & LF
                 & "{'type':'turn.failed','error':{'message':"
                 & "'{\'type\':\'error\',\'error\':{\'message\':"
                 & "\'Invalid schema\'},\'status\':400}'}}" & LF),
              Code => 1));
      Limit   : constant Reply :=
        Interpret
          (Harnesses.Codex,
           Ended
             (J ("{'type':'error','message':'You have hit your usage limit. "
                 & "Try again later.'}" & LF),
              Code => 1));
      Silent  : constant Reply :=
        Interpret (Harnesses.Codex, Ended ("", Code => 2, Errors => "bad"));
   begin
      Assert
        (Invalid.Failure.Kind = Failures.Execution_Error
         and then To_String (Invalid.Failure.Message) = "Invalid schema",
         "the message inside the message is the one given: "
         & To_String (Invalid.Failure.Message));
      Assert
        (Limit.Failure.Kind = Failures.Quota_Exhausted,
         "a usage limit is a quota");
      Assert
        (Silent.Failure.Kind = Failures.Execution_Error
         and then Has (To_String (Silent.Failure.Message), "code 2"),
         "no events is a process that failed");
   end A_Codex_Failure_Is_Read_From_Its_Events;

   Opencode_Done : constant String :=
     J ("{'type':'step_start','part':{'type':'step-start'}}" & LF
        & "{'type':'text','part':{'messageID':'m1','type':'text',"
        & "'text':'working'}}" & LF
        & "{'type':'step_finish','part':{'tokens':{'input':3,'output':4,"
        & "'cache':{'read':1,'write':2}}}}" & LF
        & "{'type':'text','part':{'messageID':'m2','type':'text',"
        & "'text':'{\'outcome\':\'Done\','}}" & LF
        & "{'type':'text','part':{'messageID':'m2','type':'text',"
        & "'text':'\'summary\':\'hi\',\'data\':{}}'}}" & LF
        & "{'type':'step_finish','part':{'tokens':{'input':5,'output':6,"
        & "'cache':{'read':0,'write':0}}}}" & LF);

   procedure An_OpenCode_Answer_Is_The_Text_Of_Its_Last_Message
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Said : constant Reply :=
        Interpret (Harnesses.Opencode, Ended (Opencode_Done));
   begin
      Assert (Said.Succeeded, "it succeeded");
      Assert
        (To_String (Said.Answer) =
         J ("{'outcome':'Done','summary':'hi','data':{}}"),
         "the last message's parts are put together: "
         & To_String (Said.Answer));
      Assert
        (Said.Usage.Input_Tokens = 3 + 1 + 2 + 5
         and then Said.Usage.Output_Tokens = 10,
         "and every step's tokens are counted");
   end An_OpenCode_Answer_Is_The_Text_Of_Its_Last_Message;

   procedure An_OpenCode_Error_Is_A_Failure
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Said : constant Reply :=
        Interpret
          (Harnesses.Opencode,
           Ended
             (J ("{'type':'error','error':{'name':'APIError','data':"
                 & "{'message':'rate limit exceeded'}}}" & LF)));
   begin
      Assert
        (not Said.Succeeded
         and then Said.Failure.Kind = Failures.Quota_Exhausted
         and then To_String (Said.Failure.Message) = "rate limit exceeded",
         "an error event is the failure, and a rate limit a quota");
   end An_OpenCode_Error_Is_A_Failure;

   procedure Quota_Messages_Are_Told_From_Others (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Is_Quota_Message ("You have hit your limit"), "limit");
      Assert (Is_Quota_Message ("USAGE LIMIT reached"), "case does not matter");
      Assert (Is_Quota_Message ("Too Many Requests"), "too many requests");
      Assert (Is_Quota_Message ("insufficient_quota"), "quota");
      Assert (Is_Quota_Message ("rate_limit_exceeded"), "rate limit");
      Assert (not Is_Quota_Message ("the test suite failed"), "not a quota");
      Assert (not Is_Quota_Message (""), "nothing is not a quota");
   end Quota_Messages_Are_Told_From_Others;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Harness_Commands");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Claude_Is_Run_Headless_With_The_Envelope_Schema'Access,
         "Claude is run headless with the envelope schema");
      Register_Routine
        (T, Claude_Permissions_Follow_The_Level'Access,
         "Claude's permissions follow the level");
      Register_Routine
        (T, Claude_Is_Given_Tools_And_The_Skill_Directory'Access,
         "Claude is given tools and the skill directory");
      Register_Routine
        (T, Codex_Is_Run_In_A_Sandbox_That_Matches_The_Level'Access,
         "Codex is run in a sandbox that matches the level");
      Register_Routine
        (T,
         OpenCode_Is_Run_Alone_With_Its_Permissions_In_The_Environment'Access,
         "OpenCode is run alone with its permissions in the environment");
      Register_Routine
        (T, A_Tool_Allowlist_Is_Refused_Where_It_Cannot_Be_Kept'Access,
         "A tool allowlist is refused where it cannot be kept");
      Register_Routine
        (T, A_Claude_Answer_Is_Its_Structured_Output'Access,
         "A Claude answer is its structured output");
      Register_Routine
        (T, Without_Structured_Output_The_Result_Text_Is_The_Answer'Access,
         "Without structured output the result text is the answer");
      Register_Routine
        (T, A_Claude_Error_Is_A_Quota_When_It_Says_So'Access,
         "A Claude error is a quota when it says so");
      Register_Routine
        (T, A_Claude_Process_That_Printed_Nothing_Usable_Fails'Access,
         "A Claude process that printed nothing usable fails");
      Register_Routine
        (T, A_Codex_Answer_Is_Its_Last_Agent_Message'Access,
         "A Codex answer is its last agent message");
      Register_Routine
        (T, A_Codex_Failure_Is_Read_From_Its_Events'Access,
         "A Codex failure is read from its events");
      Register_Routine
        (T, An_OpenCode_Answer_Is_The_Text_Of_Its_Last_Message'Access,
         "An OpenCode answer is the text of its last message");
      Register_Routine
        (T, An_OpenCode_Error_Is_A_Failure'Access,
         "An OpenCode error is a failure");
      Register_Routine
        (T, Quota_Messages_Are_Told_From_Others'Access,
         "Quota messages are told from others");
   end Register_Tests;

end Synapse.Pipeline.Harness_Commands.Tests;
