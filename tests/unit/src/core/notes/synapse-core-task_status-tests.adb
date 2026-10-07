with AUnit.Assertions;

package body Synapse.Core.Task_Status.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   procedure Any_Unchecked_Item_Means_In_Progress (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Next_Status ((Total => 3, Checked => 1)) = In_Progress,
         "one of three");
   end Any_Unchecked_Item_Means_In_Progress;

   procedure Every_Item_Checked_Means_Review (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Next_Status ((Total => 3, Checked => 3)) = Review, "all three");
   end Every_Item_Checked_Means_Review;

   procedure No_Checklist_At_All_Is_Ambiguous_And_Is_Not_Review
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Next_Status ((Total => 0, Checked => 0)) = In_Progress,
         "nothing verified is not everything verified");
   end No_Checklist_At_All_Is_Ambiguous_And_Is_Not_Review;

   procedure Counting_Reads_Checked_And_Unchecked_Items
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      C : constant Checklist_Count :=
        Count_Checklist
          ("# A task" & LF & LF & "- [ ] Step one" & LF & "- [x] Step two" &
           LF & "- [X] Step three" & LF);
   begin
      Assert (C.Total = 3 and then C.Checked = 2, "the x in either case");
   end Counting_Reads_Checked_And_Unchecked_Items;

   procedure Other_Bullets_Are_Not_Checklist_Lines
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Count_Checklist
           ("## Sources" & LF & "- `core/foo.ext` (3)" & LF & LF & "## Links" &
            LF & "- part_of [[Parent]]" & LF)
           .Total =
         0,
         "source rows and link edges");
      Assert
        (Count_Checklist
           ("- [y] not a mark" & LF & "- [] none" & LF & "- [ ]" & LF &
            "-[ ] no space" & LF)
           .Total =
         1,
         "only a well formed one: `- [ ]` with nothing after it counts");
   end Other_Bullets_Are_Not_Checklist_Lines;

   procedure Leading_Blanks_And_A_Carriage_Return_Are_Tolerated
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      C : constant Checklist_Count :=
        Count_Checklist
          ("- [ ] Outer step" & LF & "  - [x] Nested detail" & LF &
           Character'Val (9) & "- [ ] Tabbed" & Character'Val (13) & LF);
   begin
      Assert (C.Total = 3 and then C.Checked = 1, "nested, tabbed, CRLF");
   end Leading_Blanks_And_A_Carriage_Return_Are_Tolerated;

   procedure Only_In_Progress_And_Review_Are_Automatic_Targets
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Is_Automatic_Target (In_Progress)
         and then Is_Automatic_Target (Review),
         "the two");
      Assert
        (not Is_Automatic_Target (Todo) and then not Is_Automatic_Target (Done)
         and then not Is_Automatic_Target (Canceled)
         and then not Is_Automatic_Target (Cancelled),
         "never the rest");
   end Only_In_Progress_And_Review_Are_Automatic_Targets;

   procedure A_Status_Is_Spelled_As_A_Note_Spells_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      for S in Status loop
         Assert
           (Parse (Image (S)).Found and then Parse (Image (S)).Value = S,
            "round trip: " & Image (S));
      end loop;
      Assert (Image (In_Progress) = "IN-PROGRESS", "the hyphen");
      Assert (not Parse ("in-progress").Found, "exactly as written");
      Assert
        (not Parse ("").Found and then not Parse ("DONE ").Found,
         "nothing near it");
   end A_Status_Is_Spelled_As_A_Note_Spells_It;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Task_Status");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Any_Unchecked_Item_Means_In_Progress'Access,
         "Any unchecked item means in progress");
      Register_Routine
        (T, Every_Item_Checked_Means_Review'Access,
         "Every item checked means review");
      Register_Routine
        (T, No_Checklist_At_All_Is_Ambiguous_And_Is_Not_Review'Access,
         "No checklist at all is ambiguous and is not review");
      Register_Routine
        (T, Counting_Reads_Checked_And_Unchecked_Items'Access,
         "Counting reads checked and unchecked items");
      Register_Routine
        (T, Other_Bullets_Are_Not_Checklist_Lines'Access,
         "Other bullets are not checklist lines");
      Register_Routine
        (T, Leading_Blanks_And_A_Carriage_Return_Are_Tolerated'Access,
         "Leading blanks and a carriage return are tolerated");
      Register_Routine
        (T, Only_In_Progress_And_Review_Are_Automatic_Targets'Access,
         "Only in progress and review are automatic targets");
      Register_Routine
        (T, A_Status_Is_Spelled_As_A_Note_Spells_It'Access,
         "A status is spelled as a note spells it");
   end Register_Tests;

end Synapse.Core.Task_Status.Tests;
