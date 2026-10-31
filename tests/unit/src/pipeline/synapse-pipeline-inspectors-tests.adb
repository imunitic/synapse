with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Fake_Transport;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.States;

package body Synapse.Pipeline.Inspectors.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package JSON renames Synapse.Core.JSON;

   function Initial_State return States.State is
      Pipeline : Resolved.Pipeline;
   begin
      Pipeline.Name := To_Unbounded_String ("P");
      Pipeline.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String ("A"), Harness => Harnesses.Claude,
            others => <>));
      Pipeline.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String ("B"), Harness => Harnesses.Claude,
            others => <>));
      return States.Initial (Pipeline, JSON.Null_Value);
   end Initial_State;

   --  Waits, up to about two seconds, until the fake has given N answers.
   procedure Wait_For
     (Box : Fake_Transport.Mailbox; N : Positive) is
   begin
      for Try in 1 .. 400 loop
         exit when Box.Answered >= N;
         delay 0.005;
      end loop;
   end Wait_For;

   function Current_Step_In (Reply : String) return String is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Reply);
   begin
      Assert (Parsed.Ok, "the answer is JSON: " & Reply);
      return JSON.As_String
        (JSON.Member_Value
           (JSON.Member_Value (Parsed.Item, "result"), "current_step"));
   end Current_Step_In;

   procedure A_Client_Is_Answered_From_The_Live_Run
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Transport : Fake_Transport.Fake_Transport;
      Context   : aliased Contexts.Execution_Context;
      Listening : Boolean := False;

      procedure Action (Is_Listening : Boolean; Reason : String) is
         pragma Unreferenced (Reason);
         Moved : States.State := Initial_State;
      begin
         Listening := Is_Listening;
         Context.Start ("exec-1", Initial_State);
         Transport.Box.Put ("{""command"":""info""}");
         Wait_For (Transport.Box, 1);
         Moved.Current_Step := To_Unbounded_String ("B");
         Moved.Steps_Run := 1;
         Context.Publish (Moved);
         Context.Record_Event ("step.finished", "A", JSON.Null_Value);
         Transport.Box.Put ("{""command"":""info""}");
         Transport.Box.Put ("{""command"":""events""}");
         Wait_For (Transport.Box, 3);
      end Action;
   begin
      Serve_While
        (Transport, "/work/pipelines/exec-1.fake", Context, Action'Access);
      Assert (Listening, "it listened");
      Assert
        (To_String (Transport.Endpoint) = "/work/pipelines/exec-1.fake",
         "where it was told to");
      declare
         Answers : constant Synapse.Core.Text_Lists.Vector :=
           Transport.Box.Answers;
      begin
         Assert
           (Natural (Answers.Length) = 3, "three requests, three answers");
         Assert
           (Current_Step_In (To_String (Answers (1))) = "A",
            "the first saw the run at A");
         Assert
           (Current_Step_In (To_String (Answers (2))) = "B",
            "the second saw it at B, as published meanwhile");
         Assert
           (Ada.Strings.Fixed.Index
              (To_String (Answers (3)), """kind"":""step.finished""") > 0,
            "and the third the event recorded");
      end;
      Assert
        (Transport.Closed, "it stopped listening when the action was done");
   end A_Client_Is_Answered_From_The_Live_Run;

   procedure A_Place_To_Listen_That_Cannot_Be_Had_Does_Not_Stop_The_Action
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Transport : Fake_Transport.Fake_Transport;
      Context   : aliased Contexts.Execution_Context;
      Listening : Boolean := True;
      Reason    : Unbounded_String;
      Ran       : Natural := 0;

      procedure Action (Is_Listening : Boolean; Why : String) is
      begin
         Ran := Ran + 1;
         Listening := Is_Listening;
         Reason := To_Unbounded_String (Why);
      end Action;
   begin
      Transport.Refuse := True;
      Serve_While (Transport, "/x.fake", Context, Action'Access);
      Assert
        (not Listening and then To_String (Reason) = "the fake refuses",
         "the action is told it is not listening, and why");
      Assert (Ran = 1, "and the action ran, once");
      Assert (not Transport.Closed, "there was nothing to close");
   end A_Place_To_Listen_That_Cannot_Be_Had_Does_Not_Stop_The_Action;

   procedure A_Serving_Task_That_Fails_Does_Not_Touch_The_Action
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Transport : Fake_Transport.Fake_Transport;
      Context   : aliased Contexts.Execution_Context;
      Listening : Boolean := False;
      Steps     : Natural := 0;

      procedure Action (Is_Listening : Boolean; Reason : String) is
         pragma Unreferenced (Reason);
      begin
         Listening := Is_Listening;
         for N in 1 .. 20 loop
            Context.Publish (Initial_State);
            Steps := Steps + 1;
            delay 0.002;
         end loop;
      end Action;
   begin
      Transport.Crash := True;
      Serve_While (Transport, "/x.fake", Context, Action'Access);
      Assert (Listening, "it did listen");
      Assert
        (Steps = 20,
         "the action ran to its end whatever the server did meanwhile");
   end A_Serving_Task_That_Fails_Does_Not_Touch_The_Action;

   procedure An_Action_That_Raises_Raises_After_The_Server_Stops
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Transport : Fake_Transport.Fake_Transport;
      Context   : aliased Contexts.Execution_Context;
      Raised    : Boolean := False;

      procedure Action (Listening : Boolean; Reason : String) is
         pragma Unreferenced (Listening, Reason);
      begin
         raise Constraint_Error with "boom";
      end Action;
   begin
      begin
         Serve_While (Transport, "/x.fake", Context, Action'Access);
      exception
         when Constraint_Error =>
            Raised := True;
      end;
      Assert (Raised, "the action's own exception comes out");
      Assert
        (Transport.Closed,
         "the server was stopped and closed, not left running");
   end An_Action_That_Raises_Raises_After_The_Server_Stops;

   procedure Ids_Are_Exec_And_Eight_Hex_Digits (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      First    : constant String := New_Id;
      Distinct : Boolean := False;
   begin
      Assert
        (First'Length = 13 and then First (First'First .. First'First + 4) =
         "exec-",
         "the shape: " & First);
      for C of First (First'First + 5 .. First'Last) loop
         Assert (C in '0' .. '9' | 'a' .. 'f', "hexadecimal: " & First);
      end loop;
      for N in 1 .. 50 loop
         if New_Id /= First then
            Distinct := True;
         end if;
         delay 0.002;
      end loop;
      Assert (Distinct, "and not always the same");
   end Ids_Are_Exec_And_Eight_Hex_Digits;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Inspectors");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Client_Is_Answered_From_The_Live_Run'Access,
         "A client is answered from the live run");
      Register_Routine
        (T, A_Place_To_Listen_That_Cannot_Be_Had_Does_Not_Stop_The_Action
              'Access,
         "A place to listen that cannot be had does not stop the action");
      Register_Routine
        (T, A_Serving_Task_That_Fails_Does_Not_Touch_The_Action'Access,
         "A serving task that fails does not touch the action");
      Register_Routine
        (T, An_Action_That_Raises_Raises_After_The_Server_Stops'Access,
         "An action that raises raises after the server stops");
      Register_Routine
        (T, Ids_Are_Exec_And_Eight_Hex_Digits'Access,
         "Ids are exec and eight hex digits");
   end Register_Tests;

end Synapse.Pipeline.Inspectors.Tests;
