with Ada.Containers.Vectors;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Routing;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Scripted_Runners;
with Synapse.Pipeline.Scripts;
with Synapse.Pipeline.Sessions;

package body Synapse.Pipeline.Engine.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Failures.Failure_Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package JSON renames Synapse.Core.JSON;

   use type JSON.Kind;
   use type Routing.Count_Vectors.Vector;

   --  What every scripted answer is made of.
   function Done (Outcome : String; Summary : String := "ok") return String is
     ("{""outcome"":""" & Outcome & """,""summary"":""" & Summary
      & """,""data"":{}}");

   procedure Add_Step
     (P : in out Resolved.Pipeline; Name : String; Retries : Natural := 0;
      Timeout : Natural := 0) is
   begin
      P.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String (Name), Harness => Harnesses.Claude,
            Retries => Retries, Timeout_Seconds => Timeout, others => <>));
   end Add_Step;

   procedure Add_Edge
     (P : in out Resolved.Pipeline; From, To : String; Guard : String := "";
      Max : Natural := 0)
   is
      Parsed : constant JSON.Parse_Result :=
        JSON.Parse (if Guard = "" then "null" else Guard);
   begin
      P.Edges.Append
        (Resolved.Edge'
           (From => To_Unbounded_String (From), To => To_Unbounded_String (To),
            Has_Guard => Guard /= "", Guard => Parsed.Item,
            Max_Iterations => Max));
   end Add_Edge;

   Changes_Requested : constant String :=
     "{""=="": [{""var"": ""outcome""}, ""Changes_Requested""]}";

   --  A runner answering from the script.
   function Runner_For (Text : String) return Scripted_Runners.Scripted_Runner
   is
      R : constant Scripted_Runners.Script_Results.Result :=
        Scripted_Runners.Parse (Text);
   begin
      Assert
        (Scripted_Runners.Script_Results.Is_Success (R),
         "the script parses: "
         & (if Scripted_Runners.Script_Results.Is_Success (R) then ""
            else To_String (Scripted_Runners.Script_Results.Error (R))));
      return Scripted_Runners.Create
        (Scripted_Runners.Script_Results.Value_Or (R, Scripts.Empty));
   end Runner_For;

   function Start (P : Resolved.Pipeline) return States.State is
     (States.Initial (P, JSON.Parse ("{""task"":""x""}").Item));

   Settings : constant Configs.Config := (others => <>);

   --  The names of the steps a run goes through, in order, to its end.
   function Trail
     (P      : Resolved.Pipeline;
      Runner : in out Session_Runner.Runner'Class;
      Final  : out States.State) return String
   is
      Visited : Unbounded_String;
      Run     : States.State := Start (P);
   begin
      for Guard in 1 .. 100 loop
         exit when States.Is_Terminal (Run);
         Append (Visited, To_String (Run.Current_Step) & " ");
         Run := Execute_Step (P, Run, Settings, Runner);
      end loop;
      Final := Run;
      return To_String (Visited);
   end Trail;

   procedure A_Pipeline_Runs_Its_Steps_In_Order (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : Resolved.Pipeline;
   begin
      P.Name := To_Unbounded_String ("Straight");
      Add_Step (P, "A");
      Add_Step (P, "B");
      Add_Step (P, "C");
      declare
         R : Scripted_Runners.Scripted_Runner :=
           Runner_For
             ("{""A"":[" & Done ("Done", "from A") & "],""B"":["
              & Done ("Done") & "],""C"":[" & Done ("Done", "last") & "]}");
         Run : States.State := Start (P);
      begin
         Run := Execute_Step (P, Run, Settings, R);
         Assert
           (Run.Status = States.Running
            and then To_String (Run.Current_Step) = "B"
            and then Run.Steps_Run = 1,
            "after A the run is at B");
         Assert
           (JSON.As_String (JSON.Member_Value (Run.Previous_Output, "summary"))
            = "from A",
            "holding A's result");
         Assert
           (JSON.Has_Member (Run.Initial_Input, "task"),
            "and the input it began with");
         Run := Execute_Step (P, Run, Settings, R);
         Run := Execute_Step (P, Run, Settings, R);
         Assert
           (Run.Status = States.Completed
            and then Length (Run.Current_Step) = 0
            and then Run.Steps_Run = 3,
            "past the last step it is completed");
         Assert
           (JSON.As_String (JSON.Member_Value (Run.Previous_Output, "summary"))
            = "last",
            "and its output is the last step's result");
      end;
   end A_Pipeline_Runs_Its_Steps_In_Order;

   procedure A_Review_Loop_Goes_Back_Then_Completes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : Resolved.Pipeline;
   begin
      Add_Step (P, "Develop");
      Add_Step (P, "Test");
      Add_Step (P, "Review");
      Add_Edge (P, "Review", "Develop", Changes_Requested, 5);
      declare
         R : Scripted_Runners.Scripted_Runner :=
           Runner_For
             ("{""Develop"":[" & Done ("Done") & "," & Done ("Done")
              & "],""Test"":[" & Done ("Passed") & "," & Done ("Passed")
              & "],""Review"":[" & Done ("Changes_Requested") & ","
              & Done ("Approved") & "]}");
         Final : States.State;
         Path  : constant String := Trail (P, R, Final);
      begin
         Assert
           (Path = "Develop Test Review Develop Test Review ",
            "it goes back to Develop once: " & Path);
         Assert
           (Final.Status = States.Completed and then Final.Steps_Run = 6
            and then Final.Fired (1) = 1,
            "six steps in all, the edge fired once");
      end;
   end A_Review_Loop_Goes_Back_Then_Completes;

   procedure An_Edge_At_Its_Bound_Falls_Through (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : Resolved.Pipeline;
   begin
      Add_Step (P, "Develop");
      Add_Step (P, "Review");
      Add_Edge (P, "Review", "Develop", Changes_Requested, 1);
      declare
         R : Scripted_Runners.Scripted_Runner :=
           Runner_For
             ("{""Develop"":[" & Done ("Done") & "," & Done ("Done")
              & "],""Review"":[" & Done ("Changes_Requested") & ","
              & Done ("Changes_Requested") & "]}");
         Final : States.State;
         Path  : constant String := Trail (P, R, Final);
      begin
         Assert
           (Path = "Develop Review Develop Review ",
            "it goes back once: " & Path);
         Assert
           (Final.Status = States.Completed and then Final.Fired (1) = 1,
            "and the second time falls through, the last step, to completion");
      end;
   end An_Edge_At_Its_Bound_Falls_Through;

   procedure A_Step_Is_Retried_After_An_Error_Or_A_Bad_Result
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : Resolved.Pipeline;
   begin
      Add_Step (P, "A", Retries => 2);
      declare
         R : Scripted_Runners.Scripted_Runner :=
           Runner_For
             ("{""A"":[{""fail"":""timeout""},"
              & "{""fail"":""result_contract_failure""}," & Done ("Done")
              & "]}");
         Run : constant States.State :=
           Execute_Step (P, Start (P), Settings, R);
      begin
         Assert
           (Run.Status = States.Completed and then Run.Steps_Run = 1
            and then Scripted_Runners.Remaining (R, "A") = 0,
            "the third try gives a result, and one step is counted");
      end;
   end A_Step_Is_Retried_After_An_Error_Or_A_Bad_Result;

   procedure A_Step_Out_Of_Retries_Fails_The_Run (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : Resolved.Pipeline;
   begin
      Add_Step (P, "A", Retries => 1);
      Add_Step (P, "B");
      declare
         R : Scripted_Runners.Scripted_Runner :=
           Runner_For
             ("{""A"":[{""fail"":""timeout""},{""fail"":""execution_error"","
              & """message"":""crashed""}," & Done ("Done") & "]}");
         Before : constant States.State := Start (P);
         Run    : constant States.State :=
           Execute_Step (P, Before, Settings, R);
      begin
         Assert
           (Run.Status = States.Failed
            and then Run.Failure.Kind = Failures.Execution_Error
            and then To_String (Run.Failure.Step) = "A"
            and then To_String (Run.Failure.Message) = "crashed",
            "the last failure is the run's");
         Assert
           (To_String (Run.Current_Step) = "A" and then Run.Steps_Run = 0
            and then Run.Fired = Before.Fired
            and then JSON.Kind_Of (Run.Previous_Output) = JSON.JSON_Null,
            "and nothing moved: it is still at A with no output");
         Assert
           (Scripted_Runners.Remaining (R, "A") = 1,
            "two tries were made, no more");
      end;
   end A_Step_Out_Of_Retries_Fails_The_Run;

   procedure A_Used_Up_Quota_Is_Not_Retried (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      P : Resolved.Pipeline;
   begin
      Add_Step (P, "A", Retries => 3);
      declare
         R : Scripted_Runners.Scripted_Runner :=
           Runner_For
             ("{""A"":[{""fail"":""quota_exhausted"",""reset"":""09:00""},"
              & Done ("Done") & "]}");
         Run : constant States.State :=
           Execute_Step (P, Start (P), Settings, R);
      begin
         Assert
           (Run.Status = States.Failed
            and then Run.Failure.Kind = Failures.Quota_Exhausted
            and then Run.Failure.Reset.Found,
            "the run fails with the quota and when it resets");
         Assert
           (Scripted_Runners.Remaining (R, "A") = 1,
            "the runner was asked once, not four times");
      end;
   end A_Used_Up_Quota_Is_Not_Retried;

   procedure A_Guard_That_Fails_Fails_The_Run (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      P : Resolved.Pipeline;
   begin
      Add_Step (P, "A");
      Add_Step (P, "B");
      Add_Edge (P, "A", "B", "{""var"": ""outcome""}");
      declare
         R : Scripted_Runners.Scripted_Runner :=
           Runner_For ("{""A"":[" & Done ("Done") & "]}");
         Run : constant States.State :=
           Execute_Step (P, Start (P), Settings, R);
      begin
         Assert
           (Run.Status = States.Failed
            and then Run.Failure.Kind = Failures.Execution_Error
            and then Ada.Strings.Fixed.Index
                       (To_String (Run.Failure.Message),
                        "edge A -> B: the guard did not come to true or "
                        & "false") > 0,
            "the run fails, naming the edge");
         Assert
           (To_String (Run.Current_Step) = "A" and then Run.Steps_Run = 0
            and then JSON.Kind_Of (Run.Previous_Output) = JSON.JSON_Null,
            "and its result is not taken");
      end;
   end A_Guard_That_Fails_Fails_The_Run;

   procedure A_Run_Stops_At_The_Ceiling (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      P     : Resolved.Pipeline;
      Small : Configs.Config;
   begin
      Small.Step_Ceiling := 2;
      Add_Step (P, "A");
      Add_Edge (P, "A", "A");
      declare
         R : Scripted_Runners.Scripted_Runner :=
           Runner_For
             ("{""A"":[" & Done ("Done") & "," & Done ("Done") & ","
              & Done ("Done") & "]}");
         Run : States.State := Start (P);
      begin
         Run := Execute_Step (P, Run, Small, R);
         Run := Execute_Step (P, Run, Small, R);
         Assert
           (Run.Status = States.Running and then Run.Steps_Run = 2,
            "two steps are allowed");
         Run := Execute_Step (P, Run, Small, R);
         Assert
           (Run.Status = States.Failed
            and then Run.Failure.Kind = Failures.Ceiling_Reached
            and then Run.Steps_Run = 2
            and then Scripted_Runners.Remaining (R, "A") = 1,
            "the third is refused before its session is asked for");
      end;
   end A_Run_Stops_At_The_Ceiling;

   --  A runner that keeps what it is asked, and answers from a script.
   package Request_Vectors is new Ada.Containers.Vectors
     (Positive, Sessions.Session_Request, Sessions."=");

   type Recording_Runner is limited new Session_Runner.Runner with record
      Inner : Scripted_Runners.Scripted_Runner;
      Seen  : Request_Vectors.Vector;
   end record;

   overriding
   function Run_Session
     (R : in out Recording_Runner; Request : Sessions.Session_Request)
      return Sessions.Session_Result
   is
   begin
      R.Seen.Append (Request);
      return R.Inner.Run_Session (Request);
   end Run_Session;

   procedure The_Runner_Is_Asked_With_The_Step_The_State_And_The_Limits
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : Resolved.Pipeline;
      Limits : Configs.Config;
   begin
      Limits.Default_Timeout_Seconds := 600;
      Add_Step (P, "A", Retries => 1, Timeout => 90);
      Add_Step (P, "B");
      declare
         R : Recording_Runner :=
           (Inner =>
              Runner_For
                ("{""A"":[{""fail"":""timeout""}," & Done ("Done", "from A")
                 & "],""B"":[" & Done ("Done") & "]}"),
            Seen => <>);
         Run : States.State := Start (P);
      begin
         Run := Execute_Step (P, Run, Limits, R);
         Run := Execute_Step (P, Run, Limits, R);
         Assert (Natural (R.Seen.Length) = 3, "A twice, then B");
         Assert
           (R.Seen (1).Attempt = 1 and then R.Seen (2).Attempt = 2
            and then R.Seen (3).Attempt = 1,
            "the attempt number counts the retries");
         Assert
           (R.Seen (1).Timeout_Seconds = 90
            and then R.Seen (3).Timeout_Seconds = 600,
            "a step's own timeout, else the configuration's");
         Assert
           (JSON.Kind_Of (R.Seen (2).Previous_Output) = JSON.JSON_Null
            and then JSON.Has_Member (R.Seen (3).Previous_Output, "summary")
            and then JSON.Has_Member (R.Seen (3).Initial_Input, "task"),
            "A's retry has no output before it; B is given A's result and "
            & "the input");
      end;
   end The_Runner_Is_Asked_With_The_Step_The_State_And_The_Limits;

   procedure A_State_At_A_Step_The_Pipeline_Lacks_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : Resolved.Pipeline;
   begin
      Add_Step (P, "A");
      declare
         R : Scripted_Runners.Scripted_Runner := Runner_For ("{}");
         Run : States.State := Start (P);
      begin
         Run.Current_Step := To_Unbounded_String ("Elsewhere");
         Run := Execute_Step (P, Run, Settings, R);
         Assert
           (Run.Status = States.Failed
            and then Ada.Strings.Fixed.Index
                       (To_String (Run.Failure.Message),
                        "which the pipeline does not have") > 0,
            "it fails and does not raise");
      end;
   end A_State_At_A_Step_The_Pipeline_Lacks_Fails;

   --  Develop, then Review, which sends the run back to Develop while it asks
   --  for changes.
   function Review_Loop return Resolved.Pipeline is
      P : Resolved.Pipeline;
   begin
      P.Name := To_Unbounded_String ("Loop");
      Add_Step (P, "Develop");
      Add_Step (P, "Review");
      Add_Edge (P, "Review", "Develop", Changes_Requested, Max => 2);
      return P;
   end Review_Loop;

   function Text_Of (Item : States.State) return String is
     (JSON.To_String (States.To_JSON (Item)));

   procedure Advance_Routes_As_A_Step_Does (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      P      : constant Resolved.Pipeline := Review_Loop;
      Output : constant String := Done ("Changes_Requested", "one issue");
      R      : Scripted_Runners.Scripted_Runner :=
        Runner_For ("{""Develop"":[" & Done ("Done") & "],""Review"":["
                    & Output & "]}");
      Run    : States.State := Start (P);
   begin
      Run := Execute_Step (P, Run, Settings, R);
      declare
         By_Step    : constant States.State :=
           Execute_Step (P, Run, Settings, R);
         By_Advance : constant States.State :=
           Advance (P, Run, JSON.Parse (Output).Item);
      begin
         Assert
           (Text_Of (By_Step) = Text_Of (By_Advance),
            "the state is the same: " & Text_Of (By_Advance));
         Assert
           (To_String (By_Advance.Current_Step) = "Develop"
            and then By_Advance.Fired.Last_Index = 1
            and then By_Advance.Fired (1) = 1
            and then By_Advance.Steps_Run = 2,
            "back to Develop along the edge, which has fired once");
      end;
   end Advance_Routes_As_A_Step_Does;

   procedure Advance_Falls_Through_Completes_And_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P    : constant Resolved.Pipeline := Review_Loop;
      Mine : Resolved.Pipeline := Review_Loop;
      Run  : States.State := Start (P);
   begin
      Run := Advance (P, Run, JSON.Parse (Done ("Done")).Item);
      Assert
        (To_String (Run.Current_Step) = "Review"
         and then Run.Fired (1) = 0,
         "no edge leaves Develop, so the next declared step");
      Run := Advance (P, Run, JSON.Parse (Done ("Approved")).Item);
      Assert
        (Run.Status = States.Completed and then Length (Run.Current_Step) = 0,
         "no guard holds after the last step, so the run completes");
      Assert
        (JSON.As_String (JSON.Member_Value (Run.Previous_Output, "outcome")) =
         "Approved",
         "holding the result that ended it");

      Mine.Edges.Clear;
      Add_Edge (Mine, "Develop", "Review", "{""nope"":[1]}");
      declare
         Failed : constant States.State :=
           Advance (Mine, Start (Mine), JSON.Parse (Done ("Done")).Item);
      begin
         Assert
           (Failed.Status = States.Failed
            and then Failed.Failure.Kind = Failures.Execution_Error
            and then Failed.Steps_Run = 0,
            "a guard that fails fails the run, which stays as it was");
      end;

      declare
         Lost : States.State := Start (P);
      begin
         Lost.Current_Step := To_Unbounded_String ("Gone");
         Assert
           (Advance (P, Lost, JSON.Parse (Done ("Done")).Item).Status =
            States.Failed,
            "a step the pipeline lacks fails the run");
      end;
   end Advance_Falls_Through_Completes_And_Fails;

   procedure Hold_To_Ceiling_Fails_Only_A_Run_That_Is_Over
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P     : constant Resolved.Pipeline := Review_Loop;
      Small : Configs.Config := Settings;
      Run   : States.State := Start (P);
   begin
      Small.Step_Ceiling := 2;
      Run.Steps_Run := 1;
      Assert
        (Text_Of (Hold_To_Ceiling (Run, Small)) = Text_Of (Run),
         "below the ceiling the run is unchanged");
      Run.Steps_Run := 2;
      declare
         Held : constant States.State := Hold_To_Ceiling (Run, Small);
      begin
         Assert
           (Held.Status = States.Failed
            and then Held.Failure.Kind = Failures.Ceiling_Reached
            and then To_String (Held.Failure.Step) = "Develop",
            "at the ceiling the step that would run next is the one that "
            & "fails");
      end;
      Run.Status := States.Completed;
      Assert
        (Hold_To_Ceiling (Run, Small).Status = States.Completed,
         "a run that is over is left as it is");
   end Hold_To_Ceiling_Fails_Only_A_Run_That_Is_Over;

   --  Check, then Build, with Check sending the run to End on Discussing.
   function Gate return Resolved.Pipeline is
      P : Resolved.Pipeline;
   begin
      P.Name := To_Unbounded_String ("Gate");
      Add_Step (P, "Check");
      Add_Step (P, "Build");
      Add_Edge
        (P, "Check", "End",
         "{""=="": [{""var"": ""outcome""}, ""Discussing""]}", Max => 1);
      return P;
   end Gate;

   procedure An_Edge_To_End_Completes_The_Run (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      P : constant Resolved.Pipeline := Gate;
   begin
      declare
         Ended : constant States.State :=
           Advance (P, Start (P), JSON.Parse (Done ("Discussing")).Item);
      begin
         Assert
           (Ended.Status = States.Completed
            and then Length (Ended.Current_Step) = 0
            and then Ended.Steps_Run = 1
            and then Ended.Fired (1) = 1,
            "the edge fires and the run is complete: " & Text_Of (Ended));
         Assert
           (JSON.As_String
              (JSON.Member_Value (Ended.Previous_Output, "outcome")) =
            "Discussing",
            "the result of the step that ended it");
      end;
      declare
         Open : constant States.State :=
           Advance (P, Start (P), JSON.Parse (Done ("Ready")).Item);
      begin
         Assert
           (Open.Status = States.Running
            and then To_String (Open.Current_Step) = "Build"
            and then Open.Fired (1) = 0,
            "a guard that does not hold falls to the next step");
      end;
      declare
         Spent : States.State := Start (P);
      begin
         Spent.Fired.Replace_Element (1, 1);
         Assert
           (To_String
              (Advance (P, Spent, JSON.Parse (Done ("Discussing")).Item)
                 .Current_Step) = "Build",
            "an edge to End at its bound is passed over like any other");
      end;
   end An_Edge_To_End_Completes_The_Run;

   procedure A_Run_Ends_At_End_Without_Running_The_Rest
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : constant Resolved.Pipeline := Gate;
      R : Scripted_Runners.Scripted_Runner :=
        Runner_For ("{""Check"":[" & Done ("Discussing") & "]}");
      Final : States.State;
   begin
      Assert
        (Trail (P, R, Final) = "Check ",
         "only Check ran, and Build, which has no answer, was not asked");
      Assert (Final.Status = States.Completed, "and the run is complete");
   end A_Run_Ends_At_End_Without_Running_The_Rest;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Engine");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Pipeline_Runs_Its_Steps_In_Order'Access,
         "A pipeline runs its steps in order");
      Register_Routine
        (T, A_Review_Loop_Goes_Back_Then_Completes'Access,
         "A review loop goes back then completes");
      Register_Routine
        (T, An_Edge_At_Its_Bound_Falls_Through'Access,
         "An edge at its bound falls through");
      Register_Routine
        (T, A_Step_Is_Retried_After_An_Error_Or_A_Bad_Result'Access,
         "A step is retried after an error or a bad result");
      Register_Routine
        (T, A_Step_Out_Of_Retries_Fails_The_Run'Access,
         "A step out of retries fails the run");
      Register_Routine
        (T, A_Used_Up_Quota_Is_Not_Retried'Access,
         "A used-up quota is not retried");
      Register_Routine
        (T, A_Guard_That_Fails_Fails_The_Run'Access,
         "A guard that fails fails the run");
      Register_Routine
        (T, A_Run_Stops_At_The_Ceiling'Access, "A run stops at the ceiling");
      Register_Routine
        (T, The_Runner_Is_Asked_With_The_Step_The_State_And_The_Limits'Access,
         "The runner is asked with the step, the state and the limits");
      Register_Routine
        (T, A_State_At_A_Step_The_Pipeline_Lacks_Fails'Access,
         "A state at a step the pipeline lacks fails");
      Register_Routine
        (T, Advance_Routes_As_A_Step_Does'Access,
         "Advance routes as a step does");
      Register_Routine
        (T, Advance_Falls_Through_Completes_And_Fails'Access,
         "Advance falls through, completes and fails");
      Register_Routine
        (T, Hold_To_Ceiling_Fails_Only_A_Run_That_Is_Over'Access,
         "Hold_To_Ceiling fails only a run that is over");
      Register_Routine
        (T, An_Edge_To_End_Completes_The_Run'Access,
         "An edge to End completes the run");
      Register_Routine
        (T, A_Run_Ends_At_End_Without_Running_The_Rest'Access,
         "A run ends at End without running the rest");
   end Register_Tests;

end Synapse.Pipeline.Engine.Tests;
