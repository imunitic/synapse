with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Guards;

package body Synapse.Pipeline.Routing.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Rule (Text : String) return JSON.Value is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Parsed.Ok, "the sample is JSON: " & Text);
      return Parsed.Item;
   end Rule;

   --  The result of a step.
   function Result
     (Outcome : String; Data : String := "{}") return JSON.Value is
     (Guards.View (Outcome, "a summary", Rule (Data)));

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
      return AUnit.Format ("Synapse.Pipeline.Routing");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
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

end Synapse.Pipeline.Routing.Tests;
