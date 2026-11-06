with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Contexts;
with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Fake_Registry;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.States;
with Synapse.Pipeline.Sessions;
with Synapse.Ports.Clock;

package body Synapse.Pipeline.Recording_Runners.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   type Fixed_Clock is limited new Synapse.Ports.Clock.Clock with null record;

   overriding
   function Timestamp (C : Fixed_Clock) return String is
     ("2026-11-04T12:00:00+00:00");

   --  A runner that answers with the same result every time and keeps the
   --  request it was last given.
   type Stub_Runner is limited new Session_Runner.Runner with record
      Answer : Sessions.Session_Result;
      Seen   : Sessions.Session_Request;
   end record;

   overriding
   function Run_Session
     (R       : in out Stub_Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result is
   begin
      R.Seen := Request;
      return R.Answer;
   end Run_Session;

   function Initial_State return States.State is
      Pipeline : Resolved.Pipeline;
   begin
      Pipeline.Name := To_Unbounded_String ("P");
      Pipeline.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String ("A"), Harness => Harnesses.Claude,
            others => <>));
      return States.Initial (Pipeline, JSON.Null_Value);
   end Initial_State;

   function Request_For_A (Attempt : Positive) return Sessions.Session_Request
   is
      Result : Sessions.Session_Request;
   begin
      Result.Step.Name := To_Unbounded_String ("A");
      Result.Attempt := Attempt;
      return Result;
   end Request_For_A;

   function Events_Text (Context : Contexts.Execution_Context) return String is
      Text : Unbounded_String;
   begin
      for Item of Context.Current.Events loop
         Append (Text, JSON.To_String (Item.Detail) & "|");
      end loop;
      return To_String (Text);
   end Events_Text;

   procedure A_Session_Is_Stamped_And_Recorded (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      R        : Recording_Runner (Inner'Access, Recorder'Access);
   begin
      Inner.Answer :=
        Sessions.Success
          (Envelopes.Envelope'(others => <>),
           Transcript =>
             Synapse.Core.Optional_Text.Of_Value
               (To_Unbounded_String ("/w/exec-1/transcripts/1-A-2.jsonl")));
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", False, JSON.Null_Value, Initial_State);
      declare
         Got : constant Sessions.Session_Result :=
           R.Run_Session (Request_For_A (2));
      begin
         Assert (Got.Succeeded, "the inner runner's answer comes back");
      end;
      Assert
        (To_String (Inner.Seen.Execution_Id) = "exec-1",
         "the request it was given names the execution");
      Assert
        (Events_Text (Context) =
         "{""attempt"":2,""succeeded"":true,"
         & """transcript"":""/w/exec-1/transcripts/1-A-2.jsonl""}|",
         "and the session is an event: " & Events_Text (Context));
      Assert
        (To_String (Context.Current.Events.First_Element.Step) = "A"
         and then To_String (Context.Current.Events.First_Element.Kind) =
                  "session.finished",
         "of the kind and for the step");
   end A_Session_Is_Stamped_And_Recorded;

   procedure A_Session_That_Fails_Is_Recorded_Too
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      R        : Recording_Runner (Inner'Access, Recorder'Access);
   begin
      Inner.Answer :=
        Sessions.Failed (Failures.Failure'(others => <>));
      Recorder.Start ("exec-1", False, JSON.Null_Value, Initial_State);
      declare
         Got : constant Sessions.Session_Result :=
           R.Run_Session (Request_For_A (1));
      begin
         Assert (not Got.Succeeded, "it failed");
      end;
      Assert
        (Events_Text (Context) =
         "{""attempt"":1,""succeeded"":false,""transcript"":null}|",
         "and the event says so: " & Events_Text (Context));
   end A_Session_That_Fails_Is_Recorded_Too;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Recording_Runners");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Session_Is_Stamped_And_Recorded'Access,
         "A session is stamped and recorded");
      Register_Routine
        (T, A_Session_That_Fails_Is_Recorded_Too'Access,
         "A session that fails is recorded too");
   end Register_Tests;

end Synapse.Pipeline.Recording_Runners.Tests;
