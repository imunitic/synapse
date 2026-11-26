with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Recorders;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.States;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Changes.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Initial return States.State is
      Pipeline : Resolved.Pipeline;
   begin
      Pipeline.Name := To_Unbounded_String ("Dev");
      Pipeline.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String ("Develop"),
            Harness => Harnesses.Claude, others => <>));
      return States.Initial (Pipeline, JSON.Null_Value);
   end Initial;

   --  A run that was told its folder, with the patches of three visits, two
   --  of the step Develop, written out of order, and a name that is not one.
   procedure Set_Up (F : in out Fixture) is
      Wrote : Boolean;
   begin
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert (F.Registry.Create ("exec-1") = Registry_Store.Created, "made");
      Wrote :=
        F.Registry.Replace_Summary
          ("exec-1",
           JSON.To_String
             (Recorders.Summary
                ("exec-1", "2026-01-01T00:00:00+00:00", "", Initial,
                 Directory => "/work/widget")));
      Assert (Wrote, "a summary");
      Assert
        (F.Registry.Write_Patch ("exec-1", "10-Develop-1.patch", "ten" & LF),
         "a patch");
      Assert
        (F.Registry.Write_Patch ("exec-1", "2-Review-1.patch", "two"),
         "a patch with no line break at its end");
      Assert
        (F.Registry.Write_Patch ("exec-1", "1-Develop-1.patch", "one" & LF),
         "a patch");
      Assert
        (F.Registry.Write_Patch ("exec-1", "notes.patch", "not a visit"),
         "a file that is not named for a visit");
   end Set_Up;

   procedure The_Patches_Are_Printed_In_The_Order_The_Steps_Ran
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("exec-1")) = 0, "it succeeds");
      Assert
        (F.Base.Console.Out_Text =
         "== step Develop (visit 1, attempt 1)" & LF & "one" & LF
         & "== step Review (visit 2, attempt 1)" & LF & "two" & LF
         & "== step Develop (visit 10, attempt 1)" & LF & "ten" & LF,
         "visit 10 comes after visit 2, and each patch ends its line: "
         & F.Base.Console.Out_Text);
   end The_Patches_Are_Printed_In_The_Order_The_Steps_Ran;

   procedure One_Step_Can_Be_Asked_For (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("exec-1", "--step", "Develop")) = 0, "ok");
      Assert
        (F.Base.Console.Out_Text =
         "== step Develop (visit 1, attempt 1)" & LF & "one" & LF
         & "== step Develop (visit 10, attempt 1)" & LF & "ten" & LF,
         "only its patches: " & F.Base.Console.Out_Text);
   end One_Step_Can_Be_Asked_For;

   procedure A_Program_Gets_The_Patches_As_Data (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("exec-1", "--format", "json")) = 0, "it succeeds");
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (F.Base.Console.Out_Text);
      begin
         Assert (Parsed.Ok, "it is JSON");
         declare
            Item  : constant JSON.Value := Parsed.Item;
            Steps : constant JSON.Value := JSON.Member_Value (Item, "steps");
         begin
            Assert
              (JSON.As_String (JSON.Member_Value (Item, "format"))
               = "synapse-pipeline-changes/v1"
               and then JSON.As_String (JSON.Member_Value (Item, "directory"))
                        = "/work/widget"
               and then JSON.As_String
                          (JSON.Member_Value (Item, "execution_id"))
                        = "exec-1",
               "its format, its run and the folder the steps worked in");
            Assert (JSON.Length (Steps) = 3, "the three patches");
            Assert
              (JSON.As_String
                 (JSON.Member_Value (JSON.Element (Steps, 1), "step"))
               = "Develop"
               and then JSON.As_String
                          (JSON.Member_Value
                             (JSON.Element (Steps, 3), "patch"))
                        = "ten" & LF,
               "in the order the steps ran, each with its patch");
         end;
      end;
   end A_Program_Gets_The_Patches_As_Data;

   --  The events of a run in which Develop began its second try, and ended
   --  the first; Ended adds the end of the second.
   procedure Start_Session
     (F : in out Fixture; Ended : Boolean := False; Before : String := """x""")
   is
      Wrote : Boolean;
   begin
      Wrote :=
        F.Registry.Append_Event
          ("exec-1",
           "{""sequence"":1,""kind"":""session.started"","
           & """step"":""Develop"",""detail"":{""attempt"":1,""visit"":1,"
           & """transcript"":""t"",""before"":""old""}}" & LF
           & "{""sequence"":2,""kind"":""session.finished"","
           & """step"":""Develop"",""detail"":{}}" & LF
           & "{""sequence"":3,""kind"":""session.started"","
           & """step"":""Develop"",""detail"":{""attempt"":2,""visit"":3,"
           & """transcript"":""t"",""before"":" & Before & "}}" & LF
           & (if Ended
              then "{""sequence"":4,""kind"":""session.finished"","
                   & """step"":""Develop"",""detail"":{}}" & LF
              else ""));
      Assert (Wrote, "events");
      F.Trees.Snapshots.Append (To_Unbounded_String ("now"));
      F.Trees.Patch := To_Unbounded_String ("live" & LF);
      F.Trees.Patch_Known := True;
   end Start_Session;

   procedure The_Running_Attempt_Is_Included_With_Its_Step
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Start_Session (F, Before => """tree-1""");
      Assert
        (Run (Env (F), Args ("exec-1", "--step", "Develop")) = 0, "ok");
      Assert
        (F.Base.Console.Out_Text =
         "== step Develop (visit 1, attempt 1)" & LF & "one" & LF
         & "== step Develop (visit 10, attempt 1)" & LF & "ten" & LF
         & "== step Develop (visit 3, attempt 2)" & LF & "live" & LF,
         "the live difference after the recorded ones: "
         & F.Base.Console.Out_Text);
      Assert
        (F.Trees.Directories (1) = "/work/widget"
         and then F.Trees.Compared (1) = "tree-1..now",
         "against its before snapshot, in its folder");
      F.Base.Console.Clear;
      F.Trees.Snapshots.Append (To_Unbounded_String ("now"));
      Assert
        (Run
           (Env (F), Args ("exec-1", "--step", "Develop", "--format", "json"))
         = 0,
         "ok");
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (F.Base.Console.Out_Text);
         Steps  : constant JSON.Value :=
           JSON.Member_Value (Parsed.Item, "steps");
         Live   : constant JSON.Value := JSON.Element (Steps, 3);
      begin
         Assert (JSON.Length (Steps) = 3, "three entries");
         Assert
           (JSON.As_Integer (JSON.Member_Value (Live, "visit")) = 3
            and then JSON.As_Integer (JSON.Member_Value (Live, "attempt")) = 2
            and then JSON.As_String (JSON.Member_Value (Live, "patch"))
                     = "live" & LF,
            "its visit, attempt and patch");
      end;
   end The_Running_Attempt_Is_Included_With_Its_Step;

   procedure No_Live_Entry_Without_A_Running_Attempt
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Start_Session (F);
      Assert (Run (Env (F), Args ("exec-1")) = 0, "ok");
      Assert
        (not Has (F.Base.Console.Out_Text, "live")
         and then F.Trees.Directories.Is_Empty,
         "without --step nothing live is looked up");

      declare
         G : aliased Fixture;
      begin
         Set_Up (G);
         Start_Session (G, Ended => True);
         Assert
           (Run (Env (G), Args ("exec-1", "--step", "Develop")) = 0, "ok");
         Assert
           (not Has (G.Base.Console.Out_Text, "live")
            and then G.Trees.Directories.Is_Empty,
            "a session that ended is not running");
      end;

      declare
         G : aliased Fixture;
      begin
         Set_Up (G);
         Start_Session (G);
         G.Trees.Patch := Null_Unbounded_String;
         Assert
           (Run (Env (G), Args ("exec-1", "--step", "Develop")) = 0, "ok");
         Assert
           (not Has (G.Base.Console.Out_Text, "visit 3"),
            "a folder that is unchanged has no entry");
      end;

      declare
         G : aliased Fixture;
      begin
         Set_Up (G);
         Start_Session (G, Before => "null");
         Assert
           (Run (Env (G), Args ("exec-1", "--step", "Develop")) = 0, "ok");
         Assert
           (not Has (G.Base.Console.Out_Text, "visit 3")
            and then G.Trees.Directories.Is_Empty,
            "no before snapshot, no entry");
      end;

      declare
         G : aliased Fixture;
      begin
         G.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
         Assert
           (G.Registry.Create ("exec-1") = Registry_Store.Created, "made");
         Start_Session (G);
         Assert
           (Run (Env (G), Args ("exec-1", "--step", "Develop")) = 0, "ok");
         Assert
           (G.Trees.Directories.Is_Empty,
            "no summary, no folder, nothing asked of the trees");
      end;
   end No_Live_Entry_Without_A_Running_Attempt;

   procedure A_Run_With_No_Patch_Says_So (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("exec-1", "--step", "Nobody")) = 0, "ok");
      Assert
        (F.Base.Console.Out_Text =
         "no changes were recorded for step Nobody" & LF,
         "a step that left none: " & F.Base.Console.Out_Text);
      declare
         G : aliased Fixture;
      begin
         G.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
         Assert
           (G.Registry.Create ("exec-2") = Registry_Store.Created, "made");
         Assert (Run (Env (G), Args ("exec-2")) = 0, "ok");
         Assert
           (G.Base.Console.Out_Text = "no changes were recorded" & LF,
            "a run that left none: " & G.Base.Console.Out_Text);
         G.Base.Console.Clear;
         Assert
           (Run (Env (G), Args ("exec-2", "--format", "json")) = 0, "ok");
         Assert
           (Has (G.Base.Console.Out_Text, """steps"":[]")
            and then Has (G.Base.Console.Out_Text, """directory"":null"),
            "and as data an empty list and no folder: "
            & G.Base.Console.Out_Text);
      end;
   end A_Run_With_No_Patch_Says_So;

   --  The `status` and `snapshots` members of the JSON output.
   function Status_Of (F : Fixture) return String is
     (JSON.As_String
        (JSON.Member_Value
           (JSON.Parse (F.Base.Console.Out_Text).Item, "status")));

   function Snapshot (F : Fixture; Key : String) return JSON.Value is
     (JSON.Member_Value
        (JSON.Member_Value
           (JSON.Parse (F.Base.Console.Out_Text).Item, "snapshots"),
         Key));

   function Is_Null (Item : JSON.Value) return Boolean is
     (JSON.Kind_Of (Item) = JSON.JSON_Null);

   procedure The_Json_Says_The_Snapshots_And_The_Status
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F     : aliased Fixture;
      Item  : States.State := Initial;
      Wrote : Boolean;
   begin
      Set_Up (F);
      Item.Status := States.Completed;
      Wrote :=
        F.Registry.Replace_Summary
          ("exec-1",
           JSON.To_String
             (Recorders.Summary
                ("exec-1", "2026-01-01T00:00:00+00:00",
                 "2026-01-01T01:00:00+00:00", Item,
                 Directory  => "/work/widget",
                 Start_Tree => "tree-start",
                 End_Tree   => "tree-end")));
      Assert (Wrote, "a summary with both snapshots");
      Start_Session (F, Before => """tree-other""");
      Assert
        (Run (Env (F), Args ("exec-1", "--format", "json")) = 0, "ok");
      Assert
        (Status_Of (F) = "completed"
         and then JSON.As_String (Snapshot (F, "start")) = "tree-start"
         and then JSON.As_String (Snapshot (F, "end")) = "tree-end",
         "the summary's status and snapshots: " & F.Base.Console.Out_Text);
   end The_Json_Says_The_Snapshots_And_The_Status;

   procedure An_Older_Record_Takes_Its_Start_From_The_Events
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F     : aliased Fixture;
      Wrote : Boolean;
   begin
      F.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
      Assert (F.Registry.Create ("exec-1") = Registry_Store.Created, "made");
      Wrote :=
        F.Registry.Replace_Summary
          ("exec-1",
           "{""execution_id"":""exec-1"",""status"":""failed"","
           & """directory"":""/work/widget""}");
      Assert (Wrote, "a summary with no snapshots member");
      Start_Session (F, Before => """tree-1""");
      Assert
        (Run (Env (F), Args ("exec-1", "--format", "json")) = 0, "ok");
      Assert
        (Status_Of (F) = "failed"
         and then JSON.As_String (Snapshot (F, "start")) = "old"
         and then Is_Null (Snapshot (F, "end")),
         "the before of the first session, and no end: "
         & F.Base.Console.Out_Text);
   end An_Older_Record_Takes_Its_Start_From_The_Events;

   procedure A_Record_With_No_Snapshot_Says_Null
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("exec-1", "--format", "json")) = 0, "ok");
      Assert
        (Status_Of (F) = "running"
         and then Is_Null (Snapshot (F, "start"))
         and then Is_Null (Snapshot (F, "end")),
         "no snapshots and no events: " & F.Base.Console.Out_Text);
      F.Base.Console.Clear;
      Start_Session (F, Before => "null");
      declare
         Wrote : Boolean;
      begin
         Wrote :=
           F.Registry.Append_Event
             ("exec-1",
              "{""sequence"":5,""kind"":""step.started"","
              & """step"":""Develop"",""detail"":{""before"":""no""}}" & LF);
         Assert (Wrote, "an event that is not a session's");
      end;
      Assert
        (Run (Env (F), Args ("exec-1", "--format", "json")) = 0, "ok");
      Assert
        (JSON.As_String (Snapshot (F, "start")) = "old",
         "the first session's before even when a later one has none");

      declare
         G : aliased Fixture;
         Wrote : Boolean;
      begin
         G.Base.Vars.Set ("SYNAPSE_WORK_DIR", "/work");
         Assert
           (G.Registry.Create ("exec-1") = Registry_Store.Created, "made");
         Wrote :=
           G.Registry.Append_Event
             ("exec-1",
              "{""sequence"":1,""kind"":""session.started"","
              & """step"":""Develop"",""detail"":{""attempt"":1,""visit"":1,"
              & """before"":null}}" & LF);
         Assert (Wrote, "a session with no before");
         Assert
           (Run (Env (G), Args ("exec-1", "--format", "json")) = 0, "ok");
         Assert
           (Status_Of (G) = "incomplete"
            and then Is_Null (Snapshot (G, "start"))
            and then Is_Null (Snapshot (G, "end")),
            "no summary is incomplete, and no before is null: "
            & G.Base.Console.Out_Text);
      end;
   end A_Record_With_No_Snapshot_Says_Null;

   procedure A_Run_That_Is_Not_Recorded_Is_An_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("exec-9")) = 1, "it fails");
      Assert
        (Has (F.Base.Console.Err_Text, "there is no record of execution")
         and then F.Base.Console.Out_Text = "",
         "and says so, printing nothing: " & F.Base.Console.Err_Text);
   end A_Run_That_Is_Not_Recorded_Is_An_Error;

   procedure A_Wrong_Use_Is_A_Usage_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args) = 2, "an id is needed");
      Assert (Run (Env (F), Args ("exec-1", "exec-2")) = 2, "only one");
      Assert
        (Run (Env (F), Args ("exec-1", "--format", "xml")) = 2, "a format");
      Assert (Run (Env (F), Args ("exec-1", "--step")) = 2, "a step's name");
      Assert
        (Run (Env (F), Args ("exec-1", "--step", "A", "--step", "B")) = 2,
         "one step");
      Assert (Run (Env (F), Args ("exec-1", "--all")) = 2, "an option");
   end A_Wrong_Use_Is_A_Usage_Error;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Changes");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Patches_Are_Printed_In_The_Order_The_Steps_Ran'Access,
         "The patches are printed in the order the steps ran");
      Register_Routine
        (T, One_Step_Can_Be_Asked_For'Access, "One step can be asked for");
      Register_Routine
        (T, The_Running_Attempt_Is_Included_With_Its_Step'Access,
         "The running attempt is included with its step");
      Register_Routine
        (T, No_Live_Entry_Without_A_Running_Attempt'Access,
         "No live entry without a running attempt");
      Register_Routine
        (T, A_Program_Gets_The_Patches_As_Data'Access,
         "A program gets the patches as data");
      Register_Routine
        (T, A_Run_With_No_Patch_Says_So'Access,
         "A run with no patch says so");
      Register_Routine
        (T, The_Json_Says_The_Snapshots_And_The_Status'Access,
         "The JSON says the snapshots and the status");
      Register_Routine
        (T, An_Older_Record_Takes_Its_Start_From_The_Events'Access,
         "An older record takes its start from the events");
      Register_Routine
        (T, A_Record_With_No_Snapshot_Says_Null'Access,
         "A record with no snapshot says null");
      Register_Routine
        (T, A_Run_That_Is_Not_Recorded_Is_An_Error'Access,
         "A run that is not recorded is an error");
      Register_Routine
        (T, A_Wrong_Use_Is_A_Usage_Error'Access,
         "A wrong use is a usage error");
   end Register_Tests;

end Synapse.Pipeline.Commands.Changes.Tests;
