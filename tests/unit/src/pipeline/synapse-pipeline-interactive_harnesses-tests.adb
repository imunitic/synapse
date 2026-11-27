with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Fake_Files;

package body Synapse.Pipeline.Interactive_Harnesses.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Harnesses.Harness_Kind;

   package Commands renames Harness_Commands;

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
     (Permissions : String := ""; Model : String := "")
      return Resolved.Step
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
      return Result;
   end Step_Of;

   subtype Commands_Result is Commands.Command_Results.Result;

   function Command_Results_Ok (Made : Commands_Result) return Boolean is
     (Commands.Command_Results.Is_Success (Made));

   function Command_Of (Made : Commands_Result) return Commands.Command is
     (Commands.Command_Results.Value (Made));

   function Arguments_Of
     (Made : Commands_Result) return Synapse.Core.Text_Lists.Vector is
     (Command_Of (Made).Arguments);

   function Session_Of
     (Directory : String := "/work/repo"; Id : String := "s-1")
      return Session_Handle is
     (Id        => To_Unbounded_String (Id),
      Directory => To_Unbounded_String (Directory),
      Home      => To_Unbounded_String ("/home/u"),
      Day       => To_Unbounded_String ("2026/11/15"));

   Claude : constant access constant Interactive'Class :=
     For_Harness (Harnesses.Claude);

   Codex : constant access constant Interactive'Class :=
     For_Harness (Harnesses.Codex);

   Opencode : constant access constant Interactive'Class :=
     For_Harness (Harnesses.Opencode);

   No_Files : Synapse.Pipeline.Fake_Files.Fake_Files;

   ---------------------------------------------------------------------------
   --  Transcript records, in the shape Claude writes them
   ---------------------------------------------------------------------------

   --  A prompt of the person.
   function Prompt (Text : String) return String is
     (J ("{'type':'user','isSidechain':false,"
         & "'message':{'role':'user','content':'" & Text & "'}}") & LF);

   --  The result of a tool call, which is also a `user` record.
   function Tool_Result return String is
     (J ("{'type':'user','isSidechain':false,"
         & "'message':{'role':'user','content':[{'type':'tool_result',"
         & "'tool_use_id':'t1','content':'ok'}]}}") & LF);

   --  One block of an assistant message. Stop is the message's stop_reason.
   function Block
     (Id, Content, Stop : String; Aside : Boolean := False) return String is
     (J ("{'type':'assistant','isSidechain':"
         & (if Aside then "true" else "false") & ",'message':{'id':'" & Id
         & "','role':'assistant','content':[" & Content & "],'stop_reason':"
         & (if Stop = "" then "null" else "'" & Stop & "'") & "}}") & LF);

   function Text (Words : String) return String is
     (J ("{'type':'text','text':'" & Words & "'}"));

   Thinking : constant String := J ("{'type':'thinking','thinking':''}");
   Tool_Use : constant String :=
     J ("{'type':'tool_use','id':'t1','name':'Bash','input':{}}");

   ---------------------------------------------------------------------------
   --  Starting a session
   ---------------------------------------------------------------------------

   procedure Claude_Is_Started_Interactive_With_A_Session_Id
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Made : constant Commands_Result :=
        Claude.Build
          (Step_Of (Model => "m1"), "PROMPT", Session_Of (Id => "abc"));
      Args : constant String :=
        (if Command_Results_Ok (Made) then Joined (Arguments_Of (Made))
         else "");
   begin
      Assert (Command_Results_Ok (Made), "the command is built");
      Assert
        (To_String (Command_Of (Made).Program) = "claude", "the program");
      Assert
        (Has (Args, "--session-id abc ") and then Has (Args, "--model m1 "),
         "the runner's id and the model: " & Args);
      Assert
        (not Has (Args, "-p ") and then not Has (Args, "--json-schema")
         and then not Has (Args, "--no-session-persistence")
         and then not Has (Args, "--output-format"),
         "interactive, with the session kept for its transcript: " & Args);
      Assert
        (Length (Command_Of (Made).Standard_Input) = 0,
         "the harness reads the terminal, not standard input");
      Assert
        (Has
           (Joined (Command_Of (Made).Environment),
            "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 "),
         "and its session is kept even when Claude started this program");
   end Claude_Is_Started_Interactive_With_A_Session_Id;

   procedure The_Prompt_Is_Set_Apart_From_The_Options
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Made : constant Commands_Result :=
        Claude.Build
          (Step_Of (Permissions => "Read_Only"), "- do it", Session_Of);
      Args : constant String := Joined (Arguments_Of (Made));
   begin
      Assert
        (Has (Args, "--tools Read,Grep,Glob -- - do it "),
         "the prompt follows `--` after the options that take lists: " & Args);
   end The_Prompt_Is_Set_Apart_From_The_Options;

   procedure Permissions_Are_The_Same_As_Headless (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      function Args_Of (Level : String) return String is
        (Joined
           (Arguments_Of
              (Claude.Build
                 (Step_Of (Permissions => Level), "P", Session_Of))));
   begin
      Assert
        (Has (Args_Of (""), "--permission-mode auto "),
         "a step with no level is left to the auto mode");
      Assert
        (Has (Args_Of ("Read_Only"), "--permission-mode dontAsk --tools "),
         "a read-only one has only the tools that read");
      Assert
        (Has (Args_Of ("Full_Access"), "--permission-mode bypassPermissions "),
         "a full-access one is not asked");
   end Permissions_Are_The_Same_As_Headless;

   procedure A_Claude_Step_Is_Never_Started_With_Add_Dir
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      procedure Check (Level : String) is
         Args : constant String :=
           Joined
             (Arguments_Of
                (Claude.Build
                   (Step_Of (Permissions => Level), "P", Session_Of)));
      begin
         Assert
           (not Has (Args, "--add-dir"),
            "no directory is added for " & Level & ": " & Args);
      end Check;
   begin
      Check ("Read_Only");
      Check ("Workspace_Write");
      Check ("Full_Access");
   end A_Claude_Step_Is_Never_Started_With_Add_Dir;

   procedure Every_Harness_Can_Run_Interactive (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      for Kind in Harnesses.Harness_Kind loop
         Assert
           (For_Harness (Kind) /= null,
            Harnesses.Name_Of (Kind) & " implements Interactive");
      end loop;
   end Every_Harness_Can_Run_Interactive;

   ---------------------------------------------------------------------------
   --  Finding the transcript
   ---------------------------------------------------------------------------

   procedure The_Transcript_Is_In_The_Folder_Named_After_The_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Plain : constant Transcript_Source :=
        Claude.Locate (Session_Of, No_Files);
      Odd   : constant Transcript_Source :=
        Claude.Locate
          (Session_Of (Directory => "/a b/my_repo.v2", Id => "x"), No_Files);
   begin
      Assert
        (Plain.Kind = From_File
         and then To_String (Plain.Path) =
                  "/home/u/.claude/projects/-work-repo/s-1.jsonl",
         "the folder is the directory with slashes as dashes");
      Assert
        (Odd.Kind = From_File
         and then To_String (Odd.Path) =
                  "/home/u/.claude/projects/-a-b-my-repo-v2/x.jsonl",
         "and so is every other character that is not a letter or a digit");
   end The_Transcript_Is_In_The_Folder_Named_After_The_Directory;

   ---------------------------------------------------------------------------
   --  Reading turns
   ---------------------------------------------------------------------------

   function Turns_Of (Transcript : String) return Turn_State is
     (Claude.Read_Turns (Transcript));

   procedure A_Turn_With_No_Answer_Yet_Is_Not_Finished
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (not Turns_Of ("").Finished, "an empty transcript");
      Assert
        (not Turns_Of (Prompt ("go")).Finished, "only the prompt");
      Assert
        (not Turns_Of (Prompt ("go") & Block ("m1", Thinking, "")).Finished,
         "an answer that has not begun");
   end A_Turn_With_No_Answer_Yet_Is_Not_Finished;

   procedure A_Turn_Ends_With_The_Message_That_Stops
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Thought : constant String :=
        Prompt ("go") & Block ("m1", Thinking, "end_turn");
      Said    : constant Turn_State :=
        Turns_Of (Thought & Block ("m1", Text ("All done."), "end_turn"));
   begin
      Assert
        (not Turns_Of (Thought).Finished,
         "thinking that stops is not an answer yet, so a read between the "
         & "two records does not report an empty final message");
      Assert (Said.Finished, "the message that stops with end_turn");
      Assert (To_String (Said.Final) = "All done.", "its text is the final");
   end A_Turn_Ends_With_The_Message_That_Stops;

   procedure Work_Before_The_Last_Message_Is_Not_The_Final_Message
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Working : constant String :=
        Prompt ("go") & Block ("m1", Text ("Looking."), "tool_use")
        & Block ("m1", Tool_Use, "tool_use") & Tool_Result;
      Said    : constant Turn_State :=
        Turns_Of (Working & Block ("m2", Text ("The answer."), "end_turn"));
   begin
      Assert
        (not Turns_Of (Working).Finished,
         "a message that stopped to use a tool and its result");
      Assert
        (Said.Finished and then To_String (Said.Final) = "The answer.",
         "only the last message is the final one");
   end Work_Before_The_Last_Message_Is_Not_The_Final_Message;

   procedure A_New_Prompt_Starts_A_New_Turn (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Done : constant String :=
        Prompt ("go") & Block ("m1", Text ("Which one?"), "end_turn");
      Next : constant Turn_State :=
        Turns_Of (Done & Prompt ("the second"));
      Last : constant Turn_State :=
        Turns_Of
          (Done & Prompt ("the second")
           & Block ("m2", Text ("Done."), "end_turn"));
   begin
      Assert (Turns_Of (Done).Finished, "the question ends the first turn");
      Assert
        (not Next.Finished and then Length (Next.Final) = 0,
         "the person's answer starts another");
      Assert
        (Last.Finished and then To_String (Last.Final) = "Done.",
         "which ends with the next message that stops");
   end A_New_Prompt_Starts_A_New_Turn;

   procedure A_Subagent_Does_Not_End_The_Turn (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Said : constant Turn_State :=
        Turns_Of
          (Prompt ("go") & Block ("m1", Tool_Use, "tool_use")
           & Block ("a1", Text ("Sub."), "end_turn", Aside => True));
   begin
      Assert
        (not Said.Finished,
         "the end of a subagent's message is not the end of the agent's turn");
   end A_Subagent_Does_Not_End_The_Turn;

   procedure A_Line_Still_Being_Written_Is_Ignored
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Done : constant String :=
        Prompt ("go") & Block ("m1", Text ("Done."), "end_turn");
      Cut  : constant String := J ("{'type':'user','isSidechain':fal");
   begin
      Assert
        (Turns_Of (Done & Cut).Finished,
         "a partial line after the end of a turn changes nothing");
      Assert
        (not Turns_Of
               (Prompt ("go")
                & Block ("m1", Text ("Done."), "end_turn")(1 .. 60)).Finished,
         "a partial line that would have ended it does not");
   end A_Line_Still_Being_Written_Is_Ignored;

   ---------------------------------------------------------------------------
   --  Codex
   ---------------------------------------------------------------------------

   function Codex_Args
     (Permissions : String := ""; Model : String := "";
      Prompt      : String := "PROMPT") return String is
     (Joined
        (Arguments_Of
           (Codex.Build
              (Step_Of (Permissions => Permissions, Model => Model), Prompt,
               Session_Of (Id => "u-1")))));

   procedure Codex_Is_Started_Interactive_In_The_Sandbox_Of_The_Level
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Made : constant Commands_Result :=
        Codex.Build (Step_Of, "PROMPT", Session_Of);
   begin
      Assert
        (To_String (Command_Of (Made).Program) = "codex", "the program");
      Assert
        (Has (Codex_Args, "-s workspace-write "),
         "a step with no level is given the workspace: " & Codex_Args);
      Assert
        (Has (Codex_Args (Permissions => "Read_Only"), "-s read-only ")
         and then Has
                    (Codex_Args (Permissions => "Full_Access"),
                     "-s danger-full-access "),
         "and the others their own sandbox");
      Assert
        (Has (Codex_Args (Model => "m1"), "-m m1 "), "the model");
      Assert
        (not Has (Codex_Args, "exec") and then not Has (Codex_Args, "--json")
         and then not Has (Codex_Args, "--ephemeral"),
         "interactive, with the session kept for its rollout");
      Assert
        (Length (Command_Of (Made).Standard_Input) = 0,
         "the harness reads the terminal, not standard input");
   end Codex_Is_Started_Interactive_In_The_Sandbox_Of_The_Level;

   procedure The_Codex_Prompt_Carries_The_Session_Marker
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Args : constant String := Codex_Args (Prompt => "- do it");
   begin
      Assert
        (Has (Args, "-- - do it" & LF & LF & "pipeline-session: u-1 "),
         "the prompt follows `--` and ends with the session's marker: "
         & Args);
   end The_Codex_Prompt_Carries_The_Session_Marker;

   Rollouts : constant String := "/home/u/.codex/sessions/2026/11/15/";

   --  A line of a rollout: the person's message, with its text.
   function Said_By (Role, Words : String) return String is
     (J ("{'type':'response_item','payload':{'type':'message','role':'"
         & Role & "','content':[{'type':'input_text','text':'" & Words
         & "'}]}}") & LF);

   function Event (What, More : String := "") return String is
     (J ("{'type':'event_msg','payload':{'type':'" & What & "'"
         & (if More = "" then "" else "," & More) & "}}") & LF);

   procedure The_Rollout_Is_The_One_Whose_Prompt_Holds_The_Marker
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Files : Synapse.Pipeline.Fake_Files.Fake_Files;
      Meta  : constant String :=
        J ("{'type':'session_meta','payload':{'id':'x'}}") & LF;
   begin
      Files.Add_File
        (Rollouts & "rollout-2026-11-15T10-00-00-a.jsonl",
         Meta & Said_By ("user", "Fix it" & "\n\npipeline-session: u-1"));
      Files.Add_File
        (Rollouts & "rollout-2026-11-15T10-00-05-b.jsonl",
         Meta & Said_By ("user", "Fix it" & "\n\npipeline-session: u-2"));
      declare
         First  : constant Transcript_Source :=
           Codex.Locate (Session_Of (Id => "u-1"), Files);
         Second : constant Transcript_Source :=
           Codex.Locate (Session_Of (Id => "u-2"), Files);
         Other  : constant Transcript_Source :=
           Codex.Locate (Session_Of (Id => "u-3"), Files);
      begin
         Assert
           (First.Kind = From_File
            and then To_String (First.Path) =
                     Rollouts & "rollout-2026-11-15T10-00-00-a.jsonl",
            "two sessions in one directory are told apart by the marker");
         Assert
           (Second.Kind = From_File
            and then To_String (Second.Path) =
                     Rollouts & "rollout-2026-11-15T10-00-05-b.jsonl",
            "each finds its own");
         Assert
           (Other.Kind = Not_Yet, "a session that has not started has none");
      end;
   end The_Rollout_Is_The_One_Whose_Prompt_Holds_The_Marker;

   procedure Only_A_Message_Of_The_Person_Can_Hold_The_Marker
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Files : Synapse.Pipeline.Fake_Files.Fake_Files;
   begin
      Files.Add_File
        (Rollouts & "rollout-2026-11-15T10-00-00-a.jsonl",
         Said_By ("assistant", "I saw pipeline-session: u-1")
         & Said_By ("developer", "pipeline-session: u-1"));
      Assert
        (Codex.Locate (Session_Of (Id => "u-1"), Files).Kind = Not_Yet,
         "the agent quoting a marker is not the person's prompt");
      Assert
        (Codex.Locate
           (Session_Of (Id => "u-1", Directory => "/x"), No_Files).Kind =
         Not_Yet,
         "and no folder for the day means no rollout");
   end Only_A_Message_Of_The_Person_Can_Hold_The_Marker;

   procedure A_Codex_Turn_Ends_At_Task_Complete (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Started : constant String := Event ("task_started");
      Done    : constant String :=
        Started & Said_By ("assistant", "Working.")
        & Event ("task_complete", "'last_agent_message':'All done.'");
   begin
      Assert (not Turns_Of ("").Finished, "an empty rollout");
      Assert (not Turns_Of (Started).Finished, "a turn that has begun");
      Assert
        (not Turns_Of (Started & Said_By ("assistant", "Working.")).Finished,
         "an agent message is not the end of the turn");
      Assert
        (Codex.Read_Turns (Done).Finished
         and then To_String (Codex.Read_Turns (Done).Final) = "All done.",
         "task_complete ends it with the agent's last message");
   end A_Codex_Turn_Ends_At_Task_Complete;

   procedure A_Codex_Prompt_Starts_Another_Turn
     (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Asked : constant String :=
        Event ("task_started")
        & Event ("task_complete", "'last_agent_message':'Which?'");
      Next  : constant Turn_State :=
        Codex.Read_Turns (Asked & Event ("task_started"));
   begin
      Assert (Codex.Read_Turns (Asked).Finished, "the question ends a turn");
      Assert
        (not Next.Finished and then Length (Next.Final) = 0,
         "and the person's answer starts the next");
   end A_Codex_Prompt_Starts_Another_Turn;

   ---------------------------------------------------------------------------
   --  OpenCode
   ---------------------------------------------------------------------------

   function Opencode_Command_Of
     (Permissions : String := ""; Model : String := "";
      Prompt      : String := "PROMPT") return Commands.Command is
     (Command_Of
        (Opencode.Build
           (Step_Of (Permissions => Permissions, Model => Model), Prompt,
            Session_Of (Id => "ab-12-cd"))));

   function Environment_Of (Made : Commands.Command) return String is
     (Joined (Made.Environment));

   procedure OpenCode_Is_Started_On_A_Private_Server_With_The_Session_Id
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Made : constant Commands.Command := Opencode_Command_Of;
      Args : constant String := Joined (Made.Arguments);
   begin
      Assert (To_String (Made.Program) = "opencode", "the program");
      Assert
        (Has (Args, "--standalone --session ses_ab12cd "),
         "a private server that reads the environment, and the runner's id as "
         & "OpenCode takes one, without dashes: " & Args);
      Assert
        (not Has (Args, "run ") and then not Has (Args, "--auto")
         and then not Has (Args, "--format"),
         "interactive, and the person is asked what is not decided: " & Args);
      Assert
        (Length (Made.Standard_Input) = 0,
         "the harness reads the terminal, not standard input");
   end OpenCode_Is_Started_On_A_Private_Server_With_The_Session_Id;

   procedure The_OpenCode_Prompt_Is_One_Argument
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Args : constant String :=
        Joined (Opencode_Command_Of (Prompt => "- do it").Arguments);
   begin
      Assert
        (Has (Args, "--prompt=- do it "),
         "a prompt that begins with a dash is not read as an option: " & Args);
   end The_OpenCode_Prompt_Is_One_Argument;

   procedure OpenCode_Permissions_And_Model_Are_In_The_Environment
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Read  : constant String :=
        Environment_Of
          (Opencode_Command_Of (Permissions => "Read_Only", Model => "p/m"));
      Plain : constant String := Environment_Of (Opencode_Command_Of);
      Full  : constant String :=
        Environment_Of (Opencode_Command_Of (Permissions => "Full_Access"));
      Named : constant String :=
        Environment_Of
          (Opencode_Command_Of (Permissions => "Full_Access", Model => "p/m"));
   begin
      Assert
        (Has (Read, "OPENCODE_CONFIG_CONTENT=")
         and then Has (Read, """bash"":""deny""")
         and then Has (Read, """model"":""p/m"""),
         "a read-only step denies edits and commands, and names its model: "
         & Read);
      Assert
        (Has (Plain, """external_directory"":""deny""")
         and then not Has (Plain, "model"),
         "the default level keeps file tools in the directory: " & Plain);
      Assert (Full = "", "a full-access step with no model sets nothing");
      Assert
        (Has (Named, "{""model"":""p/m""}"),
         "a full-access step with a model sets only the model: " & Named);
   end OpenCode_Permissions_And_Model_Are_In_The_Environment;

   procedure The_OpenCode_Transcript_Is_The_Export_Of_The_Session
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Source : constant Transcript_Source :=
        Opencode.Locate (Session_Of (Id => "ab-12-cd"), No_Files);
   begin
      Assert
        (Source.Kind = From_Command
         and then To_String (Source.Run.Program) = "opencode"
         and then Joined (Source.Run.Arguments) = "session export ses_ab12cd ",
         "the transcript is what `opencode session export` prints");
   end The_OpenCode_Transcript_Is_The_Export_Of_The_Session;

   --  The export of a session, from its messages.
   function Export (Messages : String) return String is
     (J ("{'info':{'id':'ses_x'},'messages':[" & Messages & "]}"));

   function Asked (Words : String) return String is
     (J ("{'type':'user','text':'" & Words & "','files':[]}"));

   function Answered (Content : String) return String is
     (J ("{'type':'assistant','agent':'build','content':[" & Content
         & "],'finish':'stop'}"));

   Idle : constant String := J ("{'type':'idle','outcome':'succeeded'}");

   procedure An_OpenCode_Turn_Ends_At_Idle (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Working : constant String :=
        Asked ("go") & "," & Answered (Text (Words => "Done."));
      Done    : constant Turn_State :=
        Opencode.Read_Turns (Export (Working & "," & Idle));
   begin
      Assert (not Opencode.Read_Turns ("").Finished, "nothing yet");
      Assert
        (not Opencode.Read_Turns (Export (Asked ("go"))).Finished
         and then not Opencode.Read_Turns (Export (Working)).Finished,
         "a message of the agent is not the end of the turn");
      Assert
        (Done.Finished and then To_String (Done.Final) = "Done.",
         "the idle record ends it, with the text of the last message");
   end An_OpenCode_Turn_Ends_At_Idle;

   procedure The_Last_OpenCode_Message_Is_The_Final_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Said : constant Turn_State :=
        Opencode.Read_Turns
          (Export
             (Asked ("go") & ","
              & Answered
                  (J ("{'type':'text','text':'Looking.'},"
                      & "{'type':'tool','name':'bash'}"))
              & "," & Answered (J ("{'type':'reasoning','text':''},")
                                & Text ("The answer."))
              & "," & Idle));
   begin
      Assert
        (Said.Finished and then To_String (Said.Final) = "The answer.",
         "only the last message counts, and only its text blocks");
   end The_Last_OpenCode_Message_Is_The_Final_One;

   procedure An_OpenCode_Prompt_Starts_Another_Turn
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Asked_It : constant String :=
        Asked ("go") & "," & Answered (Text ("Which?")) & "," & Idle;
      Next     : constant Turn_State :=
        Opencode.Read_Turns (Export (Asked_It & "," & Asked ("the second")));
   begin
      Assert
        (Opencode.Read_Turns (Export (Asked_It)).Finished,
         "the question ends a turn");
      Assert
        (not Next.Finished and then Length (Next.Final) = 0,
         "and the person's answer starts the next");
   end An_OpenCode_Prompt_Starts_Another_Turn;

   procedure An_Export_That_Is_Not_Whole_Is_Not_Read
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Whole : constant String :=
        Export (Asked ("go") & "," & Answered (Text ("Done.")) & "," & Idle);
   begin
      Assert
        (Opencode.Read_Turns (Whole).Finished, "the whole document is read");
      Assert
        (not Opencode.Read_Turns (Whole (Whole'First .. Whole'Last - 3))
               .Finished
         and then not Opencode.Read_Turns ("Session not found").Finished,
         "a document that is cut, or an error, says nothing");
   end An_Export_That_Is_Not_Whole_Is_Not_Read;

   ---------------------------------------------------------------------------
   --  Whether a pipeline can be run interactively
   ---------------------------------------------------------------------------

   function Pipeline_Of
     (Left, Right : Harnesses.Harness_Kind) return Resolved.Pipeline
   is
      Result : Resolved.Pipeline;
      First  : Resolved.Step;
      Second : Resolved.Step;
   begin
      First.Name := To_Unbounded_String ("Develop");
      First.Harness := Left;
      Second.Name := To_Unbounded_String ("Review");
      Second.Harness := Right;
      Result.Steps.Append (First);
      Result.Steps.Append (Second);
      return Result;
   end Pipeline_Of;

   procedure A_Step_On_A_Harness_That_Cannot_Is_Reported
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Can      : constant Support :=
        [Harnesses.Opencode => False, others => True];
      Pipeline : constant Resolved.Pipeline :=
        Pipeline_Of (Harnesses.Claude, Harnesses.Opencode);
      Said     : constant Synapse.Core.Text_Lists.Vector :=
        Problems (Pipeline, Can);
   begin
      Assert (Natural (Said.Length) = 1, "one step");
      Assert
        (To_String (Said.First_Element) =
         "step Review runs on Opencode, which cannot run a step interactively",
         "it names the step and the harness: "
         & To_String (Said.First_Element));
      Assert
        (Natural (Problems (Pipeline_Of (Harnesses.Opencode,
                                         Harnesses.Opencode), Can).Length)
         = 2,
         "each such step is reported");
   end A_Step_On_A_Harness_That_Cannot_Is_Reported;

   procedure Nothing_Is_Reported_When_Every_Harness_Can
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Problems
           (Pipeline_Of (Harnesses.Claude, Harnesses.Codex),
            [others => True]).Is_Empty,
         "every step can");
      Assert
        (Implemented = Support'(others => True),
         "every harness there is implements it, so a real pipeline passes");
      Assert
        (Problems (Pipeline_Of (Harnesses.Codex, Harnesses.Opencode)).Is_Empty,
         "and the default is the support there is");
   end Nothing_Is_Reported_When_Every_Harness_Can;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Interactive_Harnesses");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Claude_Is_Started_Interactive_With_A_Session_Id'Access,
         "Claude is started interactive with a session id");
      Register_Routine
        (T, The_Prompt_Is_Set_Apart_From_The_Options'Access,
         "The prompt is set apart from the options");
      Register_Routine
        (T, Permissions_Are_The_Same_As_Headless'Access,
         "Permissions are the same as headless");
      Register_Routine
        (T, A_Claude_Step_Is_Never_Started_With_Add_Dir'Access,
         "A Claude step is never started with --add-dir");
      Register_Routine
        (T, Every_Harness_Can_Run_Interactive'Access,
         "Every harness can run interactive");
      Register_Routine
        (T, The_Transcript_Is_In_The_Folder_Named_After_The_Directory'Access,
         "The transcript is in the folder named after the directory");
      Register_Routine
        (T, A_Turn_With_No_Answer_Yet_Is_Not_Finished'Access,
         "A turn with no answer yet is not finished");
      Register_Routine
        (T, A_Turn_Ends_With_The_Message_That_Stops'Access,
         "A turn ends with the message that stops");
      Register_Routine
        (T, Work_Before_The_Last_Message_Is_Not_The_Final_Message'Access,
         "Work before the last message is not the final message");
      Register_Routine
        (T, A_New_Prompt_Starts_A_New_Turn'Access,
         "A new prompt starts a new turn");
      Register_Routine
        (T, A_Subagent_Does_Not_End_The_Turn'Access,
         "A subagent does not end the turn");
      Register_Routine
        (T, A_Line_Still_Being_Written_Is_Ignored'Access,
         "A line still being written is ignored");
      Register_Routine
        (T, Codex_Is_Started_Interactive_In_The_Sandbox_Of_The_Level'Access,
         "Codex is started interactive in the sandbox of the level");
      Register_Routine
        (T, The_Codex_Prompt_Carries_The_Session_Marker'Access,
         "The Codex prompt carries the session marker");
      Register_Routine
        (T, The_Rollout_Is_The_One_Whose_Prompt_Holds_The_Marker'Access,
         "The rollout is the one whose prompt holds the marker");
      Register_Routine
        (T, Only_A_Message_Of_The_Person_Can_Hold_The_Marker'Access,
         "Only a message of the person can hold the marker");
      Register_Routine
        (T, A_Codex_Turn_Ends_At_Task_Complete'Access,
         "A Codex turn ends at task_complete");
      Register_Routine
        (T, A_Codex_Prompt_Starts_Another_Turn'Access,
         "A Codex prompt starts another turn");
      Register_Routine
        (T, A_Step_On_A_Harness_That_Cannot_Is_Reported'Access,
         "A step on a harness that cannot is reported");
      Register_Routine
        (T, Nothing_Is_Reported_When_Every_Harness_Can'Access,
         "Nothing is reported when every harness can");
      Register_Routine
        (T, OpenCode_Is_Started_On_A_Private_Server_With_The_Session_Id'Access,
         "OpenCode is started on a private server with the session id");
      Register_Routine
        (T, The_OpenCode_Prompt_Is_One_Argument'Access,
         "The OpenCode prompt is one argument");
      Register_Routine
        (T, OpenCode_Permissions_And_Model_Are_In_The_Environment'Access,
         "OpenCode's permissions and model are in the environment");
      Register_Routine
        (T, The_OpenCode_Transcript_Is_The_Export_Of_The_Session'Access,
         "The OpenCode transcript is the export of the session");
      Register_Routine
        (T, An_OpenCode_Turn_Ends_At_Idle'Access,
         "An OpenCode turn ends at idle");
      Register_Routine
        (T, The_Last_OpenCode_Message_Is_The_Final_One'Access,
         "The last OpenCode message is the final one");
      Register_Routine
        (T, An_OpenCode_Prompt_Starts_Another_Turn'Access,
         "An OpenCode prompt starts another turn");
      Register_Routine
        (T, An_Export_That_Is_Not_Whole_Is_Not_Read'Access,
         "An export that is not whole is not read");
   end Register_Tests;

end Synapse.Pipeline.Interactive_Harnesses.Tests;
