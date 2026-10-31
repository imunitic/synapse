with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Harnesses;

package body Synapse.Pipeline.States.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package JSON renames Synapse.Core.JSON;

   function Value (Text : String) return JSON.Value is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Parsed.Ok, "the sample is JSON: " & Text);
      return Parsed.Item;
   end Value;

   --  A pipeline of two steps, A and B, and three edges.
   function Pipeline return Resolved.Pipeline is
      Result : Resolved.Pipeline;
   begin
      Result.Name := To_Unbounded_String ("P");
      Result.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String ("A"), Harness => Harnesses.Claude,
            others => <>));
      Result.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String ("B"), Harness => Harnesses.Claude,
            others => <>));
      for I in 1 .. 3 loop
         Result.Edges.Append (Resolved.Edge'(others => <>));
      end loop;
      return Result;
   end Pipeline;

   procedure A_Run_Starts_At_The_First_Step (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      S : constant State := Initial (Pipeline, Value ("{""k"": 1}"));
   begin
      Assert
        (To_String (S.Pipeline) = "P"
         and then To_String (S.Current_Step) = "A"
         and then S.Status = Running and then S.Steps_Run = 0,
         "running, at A, nothing run");
      Assert
        (Natural (S.Fired.Length) = 3
         and then (for all N of S.Fired => N = 0),
         "no edge has fired");
      Assert
        (JSON.Kind_Of (S.Previous_Output) = JSON.JSON_Null
         and then JSON.Has_Member (S.Initial_Input, "k"),
         "no output yet, and the input as given");
      Assert (not Is_Terminal (S), "not over");
   end A_Run_Starts_At_The_First_Step;

   procedure A_New_State_Is_Written_The_Same_Way_Every_Time
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Single : Resolved.Pipeline;
   begin
      Single.Name := To_Unbounded_String ("P");
      Single.Steps.Append
        (Resolved.Step'
           (Name => To_Unbounded_String ("A"), Harness => Harnesses.Claude,
            others => <>));
      Single.Edges.Append (Resolved.Edge'(others => <>));
      Assert
        (To_Text (Initial (Single, Value ("{""k"": 1}"))) =
         "{""format"":""synapse-pipeline-state/v1"",""pipeline"":""P"","
         & """status"":""running"",""current_step"":""A"","
         & """initial_input"":{""k"":1},""previous_output"":null,"
         & """fired"":[0],""steps_run"":0,""failure"":null}",
         "the text: " & To_Text (Initial (Single, Value ("{""k"": 1}"))));
   end A_New_State_Is_Written_The_Same_Way_Every_Time;

   --  Item must read back as itself, as JSON and as text.
   procedure Assert_Round_Trip (Item : State; Label : String) is
      Via_JSON : constant State_Results.Result := From_JSON (To_JSON (Item));
      Via_Text : constant State_Results.Result := Parse (To_Text (Item));
   begin
      Assert
        (State_Results.Is_Success (Via_JSON)
         and then State_Results.Value (Via_JSON) = Item,
         Label & ": as JSON");
      Assert
        (State_Results.Is_Success (Via_Text)
         and then State_Results.Value (Via_Text) = Item,
         Label & ": as text");
   end Assert_Round_Trip;

   procedure Every_State_Survives_The_Round_Trip (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Running_State : State := Initial (Pipeline, Value ("{""k"": [1, 2]}"));
   begin
      Assert_Round_Trip (Running_State, "a new run");
      Running_State.Previous_Output :=
        Value
          ("{""outcome"":""Changes_Requested"",""summary"":""s"","
           & """data"":{""findings"":2}}");
      Running_State.Fired.Replace_Element (1, 1);
      Running_State.Fired.Replace_Element (3, 4);
      Running_State.Steps_Run := 7;
      Running_State.Current_Step := To_Unbounded_String ("B");
      Assert_Round_Trip (Running_State, "a run part way");

      declare
         Done : State := Running_State;
      begin
         Done.Status := Completed;
         Done.Current_Step := Null_Unbounded_String;
         Assert_Round_Trip (Done, "a completed run");
      end;
      declare
         Broken : State := Running_State;
      begin
         Broken.Status := Failed;
         Broken.Failure :=
           (Kind    => Failures.Quota_Exhausted,
            Step    => To_Unbounded_String ("B"),
            Message => To_Unbounded_String ("usage limit reached"),
            Reset   =>
              Synapse.Core.Optional_Text.Of_Value
                (To_Unbounded_String ("2026-11-01T09:00:00Z")));
         Assert_Round_Trip (Broken, "a run that hit a quota");
         Broken.Failure.Kind := Failures.Execution_Error;
         Broken.Failure.Reset := Synapse.Core.Optional_Text.None;
         Assert_Round_Trip (Broken, "a run that failed with no reset time");
      end;
   end Every_State_Survives_The_Round_Trip;

   procedure Only_A_Running_State_Is_Not_Over (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      S : State := Initial (Pipeline, JSON.Null_Value);
   begin
      Assert (not Is_Terminal (S), "running");
      S.Status := Completed;
      Assert (Is_Terminal (S), "completed");
      S.Status := Failed;
      Assert (Is_Terminal (S), "failed");
   end Only_A_Running_State_Is_Not_Over;

   --  Text must be refused, saying Message.
   procedure Assert_Refused (Text, Message, Label : String) is
      R : constant State_Results.Result := Parse (Text);
   begin
      Assert (not State_Results.Is_Success (R), Label & ": refused");
      if not State_Results.Is_Success (R) then
         Assert
           (Ada.Strings.Fixed.Index
              (To_String (State_Results.Error (R)), Message) > 0,
            Label & ": says '" & Message & "', says "
            & To_String (State_Results.Error (R)));
      end if;
   end Assert_Refused;

   Sample : constant String :=
     "{""format"":""synapse-pipeline-state/v1"",""pipeline"":""P"","
     & """status"":""running"",""current_step"":""A"","
     & """initial_input"":null,""previous_output"":null,""fired"":[0],"
     & """steps_run"":0,""failure"":null}";

   function Altered (Was, Now : String) return String is
      At_Index : constant Natural := Ada.Strings.Fixed.Index (Sample, Was);
   begin
      Assert (At_Index > 0, "'" & Was & "' is in the sample");
      return Sample (Sample'First .. At_Index - 1) & Now
        & Sample (At_Index + Was'Length .. Sample'Last);
   end Altered;

   procedure A_Document_That_Is_Wrong_Is_Refused_Where
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (State_Results.Is_Success (Parse (Sample)), "the sample is fine");
      Assert_Refused ("{""a"":", "not JSON", "not JSON");
      Assert_Refused ("[]", "document: expected an object", "not an object");
      Assert_Refused
        (Altered ("state/v1", "state/v9"), "format: expected", "a format");
      Assert_Refused
        (Altered ("""running""", """paused"""),
         "document.status: expected 'running', 'completed' or 'failed'",
         "a status");
      Assert_Refused
        (Altered ("""fired"":[0],", ""), "'fired' is missing", "no fired");
      Assert_Refused
        (Altered ("[0]", "[""x""]"),
         "document.fired[1]: expected a whole number", "a bad count");
      Assert_Refused
        (Altered ("[0]", "[-1]"),
         "document.fired[1]: expected a whole number", "a negative count");
      Assert_Refused
        (Altered ("""steps_run"":0", """steps_run"":-3"),
         "document.steps_run: expected a whole number", "negative steps");
      Assert_Refused
        (Altered ("""running""", """failed"""),
         "document.failure: expected an object",
         "a failed run with no failure");
      Assert_Refused
        (Altered ("""failure"":null",
                  """failure"":{""kind"":""execution_error"","
                  & """step"":""A"",""message"":""m"",""reset"":null}"),
         "a run that has not failed has none", "a failure on a live run");
   end A_Document_That_Is_Wrong_Is_Refused_Where;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.States");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Run_Starts_At_The_First_Step'Access,
         "A run starts at the first step");
      Register_Routine
        (T, A_New_State_Is_Written_The_Same_Way_Every_Time'Access,
         "A new state is written the same way every time");
      Register_Routine
        (T, Every_State_Survives_The_Round_Trip'Access,
         "Every state survives the round trip");
      Register_Routine
        (T, Only_A_Running_State_Is_Not_Over'Access,
         "Only a running state is not over");
      Register_Routine
        (T, A_Document_That_Is_Wrong_Is_Refused_Where'Access,
         "A document that is wrong is refused, saying where");
   end Register_Tests;

end Synapse.Pipeline.States.Tests;
