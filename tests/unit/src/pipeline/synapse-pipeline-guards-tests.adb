with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON_Logic;

package body Synapse.Pipeline.Guards.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   Approved : constant String :=
     "{""=="": [{""var"": ""outcome""}, ""Approved""]}";

   function Rule (Text : String) return JSON.Value is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Parsed.Ok, "the sample is JSON: " & Text);
      return Parsed.Item;
   end Rule;

   function Data_Of (Text : String) return JSON.Value is (Rule (Text));

   --  The result of a step.
   function Result
     (Outcome : String; Data : String := "{}") return JSON.Value is
     (View (Outcome, "a summary", Data_Of (Data)));

   --  Whether the guard holds, which it must be able to say.
   function Holds_Of (Guard : String; Of_Result : JSON.Value) return Boolean is
      R : constant Guard_Results.Result := Holds (Rule (Guard), Of_Result);
   begin
      Assert
        (Guard_Results.Is_Success (R),
         "evaluates: " & Guard & " -> "
         & (if Guard_Results.Is_Success (R) then ""
            else To_String (Guard_Results.Error (R))));
      return Guard_Results.Is_Success (R) and then Guard_Results.Value (R);
   end Holds_Of;

   --  The guard must fail, saying Message.
   procedure Assert_Fails
     (Guard, Message, Label : String; Of_Result : JSON.Value) is
      R : constant Guard_Results.Result := Holds (Rule (Guard), Of_Result);
   begin
      Assert (not Guard_Results.Is_Success (R), Label & ": fails");
      if not Guard_Results.Is_Success (R) then
         Assert
           (Ada.Strings.Fixed.Index
              (To_String (Guard_Results.Error (R)), Message) > 0,
            Label & ": says '" & Message & "', says "
            & To_String (Guard_Results.Error (R)));
      end if;
   end Assert_Fails;

   procedure A_Guard_Tests_The_Outcome_And_The_Data
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Holds_Of (Approved, Result ("Approved")), "the outcome");
      Assert (not Holds_Of (Approved, Result ("Rejected")), "another outcome");
      Assert
        (Holds_Of
           ("{"">"": [{""var"": ""data.findings""}, 0]}",
            Result ("Changes_Requested", "{""findings"": 2}")),
         "a field of the data");
      Assert
        (not Holds_Of
               ("{"">"": [{""var"": ""data.findings""}, 0]}",
                Result ("Changes_Requested", "{""findings"": 0}")),
         "and not when it is zero");
      Assert
        (Holds_Of
           ("{""and"": [" & Approved
            & ", {""<"": [{""var"": ""data.score""}, 5]}]}",
            Result ("Approved", "{""score"": 3}")),
         "rules combine");
      Assert
        (Holds_Of
           ("{""=="": [{""var"": ""summary""}, ""a summary""]}",
            Result ("Approved")),
         "the summary");
   end A_Guard_Tests_The_Outcome_And_The_Data;

   procedure A_Missing_Field_Reads_As_Null (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Holds_Of
           ("{""=="": [{""var"": ""data.nothing""}, null]}", Result ("x")),
         "a field the data lacks is null");
      Assert
        (not Holds_Of
               ("{"">"": [{""var"": ""data.nothing""}, 0]}", Result ("x")),
         "and is not more than zero");
   end A_Missing_Field_Reads_As_Null;

   procedure A_Guard_Sees_Only_Outcome_Summary_And_Data
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Document : constant JSON.Value :=
        Rule
          ("{""outcome"": ""Approved"", ""summary"": ""s"", ""data"": {},"
           & " ""secret"": 1, ""environment"": {""TOKEN"": ""x""}}");
   begin
      Assert
        (Holds_Of ("{""=="": [{""var"": ""secret""}, null]}", Document),
         "another member is not there to read");
      Assert
        (Holds_Of
           ("{""=="": [{""var"": ""environment.TOKEN""}, null]}", Document),
         "nor is the environment");
      Assert (Holds_Of (Approved, Document), "while the outcome is");
   end A_Guard_Sees_Only_Outcome_Summary_And_Data;

   procedure Only_A_Boolean_Is_An_Answer (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert_Fails
        ("{""var"": ""data.n""}", "did not come to true or false",
         "a number", Result ("x", "{""n"": 3}"));
      Assert_Fails
        ("{""var"": ""outcome""}", "did not come to true or false",
         "a string", Result ("Approved"));
      Assert_Fails
        ("{""var"": ""data.nothing""}", "did not come to true or false",
         "null", Result ("x"));
   end Only_A_Boolean_Is_An_Answer;

   procedure A_Guard_That_Cannot_Run_Fails_And_Does_Not_Raise
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Fails
        ("{""frob"": [1]}", "operator that does not exist: frob",
         "an unknown operator", Result ("x"));
      Assert_Fails
        ("{""=="": [1]}", "too few arguments", "too few arguments",
         Result ("x"));
   end A_Guard_That_Cannot_Run_Fails_And_Does_Not_Raise;

   procedure A_Rule_Is_Checked_Without_Being_Run (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (not Problem (Rule (Approved)).Found, "a sound rule");
      Assert
        (not Problem
               (Rule
                  ("{""and"": [" & Approved
                   & ", {""in"": [""a"", {""var"": ""data.tags""}]}]}")).Found,
         "nested sound rules");
      Assert
        (Problem (Rule ("{""frob"": [1]}")).Found
         and then Ada.Strings.Fixed.Index
                    (To_String (Problem (Rule ("{""frob"": [1]}")).Value),
                     "'frob' is not a JsonLogic operator") > 0,
         "an unknown operator");
      Assert
        (Problem
           (Rule ("{""and"": [" & Approved & ", {""nope"": 1}]}")).Found,
         "an unknown operator inside another rule");
      Assert (Problem (Rule ("[1, 2]")).Found, "a list is not a rule");
      Assert
        (Problem (Rule ("{""=="": [1, 1], ""x"": 2}")).Found,
         "two keys are not one rule");
      Assert (Problem (Rule ("{}")).Found, "nor are none");
      for I in 1 .. Synapse.Core.JSON_Logic.Built_In_Count loop
         declare
            Name : constant String :=
              Synapse.Core.JSON_Logic.Built_In_Name (I);
         begin
            Assert
              (not Problem (Rule ("{""" & Name & """: []}")).Found,
               "the operator '" & Name & "' is known");
         end;
      end loop;
   end A_Rule_Is_Checked_Without_Being_Run;

   --  The edges of a small pipeline: 1 A->B, 2 B->A on Changes_Requested up
   --  to 3 times, 3 B->B when data.n is 1 up to 2 times, 4 B->C unguarded.
   function Edges return Resolved.Edge_Vectors.Vector is
      Result : Resolved.Edge_Vectors.Vector;

      function Edge
        (From, To : String; Guard : String := ""; Max : Natural := 0)
         return Resolved.Edge
      is
        (From => To_Unbounded_String (From), To => To_Unbounded_String (To),
         Has_Guard => Guard /= "",
         Guard => (if Guard = "" then JSON.Null_Value else Rule (Guard)),
         Max_Iterations => Max);
   begin
      Result.Append (Edge ("A", "B"));
      Result.Append
        (Edge
           ("B", "A",
            "{""=="": [{""var"": ""outcome""}, ""Changes_Requested""]}", 3));
      Result.Append
        (Edge ("B", "B", "{""=="": [{""var"": ""data.n""}, 1]}", 2));
      Result.Append (Edge ("B", "C"));
      return Result;
   end Edges;

   function Counts (A, B, C, D : Natural) return Count_Vectors.Vector is
      Result : Count_Vectors.Vector;
   begin
      Result.Append (A);
      Result.Append (B);
      Result.Append (C);
      Result.Append (D);
      return Result;
   end Counts;

   --  The edge that fires from Step, or 0.
   function Fires
     (Fired : Count_Vectors.Vector; Step : String; Of_Result : JSON.Value)
      return Natural
   is
      R : constant Route_Results.Result :=
        Route_After (Edges, Fired, Step, Of_Result);
   begin
      Assert
        (Route_Results.Is_Success (R),
         "routes: "
         & (if Route_Results.Is_Success (R) then ""
            else To_String (Route_Results.Error (R))));
      return (if Route_Results.Is_Success (R)
                and then Route_Results.Value (R).Fires
              then Route_Results.Value (R).Edge else 0);
   end Fires;

   procedure The_First_Edge_Whose_Guard_Holds_Fires
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      None : constant Count_Vectors.Vector := Counts (0, 0, 0, 0);
   begin
      Assert (Fires (None, "A", Result ("x")) = 1, "an unguarded edge");
      Assert
        (Fires (None, "B", Result ("Changes_Requested")) = 2,
         "a guard that holds");
      Assert
        (Fires (None, "B", Result ("Changes_Requested", "{""n"": 1}")) = 2,
         "the first of two that hold, in the order written");
      Assert
        (Fires (None, "B", Result ("Approved", "{""n"": 1}")) = 3,
         "the second when only it holds");
      Assert
        (Fires (None, "B", Result ("Approved")) = 4,
         "the unguarded one when no guard holds");
      Assert (Fires (None, "C", Result ("x")) = 0, "no edge leaves C");
      Assert (Fires (None, "a", Result ("x")) = 0, "names are exact");
   end The_First_Edge_Whose_Guard_Holds_Fires;

   procedure An_Edge_That_Has_Fired_Its_Bound_Is_Passed_Over
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Changes : constant JSON.Value :=
        Result ("Changes_Requested", "{""n"": 1}");
   begin
      Assert
        (Fires (Counts (0, 2, 0, 0), "B", Changes) = 2, "one short of 3");
      Assert
        (Fires (Counts (0, 3, 0, 0), "B", Changes) = 3,
         "at its bound, so the next that holds");
      Assert
        (Fires (Counts (0, 3, 2, 0), "B", Changes) = 4,
         "both at their bounds, so the unguarded");
      Assert
        (Fires (Counts (9, 0, 0, 9), "A", Result ("x")) = 1,
         "an edge with no bound never runs out");
      Assert
        (Fires (Counts (0, 3, 2, 9), "B", Changes) = 4,
         "even after many");
      declare
         Short : Count_Vectors.Vector;
      begin
         Assert
           (Fires (Short, "B", Result ("Changes_Requested")) = 2,
            "a counts list shorter than the edges means none fired");
      end;
   end An_Edge_That_Has_Fired_Its_Bound_Is_Passed_Over;

   procedure A_Guard_That_Fails_Fails_The_Routing (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Broken : Resolved.Edge_Vectors.Vector;
   begin
      Broken.Append
        (Resolved.Edge'
           (From => To_Unbounded_String ("A"),
            To => To_Unbounded_String ("B"), Has_Guard => True,
            Guard => Rule ("{""var"": ""outcome""}"), others => <>));
      declare
         R : constant Route_Results.Result :=
           Route_After (Broken, Count_Vectors.Empty_Vector, "A", Result ("x"));
      begin
         Assert
           (not Route_Results.Is_Success (R)
            and then Ada.Strings.Fixed.Index
                       (To_String (Route_Results.Error (R)),
                        "edge A -> B: the guard did not come to true or false")
                     > 0,
            "it names the edge");
      end;
   end A_Guard_That_Fails_Fails_The_Routing;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Guards");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Guard_Tests_The_Outcome_And_The_Data'Access,
         "A guard tests the outcome and the data");
      Register_Routine
        (T, A_Missing_Field_Reads_As_Null'Access,
         "A missing field reads as null");
      Register_Routine
        (T, A_Guard_Sees_Only_Outcome_Summary_And_Data'Access,
         "A guard sees only outcome, summary and data");
      Register_Routine
        (T, Only_A_Boolean_Is_An_Answer'Access,
         "Only a boolean is an answer");
      Register_Routine
        (T, A_Guard_That_Cannot_Run_Fails_And_Does_Not_Raise'Access,
         "A guard that cannot run fails and does not raise");
      Register_Routine
        (T, A_Rule_Is_Checked_Without_Being_Run'Access,
         "A rule is checked without being run");
      Register_Routine
        (T, The_First_Edge_Whose_Guard_Holds_Fires'Access,
         "The first edge whose guard holds fires");
      Register_Routine
        (T, An_Edge_That_Has_Fired_Its_Bound_Is_Passed_Over'Access,
         "An edge that has fired its bound is passed over");
      Register_Routine
        (T, A_Guard_That_Fails_Fails_The_Routing'Access,
         "A guard that fails fails the routing");
   end Register_Tests;

end Synapse.Pipeline.Guards.Tests;
