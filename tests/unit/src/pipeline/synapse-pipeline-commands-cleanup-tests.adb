with Ada.Calendar;
with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Fake_Registry;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Inspection;
with Synapse.Pipeline.Recorders;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.States;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Cleanup.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;
   use type States.Run_Status;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Day : constant Duration := 24.0 * 3600.0;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Pipeline_Of (Name : String) return Resolved.Pipeline is
      Result : Resolved.Pipeline;
   begin
      Result.Name := To_Unbounded_String (Name);
      Result.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String ("A"), Harness => Harnesses.Claude,
            others => <>));
      return Result;
   end Pipeline_Of;

   --  Keeps the record of execution Id, in Status, last written Days days ago.
   procedure Keep
     (F      : in out Fixture;
      Id     : String;
      Status : States.Run_Status;
      Days   : Natural)
   is
      Item   : States.State :=
        States.Initial (Pipeline_Of ("Dev"), JSON.Null_Value);
      Made   : constant Registry_Store.Create_Result := F.Registry.Create (Id);
      Wrote  : Boolean;
      pragma Unreferenced (Made);
   begin
      Item.Status := Status;
      Wrote :=
        F.Registry.Replace_Summary
          (Id,
           JSON.To_String
             (Recorders.Summary
                (Id, "2026-01-01T00:00:00+00:00", "", Item)));
      pragma Unreferenced (Wrote);
      F.Registry.Set_Last_Write
        (Id, Ada.Calendar."-" (Ada.Calendar.Clock, Days * Day));
   end Keep;

   procedure Set_Up (F : in out Fixture) is
   begin
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Keep (F, "exec-a", States.Completed, 40);
      Keep (F, "exec-b", States.Completed, 1);
      Keep (F, "exec-c", States.Running, 40);
      Keep (F, "exec-d", States.Running, 1);
      Keep (F, "exec-e", States.Failed, 31);
      Assert (F.Registry.Create ("exec-f") = Registry_Store.Created, "made");
   end Set_Up;

   function Left (F : Fixture) return String is
      Text : Unbounded_String;
   begin
      for Id of F.Registry.Ids loop
         Append (Text, To_String (Id) & " ");
      end loop;
      return To_String (Text);
   end Left;

   procedure What_Is_Old_And_Not_Running_Is_Removed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args) = 0, "it succeeds");
      Assert
        (F.Base.Console.Out_Text =
         "removed exec-a" & LF & "removed exec-c" & LF & "removed exec-e" & LF,
         "what was last written over 30 days ago, finished or interrupted: "
         & F.Base.Console.Out_Text);
      Assert
        (Left (F) = "exec-b exec-d exec-f ",
         "what is newer stays, and so does an execution with no summary: "
         & Left (F));
   end What_Is_Old_And_Not_Running_Is_Removed;

   procedure A_Run_That_Answers_Is_Never_Removed (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F      : aliased Fixture;
      Pipe   : constant Resolved.Pipeline := Pipeline_Of ("Dev");
      Seen   : Inspection.Snapshot;
   begin
      Set_Up (F);
      Seen.Execution_Id := To_Unbounded_String ("exec-c");
      Seen.Run := States.Initial (Pipe, JSON.Null_Value);
      F.Inspector.Runs.Include ("exec-c", Seen);
      Assert (Run (Env (F), Args ("--older-than", "1h", "--all")) = 0, "ok");
      Assert
        (Has (Left (F), "exec-c"),
         "an execution that is listening stays, however old: " & Left (F));
   end A_Run_That_Answers_Is_Never_Removed;

   procedure A_Dry_Run_Removes_Nothing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("--dry-run")) = 0, "it succeeds");
      Assert
        (F.Base.Console.Out_Text =
         "would remove exec-a" & LF & "would remove exec-c" & LF
         & "would remove exec-e" & LF,
         "it says what it would do: " & F.Base.Console.Out_Text);
      Assert
        (Natural (F.Registry.Ids.Length) = 6, "and does none of it");
   end A_Dry_Run_Removes_Nothing;

   procedure All_Removes_What_Is_Over_Whatever_Its_Age
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("--all")) = 0, "it succeeds");
      Assert
        (Left (F) = "exec-d exec-f ",
         "everything that finished goes; a recent interrupted one and an "
         & "execution with no summary stay: " & Left (F));
   end All_Removes_What_Is_Over_Whatever_Its_Age;

   procedure The_Age_Can_Be_Given (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("--older-than", "90d")) = 0, "it succeeds");
      Assert
        (Natural (F.Registry.Ids.Length) = 6, "nothing is that old");
      Assert (Run (Env (F), Args ("--older-than", "12h")) = 0, "12 hours");
      Assert
        (Left (F) = "exec-f ",
         "everything older than 12 hours goes, but an execution with no "
         & "summary to date it by: " & Left (F));
   end The_Age_Can_Be_Given;

   procedure A_Bad_Argument_Is_A_Usage_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("--older-than", "soon")) = 2
         and then Run (Env (F), Args ("--older-than")) = 2
         and then Run (Env (F), Args ("--old")) = 2
         and then Run (Env (F), Args ("--dry-run", "--dry-run")) = 2
         and then Run (Env (F), Args ("exec-a")) = 2,
         "what cleanup does not know is refused");
      Assert (Natural (F.Registry.Ids.Length) = 6, "and nothing is removed");
   end A_Bad_Argument_Is_A_Usage_Error;

   procedure A_Removal_That_Fails_Is_Reported (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Registry.Fail (Fake_Registry.Remove_Op);
      Assert
        (Run (Env (F), Args) = 1
         and then Has (F.Base.Console.Err_Text, "cannot remove exec-a"),
         "it exits 1 and says which: " & F.Base.Console.Err_Text);
   end A_Removal_That_Fails_Is_Reported;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Cleanup");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, What_Is_Old_And_Not_Running_Is_Removed'Access,
         "What is old and not running is removed");
      Register_Routine
        (T, A_Run_That_Answers_Is_Never_Removed'Access,
         "A run that answers is never removed");
      Register_Routine
        (T, A_Dry_Run_Removes_Nothing'Access, "A dry run removes nothing");
      Register_Routine
        (T, All_Removes_What_Is_Over_Whatever_Its_Age'Access,
         "--all removes what is over whatever its age");
      Register_Routine
        (T, The_Age_Can_Be_Given'Access, "The age can be given");
      Register_Routine
        (T, A_Bad_Argument_Is_A_Usage_Error'Access,
         "A bad argument is a usage error");
      Register_Routine
        (T, A_Removal_That_Fails_Is_Reported'Access,
         "A removal that fails is reported");
   end Register_Tests;

end Synapse.Pipeline.Commands.Cleanup.Tests;
