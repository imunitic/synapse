with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Core.Text_Lists;
with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Contexts;
with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Fake_Registry;
with Synapse.Pipeline.Fake_Working_Trees;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Registry_Store;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.States;
with Synapse.Pipeline.Sessions;
with Synapse.Ports.Clock;

package body Synapse.Pipeline.Recording_Runners.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Registry_Store.Create_Result;

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

   --  The detail of each `session.finished` event.
   function Events_Text (Context : Contexts.Execution_Context) return String is
      Text : Unbounded_String;
   begin
      for Item of Context.Current.Events loop
         if To_String (Item.Kind) = "session.finished" then
            Append (Text, JSON.To_String (Item.Detail) & "|");
         end if;
      end loop;
      return To_String (Text);
   end Events_Text;

   --  A session of the step A, the Visit'th step of the run, in /work.
   function Request_In_Work (Visit : Positive) return Sessions.Session_Request
   is
      Result : Sessions.Session_Request := Request_For_A (1);
   begin
      Result.Visit := Visit;
      Result.Settings.Working_Directory := To_Unbounded_String ("/work");
      return Result;
   end Request_In_Work;

   function Joined (Items : Synapse.Core.Text_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Item of Items loop
         Append (Text, To_String (Item) & "|");
      end loop;
      return To_String (Text);
   end Joined;

   procedure A_Session_That_Changed_Files_Leaves_A_Patch
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
      Diff     : constant String := "diff --git a/x b/x" & ASCII.LF;
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      Trees.Snapshots.Append (To_Unbounded_String ("tree1"));
      Trees.Snapshots.Append (To_Unbounded_String ("tree2"));
      Trees.Patch := To_Unbounded_String (Diff);
      Trees.Patch_Known := True;
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      Assert
        (R.Run_Session (Request_In_Work (2)).Succeeded,
         "the inner runner's answer comes back");
      Assert
        (Joined (Trees.Directories) = "/work|/work|",
         "the folder the session works in is looked at before and after: "
         & Joined (Trees.Directories));
      Assert
        (Joined (Trees.Names) = "exec-1-2-1-before|exec-1-2-1-after|",
         "by snapshots named for the run, the visit and the attempt: "
         & Joined (Trees.Names));
      Assert
        (Joined (Trees.Compared) = "tree1..tree2|",
         "and the two are compared");
      Assert
        (Store.Read_Patch ("exec-1", "2-A-1.patch").Found
         and then To_String (Store.Read_Patch ("exec-1", "2-A-1.patch").Value)
                  = Diff,
         "what changed is the patch of the visit, the step and the attempt");
   end A_Session_That_Changed_Files_Leaves_A_Patch;

   procedure A_Session_That_Changed_Nothing_Leaves_No_Patch
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      Trees.Snapshots.Append (To_Unbounded_String ("same"));
      Trees.Snapshots.Append (To_Unbounded_String ("same"));
      Trees.Patch_Known := True;
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      Assert (R.Run_Session (Request_In_Work (1)).Succeeded, "it ran");
      Assert
        (Trees.Compared.Is_Empty
         and then Store.Patch_Names ("exec-1").Is_Empty,
         "two snapshots that are the same are not compared, and leave none");
   end A_Session_That_Changed_Nothing_Leaves_No_Patch;

   procedure A_Folder_That_Is_Not_In_A_Repository_Leaves_No_Patch
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      Assert (R.Run_Session (Request_In_Work (1)).Succeeded, "it ran");
      Assert
        (Natural (Trees.Directories.Length) = 1
         and then Trees.Compared.Is_Empty
         and then Store.Patch_Names ("exec-1").Is_Empty,
         "a folder with no snapshot is not looked at again, and leaves none");
   end A_Folder_That_Is_Not_In_A_Repository_Leaves_No_Patch;

   procedure A_Run_That_Is_Not_Recorded_Keeps_No_Patch
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      Trees.Snapshots.Append (To_Unbounded_String ("a"));
      Trees.Snapshots.Append (To_Unbounded_String ("b"));
      Trees.Patch := To_Unbounded_String ("diff --git a/x b/x" & ASCII.LF);
      Trees.Patch_Known := True;
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", False, JSON.Null_Value, Initial_State);
      Assert (R.Run_Session (Request_In_Work (1)).Succeeded, "it ran");
      Assert
        (Store.Patch_Names ("exec-1").Is_Empty,
         "a run that is not recorded keeps no patch");
   end A_Run_That_Is_Not_Recorded_Keeps_No_Patch;

   procedure A_Large_New_File_Is_Kept_As_Its_Path_And_Lines
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
      Big      : constant String :=
        "diff --git a/big.dat b/big.dat" & ASCII.LF
        & "new file mode 100644" & ASCII.LF
        & "--- /dev/null" & ASCII.LF
        & "+++ b/big.dat" & ASCII.LF
        & "@@ -0,0 +1,2 @@" & ASCII.LF
        & "+" & String'(1 .. 200 => 'x') & ASCII.LF
        & "+" & String'(1 .. 200 => 'y') & ASCII.LF;
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      Trees.Snapshots.Append (To_Unbounded_String ("a"));
      Trees.Snapshots.Append (To_Unbounded_String ("b"));
      Trees.Patch := To_Unbounded_String (Big);
      Trees.Patch_Known := True;
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      R.Largest := 100;
      Recorder.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      Assert (R.Run_Session (Request_In_Work (1)).Succeeded, "it ran");
      declare
         Kept : constant Registry_Store.Maybe_Content :=
           Store.Read_Patch ("exec-1", "1-A-1.patch");
      begin
         Assert (Kept.Found, "there is a patch");
         Assert
           (Ada.Strings.Unbounded.Index (Kept.Value, "yyyy") = 0
            and then Ada.Strings.Unbounded.Index
                       (Kept.Value, "@@ -0,0 +1,2 @@") > 0
            and then Ada.Strings.Unbounded.Index
                       (Kept.Value, "Content not kept") > 0,
            "the lines of a file past the limit are left out, and it says so");
      end;
   end A_Large_New_File_Is_Kept_As_Its_Path_And_Lines;

   procedure A_Session_Is_Stamped_And_Recorded (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      R        : Recording_Runner (Inner'Access, Recorder'Access, null);
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
        (To_String (Context.Current.Events.Last_Element.Step) = "A"
         and then To_String (Context.Current.Events.Last_Element.Kind) =
                  "session.finished",
         "of the kind and for the step");
   end A_Session_Is_Stamped_And_Recorded;

   --  The kinds of the events, in order, each with its detail.
   function Kinds_And_Details
     (Context : Contexts.Execution_Context) return String
   is
      Text : Unbounded_String;
   begin
      for Item of Context.Current.Events loop
         Append
           (Text,
            To_String (Item.Kind) & " " & JSON.To_String (Item.Detail) & "|");
      end loop;
      return To_String (Text);
   end Kinds_And_Details;

   procedure A_Session_Starts_With_An_Event_Before_It_Finishes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      Trees.Snapshots.Append (To_Unbounded_String ("tree1"));
      Trees.Snapshots.Append (To_Unbounded_String ("tree1"));
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      Assert (R.Run_Session (Request_In_Work (2)).Succeeded, "it ran");
      Assert
        (Kinds_And_Details (Context) =
         "session.started {""attempt"":1,""visit"":2,"
         & """transcript"":""memory:exec-1/transcripts/2-A-1.jsonl"","
         & """before"":""tree1""}|"
         & "session.finished {""attempt"":1,""succeeded"":true,"
         & """transcript"":null}|",
         "the start comes first, with the attempt, the visit, the transcript "
         & "path and the before tree: " & Kinds_And_Details (Context));
   end A_Session_Starts_With_An_Event_Before_It_Finishes;

   procedure A_Session_With_No_Working_Trees_Starts_With_No_Before
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      R        : Recording_Runner (Inner'Access, Recorder'Access, null);
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", False, JSON.Null_Value, Initial_State);
      Assert (R.Run_Session (Request_For_A (1)).Succeeded, "it ran");
      Assert
        (Ada.Strings.Unbounded.Index
           (To_Unbounded_String (Kinds_And_Details (Context)),
            """before"":null}|") > 0,
         "before is null: " & Kinds_And_Details (Context));
   end A_Session_With_No_Working_Trees_Starts_With_No_Before;

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
      R        : Recording_Runner (Inner'Access, Recorder'Access, null);
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

   procedure The_Last_Attempt_Is_Remembered (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      R        : Recording_Runner (Inner'Access, Recorder'Access, null);
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", False, JSON.Null_Value, Initial_State);
      Assert (R.Last_Attempt = 0, "no attempt before the first session");
      Assert (R.Run_Session (Request_For_A (1)).Succeeded, "the first ran");
      Assert (R.Run_Session (Request_For_A (2)).Succeeded, "the retry ran");
      Assert
        (R.Last_Attempt = 2,
         "the attempt of the last session is kept:"
         & Natural'Image (R.Last_Attempt));
   end The_Last_Attempt_Is_Remembered;

   --  The snapshot Which of the summary of exec-1 in Store: its tree, or
   --  "null".
   function Snapshot_Of
     (Store : Fake_Registry.Fake_Registry; Which : String) return String
   is
      Held  : constant Registry_Store.Maybe_Content :=
        Store.Read_Summary ("exec-1");
      Value : JSON.Value;
   begin
      Assert (Held.Found, "there is a summary");
      Value :=
        JSON.Member_Value
          (JSON.Member_Value (JSON.Parse (To_String (Held.Value)).Item,
                              "snapshots"),
           Which);
      return
        (if JSON."=" (JSON.Kind_Of (Value), JSON.JSON_String)
         then JSON.As_String (Value) else "null");
   end Snapshot_Of;

   --  Trees hands out t1 .. tCount, one to each snapshot.
   procedure Hand_Out
     (Trees : in out Fake_Working_Trees.Fake_Working_Trees; Count : Positive)
   is
   begin
      for I in 1 .. Count loop
         Trees.Snapshots.Append
           (To_Unbounded_String
              ("t" & Ada.Strings.Fixed.Trim (I'Image, Ada.Strings.Left)));
      end loop;
   end Hand_Out;

   procedure Only_The_First_Before_Is_Pinned_As_The_Start
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      Hand_Out (Trees, 4);
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      Assert (R.Run_Session (Request_In_Work (1)).Succeeded, "the first ran");
      Assert (R.Run_Session (Request_In_Work (2)).Succeeded, "the second ran");
      Assert
        (Joined (Trees.Pinned) = "refs/synapse/runs/exec-1/start=t1|",
         "only the first before is pinned, as the start: "
         & Joined (Trees.Pinned));
      Assert
        (Snapshot_Of (Store, "start") = "t1"
         and then Snapshot_Of (Store, "end") = "null",
         "and it is the start in the summary");
   end Only_The_First_Before_Is_Pinned_As_The_Start;

   procedure A_Session_With_No_Before_Pins_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      Assert (R.Run_Session (Request_In_Work (1)).Succeeded, "it ran");
      Assert (Trees.Pinned.Is_Empty, "no snapshot, nothing pinned");
      Assert
        (Snapshot_Of (Store, "start") = "null", "and no start recorded");
   end A_Session_With_No_Before_Pins_Nothing;

   procedure Finish_Pins_The_End (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      Hand_Out (Trees, 3);
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      Assert (R.Run_Session (Request_In_Work (1)).Succeeded, "it ran");
      R.Finish ("/work");
      Assert
        (Trees.Names.Last_Element = "exec-1-end"
         and then Trees.Directories.Last_Element = "/work",
         "the end is a snapshot of the run's folder: " & Joined (Trees.Names));
      Assert
        (Joined (Trees.Pinned)
         = "refs/synapse/runs/exec-1/start=t1|"
           & "refs/synapse/runs/exec-1/end=t3|",
         "pinned as the end: " & Joined (Trees.Pinned));
      Assert
        (Snapshot_Of (Store, "start") = "t1"
         and then Snapshot_Of (Store, "end") = "t3",
         "and both are in the summary");
   end Finish_Pins_The_End;

   procedure Finish_Without_A_Start_Pins_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
      Bare     : Recording_Runner (Inner'Access, Recorder'Access, null);
   begin
      Trees.Snapshots.Append (To_Unbounded_String ("t1"));
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      R.Finish ("/work");
      Bare.Finish ("/work");
      Assert
        (Trees.Pinned.Is_Empty and then Trees.Names.Is_Empty,
         "with no start nothing is taken or pinned");
      Assert (Snapshot_Of (Store, "end") = "null", "and no end recorded");
   end Finish_Without_A_Start_Pins_Nothing;

   procedure A_Failing_Pin_Records_Nothing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Context  : aliased Contexts.Execution_Context;
      Store    : aliased Fake_Registry.Fake_Registry;
      Clock    : aliased Fixed_Clock;
      Recorder : aliased Recorders.Recorder
        (Context'Access, Store'Access, Clock'Access);
      Inner    : aliased Stub_Runner;
      Trees    : aliased Fake_Working_Trees.Fake_Working_Trees;
      R        : Recording_Runner
        (Inner'Access, Recorder'Access, Trees'Access);
   begin
      Inner.Answer := Sessions.Success (Envelopes.Envelope'(others => <>));
      Hand_Out (Trees, 3);
      Trees.Pin_Fails := True;
      Assert (Store.Create ("exec-1") = Registry_Store.Created, "made");
      R.Id := To_Unbounded_String ("exec-1");
      Recorder.Start ("exec-1", True, JSON.Null_Value, Initial_State);
      Assert (R.Run_Session (Request_In_Work (1)).Succeeded, "it ran");
      R.Finish ("/work");
      Assert
        (Snapshot_Of (Store, "start") = "null"
         and then Snapshot_Of (Store, "end") = "null",
         "a snapshot that is not pinned is not recorded");
   end A_Failing_Pin_Records_Nothing;

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
      Register_Routine
        (T, A_Session_Starts_With_An_Event_Before_It_Finishes'Access,
         "A session starts with an event before it finishes");
      Register_Routine
        (T, A_Session_With_No_Working_Trees_Starts_With_No_Before'Access,
         "A session with no working trees starts with no before");
      Register_Routine
        (T, A_Session_That_Changed_Files_Leaves_A_Patch'Access,
         "A session that changed files leaves a patch");
      Register_Routine
        (T, A_Session_That_Changed_Nothing_Leaves_No_Patch'Access,
         "A session that changed nothing leaves no patch");
      Register_Routine
        (T, A_Folder_That_Is_Not_In_A_Repository_Leaves_No_Patch'Access,
         "A folder that is not in a repository leaves no patch");
      Register_Routine
        (T, A_Run_That_Is_Not_Recorded_Keeps_No_Patch'Access,
         "A run that is not recorded keeps no patch");
      Register_Routine
        (T, A_Large_New_File_Is_Kept_As_Its_Path_And_Lines'Access,
         "A large new file is kept as its path and lines");
      Register_Routine
        (T, The_Last_Attempt_Is_Remembered'Access,
         "The last attempt is remembered");
      Register_Routine
        (T, Only_The_First_Before_Is_Pinned_As_The_Start'Access,
         "Only the first before is pinned as the start");
      Register_Routine
        (T, A_Session_With_No_Before_Pins_Nothing'Access,
         "A session with no before pins nothing");
      Register_Routine
        (T, Finish_Pins_The_End'Access, "Finish pins the end");
      Register_Routine
        (T, Finish_Without_A_Start_Pins_Nothing'Access,
         "Finish without a start pins nothing");
      Register_Routine
        (T, A_Failing_Pin_Records_Nothing'Access,
         "A failing pin records nothing");
   end Register_Tests;

end Synapse.Pipeline.Recording_Runners.Tests;
