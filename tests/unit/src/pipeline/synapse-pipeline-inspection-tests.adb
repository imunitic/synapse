with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Interfaces;

with AUnit.Assertions;

with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;

package body Synapse.Pipeline.Inspection.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type JSON.Kind;
   use type JSON.Value;
   use type Interfaces.Unsigned_32;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Value (Text : String) return JSON.Value is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Parsed.Ok, "the sample is JSON: " & Text);
      return Parsed.Item;
   end Value;

   --  A run at the second of two steps with three events behind it.
   function Seen_Run (Input : String := "{""task"":""x""}") return Snapshot is
      Pipeline : Resolved.Pipeline;
      Result   : Snapshot;
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
      Result.Execution_Id := To_Unbounded_String ("exec-1");
      Result.Description :=
        Value ("{""format"":""d/v1"",""name"":""P"",""steps"":[]}");
      Result.Run := States.Initial (Pipeline, Value (Input));
      Result.Run.Current_Step := To_Unbounded_String ("B");
      Result.Run.Steps_Run := 1;
      Result.Run.Previous_Output :=
        Value ("{""outcome"":""Done"",""summary"":""s"",""data"":{}}");
      for N in 1 .. 3 loop
         Result.Events.Append
           (Event'
              (Sequence => N,
               Kind => To_Unbounded_String ("step.finished"),
               Step => To_Unbounded_String ("A"),
               Detail => Value ("{""n"":" & Integer'Image (N) & "}")));
      end loop;
      return Result;
   end Seen_Run;

   --  The result of a request that is answered ok, or a failed assertion.
   function Result_Of (Seen : Snapshot; Request : String) return JSON.Value is
      Reply : constant JSON.Parse_Result :=
        JSON.Parse (Respond (Seen, Request));
   begin
      Assert (Reply.Ok, "the answer is JSON for " & Request);
      Assert
        (JSON.Has_Member (Reply.Item, "ok")
         and then JSON.As_Boolean (JSON.Member_Value (Reply.Item, "ok")),
         "answered ok: " & Request & " -> " & Respond (Seen, Request));
      return JSON.Member_Value (Reply.Item, "result");
   end Result_Of;

   --  The request must be refused, saying Message.
   procedure Assert_Refused
     (Seen : Snapshot; Request, Message, Label : String)
   is
      Text  : constant String := Respond (Seen, Request);
      Reply : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Reply.Ok, Label & ": the answer is JSON");
      Assert
        (JSON.Has_Member (Reply.Item, "ok")
         and then not JSON.As_Boolean (JSON.Member_Value (Reply.Item, "ok")),
         Label & ": refused: " & Text);
      Assert
        (Ada.Strings.Fixed.Index (Text, Message) > 0,
         Label & ": says '" & Message & "', says " & Text);
   end Assert_Refused;

   procedure Info_Is_The_Run_In_Brief (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Brief : constant JSON.Value :=
        Result_Of (Seen_Run, "{""command"":""info""}");
   begin
      Assert
        (JSON.As_String (JSON.Member_Value (Brief, "execution_id")) = "exec-1"
         and then JSON.As_String (JSON.Member_Value (Brief, "pipeline")) = "P"
         and then JSON.As_String (JSON.Member_Value (Brief, "status")) =
                  "running"
         and then JSON.As_String (JSON.Member_Value (Brief, "current_step")) =
                  "B"
         and then JSON.As_Integer (JSON.Member_Value (Brief, "steps_run")) = 1
         and then JSON.Kind_Of (JSON.Member_Value (Brief, "failure")) =
                  JSON.JSON_Null,
         "who, what, where");
      declare
         Broken : Snapshot := Seen_Run;
      begin
         Broken.Run.Status := States.Failed;
         Broken.Run.Failure :=
           (Kind => Failures.Quota_Exhausted,
            Step => To_Unbounded_String ("B"),
            Message => To_Unbounded_String ("limit"), Reset => <>);
         Assert
           (JSON.Kind_Of
              (JSON.Member_Value
                 (Result_Of (Broken, "{""command"":""info""}"), "failure")) =
            JSON.JSON_Object,
            "a failed run says why");
      end;
   end Info_Is_The_Run_In_Brief;

   procedure State_Is_The_Whole_State (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Seen : constant Snapshot := Seen_Run;
   begin
      Assert
        (Result_Of (Seen, "{""command"":""state""}") =
         States.To_JSON (Seen.Run),
         "exactly the state document");
   end State_Is_The_Whole_State;

   procedure Events_Come_Oldest_First_And_After_A_Point
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      All_Events : constant JSON.Value :=
        Result_Of (Seen_Run, "{""command"":""events""}");
      Later      : constant JSON.Value :=
        Result_Of (Seen_Run, "{""command"":""events"",""after"":1}");
   begin
      Assert
        (JSON.Length (All_Events) = 3
         and then JSON.As_Integer
                    (JSON.Member_Value
                       (JSON.Element (All_Events, 1), "sequence")) = 1
         and then JSON.As_Integer
                    (JSON.Member_Value
                       (JSON.Element (All_Events, 3), "sequence")) = 3,
         "all three, in order");
      Assert
        (JSON.Length (Later) = 2
         and then JSON.As_Integer
                    (JSON.Member_Value (JSON.Element (Later, 1), "sequence"))
                  = 2,
         "those after the first");
      Assert
        (JSON.Length
           (Result_Of (Seen_Run, "{""command"":""events"",""after"":3}")) = 0,
         "none after the last");
      Assert_Refused
        (Seen_Run, "{""command"":""events"",""after"":""x""}",
         "'after' is a whole number", "after as text");
      Assert_Refused
        (Seen_Run, "{""command"":""events"",""after"":-1}",
         "'after' is a whole number", "after below zero");
   end Events_Come_Oldest_First_And_After_A_Point;

   procedure A_Query_Is_Evaluated_Over_The_Run (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      function Query (Rule : String) return JSON.Value is
        (Result_Of
           (Seen_Run, "{""command"":""query"",""expression"":" & Rule & "}"));
   begin
      Assert
        (JSON.As_String (Query ("{""var"":""current_step""}")) = "B",
         "a member of the brief");
      Assert
        (JSON.As_String (Query ("{""var"":""state.initial_input.task""}")) =
         "x",
         "something in the state");
      Assert
        (JSON.As_String
           (Query ("{""var"":""state.previous_output.outcome""}")) = "Done",
         "the last result");
      Assert
        (JSON.As_Boolean
           (Query ("{""=="":[{""var"":""status""},""running""]}")),
         "a comparison");
      Assert
        (JSON.Length (Query ("{""var"":""events""}")) = 3, "the events");
      Assert
        (JSON.Kind_Of (Query ("{""var"":""events.1.kind""}")) =
         JSON.JSON_Null,
         "a path goes through objects only, not into a list");
      Assert
        (JSON.Kind_Of (Query ("{""var"":""nothing.here""}")) = JSON.JSON_Null,
         "what is not there is null");
   end A_Query_Is_Evaluated_Over_The_Run;

   procedure Nothing_That_Changes_The_Run_Is_A_Command
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Refused
        (Seen_Run, "{""command"":""execute""}",
         "'execute' is not a command; the commands are info, state, pipeline, "
         & "events and query", "execute");
      Assert_Refused
        (Seen_Run, "{""command"":""advance""}", "'advance' is not a command",
         "advance");
      Assert_Refused
        (Seen_Run, "{""command"":""retry""}", "'retry' is not a command",
         "retry");
      Assert_Refused
        (Seen_Run, "{""command"":""cancel""}", "'cancel' is not a command",
         "cancel");
   end Nothing_That_Changes_The_Run_Is_A_Command;

   procedure A_Request_That_Is_Wrong_Is_Refused (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Refused (Seen_Run, "{""command"":", "not JSON", "not JSON");
      Assert_Refused (Seen_Run, "[]", "not an object", "a list");
      Assert_Refused (Seen_Run, "{}", "has no command", "no command");
      Assert_Refused
        (Seen_Run, "{""command"":3}", "has no command", "a number command");
      Assert_Refused
        (Seen_Run, "{""command"":""query""}", "a query has an 'expression'",
         "a query with nothing to ask");
      Assert_Refused
        (Seen_Run,
         "{""command"":""query"",""expression"":{""frob"":[1]}}",
         "operator that does not exist: frob", "an unknown operator");
      Assert_Refused
        (Seen_Run,
         "{""command"":""query"",""expression"":{""=="":[1]}}",
         "too few arguments", "too few arguments");
   end A_Request_That_Is_Wrong_Is_Refused;

   procedure The_Limits_Are_Enforced (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Big_Request : constant String :=
        "{""command"":""info"",""pad"":""" & [1 .. Max_Request_Bytes => 'x']
        & """}";
      Huge_Input  : constant String :=
        "{""blob"":""" & [1 .. Max_Response_Bytes + 10 => 'x'] & """}";
   begin
      Assert_Refused
        (Seen_Run, Big_Request, "the request is larger than", "a big request");
      Assert_Refused
        (Seen_Run (Huge_Input), "{""command"":""state""}",
         "the answer is larger than", "a big answer");
      Assert
        (JSON.Has_Member
           (Result_Of (Seen_Run (Huge_Input), "{""command"":""info""}"),
            "status"),
         "while the brief still comes");
   end The_Limits_Are_Enforced;

   procedure Garbage_Never_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Alphabet : constant String :=
        "{}[]"":,0123 cmdinfosteqrxu\" & Character'Val (0)
        & Character'Val (200);
      Seed     : Interfaces.Unsigned_32 := 4242;

      function Next (Limit : Positive) return Positive is
      begin
         Seed := Seed * 1664525 + 1013904223;
         return Natural (Seed / 65536) mod Limit + 1;
      end Next;
   begin
      for Round in 1 .. 3000 loop
         declare
            Text : String (1 .. Next (40));
         begin
            for I in Text'Range loop
               Text (I) := Alphabet (Next (Alphabet'Length));
            end loop;
            declare
               Reply : constant JSON.Parse_Result :=
                 JSON.Parse (Respond (Seen_Run, Text));
            begin
               Assert
                 (Reply.Ok and then JSON.Has_Member (Reply.Item, "ok"),
                  "always an answer: round" & Round'Image);
            end;
         exception
            when others =>
               Assert (False, "raised on round" & Round'Image);
         end;
      end loop;
   end Garbage_Never_Raises;

   procedure Pipeline_Is_What_The_Run_Executes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Seen   : constant Snapshot := Seen_Run;
      Answer : constant JSON.Value :=
        Result_Of (Seen, "{""command"":""pipeline""}");
   begin
      Assert (Answer = Seen.Description, "the description it started with");
      Assert
        (not JSON.Has_Member
               (Result_Of (Seen, "{""command"":""info""}"), "steps"),
         "the brief stays brief");
      Assert
        (JSON.As_String
           (Result_Of
              (Seen,
               "{""command"":""query"",""expression"":"
               & "{""var"":""pipeline.name""}}")) = "P",
         "a query reaches into it");
      Assert
        (JSON.Kind_Of
           (Result_Of
              (Seen,
               "{""command"":""query"",""expression"":"
               & "{""var"":""pipeline.steps""}}")) = JSON.JSON_Array,
         "its steps");
   end Pipeline_Is_What_The_Run_Executes;

   procedure A_Description_Over_The_Limit_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Seen : Snapshot := Seen_Run;
   begin
      Seen.Description :=
        JSON.Make_String (Ada.Strings.Fixed."*" (Max_Response_Bytes + 1, 'x'));
      Assert_Refused
        (Seen, "{""command"":""pipeline""}", "the answer is larger than",
         "an enormous pipeline");
   end A_Description_Over_The_Limit_Is_Refused;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Inspection");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Info_Is_The_Run_In_Brief'Access, "Info is the run in brief");
      Register_Routine
        (T, State_Is_The_Whole_State'Access, "State is the whole state");
      Register_Routine
        (T, Events_Come_Oldest_First_And_After_A_Point'Access,
         "Events come oldest first and after a point");
      Register_Routine
        (T, A_Query_Is_Evaluated_Over_The_Run'Access,
         "A query is evaluated over the run");
      Register_Routine
        (T, Nothing_That_Changes_The_Run_Is_A_Command'Access,
         "Nothing that changes the run is a command");
      Register_Routine
        (T, A_Request_That_Is_Wrong_Is_Refused'Access,
         "A request that is wrong is refused");
      Register_Routine
        (T, The_Limits_Are_Enforced'Access, "The limits are enforced");
      Register_Routine
        (T, Garbage_Never_Raises'Access, "Garbage never raises");
      Register_Routine
        (T, Pipeline_Is_What_The_Run_Executes'Access,
         "Pipeline is what the run executes");
      Register_Routine
        (T, A_Description_Over_The_Limit_Is_Refused'Access,
         "A description over the limit is refused");
   end Register_Tests;

end Synapse.Pipeline.Inspection.Tests;
