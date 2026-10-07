with AUnit.Assertions;

with Synapse.Adapters.Fake_Repo_Reader;

package body Synapse.Core.Deps.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package Fake renames Adapters.Fake_Repo_Reader;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function Joined (V : Text_Lists.Vector) return String is
      Result : Unbounded_String;
   begin
      for Item of V loop
         Append (Result, Item & ";");
      end loop;
      return To_String (Result);
   end Joined;

   function Shown (Found : Maybe_Row) return String is
     (if Found.Found then
        To_String (Found.Value.Path) & "|" & To_String (Found.Value.Library)
      else "none");

   procedure Parse_Row_Splits_On_The_Tab_And_A_Truncated_Line_Is_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown (Parse_Row ("widget/build.deps" & HT & "widget")) =
         "widget/build.deps|widget",
         "a row");
      Assert (Shown (Parse_Row ("just-a-path")) = "none", "truncated");
      Assert
        (Shown (Parse_Row ("a" & HT & "b" & HT & "c")) = "a|b",
         "extra columns are ignored");
      Assert (Shown (Parse_Row ("")) = "none", "empty");
   end Parse_Row_Splits_On_The_Tab_And_A_Truncated_Line_Is_None;

   procedure Libraries_Split_On_White_Space_And_Commas
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Joined (Split_Libraries ("widget")) = "widget;", "one name");
      Assert
        (Joined (Split_Libraries ("widget str")) = "widget;str;", "a list");
      Assert
        (Joined (Split_Libraries ("alpha, beta")) = "alpha;beta;",
         "a comma list");
      Assert
        (Joined
           (Split_Libraries
              ("  a" & HT & "b" & Character'Val (13) & LF & ",,c,")) =
         "a;b;c;",
         "every separator, none left in a name");
      Assert (Joined (Split_Libraries ("")) = "", "empty");
      Assert (Joined (Split_Libraries (" , ")) = "", "only separators");
   end Libraries_Split_On_White_Space_And_Commas;

   function Rows (V : Row_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for Item of V loop
         Append (Result, Item.Path & ">" & Item.Library & ";");
      end loop;
      return To_String (Result);
   end Rows;

   function Kept_Of (A, B, C : String := "") return Text_Lists.Vector is
      Result : Text_Lists.Vector;

      procedure Add (Path : String) is
      begin
         if Path /= "" then
            Result.Append (To_Unbounded_String (Path));
         end if;
      end Add;
   begin
      Add (A);
      Add (B);
      Add (C);
      return Result;
   end Kept_Of;

   procedure A_Build_File_Rule_Splits_Its_Declared_List
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
   begin
      Disk.Put
        ("widget/src/build.deps",
         "name widget" & LF & "depends gadget str" & LF);
      Disk.Put ("widget/src/main.xx", "run" & LF);
      Assert
        (Rows
           (Compute
              (Disk, Kept_Of ("widget/src/build.deps", "widget/src/main.xx"),
               Namespace.Parse
                 ("{""xx"": {""kind"": ""build-file""," &
                  " ""file"": ""build.deps""," &
                  " ""prefix"": ""depends ""}}"))) =
         "widget/src/main.xx>gadget;widget/src/main.xx>str;",
         "a row per library");
   end A_Build_File_Rule_Splits_Its_Declared_List;

   procedure Two_Extensions_Sharing_A_Build_File_Extract_Independently
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
   begin
      Disk.Put
        ("widget/src/build.deps",
         "depends gadget" & LF & "requires thing" & LF);
      Disk.Put ("widget/src/main.xx", "run" & LF);
      Disk.Put ("widget/src/main.yy", "run" & LF);
      Assert
        (Rows
           (Compute
              (Disk,
               Kept_Of
                 ("widget/src/build.deps", "widget/src/main.xx",
                  "widget/src/main.yy"),
               Namespace.Parse
                 ("{""xx"": {""kind"": ""build-file""," &
                  " ""file"": ""build.deps""," &
                  " ""prefix"": ""depends ""}," &
                  " ""yy"": {""kind"": ""build-file""," &
                  " ""file"": ""build.deps""," &
                  " ""prefix"": ""requires ""}}"))) =
         "widget/src/main.xx>gadget;widget/src/main.yy>thing;",
         "each reads its own prefix");
   end Two_Extensions_Sharing_A_Build_File_Extract_Independently;

   procedure A_File_With_No_Rule_Contributes_No_Rows
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
   begin
      Assert
        (Compute
           (Disk, Kept_Of ("README.md"),
            Namespace.Parse
              ("{""xx"": {""kind"": ""build-file""," &
               " ""file"": ""build.deps""," & " ""prefix"": ""depends ""}}"))
           .Is_Empty,
         "no rows");
   end A_File_With_No_Rule_Contributes_No_Rows;

   procedure An_Empty_Registry_Reads_No_File (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
   begin
      Assert
        (Compute (Disk, Kept_Of ("widget/src/main.xx"), Namespace.Parse ("{}"))
           .Is_Empty,
         "no rows");
      Assert (Disk.Reads = 0, "and no file was touched");
   end An_Empty_Registry_Reads_No_File;

   procedure An_In_File_Rule_Reads_The_File_Itself
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
   begin
      Disk.Put ("pkg/main.yy", "uses beta, alpha" & LF);
      Assert
        (Rows
           (Compute
              (Disk, Kept_Of ("pkg/main.yy"),
               Namespace.Parse
                 ("{""yy"": {""kind"": ""in-file""," &
                  " ""prefix"": ""uses ""}}"))) =
         "pkg/main.yy>alpha;pkg/main.yy>beta;",
         "sorted by library within a path");
   end An_In_File_Rule_Reads_The_File_Itself;

   procedure An_Image_Is_A_Tab_Separated_Line (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Image
           ((Path    => To_Unbounded_String ("a/b.xx"),
             Library => To_Unbounded_String ("lib"))) =
         "a/b.xx" & HT & "lib" & LF,
         "path, tab, library, line feed");
   end An_Image_Is_A_Tab_Separated_Line;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Deps");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Parse_Row_Splits_On_The_Tab_And_A_Truncated_Line_Is_None'Access,
         "Parse_Row splits on the tab and a truncated line is none");
      Register_Routine
        (T, Libraries_Split_On_White_Space_And_Commas'Access,
         "Libraries split on white space and commas");
      Register_Routine
        (T, A_Build_File_Rule_Splits_Its_Declared_List'Access,
         "A build-file rule splits its declared list");
      Register_Routine
        (T, Two_Extensions_Sharing_A_Build_File_Extract_Independently'Access,
         "Two extensions sharing a build file extract independently");
      Register_Routine
        (T, A_File_With_No_Rule_Contributes_No_Rows'Access,
         "A file with no rule contributes no rows");
      Register_Routine
        (T, An_Empty_Registry_Reads_No_File'Access,
         "An empty registry reads no file");
      Register_Routine
        (T, An_In_File_Rule_Reads_The_File_Itself'Access,
         "An in-file rule reads the file itself");
      Register_Routine
        (T, An_Image_Is_A_Tab_Separated_Line'Access,
         "An image is a tab-separated line");
   end Register_Tests;

end Synapse.Core.Deps.Tests;
