with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;

package body Synapse.Pipeline.Contexts.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Initial_State return States.State is
      Pipeline : Resolved.Pipeline;
   begin
      Pipeline.Name := To_Unbounded_String ("P");
      Pipeline.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String ("A"), Harness => Harnesses.Claude,
            others => <>));
      return States.Initial (Pipeline, Synapse.Core.JSON.Null_Value);
   end Initial_State;

   procedure A_Context_Holds_The_Run_It_Was_Started_With
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context : Execution_Context;
   begin
      Context.Start ("exec-7", Initial_State);
      declare
         Seen : constant Inspection.Snapshot := Context.Current;
      begin
         Assert
           (To_String (Seen.Execution_Id) = "exec-7"
            and then To_String (Seen.Run.Current_Step) = "A"
            and then Seen.Events.Is_Empty,
            "its identity, where it is, and nothing yet happened");
      end;
   end A_Context_Holds_The_Run_It_Was_Started_With;

   procedure A_Published_State_Replaces_The_Last (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context : Execution_Context;
      Later   : States.State := Initial_State;
   begin
      Context.Start ("exec-1", Initial_State);
      declare
         Before : constant Inspection.Snapshot := Context.Current;
      begin
         Later.Steps_Run := 5;
         Context.Publish (Later);
         Assert (Context.Current.Run.Steps_Run = 5, "the new state is seen");
         Assert
           (Before.Run.Steps_Run = 0,
            "a snapshot taken earlier does not change");
      end;
   end A_Published_State_Replaces_The_Last;

   procedure Events_Are_Numbered_And_The_Oldest_Forgotten
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context : Execution_Context;
   begin
      Context.Start ("exec-1", Initial_State);
      Context.Record_Event
        ("run.started", "A", Synapse.Core.JSON.Null_Value);
      Context.Record_Event
        ("step.started", "A", Synapse.Core.JSON.Null_Value);
      declare
         --  Taken once: a vector inside a function result is indexed only
         --  while the result is still there.
         Seen : constant Inspection.Snapshot := Context.Current;
      begin
         Assert
           (Seen.Events (1).Sequence = 1 and then Seen.Events (2).Sequence = 2
            and then To_String (Seen.Events (2).Kind) = "step.started",
            "numbered in order from 1");
      end;
      for N in 3 .. 250 loop
         Context.Record_Event
           ("step.started", "A", Synapse.Core.JSON.Null_Value);
      end loop;
      declare
         Seen : constant Inspection.Snapshot := Context.Current;
      begin
         Assert
           (Natural (Seen.Events.Length) = Inspection.Max_Events,
            "no more than the most kept");
         Assert
           (Seen.Events.First_Element.Sequence = 51
            and then Seen.Events.Last_Element.Sequence = 250,
            "the oldest are the ones forgotten, and numbers go on");
      end;
      Context.Start ("exec-2", Initial_State);
      Assert
        (Context.Current.Events.Is_Empty,
         "starting again clears them");
   end Events_Are_Numbered_And_The_Oldest_Forgotten;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Contexts");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Context_Holds_The_Run_It_Was_Started_With'Access,
         "A context holds the run it was started with");
      Register_Routine
        (T, A_Published_State_Replaces_The_Last'Access,
         "A published state replaces the last");
      Register_Routine
        (T, Events_Are_Numbered_And_The_Oldest_Forgotten'Access,
         "Events are numbered and the oldest forgotten");
   end Register_Tests;

end Synapse.Pipeline.Contexts.Tests;
