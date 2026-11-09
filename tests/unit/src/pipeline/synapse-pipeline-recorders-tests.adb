with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Fake_Registry;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Inspection;
with Synapse.Pipeline.Resolved;

package body Synapse.Pipeline.Recorders.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;
   use type States.Run_Status;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  A clock that says a different time each time it is asked.
   Ticks : Natural := 0;

   type Counting_Clock is limited new Synapse.Ports.Clock.Clock
   with null record;

   overriding
   function Timestamp (C : Counting_Clock) return String;

   overriding
   function Timestamp (C : Counting_Clock) return String is
      pragma Unreferenced (C);
   begin
      Ticks := Ticks + 1;
      return "2026-11-04T12:00:0" & Character'Val (48 + Ticks mod 10)
        & "+00:00";
   end Timestamp;

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

   function Summary_Of
     (F : Fake_Registry.Fake_Registry; Id : String) return JSON.Value
   is
      Held : constant Registry_Store.Maybe_Content := F.Read_Summary (Id);
   begin
      Assert (Held.Found, "there is a summary");
      return JSON.Parse (To_String (Held.Value)).Item;
   end Summary_Of;

   function Text (V : JSON.Value; Key : String) return String is
     (if JSON.Kind_Of (JSON.Member_Value (V, Key)) = JSON.JSON_String
      then JSON.As_String (JSON.Member_Value (V, Key))
      else "<" & JSON.Kind_Of (JSON.Member_Value (V, Key))'Image & ">");

   procedure A_Run_Is_Recorded_From_Its_Start (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Context : aliased Contexts.Execution_Context;
      Store   : aliased Fake_Registry.Fake_Registry;
      Clock   : aliased Counting_Clock;
      R       : Recorder (Context'Access, Store'Access, Clock'Access);
   begin
      Ticks := 0;
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      declare
         S : constant JSON.Value := Summary_Of (Store, "exec-1");
      begin
         Assert (Text (S, "format") = Format, "the format");
         Assert
           (Text (S, "id") = "exec-1" and then Text (S, "pipeline") = "P",
            "who it is");
         Assert
           (Text (S, "status") = "running"
            and then Text (S, "current_step") = "A",
            "where it is");
         Assert
           (Text (S, "started") = "2026-11-04T12:00:01+00:00"
            and then JSON.Kind_Of (JSON.Member_Value (S, "ended")) =
                     JSON.JSON_Null,
            "when it began, and it has not ended");
         Assert
           (Text (JSON.Member_Value (S, "state"), "status") = "running",
            "with the state beside it");
      end;
      Assert
        (To_String (Context.Current.Execution_Id) = "exec-1",
         "the context knows the run too");
   end A_Run_Is_Recorded_From_Its_Start;

   procedure Events_Are_Kept_As_The_Socket_Gives_Them
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context : aliased Contexts.Execution_Context;
      Store   : aliased Fake_Registry.Fake_Registry;
      Clock   : aliased Counting_Clock;
      R       : Recorder (Context'Access, Store'Access, Clock'Access);
      LF      : constant Character := Character'Val (10);
      Seen    : Inspection.Event_Vectors.Vector;
   begin
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      R.Record_Event ("run.started", "A", JSON.Null_Value);
      R.Record_Event ("step.started", "A", JSON.Null_Value);
      Seen := Context.Current.Events;
      declare
         Held : constant Registry_Store.Maybe_Content :=
           Store.Read_Events ("exec-1");
      begin
         Assert (Held.Found, "the events are kept");
         Assert
           (To_String (Held.Value) =
            JSON.To_String (Inspection.Event_JSON (Seen (1))) & LF
            & JSON.To_String (Inspection.Event_JSON (Seen (2))) & LF,
            "one line each, in order, as the socket would give them: "
            & To_String (Held.Value));
      end;
   end Events_Are_Kept_As_The_Socket_Gives_Them;

   procedure A_Run_That_Ends_Is_Recorded_As_Ended
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context : aliased Contexts.Execution_Context;
      Store   : aliased Fake_Registry.Fake_Registry;
      Clock   : aliased Counting_Clock;
      R       : Recorder (Context'Access, Store'Access, Clock'Access);
      Done    : States.State := Initial_State;
   begin
      Ticks := 0;
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Start ("exec-1", True, JSON.Null_Value, Done);
      Done.Status := States.Completed;
      Done.Current_Step := Null_Unbounded_String;
      R.Publish (Done);
      declare
         S : constant JSON.Value := Summary_Of (Store, "exec-1");
      begin
         Assert
           (Text (S, "status") = "completed"
            and then JSON.Kind_Of (JSON.Member_Value (S, "current_step")) =
                     JSON.JSON_Null,
            "it is completed and has no step");
         Assert
           (Text (S, "started") = "2026-11-04T12:00:01+00:00"
            and then Text (S, "ended") = "2026-11-04T12:00:02+00:00",
            "it began and ended at the times the clock gave");
      end;
      Assert
        (Context.Current.Run.Status = States.Completed,
         "and the context has the new state");
   end A_Run_That_Ends_Is_Recorded_As_Ended;

   procedure A_Run_Without_A_Directory_Is_Only_Held_By_The_Context
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context : aliased Contexts.Execution_Context;
      Store   : aliased Fake_Registry.Fake_Registry;
      Clock   : aliased Counting_Clock;
      R       : Recorder (Context'Access, Store'Access, Clock'Access);
   begin
      R.Start ("exec-1", False, JSON.Null_Value, Initial_State);
      R.Record_Event ("run.started", "A", JSON.Null_Value);
      Assert (Store.Held.Is_Empty, "nothing is written");
      Assert
        (Natural (Context.Current.Events.Length) = 1,
         "and the context has the event");
   end A_Run_Without_A_Directory_Is_Only_Held_By_The_Context;

   procedure A_Registry_That_Cannot_Write_Does_Not_Stop_The_Run
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context : aliased Contexts.Execution_Context;
      Store   : aliased Fake_Registry.Fake_Registry;
      Clock   : aliased Counting_Clock;
      R       : Recorder (Context'Access, Store'Access, Clock'Access);
      Later   : States.State := Initial_State;
   begin
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      Store.Fail (Fake_Registry.Replace_Op);
      Store.Fail (Fake_Registry.Append_Op);
      R.Start ("exec-1", True, JSON.Null_Value, Later);
      R.Record_Event ("run.started", "A", JSON.Null_Value);
      Later.Status := States.Failed;
      R.Publish (Later);
      Assert
        (not Store.Read_Summary ("exec-1").Found
         and then not Store.Read_Events ("exec-1").Found,
         "nothing was written");
      Assert
        (Context.Current.Run.Status = States.Failed
         and then Natural (Context.Current.Events.Length) = 1,
         "and the context is as if it had been");
   end A_Registry_That_Cannot_Write_Does_Not_Stop_The_Run;

   procedure What_The_Run_Ran_Is_Kept_With_Its_Record
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context : aliased Contexts.Execution_Context;
      Store   : aliased Fake_Registry.Fake_Registry;
      Clock   : aliased Counting_Clock;
      R       : Recorder (Context'Access, Store'Access, Clock'Access);
   begin
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Start
        ("exec-1", True, JSON.Parse ("{""name"":""P""}").Item,
         Initial_State);
      R.Record_Definition ("synapse-pipeline/P.synapse", "Pipeline P {}");
      Assert
        (Store.Read_Description ("exec-1").Found
         and then To_String (Store.Read_Description ("exec-1").Value) =
                  "{""name"":""P""}",
         "the description is kept as the run began with it");
      Assert
        (Store.Read_Definition ("exec-1", "synapse-pipeline/P.synapse").Found
         and then To_String
                    (Store.Read_Definition
                       ("exec-1", "synapse-pipeline/P.synapse").Value) =
                  "Pipeline P {}",
         "and so is a definition file");
   end What_The_Run_Ran_Is_Kept_With_Its_Record;

   procedure A_Run_Without_A_Directory_Keeps_Nothing_Of_What_It_Ran
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context : aliased Contexts.Execution_Context;
      Store   : aliased Fake_Registry.Fake_Registry;
      Clock   : aliased Counting_Clock;
      R       : Recorder (Context'Access, Store'Access, Clock'Access);
   begin
      R.Start
        ("exec-1", False, JSON.Parse ("{""name"":""P""}").Item,
         Initial_State);
      R.Record_Definition ("synapse-pipeline/P.synapse", "Pipeline P {}");
      Assert
        (Store.Held.Is_Empty
         and then Store.Attempts (Fake_Registry.Description_Op) = 0
         and then Store.Attempts (Fake_Registry.Definition_Op) = 0,
         "nothing is written and nothing is tried");
   end A_Run_Without_A_Directory_Keeps_Nothing_Of_What_It_Ran;

   procedure A_Registry_That_Cannot_Keep_What_The_Run_Ran_Does_Not_Stop_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context : aliased Contexts.Execution_Context;
      Store   : aliased Fake_Registry.Fake_Registry;
      Clock   : aliased Counting_Clock;
      R       : Recorder (Context'Access, Store'Access, Clock'Access);
   begin
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      Store.Fail (Fake_Registry.Description_Op);
      Store.Fail (Fake_Registry.Definition_Op);
      R.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      R.Record_Definition ("synapse-pipeline/P.synapse", "Pipeline P {}");
      Assert
        (not Store.Read_Description ("exec-1").Found
         and then not Store.Read_Definition
                        ("exec-1", "synapse-pipeline/P.synapse").Found,
         "nothing was written");
      Assert
        (Store.Read_Summary ("exec-1").Found
         and then Context.Current.Run.Status = States.Running,
         "and the summary and the run are as they would have been");
   end A_Registry_That_Cannot_Keep_What_The_Run_Ran_Does_Not_Stop_It;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Recorders");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Run_Is_Recorded_From_Its_Start'Access,
         "A run is recorded from its start");
      Register_Routine
        (T, Events_Are_Kept_As_The_Socket_Gives_Them'Access,
         "Events are kept as the socket gives them");
      Register_Routine
        (T, A_Run_That_Ends_Is_Recorded_As_Ended'Access,
         "A run that ends is recorded as ended");
      Register_Routine
        (T, A_Run_Without_A_Directory_Is_Only_Held_By_The_Context'Access,
         "A run without a directory is only held by the context");
      Register_Routine
        (T, A_Registry_That_Cannot_Write_Does_Not_Stop_The_Run'Access,
         "A registry that cannot write does not stop the run");
      Register_Routine
        (T, What_The_Run_Ran_Is_Kept_With_Its_Record'Access,
         "What the run ran is kept with its record");
      Register_Routine
        (T, A_Run_Without_A_Directory_Keeps_Nothing_Of_What_It_Ran'Access,
         "A run without a directory keeps nothing of what it ran");
      Register_Routine
        (T,
         A_Registry_That_Cannot_Keep_What_The_Run_Ran_Does_Not_Stop_It'Access,
         "A registry that cannot keep what the run ran does not stop it");
   end Register_Tests;

end Synapse.Pipeline.Recorders.Tests;
