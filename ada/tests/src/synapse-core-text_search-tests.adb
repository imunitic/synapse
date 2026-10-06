with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.UTF8;

package body Synapse.Core.Text_Search.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   type Scalars is array (Positive range <>) of UTF8.Scalar_Value;

   function U (Items : Scalars) return String is
      Result : Unbounded_String;
   begin
      for CP of Items loop
         Append (Result, UTF8.Encode (CP));
      end loop;
      return To_String (Result);
   end U;

   function Terms (A : String; B : String := "") return Text_Lists.Vector is
      Result : Text_Lists.Vector;
   begin
      Result.Append (To_Unbounded_String (A));
      if B /= "" then
         Result.Append (To_Unbounded_String (B));
      end if;
      return Result;
   end Terms;

   function Line_Of (Text : String; Found : Maybe_Line) return String
   is (if Found.Found then Text (Found.First .. Found.Last) else "<none>");

   function Ranges (Text : String; First : Positive; T : Text_Lists.Vector)
      return String
   is (Image (Match_Ranges (Text, First, T)));

   procedure The_First_Matching_Line_Ignores_Case (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String := "one" & LF & "Two Widget" & LF & "three widget"
        & LF;
   begin
      Assert (Line_Of (Text, First_Matching_Line (Text, "widget"))
              = "Two Widget", "case folded");
      Assert (Line_Of (Text, First_Matching_Line ("one" & LF & "two" & LF,
                                                  "gadget")) = "<none>",
              "no match");
      Assert (not First_Matching_Line (Text, "").Found, "an empty query");
      Assert (not First_Matching_Line ("", "x").Found, "empty text");
      Assert (Line_Of ("abc", First_Matching_Line ("abc", "B")) = "abc",
              "no line feed");
      Assert (Line_Of ("a" & LF & "b", First_Matching_Line ("a" & LF & "b",
                                                            "B")) = "b",
              "the last line");
   end The_First_Matching_Line_Ignores_Case;

   procedure Any_Of_Several_Terms_Finds_A_Line (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Text : constant String := "alpha" & LF & "beta gadget" & LF & "widget"
        & LF;
   begin
      Assert (Line_Of (Text, First_Matching_Line_Any
                               (Text, Terms ("widget", "gadget")))
              = "beta gadget", "the earlier line");
      Assert (not First_Matching_Line_Any (Text, Terms ("nothing")).Found,
              "no term");
      Assert (not First_Matching_Line_Any
                    (Text, Text_Lists.Vectors.Empty_Vector).Found,
              "no terms at all");
   end Any_Of_Several_Terms_Finds_A_Line;

   procedure Counting_Ignores_Case (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Count_Ignore_Case ("Widget widget WIDGET gadget", "widget") = 3,
              "three");
      Assert (Count_Ignore_Case ("anything", "") = 0, "an empty needle");
      Assert (Count_Ignore_Case ("", "x") = 0, "an empty haystack");
      Assert (Count_Ignore_Case ("aaaa", "aa") = 2, "non-overlapping");
   end Counting_Ignores_Case;

   procedure Non_Latin_Text_Is_Searched_Too (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Upper_Moscow : constant String :=
        U ([16#41C#, 16#41E#, 16#421#, 16#41A#, 16#412#, 16#410#]);
      Lower_Moscow : constant String :=
        U ([16#43C#, 16#43E#, 16#441#, 16#43A#, 16#432#, 16#430#]);
      City : constant String :=
        U ([16#433#, 16#43E#, 16#440#, 16#43E#, 16#434#]);
      Text : constant String :=
        "one" & LF & City & " " & Upper_Moscow & LF & "x" & LF;
   begin
      Assert (Line_Of (Text, First_Matching_Line (Text, Lower_Moscow))
              = City & " " & Upper_Moscow, "Cyrillic line");
      Assert (Count_Ignore_Case (Upper_Moscow & " " & Lower_Moscow,
                                 Upper_Moscow) = 2, "Cyrillic count");
   end Non_Latin_Text_Is_Searched_Too;

   procedure Ranges_Merge_Consecutive_Lines (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Text : constant String :=
        "alpha widget" & LF & "widget again" & LF & "plain" & LF & "plain" & LF
        & "the Widget" & LF;
   begin
      Assert (Ranges (Text, 1, Terms ("widget")) = "1-2,5",
              "merged and apart");
      Assert (Match_Ranges (Text, 1, Terms ("widget")).Length = 2,
              "two ranges");
      Assert (Ranges ("no" & LF & "yes widget" & LF, 20, Terms ("widget"))
              = "21", "numbered from the first line");
      Assert (Ranges ("one gadget" & LF & "two" & LF & "three widget" & LF, 1,
                      Terms ("widget", "gadget")) = "1,3", "either term");
      Assert (Ranges ("w" & LF & "w" & LF & "w", 1, Terms ("w")) = "1-3",
              "three in a row, no final line feed");
      Assert (Ranges ("", 1, Terms ("w")) = "", "empty text");
      Assert (Ranges (Text, 1, Terms ("absent")) = "", "no match");
   end Ranges_Merge_Consecutive_Lines;

   procedure Ranges_Are_Written_With_Bare_Single_Lines
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Value : Range_Vectors.Vector;
   begin
      Assert (Image (Value) = "", "none");
      Value.Append (Line_Range'(First => 12, Last => 14));
      Value.Append (Line_Range'(First => 40, Last => 41));
      Value.Append (Line_Range'(First => 88, Last => 88));
      Assert (Image (Value) = "12-14,40-41,88", "mixed");
   end Ranges_Are_Written_With_Bare_Single_Lines;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Text_Search");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_First_Matching_Line_Ignores_Case'Access,
         "The first matching line ignores case");
      Register_Routine
        (T, Any_Of_Several_Terms_Finds_A_Line'Access,
         "Any of several terms finds a line");
      Register_Routine
        (T, Counting_Ignores_Case'Access, "Counting ignores case");
      Register_Routine
        (T, Non_Latin_Text_Is_Searched_Too'Access,
         "Non-Latin text is searched too");
      Register_Routine
        (T, Ranges_Merge_Consecutive_Lines'Access,
         "Ranges merge consecutive lines");
      Register_Routine
        (T, Ranges_Are_Written_With_Bare_Single_Lines'Access,
         "Ranges are written with bare single lines");
   end Register_Tests;

end Synapse.Core.Text_Search.Tests;
