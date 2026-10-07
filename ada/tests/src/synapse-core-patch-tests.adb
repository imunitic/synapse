with AUnit.Assertions;

package body Synapse.Core.Patch.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  The note after a patch that worked, or a marker that says it did not.
   function Text_Of (R : Results.Result) return String is
     (if Results.Is_Success (R) then To_String (Results.Value (R))
      else "FAILED: " & Error_Kind'Image (Results.Error (R)));

   --  Why a patch failed; Too_Large stands in for a patch that did not.
   function Error_Of (R : Results.Result) return Error_Kind is
     (if Results.Is_Success (R) then Too_Large else Results.Error (R));

   procedure Frontmatter_Target_Delegates (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Frontmatter_Key, Name => To_Unbounded_String ("status"));
   begin
      Assert
        (Text_Of
           (Apply
              ("---" & LF & "title: ""x""" & LF & "status: TODO" & LF & "---" &
               LF & "body" & LF,
               W, Replace, "REVIEW", False)) =
         "---" & LF & "title: ""x""" & LF & "status: REVIEW" & LF & "---" &
         LF & "body" & LF,
         "Frontmatter Target Delegates");
   end Frontmatter_Target_Delegates;

   procedure Heading_Replace_Keeps_Heading_And_What_Follows
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Status"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Status" & LF & "Discussing" & LF &
               LF & "## Problem" & LF & "Something." & LF,
               W, Replace, "Ready" & LF, False)) =
         "# Title" & LF & LF & "## Status" & LF & "Ready" & LF & LF &
         "## Problem" & LF & "Something." & LF,
         "Heading Replace Keeps Heading And What Follows");
   end Heading_Replace_Keeps_Heading_And_What_Follows;

   procedure Heading_Append_Goes_Before_The_Next_Heading
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Notes" & LF & "- first" & LF & LF &
               "## Other" & LF & "x" & LF,
               W, Append, "- second" & LF, False)) =
         "# Title" & LF & LF & "## Notes" & LF & "- first" & LF & "- second" &
         LF & LF & "## Other" & LF & "x" & LF,
         "Heading Append Goes Before The Next Heading");
   end Heading_Append_Goes_Before_The_Next_Heading;

   procedure Heading_Prepend_Goes_Right_After_The_Heading_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Notes" & LF & "- first" & LF, W,
               Prepend, "- zeroth" & LF, False)) =
         "# Title" & LF & LF & "## Notes" & LF & "- zeroth" & LF & "- first" &
         LF,
         "Heading Prepend Goes Right After The Heading Line");
   end Heading_Prepend_Goes_Right_After_The_Heading_Line;

   procedure A_Nested_Path_Resolves_Within_The_Firsts_Section
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      W.Path.Append (To_Unbounded_String ("Sub"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Notes" & LF & "### Sub" & LF & "old" &
               LF & LF & "## Other" & LF & "### Sub" & LF & "unrelated" & LF,
               W, Replace, "new" & LF, False)) =
         "# Title" & LF & LF & "## Notes" & LF & "### Sub" & LF & "new" & LF &
         LF & "## Other" & LF & "### Sub" & LF & "unrelated" & LF,
         "A Nested Path Resolves Within The Firsts Section");
   end A_Nested_Path_Resolves_Within_The_Firsts_Section;

   procedure A_Heading_At_The_End_Runs_To_The_End (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Notes" & LF & "old" & LF, W, Replace,
               "new" & LF, False)) =
         "# Title" & LF & LF & "## Notes" & LF & "new" & LF,
         "A Heading At The End Runs To The End");
   end A_Heading_At_The_End_Runs_To_The_End;

   procedure A_Heading_At_The_End_With_No_Final_Newline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Notes" & LF & "old", W, Replace,
               "new", False)) =
         "# Title" & LF & LF & "## Notes" & LF & "new",
         "A Heading At The End With No Final Newline");
   end A_Heading_At_The_End_With_No_Final_Newline;

   procedure A_Heading_With_No_Content_Takes_An_Append
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Notes", W, Append, "text", False)) =
         "# Title" & LF & LF & "## Notestext",
         "A Heading With No Content Takes An Append");
   end A_Heading_With_No_Content_Takes_An_Append;

   procedure A_Missing_Heading_Is_An_Error_Without_Create
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Nope"));
      Assert
        (Error_Of
           (Apply
              ("# Title" & LF & LF & "body" & LF, W, Replace, "x", False)) =
         Target_Not_Found,
         "A Missing Heading Is An Error Without Create");
   end A_Missing_Heading_Is_An_Error_Without_Create;

   procedure A_Missing_Heading_Is_Appended_With_Create
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("New"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Existing" & LF & "x" & LF, W, Replace,
               "content" & LF, True)) =
         "# Title" & LF & LF & "## Existing" & LF & "x" & LF & LF & "## New" &
         LF & "content" & LF,
         "A Missing Heading Is Appended With Create");
   end A_Missing_Heading_Is_Appended_With_Create;

   procedure A_New_Section_Keeps_The_Parents_Blank_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      W.Path.Append (To_Unbounded_String ("Sub"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Notes" & LF & "existing" & LF & LF &
               "## Other" & LF & "x" & LF,
               W, Replace, "new" & LF, True)) =
         "# Title" & LF & LF & "## Notes" & LF & "existing" & LF & "### Sub" &
         LF & "new" & LF & LF & "## Other" & LF & "x" & LF,
         "A New Section Keeps The Parents Blank Line");
   end A_New_Section_Keeps_The_Parents_Blank_Line;

   procedure A_Missing_Nested_Segment_Is_One_Level_Deeper
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      W.Path.Append (To_Unbounded_String ("Sub"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Notes" & LF & "existing" & LF, W,
               Replace, "new" & LF, True)) =
         "# Title" & LF & LF & "## Notes" & LF & "existing" & LF & "### Sub" &
         LF & "new" & LF,
         "A Missing Nested Segment Is One Level Deeper");
   end A_Missing_Nested_Segment_Is_One_Level_Deeper;

   procedure A_New_Section_Is_Separated_From_A_Note_With_No_Final_Newline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("New"));
      Assert
        (Text_Of
           (Apply ("# Title" & LF & LF & "body", W, Replace, "x" & LF, True)) =
         "# Title" & LF & LF & "body" & LF & LF & "## New" & LF & "x" & LF,
         "A New Section Is Separated From A Note With No Final Newline");
   end A_New_Section_Is_Separated_From_A_Note_With_No_Final_Newline;

   procedure A_New_Section_After_A_Note_Ending_In_A_Blank_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("New"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "body" & LF & LF, W, Replace, "x" & LF,
               True)) =
         "# Title" & LF & LF & "body" & LF & LF & "## New" & LF & "x" & LF,
         "A New Section After A Note Ending In A Blank Line");
   end A_New_Section_After_A_Note_Ending_In_A_Blank_Line;

   procedure A_New_Section_In_An_Empty_Note (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("New"));
      Assert
        (Text_Of (Apply ("", W, Replace, "x" & LF, True)) =
         "## New" & LF & "x" & LF,
         "A New Section In An Empty Note");
   end A_New_Section_In_An_Empty_Note;

   procedure Several_Missing_Levels_Each_Go_One_Deeper
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("A"));
      W.Path.Append (To_Unbounded_String ("B"));
      W.Path.Append (To_Unbounded_String ("C"));
      Assert
        (Text_Of (Apply ("# T" & LF, W, Replace, "x" & LF, True)) =
         "# T" & LF & LF & "## A" & LF & "### B" & LF & "#### C" & LF & "x" &
         LF,
         "Several Missing Levels Each Go One Deeper");
   end Several_Missing_Levels_Each_Go_One_Deeper;

   procedure Levels_Stop_At_Six (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("A"));
      W.Path.Append (To_Unbounded_String ("B"));
      W.Path.Append (To_Unbounded_String ("C"));
      W.Path.Append (To_Unbounded_String ("D"));
      W.Path.Append (To_Unbounded_String ("E"));
      W.Path.Append (To_Unbounded_String ("F"));
      Assert
        (Text_Of (Apply ("# T" & LF, W, Replace, "x" & LF, True)) =
         "# T" & LF & LF & "## A" & LF & "### B" & LF & "#### C" & LF &
         "##### D" & LF & "###### E" & LF & "###### F" & LF & "x" & LF,
         "Levels Stop At Six");
   end Levels_Stop_At_Six;

   procedure Rename_Swaps_Only_The_Title (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Old Name"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Old Name" & LF & "content stays" &
               LF & LF & "## Other" & LF & "x" & LF,
               W, Rename, "New Name", False)) =
         "# Title" & LF & LF & "## New Name" & LF & "content stays" & LF & LF &
         "## Other" & LF & "x" & LF,
         "Rename Swaps Only The Title");
   end Rename_Swaps_Only_The_Title;

   procedure Rename_On_A_Nested_Path (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      W.Path.Append (To_Unbounded_String ("Sub"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Notes" & LF & "### Sub" & LF & "old" &
               LF,
               W, Rename, "Renamed", False)) =
         "# Title" & LF & LF & "## Notes" & LF & "### Renamed" & LF & "old" &
         LF,
         "Rename On A Nested Path");
   end Rename_On_A_Nested_Path;

   procedure Rename_Trims_The_Old_Titles_Padding (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Padded"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "##   Padded  " & LF & "x" & LF, W,
               Rename, "Tight", False)) =
         "# Title" & LF & LF & "##   Tight  " & LF & "x" & LF,
         "Rename Trims The Old Titles Padding");
   end Rename_Trims_The_Old_Titles_Padding;

   procedure Rename_Of_A_Missing_Heading_Is_An_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Nope"));
      Assert
        (Error_Of
           (Apply ("# Title" & LF & LF & "body" & LF, W, Rename, "x", False)) =
         Target_Not_Found,
         "Rename Of A Missing Heading Is An Error");
   end Rename_Of_A_Missing_Heading_Is_An_Error;

   procedure Rename_Refuses_Multiline_Text (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      Assert
        (Error_Of
           (Apply
              ("# Title" & LF & LF & "## Notes" & LF & "x" & LF, W, Rename,
               "a" & LF & "b", False)) =
         Multiline_Heading_Text,
         "Rename Refuses Multiline Text");
   end Rename_Refuses_Multiline_Text;

   procedure Rename_Of_A_Block_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Block_Id, Name => To_Unbounded_String ("abc123"));
   begin
      Assert
        (Error_Of (Apply ("text ^abc123" & LF, W, Rename, "new", False)) =
         Invalid_Operation_For_Target,
         "Rename Of A Block Is Refused");
   end Rename_Of_A_Block_Is_Refused;

   procedure Rename_Of_A_Frontmatter_Key_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Frontmatter_Key, Name => To_Unbounded_String ("status"));
   begin
      Assert
        (Error_Of
           (Apply
              ("---" & LF & "status: TODO" & LF & "---" & LF & "body" & LF, W,
               Rename, "new", False)) =
         Invalid_Operation_For_Target,
         "Rename Of A Frontmatter Key Is Refused");
   end Rename_Of_A_Frontmatter_Key_Is_Refused;

   procedure A_Hash_Line_In_A_Fence_Is_Not_A_Heading
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Approach"));
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "## Approach" & LF & "text" & LF & LF &
               "```yaml" & LF & "# not.a.heading: value" & LF & "key: value" &
               LF & "```" & LF & LF & "## Constraints" & LF & "c" & LF,
               W, Replace, "new" & LF, False)) =
         "# Title" & LF & LF & "## Approach" & LF & "new" & LF & LF &
         "## Constraints" & LF & "c" & LF,
         "A Hash Line In A Fence Is Not A Heading");
   end A_Hash_Line_In_A_Fence_Is_Not_A_Heading;

   procedure A_Tilde_Fence_Hides_Headings_Too (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Hidden"));
      Assert
        (Error_Of
           (Apply
              ("# T" & LF & LF & "~~~" & LF & "## Hidden" & LF & "~~~" & LF &
               LF & "## Real" & LF & "x" & LF,
               W, Replace, "n" & LF, False)) =
         Target_Not_Found,
         "A Tilde Fence Hides Headings Too");
   end A_Tilde_Fence_Hides_Headings_Too;

   procedure A_Hash_Run_Needs_A_Space (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("NotAHeading"));
      Assert
        (Error_Of
           (Apply
              ("# T" & LF & LF & "##NotAHeading" & LF & LF & "## Real" & LF &
               "x" & LF,
               W, Replace, "n" & LF, False)) =
         Target_Not_Found,
         "A Hash Run Needs A Space");
   end A_Hash_Run_Needs_A_Space;

   procedure Seven_Hashes_Are_Not_A_Heading (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Seven"));
      Assert
        (Error_Of
           (Apply
              ("# T" & LF & LF & "####### Seven" & LF & LF & "## Real" & LF &
               "x" & LF,
               W, Replace, "n" & LF, False)) =
         Target_Not_Found,
         "Seven Hashes Are Not A Heading");
   end Seven_Hashes_Are_Not_A_Heading;

   procedure A_Duplicate_Heading_Resolves_To_The_First
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Dup"));
      Assert
        (Text_Of
           (Apply
              ("# T" & LF & LF & "## Dup" & LF & "first" & LF & LF & "## Dup" &
               LF & "second" & LF,
               W, Replace, "n" & LF, False)) =
         "# T" & LF & LF & "## Dup" & LF & "n" & LF & LF & "## Dup" & LF &
         "second" & LF,
         "A Duplicate Heading Resolves To The First");
   end A_Duplicate_Heading_Resolves_To_The_First;

   procedure Block_Replace_Keeps_The_Id (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Block_Id, Name => To_Unbounded_String ("my-block"));
   begin
      Assert
        (Text_Of
           (Apply
              ("# Title" & LF & LF & "Old text ^my-block" & LF & LF & "More." &
               LF,
               W, Replace, "New text", False)) =
         "# Title" & LF & LF & "New text ^my-block" & LF & LF & "More." & LF,
         "Block Replace Keeps The Id");
   end Block_Replace_Keeps_The_Id;

   procedure Block_Append_Goes_Before_The_Id (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Block_Id, Name => To_Unbounded_String ("my-block"));
   begin
      Assert
        (Text_Of (Apply ("Text ^my-block" & LF, W, Append, " more", False)) =
         "Text more ^my-block" & LF,
         "Block Append Goes Before The Id");
   end Block_Append_Goes_Before_The_Id;

   procedure Block_Prepend_Goes_At_The_Line_Start (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Block_Id, Name => To_Unbounded_String ("my-block"));
   begin
      Assert
        (Text_Of (Apply ("Text ^my-block" & LF, W, Prepend, "> ", False)) =
         "> Text ^my-block" & LF,
         "Block Prepend Goes At The Line Start");
   end Block_Prepend_Goes_At_The_Line_Start;

   procedure A_Block_On_The_Last_Line_With_No_Newline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Block_Id, Name => To_Unbounded_String ("end"));
   begin
      Assert
        (Text_Of (Apply ("Text ^end", W, Replace, "Done", False)) =
         "Done ^end",
         "A Block On The Last Line With No Newline");
   end A_Block_On_The_Last_Line_With_No_Newline;

   procedure A_Missing_Block_Is_An_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Block_Id, Name => To_Unbounded_String ("nope"));
   begin
      Assert
        (Error_Of (Apply ("no blocks here" & LF, W, Replace, "x", False)) =
         Target_Not_Found,
         "A Missing Block Is An Error");
   end A_Missing_Block_Is_An_Error;

   procedure A_Block_Id_Must_Be_The_Whole_Suffix (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Block_Id, Name => To_Unbounded_String ("my-block"));
   begin
      Assert
        (Error_Of (Apply ("Text ^my-block-2" & LF, W, Replace, "x", False)) =
         Target_Not_Found,
         "A Block Id Must Be The Whole Suffix");
   end A_Block_Id_Must_Be_The_Whole_Suffix;

   procedure A_Block_Needs_A_Space_Before_The_Caret
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Block_Id, Name => To_Unbounded_String ("my-block"));
   begin
      Assert
        (Error_Of (Apply ("Text^my-block" & LF, W, Replace, "x", False)) =
         Target_Not_Found,
         "A Block Needs A Space Before The Caret");
   end A_Block_Needs_A_Space_Before_The_Caret;

   procedure No_Frontmatter_Is_Its_Own_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Frontmatter_Key, Name => To_Unbounded_String ("status"));
   begin
      Assert
        (Error_Of (Apply ("# Just prose" & LF, W, Replace, "x", False)) =
         No_Frontmatter,
         "No Frontmatter Is Its Own Error");
   end No_Frontmatter_Is_Its_Own_Error;

   procedure A_Section_That_Is_Only_Blank_Lines_Keeps_One_As_A_Separator
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : Target := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("Notes"));
      Assert
        (Text_Of
           (Apply
              ("## Notes" & LF & LF & LF & "## Other" & LF, W, Append,
               "x" & LF, False)) =
         "## Notes" & LF & LF & "x" & LF & LF & "## Other" & LF,
         "two blank lines: the first is the separator");
      Assert
        (Text_Of
           (Apply
              ("## Notes" & LF & LF & "## Other" & LF, W, Append, "x" & LF,
               False)) =
         "## Notes" & LF & LF & "x" & LF & "## Other" & LF,
         "one blank line is below the rule: nothing is held back");
   end A_Section_That_Is_Only_Blank_Lines_Keeps_One_As_A_Separator;

   procedure A_Block_Suffix_Needs_The_Caret_And_Can_Be_The_Whole_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      W : constant Target :=
        (Kind => Block_Id, Name => To_Unbounded_String ("id"));
   begin
      Assert
        (Error_Of (Apply ("a bid" & LF, W, Replace, "x", False)) =
         Target_Not_Found,
         "a space and a letter are not ` ^`");
      Assert
        (Text_Of (Apply (" ^id" & LF, W, Replace, "T", False)) = "T ^id" & LF,
         "a line that is only the suffix has an empty text before it");
   end A_Block_Suffix_Needs_The_Caret_And_Can_Be_The_Whole_Line;

   function Joined (V : Text_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Item of V loop
         Append (Text, Item & ";");
      end loop;
      return To_String (Text);
   end Joined;

   procedure The_Map_Lists_Nested_Heading_Paths_Joined_By_Colons
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Note : constant String       :=
        "---" & LF & "title: ""x""" & LF & "status: TODO" & LF & "---" & LF &
        LF & "# Title" & LF & LF & "## Notes" & LF & "### Sub" & LF & "old" &
        LF & LF & "## Other" & LF & "x" & LF;
      Map  : constant Document_Map := Map_Of (Note);
      W    : Target                := (Kind => Heading, Path => <>);
   begin
      Assert
        (Joined (Map.Headings) =
         "Title;Title::Notes;Title::Notes::Sub;Title::Other;",
         "four, nested");
      W.Path.Append (To_Unbounded_String ("Title"));
      W.Path.Append (To_Unbounded_String ("Notes"));
      W.Path.Append (To_Unbounded_String ("Sub"));
      Assert
        (Results.Is_Success (Apply (Note, W, Replace, "new" & LF, False)),
         "each reported path is a real target");
   end The_Map_Lists_Nested_Heading_Paths_Joined_By_Colons;

   procedure The_Map_Lists_Block_Ids_And_Frontmatter_Keys_In_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : constant Document_Map :=
        Map_Of
          ("---" & LF & "title: ""x""" & LF & "status: TODO" & LF &
           "tags: [a, b]" & LF & "  nested: skipped" & LF & "---" & LF & LF &
           "First ^one" & LF & LF & "Second ^two" & LF);
   begin
      Assert (Joined (Map.Blocks) = "one;two;", "blocks");
      Assert
        (Joined (Map.Frontmatter_Keys) = "title;status;tags;",
         "keys, with a nested line skipped");
   end The_Map_Lists_Block_Ids_And_Frontmatter_Keys_In_Order;

   procedure A_Note_With_Nothing_Structured_Has_An_Empty_Map
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : constant Document_Map :=
        Map_Of ("just prose, nothing structured" & LF);
   begin
      Assert
        (Map.Headings.Is_Empty and then Map.Blocks.Is_Empty
         and then Map.Frontmatter_Keys.Is_Empty,
         "all three empty");
      Assert (Map_Of ("").Headings.Is_Empty, "an empty note");
   end A_Note_With_Nothing_Structured_Has_An_Empty_Map;

   procedure The_Map_Never_Reports_A_Fenced_Line_As_A_Heading
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : constant Document_Map :=
        Map_Of
          ("# Title" & LF & LF & "## Approach" & LF & "text" & LF & LF &
           "```yaml" & LF & "# schema-overrides/vault-note/v1.yaml" & LF &
           "key: value" & LF & "```" & LF & LF & "## Constraints" & LF & "c" &
           LF);
   begin
      Assert
        (Joined (Map.Headings) = "Title;Title::Approach;Title::Constraints;",
         "three");
   end The_Map_Never_Reports_A_Fenced_Line_As_A_Heading;

   procedure A_Sibling_After_A_Deeper_Branch_Pops_Back_To_Its_Parent
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : constant Document_Map :=
        Map_Of
          ("# A" & LF & "## B" & LF & "### C" & LF & "## D" & LF & "# E" & LF &
           "## F" & LF);
   begin
      Assert
        (Joined (Map.Headings) = "A;A::B;A::B::C;A::D;E;E::F;",
         "the ancestor stack unwinds");
   end A_Sibling_After_A_Deeper_Branch_Pops_Back_To_Its_Parent;

   procedure A_Block_Id_Must_Be_Plain_To_Be_Listed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : constant Document_Map :=
        Map_Of
          ("ok ^a-1_b" & LF & "no space^c" & LF & "bad ^d.e" & LF & "empty ^" &
           LF & "^lead" & LF);
   begin
      Assert (Joined (Map.Blocks) = "a-1_b;", "only the well formed one");
   end A_Block_Id_Must_Be_Plain_To_Be_Listed;

   procedure Bounds_Of_The_Text_Do_Not_Matter (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Padded : constant String (101 .. 115) :=
        "# T" & LF & "## N" & LF & "old" & LF & LF & "x";
      W      : Target                       := (Kind => Heading, Path => <>);
   begin
      W.Path.Append (To_Unbounded_String ("N"));
      Assert
        (Text_Of (Apply (Padded, W, Replace, "new" & LF, False)) =
         "# T" & LF & "## N" & LF & "new" & LF,
         "a string that does not start at 1");
      Assert (Joined (Map_Of (Padded).Headings) = "T;T::N;", "and its map");
   end Bounds_Of_The_Text_Do_Not_Matter;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Patch");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Frontmatter_Target_Delegates'Access,
         "Frontmatter Target Delegates");
      Register_Routine
        (T, Heading_Replace_Keeps_Heading_And_What_Follows'Access,
         "Heading Replace Keeps Heading And What Follows");
      Register_Routine
        (T, Heading_Append_Goes_Before_The_Next_Heading'Access,
         "Heading Append Goes Before The Next Heading");
      Register_Routine
        (T, Heading_Prepend_Goes_Right_After_The_Heading_Line'Access,
         "Heading Prepend Goes Right After The Heading Line");
      Register_Routine
        (T, A_Nested_Path_Resolves_Within_The_Firsts_Section'Access,
         "A Nested Path Resolves Within The Firsts Section");
      Register_Routine
        (T, A_Heading_At_The_End_Runs_To_The_End'Access,
         "A Heading At The End Runs To The End");
      Register_Routine
        (T, A_Heading_At_The_End_With_No_Final_Newline'Access,
         "A Heading At The End With No Final Newline");
      Register_Routine
        (T, A_Heading_With_No_Content_Takes_An_Append'Access,
         "A Heading With No Content Takes An Append");
      Register_Routine
        (T, A_Missing_Heading_Is_An_Error_Without_Create'Access,
         "A Missing Heading Is An Error Without Create");
      Register_Routine
        (T, A_Missing_Heading_Is_Appended_With_Create'Access,
         "A Missing Heading Is Appended With Create");
      Register_Routine
        (T, A_New_Section_Keeps_The_Parents_Blank_Line'Access,
         "A New Section Keeps The Parents Blank Line");
      Register_Routine
        (T, A_Missing_Nested_Segment_Is_One_Level_Deeper'Access,
         "A Missing Nested Segment Is One Level Deeper");
      Register_Routine
        (T,
         A_New_Section_Is_Separated_From_A_Note_With_No_Final_Newline'Access,
         "A New Section Is Separated From A Note With No Final Newline");
      Register_Routine
        (T, A_New_Section_After_A_Note_Ending_In_A_Blank_Line'Access,
         "A New Section After A Note Ending In A Blank Line");
      Register_Routine
        (T, A_New_Section_In_An_Empty_Note'Access,
         "A New Section In An Empty Note");
      Register_Routine
        (T, Several_Missing_Levels_Each_Go_One_Deeper'Access,
         "Several Missing Levels Each Go One Deeper");
      Register_Routine (T, Levels_Stop_At_Six'Access, "Levels Stop At Six");
      Register_Routine
        (T, Rename_Swaps_Only_The_Title'Access, "Rename Swaps Only The Title");
      Register_Routine
        (T, Rename_On_A_Nested_Path'Access, "Rename On A Nested Path");
      Register_Routine
        (T, Rename_Trims_The_Old_Titles_Padding'Access,
         "Rename Trims The Old Titles Padding");
      Register_Routine
        (T, Rename_Of_A_Missing_Heading_Is_An_Error'Access,
         "Rename Of A Missing Heading Is An Error");
      Register_Routine
        (T, Rename_Refuses_Multiline_Text'Access,
         "Rename Refuses Multiline Text");
      Register_Routine
        (T, Rename_Of_A_Block_Is_Refused'Access,
         "Rename Of A Block Is Refused");
      Register_Routine
        (T, Rename_Of_A_Frontmatter_Key_Is_Refused'Access,
         "Rename Of A Frontmatter Key Is Refused");
      Register_Routine
        (T, A_Hash_Line_In_A_Fence_Is_Not_A_Heading'Access,
         "A Hash Line In A Fence Is Not A Heading");
      Register_Routine
        (T, A_Tilde_Fence_Hides_Headings_Too'Access,
         "A Tilde Fence Hides Headings Too");
      Register_Routine
        (T, A_Hash_Run_Needs_A_Space'Access, "A Hash Run Needs A Space");
      Register_Routine
        (T, Seven_Hashes_Are_Not_A_Heading'Access,
         "Seven Hashes Are Not A Heading");
      Register_Routine
        (T, A_Duplicate_Heading_Resolves_To_The_First'Access,
         "A Duplicate Heading Resolves To The First");
      Register_Routine
        (T, Block_Replace_Keeps_The_Id'Access, "Block Replace Keeps The Id");
      Register_Routine
        (T, Block_Append_Goes_Before_The_Id'Access,
         "Block Append Goes Before The Id");
      Register_Routine
        (T, Block_Prepend_Goes_At_The_Line_Start'Access,
         "Block Prepend Goes At The Line Start");
      Register_Routine
        (T, A_Block_On_The_Last_Line_With_No_Newline'Access,
         "A Block On The Last Line With No Newline");
      Register_Routine
        (T, A_Missing_Block_Is_An_Error'Access, "A Missing Block Is An Error");
      Register_Routine
        (T, A_Block_Id_Must_Be_The_Whole_Suffix'Access,
         "A Block Id Must Be The Whole Suffix");
      Register_Routine
        (T, A_Block_Needs_A_Space_Before_The_Caret'Access,
         "A Block Needs A Space Before The Caret");
      Register_Routine
        (T, No_Frontmatter_Is_Its_Own_Error'Access,
         "No Frontmatter Is Its Own Error");
      Register_Routine
        (T, A_Block_Suffix_Needs_The_Caret_And_Can_Be_The_Whole_Line'Access,
         "A block suffix needs the caret and can be the whole line");
      Register_Routine
        (T, A_Section_That_Is_Only_Blank_Lines_Keeps_One_As_A_Separator'Access,
         "A section that is only blank lines keeps one as a separator");
      Register_Routine
        (T, The_Map_Lists_Nested_Heading_Paths_Joined_By_Colons'Access,
         "The map lists nested heading paths joined by colons");
      Register_Routine
        (T, The_Map_Lists_Block_Ids_And_Frontmatter_Keys_In_Order'Access,
         "The map lists block ids and frontmatter keys in order");
      Register_Routine
        (T, A_Note_With_Nothing_Structured_Has_An_Empty_Map'Access,
         "A note with nothing structured has an empty map");
      Register_Routine
        (T, The_Map_Never_Reports_A_Fenced_Line_As_A_Heading'Access,
         "The map never reports a fenced line as a heading");
      Register_Routine
        (T, A_Sibling_After_A_Deeper_Branch_Pops_Back_To_Its_Parent'Access,
         "A sibling after a deeper branch pops back to its parent");
      Register_Routine
        (T, A_Block_Id_Must_Be_Plain_To_Be_Listed'Access,
         "A block id must be plain to be listed");
      Register_Routine
        (T, Bounds_Of_The_Text_Do_Not_Matter'Access,
         "Bounds of the text do not matter");
   end Register_Tests;

end Synapse.Core.Patch.Tests;
