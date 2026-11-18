with Ada.Strings.Fixed;

with AUnit.Assertions;

package body Synapse.Pipeline.Patches.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Image (Count : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Count), Ada.Strings.Left));

   --  The lines a new file adds, Count of them Width characters wide.
   function Rows (Count : Natural; Width : Positive) return String is
      Row : constant String := "+" & String'(1 .. Width => 'x') & LF;
   begin
      if Count = 0 then
         return "";
      end if;
      return Row & Rows (Count - 1, Width);
   end Rows;

   --  What git prints of a file that is new, before its lines.
   function Head (Path : String) return String is
     ("diff --git a/" & Path & " b/" & Path & LF
      & "new file mode 100644" & LF
      & "index 0000000..1111111" & LF
      & "--- /dev/null" & LF
      & "+++ b/" & Path & LF);

   function New_File (Path : String; Count : Natural; Width : Positive)
      return String
   is (Head (Path) & "@@ -0,0 +1," & Image (Count) & " @@" & LF
       & Rows (Count, Width));

   --  The same file with its lines left out.
   function Stub (Path : String; Count : Natural) return String is
     (Head (Path) & "@@ -0,0 +1," & Image (Count) & " @@" & LF
      & "\ " & Not_Kept & LF);

   --  A file that already existed, with one long line changed.
   function Changed (Path : String; Width : Positive) return String is
     ("diff --git a/" & Path & " b/" & Path & LF
      & "index 1111111..2222222 100644" & LF
      & "--- a/" & Path & LF
      & "+++ b/" & Path & LF
      & "@@ -1 +1 @@" & LF
      & "-old" & LF
      & "+" & String'(1 .. Width => 'y') & LF);

   procedure A_Small_New_File_Is_Kept_Whole (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Patch : constant String := New_File ("a.txt", 3, 10);
   begin
      Assert (Capped (Patch, 1000) = Patch, "a file under the limit is kept");
   end A_Small_New_File_Is_Kept_Whole;

   procedure A_Large_New_File_Is_Left_Out_With_Its_Number_Of_Lines
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Capped (New_File ("big.dat", 5, 100), 300) = Stub ("big.dat", 5),
         "its header stays, and its hunk says how many lines it had");
      Assert
        (Capped (New_File ("one.txt", 1, 50), 0) = Stub ("one.txt", 1),
         "with no limit left, any new file is left out");
   end A_Large_New_File_Is_Left_Out_With_Its_Number_Of_Lines;

   procedure A_File_That_Existed_Is_Kept_Whole_However_Large
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Patch : constant String := Changed ("m.txt", 500);
   begin
      Assert (Capped (Patch, 10) = Patch, "a changed file is not cut");
   end A_File_That_Existed_Is_Kept_Whole_However_Large;

   procedure Only_The_Large_New_File_Of_Several_Is_Left_Out
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Before : constant String := Changed ("m.txt", 20);
      Small  : constant String := New_File ("s.txt", 2, 5);
   begin
      Assert
        (Capped
           (Before & New_File ("big.dat", 8, 100) & Small, 400)
         = Before & Stub ("big.dat", 8) & Small,
         "the others are as they were, in their order");
   end Only_The_Large_New_File_Of_Several_Is_Left_Out;

   procedure A_New_Binary_File_Has_No_Lines_To_Leave_Out
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Patch : constant String :=
        "diff --git a/b.bin b/b.bin" & LF
        & "new file mode 100644" & LF
        & "index 0000000..1111111" & LF
        & "Binary files /dev/null and b/b.bin differ" & LF;
   begin
      Assert (Capped (Patch, 0) = Patch, "a binary file is kept as it is");
   end A_New_Binary_File_Has_No_Lines_To_Leave_Out;

   procedure An_Empty_Patch_Is_Empty (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Capped ("", 0) = "", "nothing is kept of nothing");
   end An_Empty_Patch_Is_Empty;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Patches");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Small_New_File_Is_Kept_Whole'Access,
         "A new file under the limit is kept whole");
      Register_Routine
        (T, A_Large_New_File_Is_Left_Out_With_Its_Number_Of_Lines'Access,
         "A large new file is left out with its number of lines");
      Register_Routine
        (T, A_File_That_Existed_Is_Kept_Whole_However_Large'Access,
         "A file that existed is kept whole however large");
      Register_Routine
        (T, Only_The_Large_New_File_Of_Several_Is_Left_Out'Access,
         "Only the large new file of several is left out");
      Register_Routine
        (T, A_New_Binary_File_Has_No_Lines_To_Leave_Out'Access,
         "A new binary file has no lines to leave out");
      Register_Routine
        (T, An_Empty_Patch_Is_Empty'Access, "An empty patch is empty");
   end Register_Tests;

end Synapse.Pipeline.Patches.Tests;
