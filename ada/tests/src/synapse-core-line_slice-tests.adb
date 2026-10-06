with AUnit.Assertions;

package body Synapse.Core.Line_Slice.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  The text of lines First .. Last, or "<none>".
   function Cut (Text : String; First, Last : Natural) return String is
      Found : constant Maybe_Bounds := Bounds (Text, First, Last);
   begin
      if not Found.Found then
         return "<none>";
      end if;
      return Text (Found.From .. Found.To);
   end Cut;

   procedure Count_Lines_Counts_Line_Feeds (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Count_Lines ("a" & LF & "b" & LF & "c" & LF) = 3, "terminated");
      Assert
        (Count_Lines ("a" & LF & "b" & LF & "c") = 2,
         "an unterminated last line is not one");
      Assert (Count_Lines ("") = 0, "empty");
   end Count_Lines_Counts_Line_Feeds;

   procedure Lines_Come_Out_As_Sed_Prints_Them (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Text : constant String :=
        "one" & LF & "two" & LF & "three" & LF & "four";
   begin
      Assert (Cut (Text, 2, 3) = "two" & LF & "three" & LF, "the middle");
      Assert (Cut (Text, 1, 1) = "one" & LF, "the first, with its terminator");
      Assert
        (Cut (Text, 4, 4) = "four", "an unterminated last line gets none");
      Assert (Cut (Text, 1, 4) = Text, "all of it");
      Assert (Cut (Text, 3, 4) = "three" & LF & "four", "to the end");
   end Lines_Come_Out_As_Sed_Prints_Them;

   procedure A_Range_Past_The_End_Is_Not_Found (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Text : constant String := "one" & LF & "two" & LF;
   begin
      Assert (Cut (Text, 2, 5) = "<none>", "not a short slice");
      Assert (Cut (Text, 0, 1) = "<none>", "lines start at 1");
      Assert (Cut (Text, 2, 1) = "<none>", "backwards");
      Assert (Cut (Text, 9, 9) = "<none>", "far past the end");
      Assert (Cut ("", 2, 2) = "<none>", "an empty text has no line two");
   end A_Range_Past_The_End_Is_Not_Found;

   procedure The_Position_After_The_Last_Line_Feed_Is_An_Empty_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text  : constant String       := "a" & LF;
      Empty : constant Maybe_Bounds := Bounds (Text, 2, 2);
   begin
      Assert
        (Empty.Found and then Empty.To = Empty.From - 1,
         "an empty slice, as the callers' range checks never reach it");
      Assert (Cut ("", 1, 1) = "", "an empty text has an empty line one");
   end The_Position_After_The_Last_Line_Feed_Is_An_Empty_Line;

   procedure Slices_Work_On_A_Text_That_Does_Not_Start_At_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Whole : constant String := "xxx" & "a" & LF & "b" & LF;
   begin
      Assert
        (Cut (Whole (4 .. Whole'Last), 2, 2) = "b" & LF, "offset indices");
      Assert (Next_Line_Feed (Whole (4 .. Whole'Last), 1) = 5, "first lf");
      Assert (Next_Line_Feed (Whole, 100) = 0, "from past the end");
   end Slices_Work_On_A_Text_That_Does_Not_Start_At_One;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Line_Slice");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Count_Lines_Counts_Line_Feeds'Access,
         "Count_Lines counts line feeds");
      Register_Routine
        (T, Lines_Come_Out_As_Sed_Prints_Them'Access,
         "Lines come out as sed prints them");
      Register_Routine
        (T, A_Range_Past_The_End_Is_Not_Found'Access,
         "A range past the end is not found");
      Register_Routine
        (T, The_Position_After_The_Last_Line_Feed_Is_An_Empty_Line'Access,
         "The position after the last line feed is an empty line");
      Register_Routine
        (T, Slices_Work_On_A_Text_That_Does_Not_Start_At_One'Access,
         "Slices work on a text that does not start at one");
   end Register_Tests;

end Synapse.Core.Line_Slice.Tests;
