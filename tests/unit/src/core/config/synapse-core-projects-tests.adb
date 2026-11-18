with Ada.Strings.Unbounded;

with AUnit.Assertions;

package body Synapse.Core.Projects.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Known return Project_List is
      Result : Project_List;
   begin
      Result.Append
        (Project'(Name   => To_Unbounded_String ("widget"),
                  Prefix => To_Unbounded_String ("wd")));
      return Result;
   end Known;

   procedure Parse_Keeps_The_Pairs_In_Order (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Found : constant Project_List :=
        Parse
          ("# the projects" & LF & LF & "widget=wd" & LF &
           "  gadget = gd  " & LF & "no-equals" & LF & "=nothing" & LF &
           "empty=" & LF & "last=ls");
   begin
      Assert (Natural (Found.Length) = 3, "three pairs:" & Found.Length'Image);
      Assert (To_String (Found (1).Name) = "widget", "first name");
      Assert (To_String (Found (2).Name) = "gadget", "a name is trimmed");
      Assert (To_String (Found (2).Prefix) = "gd", "a prefix is trimmed");
      Assert
        (To_String (Found (3).Prefix) = "ls",
         "a last line with no line feed is read");
   end Parse_Keeps_The_Pairs_In_Order;

   procedure A_Valid_Pair_Is_Not_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Refusal ("gadget", "gd", Known) = "", "a new pair");
      Assert
        (Refusal ("a.b_c-1", "x-1", Known) = "",
         "the characters a name and a prefix may hold");
   end A_Valid_Pair_Is_Not_Refused;

   procedure A_Bad_Name_Or_Prefix_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      None : Project_List;
   begin
      Assert (Refusal ("Widget", "wd", None) /= "", "an upper case name");
      Assert (Refusal ("-w", "wd", None) /= "", "a name starts with a hyphen");
      Assert (Refusal ("", "wd", None) /= "", "an empty name");
      Assert
        (Refusal ([1 .. 65 => 'a'], "wd", None) /= "", "a name of 65");
      Assert
        (Refusal ([1 .. 64 => 'a'], "wd", None) = "", "a name of 64");
      Assert (Refusal ("w", "1d", None) /= "", "a prefix starts with a digit");
      Assert (Refusal ("w", "wd-", None) /= "", "a prefix ends with a hyphen");
      Assert (Refusal ("w", "w_d", None) /= "", "an underscore in a prefix");
      Assert
        (Refusal ("w", [1 .. 33 => 'a'], None) /= "", "a prefix of 33");
   end A_Bad_Name_Or_Prefix_Is_Refused;

   procedure A_Name_Or_Prefix_In_Use_Is_Refused (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Refusal ("widget", "xx", Known) =
         "widget is already a project, with the prefix wd.",
         "a name in use: " & Refusal ("widget", "xx", Known));
      Assert
        (Refusal ("other", "wd", Known) =
         "The prefix wd is already the prefix of widget.",
         "a prefix in use: " & Refusal ("other", "wd", Known));
   end A_Name_Or_Prefix_In_Use_Is_Refused;

   procedure With_Added_Appends_A_Last_Line (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (With_Added ("", "a", "b") = "a=b" & LF, "into nothing");
      Assert
        (With_Added ("# c" & LF, "a", "b") = "# c" & LF & "a=b" & LF,
         "after a line feed");
      Assert
        (With_Added ("x=y", "a", "b") = "x=y" & LF & "a=b" & LF,
         "a last line with no line feed gets one first");
   end With_Added_Appends_A_Last_Line;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Projects");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Parse_Keeps_The_Pairs_In_Order'Access,
         "Parse keeps the pairs in order");
      Register_Routine
        (T, A_Valid_Pair_Is_Not_Refused'Access,
         "A valid pair is not refused");
      Register_Routine
        (T, A_Bad_Name_Or_Prefix_Is_Refused'Access,
         "A bad name or prefix is refused");
      Register_Routine
        (T, A_Name_Or_Prefix_In_Use_Is_Refused'Access,
         "A name or prefix in use is refused");
      Register_Routine
        (T, With_Added_Appends_A_Last_Line'Access,
         "With_Added appends a last line");
   end Register_Tests;

end Synapse.Core.Projects.Tests;
