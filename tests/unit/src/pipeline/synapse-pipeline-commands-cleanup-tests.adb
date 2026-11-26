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
     (F         : in out Fixture;
      Id        : String;
      Status    : States.Run_Status;
      Days      : Natural;
      Directory : String := "")
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
                (Id, "2026-01-01T00:00:00+00:00", "", Item,
                 Directory => Directory)));
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
         and then Run (Env (F), Args ("exec/a")) = 2,
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

   --  The refs unpinned so far, each followed by a space.
   function Unpinned (F : Fixture) return String is
      Text : Unbounded_String;
   begin
      for Ref of F.Trees.Unpinned loop
         Append (Text, To_String (Ref) & " ");
      end loop;
      return To_String (Text);
   end Unpinned;

   procedure A_Removed_Run_Unpins_Its_Snapshots (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Keep (F, "exec-g", States.Completed, 40, Directory => "/repo");
      Keep (F, "exec-h", States.Completed, 1, Directory => "/repo");
      Assert (Run (Env (F), Args) = 0, "it succeeds");
      Assert
        (Unpinned (F) =
         "refs/synapse/runs/exec-g/start refs/synapse/runs/exec-g/end ",
         "the old run with a folder has both its refs deleted; the runs "
         & "with no folder and the kept run have none: " & Unpinned (F));
   end A_Removed_Run_Unpins_Its_Snapshots;

   procedure A_Dry_Run_Unpins_Nothing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Keep (F, "exec-g", States.Completed, 40, Directory => "/repo");
      Assert (Run (Env (F), Args ("--dry-run")) = 0, "it succeeds");
      Assert
        (F.Trees.Unpinned.Is_Empty,
         "a dry run deletes no ref: " & Unpinned (F));
   end A_Dry_Run_Unpins_Nothing;

   --  Makes the execution Id answer on its socket, as a running one does.
   procedure Answer (F : in out Fixture; Id : String) is
      Seen : Inspection.Snapshot;
   begin
      Seen.Execution_Id := To_Unbounded_String (Id);
      Seen.Run := States.Initial (Pipeline_Of ("Dev"), JSON.Null_Value);
      F.Inspector.Runs.Include (Id, Seen);
   end Answer;

   procedure A_Given_Execution_Is_Removed_Whatever_Its_Age
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("exec-d", "exec-b", "exec-f", "exec-b")) = 0,
         "it succeeds: " & F.Base.Console.Err_Text);
      Assert
        (F.Base.Console.Out_Text =
         "removed exec-d" & LF & "removed exec-b" & LF & "removed exec-f" & LF,
         "the given ones go, in the order given and once each, recent, "
         & "interrupted or with no summary: " & F.Base.Console.Out_Text);
      Assert
        (Left (F) = "exec-a exec-c exec-e ",
         "the ones not given stay, however old: " & Left (F));
   end A_Given_Execution_Is_Removed_Whatever_Its_Age;

   procedure A_Given_Running_Execution_Is_Kept
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Answer (F, "exec-b");
      Assert
        (Run (Env (F), Args ("exec-a", "exec-b", "exec-e")) = 1,
         "it exits 1");
      Assert
        (F.Base.Console.Err_Text =
         "error: exec-b is running, not removed" & LF,
         "it says which was kept: " & F.Base.Console.Err_Text);
      Assert
        (Left (F) = "exec-b exec-c exec-d exec-f ",
         "the running one stays and the others go: " & Left (F));
   end A_Given_Running_Execution_Is_Kept;

   procedure An_Unknown_Execution_Is_Reported (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("exec-x", "exec-a")) = 1, "it exits 1");
      Assert
        (F.Base.Console.Err_Text = "error: no execution exec-x" & LF,
         "it names the unknown one: " & F.Base.Console.Err_Text);
      Assert
        (F.Base.Console.Out_Text = "removed exec-a" & LF,
         "and removes the other: " & F.Base.Console.Out_Text);
      Assert
        (Left (F) = "exec-b exec-c exec-d exec-e exec-f ", Left (F));
   end An_Unknown_Execution_Is_Reported;

   procedure A_Given_Executions_Snapshots_Are_Unpinned
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Keep (F, "exec-h", States.Completed, 1, Directory => "/repo");
      Assert (Run (Env (F), Args ("exec-h")) = 0, "it succeeds");
      Assert
        (Unpinned (F) =
         "refs/synapse/runs/exec-h/start refs/synapse/runs/exec-h/end ",
         "both refs of the given run are deleted: " & Unpinned (F));
      Assert (not Has (Left (F), "exec-h"), "and the run is gone");
   end A_Given_Executions_Snapshots_Are_Unpinned;

   procedure A_Dry_Run_With_Ids_Removes_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Keep (F, "exec-h", States.Completed, 1, Directory => "/repo");
      Assert
        (Run (Env (F), Args ("--dry-run", "exec-b", "exec-h")) = 0,
         "it succeeds");
      Assert
        (F.Base.Console.Out_Text =
         "would remove exec-b" & LF & "would remove exec-h" & LF,
         "it says what it would do: " & F.Base.Console.Out_Text);
      Assert
        (Natural (F.Registry.Ids.Length) = 7
         and then F.Trees.Unpinned.Is_Empty,
         "and removes and unpins nothing: " & Left (F));
   end A_Dry_Run_With_Ids_Removes_Nothing;

   procedure Ids_With_All_Are_A_Usage_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("exec-a", "--all")) = 2
         and then Run (Env (F), Args ("--all", "exec-a")) = 2
         and then Run (Env (F), Args ("--older-than", "1d", "exec-a")) = 2
         and then Run (Env (F), Args ("exec-a", "../exec-b")) = 2,
         "ids with --all or --older-than, and an id that is not a plain "
         & "name, are refused");
      Assert (Natural (F.Registry.Ids.Length) = 6, "and nothing is removed");
   end Ids_With_All_Are_A_Usage_Error;

   procedure JSON_Lists_What_Was_Removed_And_Kept
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Answer (F, "exec-c");
      Assert (Run (Env (F), Args ("--format", "json")) = 0, "it succeeds");
      Assert
        (F.Base.Console.Out_Text =
         "{""format"":""synapse-pipeline-cleanup/v1"",""dry_run"":false,"
         & """removed"":[""exec-a"",""exec-e""],""kept"":["
         & "{""id"":""exec-b"",""reason"":""too_recent""},"
         & "{""id"":""exec-c"",""reason"":""running""},"
         & "{""id"":""exec-d"",""reason"":""too_recent""},"
         & "{""id"":""exec-f"",""reason"":""too_recent""}]}" & LF,
         "one document: the old ones removed, the running one kept, and the "
         & "recent ones and the one with no summary to date it by kept as "
         & "too recent: "
         & F.Base.Console.Out_Text);
      Assert
        (Left (F) = "exec-b exec-c exec-d exec-f ",
         "and what it lists as removed is gone: " & Left (F));
   end JSON_Lists_What_Was_Removed_And_Kept;

   procedure A_JSON_Dry_Run_Removes_Nothing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("--dry-run", "--format", "json", "--all")) = 0,
         "it succeeds");
      Assert
        (F.Base.Console.Out_Text =
         "{""format"":""synapse-pipeline-cleanup/v1"",""dry_run"":true,"
         & """removed"":[""exec-a"",""exec-b"",""exec-c"",""exec-e""],"
         & """kept"":[{""id"":""exec-d"",""reason"":""too_recent""},"
         & "{""id"":""exec-f"",""reason"":""too_recent""}]}" & LF,
         "it lists what would be removed: " & F.Base.Console.Out_Text);
      Assert (Natural (F.Registry.Ids.Length) = 6, "and removes none of it");
   end A_JSON_Dry_Run_Removes_Nothing;

   procedure JSON_With_Ids_Reports_A_Running_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Answer (F, "exec-b");
      Assert
        (Run (Env (F), Args ("exec-a", "exec-b", "exec-x", "--format", "json"))
         = 1,
         "it exits 1, as in text");
      Assert
        (F.Base.Console.Out_Text =
         "{""format"":""synapse-pipeline-cleanup/v1"",""dry_run"":false,"
         & """removed"":[""exec-a""],""kept"":["
         & "{""id"":""exec-b"",""reason"":""running""},"
         & "{""id"":""exec-x"",""reason"":""not_found""}]}" & LF,
         "the running and the unknown one are kept and why: "
         & F.Base.Console.Out_Text);
      Assert
        (F.Base.Console.Err_Text = "",
         "and nothing is printed per execution: " & F.Base.Console.Err_Text);
      Assert
        (Left (F) = "exec-b exec-c exec-d exec-e exec-f ", Left (F));
   end JSON_With_Ids_Reports_A_Running_One;

   procedure An_Unknown_Format_Is_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("--format", "yaml")) = 2
         and then Run (Env (F), Args ("--format")) = 2
         and then Run (Env (F), Args ("--format", "json", "--format", "json"))
                  = 2,
         "an unknown format, a missing one and a second one are refused");
      Assert (Natural (F.Registry.Ids.Length) = 6, "and nothing is removed");
   end An_Unknown_Format_Is_A_Usage_Error;

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
      Register_Routine
        (T, A_Removed_Run_Unpins_Its_Snapshots'Access,
         "A removed run unpins its snapshots");
      Register_Routine
        (T, A_Dry_Run_Unpins_Nothing'Access, "A dry run unpins nothing");
      Register_Routine
        (T, A_Given_Execution_Is_Removed_Whatever_Its_Age'Access,
         "A given execution is removed whatever its age");
      Register_Routine
        (T, A_Given_Running_Execution_Is_Kept'Access,
         "A given running execution is kept and the others are removed");
      Register_Routine
        (T, An_Unknown_Execution_Is_Reported'Access,
         "An unknown execution is reported and the others are removed");
      Register_Routine
        (T, A_Given_Executions_Snapshots_Are_Unpinned'Access,
         "A given execution's snapshots are unpinned");
      Register_Routine
        (T, A_Dry_Run_With_Ids_Removes_Nothing'Access,
         "A dry run with ids removes nothing");
      Register_Routine
        (T, Ids_With_All_Are_A_Usage_Error'Access,
         "Ids with --all are a usage error");
      Register_Routine
        (T, JSON_Lists_What_Was_Removed_And_Kept'Access,
         "json lists what was removed and what was kept and why");
      Register_Routine
        (T, A_JSON_Dry_Run_Removes_Nothing'Access,
         "a json dry run lists what would be removed and removes nothing");
      Register_Routine
        (T, JSON_With_Ids_Reports_A_Running_One'Access,
         "json with ids reports a running one as kept");
      Register_Routine
        (T, An_Unknown_Format_Is_A_Usage_Error'Access,
         "an unknown format is a usage error");
   end Register_Tests;

end Synapse.Pipeline.Commands.Cleanup.Tests;
