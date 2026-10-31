with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Session_Runner;

package body Synapse.Pipeline.Sessions.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package JSON renames Synapse.Core.JSON;

   function Value (Text : String) return JSON.Value is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Parsed.Ok, "the sample is JSON: " & Text);
      return Parsed.Item;
   end Value;

   function Step_With (Timeout : Natural) return Resolved.Step is
     (Name => To_Unbounded_String ("A"), Harness => Harnesses.Claude,
      Timeout_Seconds => Timeout, others => <>);

   function Run_At_A return States.State is
      Pipeline : Resolved.Pipeline;
   begin
      Pipeline.Name := To_Unbounded_String ("P");
      Pipeline.Steps.Append (Step_With (0));
      return Run : States.State :=
        States.Initial (Pipeline, Value ("{""task"": ""x""}"))
      do
         Run.Previous_Output := Value ("{""outcome"": ""Done""}");
      end return;
   end Run_At_A;

   procedure A_Session_Is_Asked_For_From_The_Step_And_The_Run
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Settings : Configs.Config;
   begin
      Settings.Environment.Include ("SYNAPSE_VAULT_DIR", "/vault");
      declare
         Asked : constant Session_Request :=
           Request_For (Step_With (0), Run_At_A, Settings);
      begin
         Assert
           (To_String (Asked.Step.Name) = "A"
            and then JSON.Has_Member (Asked.Initial_Input, "task")
            and then JSON.Has_Member (Asked.Previous_Output, "outcome"),
            "the step, and what the run has so far");
         Assert
           (Asked.Settings.Environment.Element ("SYNAPSE_VAULT_DIR") =
            "/vault",
            "the settings, as they are");
         Assert (Asked.Attempt = 1, "the first try");
         Assert
           (Request_For (Step_With (0), Run_At_A, Settings, 3).Attempt = 3,
            "or the one given");
      end;
   end A_Session_Is_Asked_For_From_The_Step_And_The_Run;

   procedure The_Step_Limit_Beats_The_Default (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Settings : Configs.Config;
   begin
      Settings.Default_Timeout_Seconds := 600;
      Assert
        (Request_For (Step_With (90), Run_At_A, Settings).Timeout_Seconds = 90,
         "the step's own limit");
      Assert
        (Request_For (Step_With (0), Run_At_A, Settings).Timeout_Seconds = 600,
         "none given, so the configuration's");
   end The_Step_Limit_Beats_The_Default;

   procedure A_Result_Holds_What_It_Was_Given (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Item : Envelopes.Envelope;
      Used : constant Usage_Report :=
        (Reported => True, Input_Tokens => 120, Output_Tokens => 45,
         Elapsed_Seconds => 8);
   begin
      Item.Outcome := To_Unbounded_String ("Approved");
      declare
         Done : constant Session_Result :=
           Success
             (Item, Used,
              Synapse.Core.Optional_Text.Of_Value
                (To_Unbounded_String ("/log/a.txt")));
      begin
         Assert
           (Done.Succeeded
            and then To_String (Done.Result.Outcome) = "Approved"
            and then Done.Usage = Used
            and then Done.Transcript.Found,
            "a success, with its usage and its transcript");
      end;
      declare
         Broke : constant Session_Result :=
           Failed
             ((Kind => Failures.Quota_Exhausted,
               Step => To_Unbounded_String ("A"), Message => <>,
               Reset =>
                 Synapse.Core.Optional_Text.Of_Value
                   (To_Unbounded_String ("09:00"))),
              Used);
      begin
         Assert
           (not Broke.Succeeded
            and then Broke.Failure.Kind = Failures.Quota_Exhausted
            and then Broke.Failure.Reset.Found and then Broke.Usage = Used
            and then not Broke.Transcript.Found,
            "a failure, with the reset time and the usage so far");
      end;
   end A_Result_Holds_What_It_Was_Given;

   --  A runner that answers every session the same way and keeps what it was
   --  asked.
   type Fake_Runner is limited new Session_Runner.Runner with record
      Answer : Session_Result;
      Asked  : Natural := 0;
      Last   : Session_Request;
   end record;

   overriding
   function Run_Session
     (R : in out Fake_Runner; Request : Session_Request)
      return Session_Result
   is
   begin
      R.Asked := R.Asked + 1;
      R.Last := Request;
      return R.Answer;
   end Run_Session;

   --  How the engine uses a runner: through the interface alone.
   function Ask
     (R : in out Session_Runner.Runner'Class; Request : Session_Request)
      return Session_Result is
     (R.Run_Session (Request));

   procedure A_Runner_Is_Used_Through_The_Port (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R        : Fake_Runner;
      Item     : Envelopes.Envelope;
      Settings : constant Configs.Config := (others => <>);
   begin
      Item.Outcome := To_Unbounded_String ("Done");
      R.Answer := Success (Item);
      declare
         Got : constant Session_Result :=
           Ask (R, Request_For (Step_With (0), Run_At_A, Settings));
      begin
         Assert
           (R.Asked = 1 and then To_String (R.Last.Step.Name) = "A",
            "it was asked once, for step A");
         Assert
           (Got.Succeeded and then To_String (Got.Result.Outcome) = "Done",
            "and its answer comes back");
      end;
      R.Answer :=
        Failed
          ((Kind => Failures.Execution_Error,
            Step => To_Unbounded_String ("A"),
            Message => To_Unbounded_String ("crashed"),
            Reset => <>));
      Assert
        (not Ask (R, Request_For (Step_With (0), Run_At_A, Settings)).Succeeded
         and then R.Asked = 2,
         "a failure comes back as one, and the runner is asked again");
   end A_Runner_Is_Used_Through_The_Port;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Sessions");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Session_Is_Asked_For_From_The_Step_And_The_Run'Access,
         "A session is asked for from the step and the run");
      Register_Routine
        (T, The_Step_Limit_Beats_The_Default'Access,
         "The step limit beats the default");
      Register_Routine
        (T, A_Result_Holds_What_It_Was_Given'Access,
         "A result holds what it was given");
      Register_Routine
        (T, A_Runner_Is_Used_Through_The_Port'Access,
         "A runner is used through the port");
   end Register_Tests;

end Synapse.Pipeline.Sessions.Tests;
