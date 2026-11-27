with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Fake_Process;
with Synapse.Pipeline.Fake_Registry;
with Synapse.Pipeline.Fake_Terminal;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;
with Synapse.Ports.Variables;

package body Synapse.Pipeline.Interactive_Runners.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Failures.Failure_Kind;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

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

   --  Remembers what it was told, in order.
   type Recording_Observer is limited new Attention_Observer with record
      Told : Unbounded_String;
   end record;

   overriding
   procedure Waiting
     (O : in out Recording_Observer; Step, Reason : String);

   overriding
   procedure Resumed (O : in out Recording_Observer; Step : String);

   overriding
   procedure Waiting
     (O : in out Recording_Observer; Step, Reason : String) is
   begin
      Append (O.Told, "waiting " & Step & ": " & Reason & ";");
   end Waiting;

   overriding
   procedure Resumed (O : in out Recording_Observer; Step : String) is
   begin
      Append (O.Told, "resumed " & Step & ";");
   end Resumed;

   ---------------------------------------------------------------------------
   --  Records of Claude's transcript, as the harness adapter reads them
   ---------------------------------------------------------------------------

   Transcript : constant String :=
     "/home/u/.claude/projects/-work-tree/u-1.jsonl";

   function Asked (Words : String) return String is
     (J ("{'type':'user','isSidechain':false,"
         & "'message':{'role':'user','content':'" & Words & "'}}") & LF);

   function Said (Id, Words, Stop : String) return String is
     (J ("{'type':'assistant','isSidechain':false,'message':{'id':'" & Id
         & "','role':'assistant','content':[{'type':'text','text':'" & Words
         & "'}],'stop_reason':'" & Stop & "'}}") & LF);

   --  An answer that is a result: the words are the JSON, quoted for JSON.
   function Result_Said (Id, Outcome : String) return String is
     (Said (Id,
            "{\""outcome\"":\""" & Outcome
            & "\"",\""summary\"":\""did it\"",\""data\"":{}}",
            "end_turn"));

   function Tick (Path, Text : String; Ends : Boolean := False)
      return Fake_Terminal.Tick is
     (Path => To_Unbounded_String (Path), Text => To_Unbounded_String (Text),
      Ends => Ends, Code => 0);

   function Step_Of
     (Harness : Harnesses.Harness_Kind := Harnesses.Claude)
      return Resolved.Step
   is
      Result : Resolved.Step;
   begin
      Result.Name := To_Unbounded_String ("Develop");
      Result.Harness := Harness;
      Result.Assignment :=
        (Present => True,
         Text => To_Unbounded_String ("Implement the feature."));
      return Result;
   end Step_Of;

   function Request_Of
     (Step : Resolved.Step; Seconds : Positive := 90)
      return Sessions.Session_Request
   is
      Result : Sessions.Session_Request;
   begin
      Result.Step := Step;
      Result.Settings.Working_Directory := To_Unbounded_String ("/work/tree");
      Result.Initial_Input := JSON.Null_Value;
      Result.Previous_Output := JSON.Null_Value;
      Result.Timeout_Seconds := Seconds;
      return Result;
   end Request_Of;

   --  A HOME and a USERPROFILE, either of which may be unset.
   type Two_Variables is limited new Synapse.Ports.Variables.Variables
   with record
      Home    : Unbounded_String;
      Profile : Unbounded_String;
   end record;

   overriding
   function Get (V : Two_Variables; Name : String)
      return Synapse.Ports.Variables.Maybe_Value is
     (if Name = "HOME" and then Length (V.Home) > 0
      then Synapse.Core.Optional_Text.Of_Value (V.Home)
      elsif Name = "USERPROFILE" and then Length (V.Profile) > 0
      then Synapse.Core.Optional_Text.Of_Value (V.Profile)
      else Synapse.Core.Optional_Text.None);

   procedure The_Home_Directory_Is_HOME_Or_USERPROFILE
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Both   : constant Two_Variables :=
        (Home    => To_Unbounded_String ("/home/u"),
         Profile => To_Unbounded_String ("C:\Users\u"));
      Only   : constant Two_Variables :=
        (Home    => Null_Unbounded_String,
         Profile => To_Unbounded_String ("C:\Users\u"));
      Nobody : constant Two_Variables := (others => Null_Unbounded_String);
   begin
      Assert (To_String (Home_Of (Both)) = "/home/u", "HOME comes first");
      Assert
        (To_String (Home_Of (Only)) = "C:\Users\u",
         "USERPROFILE where Windows has no HOME");
      Assert (Length (Home_Of (Nobody)) = 0, "and nothing when neither is set");
   end The_Home_Directory_Is_HOME_Or_USERPROFILE;

   --  The pieces a runner is made of.
   type World is limited record
      Files    : aliased Fake_Files.Fake_Files;
      Process  : aliased Fake_Process.Fake_Process;
      Registry : aliased Fake_Registry.Fake_Registry;
      Observer : aliased Recording_Observer;
   end record;

   ---------------------------------------------------------------------------

   procedure A_Valid_Result_Ends_The_Session_And_Stops_The_Harness
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W        : World;
      Terminal : aliased Fake_Terminal.Fake_Terminal;
      Runner   : Interactive_Runner
        (W.Process'Access, Terminal'Access, W.Files'Access,
         W.Registry'Access);
   begin
      Terminal.Files := W.Files'Unchecked_Access;
      Runner.Home := To_Unbounded_String ("/home/u");
      Runner.Session_Id := To_Unbounded_String ("u-1");
      Runner.Poll := 0.0;
      Runner.Observer := W.Observer'Unchecked_Access;
      Terminal.Ticks.Append
        (Tick
           (Transcript, Asked ("go") & Said ("m1", "Working.", "tool_use")));
      Terminal.Ticks.Append (Tick (Transcript, Result_Said ("m2", "Done")));
      declare
         Got  : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step_Of));
         Args : constant String :=
           (if Terminal.Requests.Is_Empty then ""
            else To_String (Terminal.Requests.First_Element.Arguments (1)));
      begin
         Assert (Got.Succeeded, "the session succeeded");
         Assert
           (To_String (Got.Result.Outcome) = "Done",
            "with the outcome the agent gave");
         Assert (Terminal.Stopped, "and the harness was stopped");
         Assert (Length (W.Observer.Told) = 0, "nobody was waited for");
         Assert
           (Natural (Terminal.Requests.Length) = 1
            and then To_String (Terminal.Requests.First_Element.Program) =
                     "claude"
            and then To_String (Terminal.Requests.First_Element.Directory) =
                     "/work/tree"
            and then Args = "--session-id",
            "claude was started in the working directory with the session id");
      end;
   end A_Valid_Result_Ends_The_Session_And_Stops_The_Harness;

   procedure A_Prompt_Definition_Is_Sent_As_Its_Text
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W        : World;
      Terminal : aliased Fake_Terminal.Fake_Terminal;
      Runner   : Interactive_Runner
        (W.Process'Access, Terminal'Access, W.Files'Access,
         W.Registry'Access);
      Step     : Resolved.Step := Step_Of;
   begin
      --  What resolution leaves of `Prompt => Review_Code`: the text of the
      --  Prompt definition.
      Step.Assignment :=
        (Present => True,
         Text => To_Unbounded_String ("Review it carefully."));
      Terminal.Files := W.Files'Unchecked_Access;
      Runner.Home := To_Unbounded_String ("/home/u");
      Runner.Session_Id := To_Unbounded_String ("u-1");
      Runner.Poll := 0.0;
      Terminal.Ticks.Append (Tick (Transcript, Result_Said ("m1", "Done")));
      declare
         Got  : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step));
         Args : Unbounded_String;
      begin
         Assert (Got.Succeeded, "the session succeeded");
         if not Terminal.Requests.Is_Empty then
            for A of Terminal.Requests.First_Element.Arguments loop
               Append (Args, To_String (A) & " ");
            end loop;
         end if;
         Assert
           (Has (To_String (Args), "Review it carefully."),
            "the prompt's text is the first message: " & To_String (Args));
         Assert
           (not Has (To_String (Args), "--add-dir"),
            "and no directory is added");
      end;
   end A_Prompt_Definition_Is_Sent_As_Its_Text;

   procedure A_Turn_Without_A_Result_Is_Waiting_For_The_Person
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W        : World;
      Terminal : aliased Fake_Terminal.Fake_Terminal;
      Runner   : Interactive_Runner
        (W.Process'Access, Terminal'Access, W.Files'Access,
         W.Registry'Access);
   begin
      Terminal.Files := W.Files'Unchecked_Access;
      Runner.Home := To_Unbounded_String ("/home/u");
      Runner.Session_Id := To_Unbounded_String ("u-1");
      Runner.Poll := 0.0;
      Runner.Observer := W.Observer'Unchecked_Access;
      Terminal.Ticks.Append
        (Tick
           (Transcript,
            Asked ("go") & Said ("m1", "Which one?", "end_turn")));
      Terminal.Ticks.Append (Tick ("", ""));
      Terminal.Ticks.Append (Tick (Transcript, Asked ("the blue one")));
      Terminal.Ticks.Append (Tick (Transcript, Result_Said ("m2", "Done")));
      declare
         Got : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step_Of));
      begin
         Assert (Got.Succeeded, "the session went on and succeeded");
         Assert
           (To_String (W.Observer.Told) =
            "waiting Develop: Which one?;resumed Develop;",
            "it was waiting once, however long, and then working again: "
            & To_String (W.Observer.Told));
      end;
   end A_Turn_Without_A_Result_Is_Waiting_For_The_Person;

   procedure A_Result_After_Waiting_Ends_The_Waiting
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W        : World;
      Terminal : aliased Fake_Terminal.Fake_Terminal;
      Runner   : Interactive_Runner
        (W.Process'Access, Terminal'Access, W.Files'Access,
         W.Registry'Access);
   begin
      Terminal.Files := W.Files'Unchecked_Access;
      Runner.Home := To_Unbounded_String ("/home/u");
      Runner.Session_Id := To_Unbounded_String ("u-1");
      Runner.Poll := 0.0;
      Runner.Observer := W.Observer'Unchecked_Access;
      Terminal.Ticks.Append
        (Tick
           (Transcript,
            Asked ("go") & Said ("m1", "Which one?", "end_turn")));
      Terminal.Ticks.Append
        (Tick (Transcript, Asked ("blue") & Result_Said ("m2", "Done")));
      declare
         Got : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step_Of));
      begin
         Assert (Got.Succeeded, "the session succeeded");
         Assert
           (To_String (W.Observer.Told) =
            "waiting Develop: Which one?;resumed Develop;",
            "the person's answer and the result came between two looks, "
            & "and the waiting still ended: " & To_String (W.Observer.Told));
      end;
   end A_Result_After_Waiting_Ends_The_Waiting;

   procedure A_Harness_That_Ends_Without_A_Result_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W        : World;
      Terminal : aliased Fake_Terminal.Fake_Terminal;
      Runner   : Interactive_Runner
        (W.Process'Access, Terminal'Access, W.Files'Access,
         W.Registry'Access);
   begin
      Terminal.Files := W.Files'Unchecked_Access;
      Runner.Home := To_Unbounded_String ("/home/u");
      Runner.Session_Id := To_Unbounded_String ("u-1");
      Runner.Poll := 0.0;
      Terminal.Ticks.Append
        (Tick
           (Transcript, Asked ("go") & Said ("m1", "Working.", "tool_use")));
      Terminal.Ticks.Append (Tick ("", "", Ends => True));
      declare
         Got : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step_Of));
      begin
         Assert
           (not Got.Succeeded
            and then Got.Failure.Kind = Failures.Execution_Error
            and then Has (To_String (Got.Failure.Message), "ended without a"),
            "it is an execution error that says so");
         Assert
           (To_String (Got.Failure.Step) = "Develop", "in the step");
      end;
   end A_Harness_That_Ends_Without_A_Result_Fails;

   procedure A_Session_Past_Its_Limit_Is_Stopped (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W        : World;
      Terminal : aliased Fake_Terminal.Fake_Terminal;
      Runner   : Interactive_Runner
        (W.Process'Access, Terminal'Access, W.Files'Access,
         W.Registry'Access);
   begin
      Terminal.Files := W.Files'Unchecked_Access;
      Runner.Home := To_Unbounded_String ("/home/u");
      Runner.Session_Id := To_Unbounded_String ("u-1");
      Runner.Poll := 0.2;
      declare
         Got : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step_Of, Seconds => 1));
      begin
         Assert
           (not Got.Succeeded
            and then Has (To_String (Got.Failure.Message), "timed out after"),
            "it timed out");
         Assert (Terminal.Stopped, "and the harness was stopped");
      end;
   end A_Session_Past_Its_Limit_Is_Stopped;

   procedure A_Harness_That_Cannot_Be_Started_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W        : World;
      Terminal : aliased Fake_Terminal.Fake_Terminal;
      Runner   : Interactive_Runner
        (W.Process'Access, Terminal'Access, W.Files'Access,
         W.Registry'Access);
   begin
      Terminal.Files := W.Files'Unchecked_Access;
      Terminal.Refusal := To_Unbounded_String ("'claude' was not found");
      declare
         Got : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step_Of));
      begin
         Assert
           (not Got.Succeeded
            and then To_String (Got.Failure.Message) =
                     "cannot run Claude: 'claude' was not found",
            "it says which harness and why");
      end;
   end A_Harness_That_Cannot_Be_Started_Fails;

   procedure The_Transcript_Of_OpenCode_Is_The_Output_Of_A_Command
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W        : World;
      Terminal : aliased Fake_Terminal.Fake_Terminal;
      Runner   : Interactive_Runner
        (W.Process'Access, Terminal'Access, W.Files'Access,
         W.Registry'Access);

      function Export (Messages : String) return String is
        (J ("{'info':{},'messages':[" & Messages & "]}"));

      Asked_It : constant String :=
        J ("{'type':'user','text':'go','files':[]}");
      Answer   : constant String :=
        J ("{'type':'assistant','content':[{'type':'text','text':"
           & "'{\""outcome\"":\""Done\"",\""summary\"":\""s\"","
           & "\""data\"":{}}'}]}");
      Idle     : constant String :=
        J ("{'type':'idle','outcome':'succeeded'}");
   begin
      Terminal.Files := W.Files'Unchecked_Access;
      Runner.Session_Id := To_Unbounded_String ("x1");
      Runner.Poll := 0.0;
      W.Process.Outcomes.Append (Fake_Process.Exited (Export ("")));
      W.Process.Outcomes.Append (Fake_Process.Exited (Export (Asked_It)));
      W.Process.Outcomes.Append
        (Fake_Process.Exited (Export (Asked_It & "," & Answer & "," & Idle)));
      declare
         Got : constant Sessions.Session_Result :=
           Runner.Run_Session (Request_Of (Step_Of (Harnesses.Opencode)));
      begin
         Assert (Got.Succeeded, "the session succeeded");
         Assert
           (Natural (W.Process.Requests.Length) = 3,
            "each look ran a command");
         declare
            First : constant Session_Process.Process_Request :=
              W.Process.Requests (1);
         begin
            Assert
              (To_String (First.Program) = "opencode"
               and then Has (To_String (First.Arguments (2)), "export"),
               "`opencode session export`");
         end;
         Assert (Terminal.Stopped, "and the harness was stopped");
      end;
   end The_Transcript_Of_OpenCode_Is_The_Output_Of_A_Command;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Interactive_Runners");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Home_Directory_Is_HOME_Or_USERPROFILE'Access,
         "The home directory is HOME or USERPROFILE");
      Register_Routine
        (T, A_Valid_Result_Ends_The_Session_And_Stops_The_Harness'Access,
         "A valid result ends the session and stops the harness");
      Register_Routine
        (T, A_Prompt_Definition_Is_Sent_As_Its_Text'Access,
         "A step whose prompt came from a Prompt definition is sent that "
         & "text");
      Register_Routine
        (T, A_Turn_Without_A_Result_Is_Waiting_For_The_Person'Access,
         "A turn without a result is waiting for the person");
      Register_Routine
        (T, A_Result_After_Waiting_Ends_The_Waiting'Access,
         "A result after waiting ends the waiting");
      Register_Routine
        (T, A_Harness_That_Ends_Without_A_Result_Fails'Access,
         "A harness that ends without a result fails");
      Register_Routine
        (T, A_Session_Past_Its_Limit_Is_Stopped'Access,
         "A session past its limit is stopped");
      Register_Routine
        (T, A_Harness_That_Cannot_Be_Started_Fails'Access,
         "A harness that cannot be started fails");
      Register_Routine
        (T, The_Transcript_Of_OpenCode_Is_The_Output_Of_A_Command'Access,
         "The transcript of OpenCode is the output of a command");
   end Register_Tests;

end Synapse.Pipeline.Interactive_Runners.Tests;
