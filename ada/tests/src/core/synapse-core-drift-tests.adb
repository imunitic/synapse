with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Hashing;

package body Synapse.Core.Drift.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

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

   function Listed (A, B, C, D : String := "") return Text_Lists.Vector is
      Result : Text_Lists.Vector;

      procedure Add (Item : String) is
      begin
         if Item /= "" then
            Result.Append (To_Unbounded_String (Item));
         end if;
      end Add;
   begin
      Add (A);
      Add (B);
      Add (C);
      Add (D);
      return Result;
   end Listed;

   procedure Name_Status_Parsing_Splits_The_Four_Classes_And_Sorts_Each
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Diff :=
        Parse_Name_Status
          ("M" & HT & "src/b.ext" & LF & "A" & HT & "src/new.ext" & LF & "D" &
           HT & "src/gone.ext" & LF & "R100" & HT & "src/old.ext" & HT &
           "src/moved.ext" & LF & "M" & HT & "src/a.ext" & LF);
   begin
      Assert
        (Joined (Got.Modified) = "src/a.ext;src/b.ext;", "modified, sorted");
      Assert (Joined (Got.Deleted) = "src/gone.ext;", "deleted");
      Assert (Joined (Got.Added) = "src/new.ext;", "added");
      Assert
        (Joined (Got.Renamed_From) = "src/old.ext;",
         "the old path, which is what the node still lists");
   end Name_Status_Parsing_Splits_The_Four_Classes_And_Sorts_Each;

   procedure A_Status_Letter_With_A_Score_Is_Still_Its_Class
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Diff :=
        Parse_Name_Status
          ("R087" & HT & "a" & HT & "b" & LF & "M" & HT & "c" & LF);
   begin
      Assert
        (Joined (Got.Renamed_From) = "a;"
         and then Joined (Got.Modified) = "c;",
         "a prefix test and not an equality");
   end A_Status_Letter_With_A_Score_Is_Still_Its_Class;

   procedure Classes_That_Are_Not_Reported_Are_Ignored_Not_Invented
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Diff :=
        Parse_Name_Status
          ("T" & HT & "src/link" & LF & "U" & HT & "src/conflict" & LF &
           "C100" & HT & "src/orig" & HT & "src/copy" & LF);
   begin
      Assert
        (Got.Modified.Is_Empty and then Got.Deleted.Is_Empty
         and then Got.Added.Is_Empty and then Got.Renamed_From.Is_Empty,
         "type changes, conflicts and copies are not classes");
   end Classes_That_Are_Not_Reported_Are_Ignored_Not_Invented;

   procedure Odd_Lines_Are_Skipped_And_A_Tab_In_A_Path_Survives
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Diff :=
        Parse_Name_Status
          (LF & "no tab here" & LF & HT & "no status" & LF & "M" & HT &
           "dir/a" & HT & "b.ext" & LF & "D" & HT & "gone" &
           Character'Val (13) & LF & "M" & HT);
   begin
      Assert
        (Joined (Got.Modified) = ";dir/a" & HT & "b.ext;",
         "the whole rest of the line is the path, a tab and an empty " &
         "path included");
      Assert (Joined (Got.Deleted) = "gone;", "a carriage return is dropped");
      Assert (Parse_Name_Status ("").Modified.Is_Empty, "empty");
   end Odd_Lines_Are_Skipped_And_A_Tab_In_A_Path_Survives;

   procedure Count_Intersect_Is_A_Merge_Pass_Over_Two_Sorted_Lists
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      A    : constant Text_Lists.Vector := Listed ("a", "c", "e", "g");
      B    : constant Text_Lists.Vector := Listed ("b", "c", "d", "e");
      None : Text_Lists.Vector;
   begin
      Assert (Count_Intersect (A, B) = 2, "two in common");
      Assert
        (Count_Intersect (A, None) = 0 and then Count_Intersect (None, B) = 0,
         "nothing to intersect with");
      Assert (Count_Intersect (A, A) = 4, "a list with itself");
   end Count_Intersect_Is_A_Merge_Pass_Over_Two_Sorted_Lists;

   procedure A_Nodes_Drift_Counts_Each_Class_Separately
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Changes : constant Diff       :=
        Parse_Name_Status
          ("M" & HT & "src/a.ext" & LF & "D" & HT & "src/b.ext" & LF & "R100" &
           HT & "src/c.ext" & HT & "src/moved.ext" & LF & "A" & HT &
           "src/z.ext" & LF);
      Mine    : constant Node_Drift :=
        Of_Node (Listed ("src/a.ext", "src/b.ext", "src/c.ext"), Changes);
   begin
      Assert
        (Mine.Modified = 1 and then Mine.Deleted = 1 and then Mine.Renamed = 1
         and then Any (Mine),
         "one of each");
      Assert
        (not Any (Of_Node (Listed ("src/other.ext"), Changes)), "untouched");
      Assert
        (not Any (Of_Node (Listed ("src/z.ext"), Changes)),
         "an added path is the repository's drift, never a node's");
   end A_Nodes_Drift_Counts_Each_Class_Separately;

   procedure Findings_Come_Out_Modified_Renamed_Deleted
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Findings ("Foo Node", (Modified => 2, Renamed => 1, Deleted => 3)) =
         "Foo Node" & HT & "content changed in 2 of its files" & LF &
         "Foo Node" & HT &
         "1 of its files were renamed -- reseat sources, prose may " &
         "still hold" & LF & "Foo Node" & HT & "3 of its files are gone" & LF,
         "in that order");
      Assert
        (Findings ("Foo", (others => 0)) = "", "a clean node says nothing");
      Assert
        (Findings ("Foo", (Modified => 1, Renamed => 0, Deleted => 0)) =
         "Foo" & HT & "content changed in 1 of its files" & LF,
         "one modified file");
      Assert
        (Findings ("Foo", (Modified => 0, Renamed => 0, Deleted => 1)) =
         "Foo" & HT & "1 of its files are gone" & LF,
         "one class");
   end Findings_Come_Out_Modified_Renamed_Deleted;

   procedure An_Undiffable_Node_Points_At_Stale (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Undiffable_Line ("Foo", No_Commit_Recorded) =
         "Foo" & HT & "no commit recorded, so nothing to diff against " &
         "-- verify with `stale`" & LF,
         "no commit");
      Assert
        (Undiffable_Line ("Bar", Baseline_Absent, "0123456789abcdef0123") =
         "Bar" & HT & "baseline 0123456789ab not in local history -- " &
         "verify with `stale`" & LF,
         "a baseline that is not here");
      Assert
        (Undiffable_Line ("Baz", Node_File_Missing) =
         "Baz" & HT & "node file missing from the vault" & LF,
         "a missing node file");
   end An_Undiffable_Node_Points_At_Stale;

   procedure Short_Commit_Is_Twelve_Characters (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Short_Commit ("0123456789abcdef") = "0123456789ab", "twelve");
      Assert (Short_Commit ("abc") = "abc", "shorter survives");
      Assert (Short_Commit ("") = "", "empty");
      Assert
        (Short_Commit ("0123456789ab") = "0123456789ab", "exactly twelve");
   end Short_Commit_Is_Twelve_Characters;

   --  The shape of a real diff: every status letter, scores, and paths of
   --  several depths, made up. Its classes were also counted and digested by
   --  the awk and sort pipeline this parser replaces.
   Name_Status : constant String :=
     "M" & HT & "mod4/sub2/file102.ext" & LF & "M" & HT &
     "mod3/sub4/file24.ext" & LF & "R98" & HT & "mod3/sub3/file38.ext" & HT &
     "moved/mod3/sub3/file38.ext" & LF & "M" & HT & "mod0/sub0/file140.ext" &
     LF & "M" & HT & "mod2/sub2/file142.ext" & LF & "M" & HT &
     "mod4/sub0/file130.ext" & LF & "R87" & HT & "mod0/sub2/file7.ext" & HT &
     "moved/mod0/sub2/file7.ext" & LF & "R100" & HT & "mod0/sub3/file28.ext" &
     HT & "moved/mod0/sub3/file28.ext" & LF & "D" & HT &
     "mod4/sub1/file116.ext" & LF & "D" & HT & "mod6/sub1/file76.ext" & LF &
     "A" & HT & "mod2/sub0/file135.ext" & LF & "M" & HT &
     "mod3/sub2/file52.ext" & LF & "R100" & HT & "mod1/sub3/file148.ext" & HT &
     "moved/mod1/sub3/file148.ext" & LF & "M" & HT & "mod6/sub4/file34.ext" &
     LF & "M" & HT & "mod5/sub0/file110.ext" & LF & "R100" & HT &
     "mod6/sub3/file118.ext" & HT & "moved/mod6/sub3/file118.ext" & LF & "D" &
     HT & "mod0/sub1/file56.ext" & LF & "M" & HT & "mod2/sub1/file121.ext" &
     LF & "M" & HT & "mod5/sub2/file82.ext" & LF & "M" & HT &
     "mod6/sub3/file83.ext" & LF & "M" & HT & "mod0/sub3/file63.ext" & LF &
     "M" & HT & "mod2/sub4/file114.ext" & LF & "R87" & HT &
     "mod3/sub2/file17.ext" & HT & "moved/mod3/sub2/file17.ext" & LF & "M" &
     HT & "mod3/sub3/file73.ext" & LF & "M" & HT & "mod3/sub4/file94.ext" &
     LF & "D" & HT & "mod3/sub1/file66.ext" & LF & "M" & HT &
     "mod5/sub2/file12.ext" & LF & "R100" & HT & "mod3/sub2/file87.ext" & HT &
     "moved/mod3/sub2/file87.ext" & LF & "M" & HT & "mod2/sub3/file93.ext" &
     LF & "U" & HT & "mod0/sub4/file119.ext" & LF & "T" & HT &
     "mod4/sub4/file109.ext" & LF & "M" & HT & "mod1/sub1/file71.ext" & LF &
     "M" & HT & "mod5/sub4/file54.ext" & LF & "T" & HT &
     "mod0/sub4/file49.ext" & LF & "M" & HT & "mod5/sub3/file33.ext" & LF &
     "M" & HT & "mod1/sub4/file64.ext" & LF & "M" & HT &
     "mod6/sub2/file62.ext" & LF & "M" & HT & "mod2/sub2/file72.ext" & LF &
     "M" & HT & "mod4/sub4/file144.ext" & LF & "M" & HT &
     "mod1/sub0/file50.ext" & LF & "R100" & HT & "mod2/sub3/file58.ext" & HT &
     "moved/mod2/sub3/file58.ext" & LF & "R100" & HT & "mod0/sub3/file98.ext" &
     HT & "moved/mod0/sub3/file98.ext" & LF & "M" & HT &
     "mod0/sub2/file112.ext" & LF & "R100" & HT & "mod6/sub2/file27.ext" & HT &
     "moved/mod6/sub2/file27.ext" & LF & "M" & HT & "mod4/sub1/file81.ext" &
     LF & "M" & HT & "mod0/sub3/file133.ext" & LF & "M" & HT &
     "mod4/sub0/file60.ext" & LF & "A" & HT & "mod3/sub0/file115.ext" & LF &
     "R98" & HT & "mod1/sub2/file127.ext" & HT &
     "moved/mod1/sub2/file127.ext" & LF & "D" & HT & "mod1/sub1/file36.ext" &
     LF & "A" & HT & "mod1/sub0/file85.ext" & LF & "R98" & HT &
     "mod1/sub3/file8.ext" & HT & "moved/mod1/sub3/file8.ext" & LF & "R100" &
     HT & "mod6/sub2/file97.ext" & HT & "moved/mod6/sub2/file97.ext" & LF &
     "M" & HT & "mod0/sub1/file21.ext" & LF & "R100" & HT &
     "mod5/sub2/file117.ext" & HT & "moved/mod5/sub2/file117.ext" & LF & "M" &
     HT & "mod3/sub1/file101.ext" & LF & "M" & HT & "mod5/sub4/file124.ext" &
     LF & "M" & HT & "mod1/sub1/file141.ext" & LF & "M" & HT &
     "mod3/sub3/file3.ext" & LF & "U" & HT & "mod2/sub4/file9.ext" & LF & "U" &
     HT & "mod5/sub4/file89.ext" & LF & "M" & HT & "mod6/sub1/file41.ext" &
     LF & "T" & HT & "mod1/sub4/file29.ext" & LF & "M" & HT &
     "mod3/sub2/file122.ext" & LF & "U" & HT & "mod2/sub4/file149.ext" & LF &
     "M" & HT & "mod2/sub0/file30.ext" & LF & "M" & HT &
     "mod1/sub2/file92.ext" & LF & "A" & HT & "mod6/sub0/file125.ext" & LF &
     "R95" & HT & "mod5/sub3/file68.ext" & HT & "moved/mod5/sub3/file68.ext" &
     LF & "D" & HT & "mod0/sub1/file126.ext" & LF & "D" & HT &
     "mod6/sub1/file6.ext" & LF & "M" & HT & "mod6/sub0/file20.ext" & LF &
     "M" & HT & "mod5/sub1/file61.ext" & LF & "M" & HT &
     "mod3/sub3/file143.ext" & LF & "U" & HT & "mod5/sub4/file19.ext" & LF &
     "M" & HT & "mod3/sub0/file10.ext" & LF & "M" & HT &
     "mod1/sub2/file22.ext" & LF & "M" & HT & "mod6/sub1/file111.ext" & LF &
     "M" & HT & "mod5/sub0/file40.ext" & LF & "U" & HT &
     "mod4/sub4/file39.ext" & LF & "M" & HT & "mod1/sub3/file113.ext" & LF &
     "U" & HT & "mod6/sub4/file69.ext" & LF & "A" & HT &
     "mod0/sub0/file35.ext" & LF & "R100" & HT & "mod4/sub3/file88.ext" & HT &
     "moved/mod4/sub3/file88.ext" & LF & "R100" & HT & "mod4/sub3/file18.ext" &
     HT & "moved/mod4/sub3/file18.ext" & LF & "M" & HT &
     "mod6/sub2/file132.ext" & LF & "R100" & HT & "mod4/sub2/file137.ext" &
     HT & "moved/mod4/sub2/file137.ext" & LF & "M" & HT &
     "mod5/sub3/file103.ext" & LF & "M" & HT & "mod1/sub3/file43.ext" & LF &
     "D" & HT & "mod5/sub1/file26.ext" & LF & "M" & HT &
     "mod4/sub1/file11.ext" & LF & "A" & HT & "mod6/sub0/file55.ext" & LF &
     "M" & HT & "mod4/sub4/file4.ext" & LF & "R98" & HT &
     "mod0/sub2/file147.ext" & HT & "moved/mod0/sub2/file147.ext" & LF & "M" &
     HT & "mod1/sub4/file134.ext" & LF & "A" & HT & "mod4/sub0/file95.ext" &
     LF & "A" & HT & "mod5/sub0/file75.ext" & LF & "M" & HT &
     "mod6/sub3/file13.ext" & LF & "A" & HT & "mod0/sub0/file105.ext" & LF &
     "T" & HT & "mod1/sub4/file99.ext" & LF & "M" & HT &
     "mod4/sub2/file32.ext" & LF & "D" & HT & "mod6/sub1/file146.ext" & LF &
     "M" & HT & "mod5/sub1/file131.ext" & LF & "T" & HT &
     "mod3/sub4/file129.ext" & LF & "M" & HT & "mod2/sub4/file44.ext" & LF &
     "T" & HT & "mod3/sub4/file59.ext" & LF & "M" & HT &
     "mod6/sub4/file104.ext" & LF & "M" & HT & "mod3/sub1/file31.ext" & LF &
     "D" & HT & "mod5/sub1/file96.ext" & LF & "A" & HT &
     "mod1/sub0/file15.ext" & LF & "A" & HT & "mod4/sub0/file25.ext" & LF &
     "U" & HT & "mod6/sub4/file139.ext" & LF & "M" & HT &
     "mod2/sub3/file23.ext" & LF & "R100" & HT & "mod5/sub3/file138.ext" & HT &
     "moved/mod5/sub3/file138.ext" & LF & "R100" & HT &
     "mod2/sub3/file128.ext" & HT & "moved/mod2/sub3/file128.ext" & LF &
     "R87" & HT & "mod1/sub2/file57.ext" & HT & "moved/mod1/sub2/file57.ext" &
     LF & "M" & HT & "mod1/sub1/file1.ext" & LF & "R100" & HT &
     "mod2/sub2/file107.ext" & HT & "moved/mod2/sub2/file107.ext" & LF & "M" &
     HT & "mod4/sub4/file74.ext" & LF & "R95" & HT & "mod6/sub3/file48.ext" &
     HT & "moved/mod6/sub3/file48.ext" & LF & "D" & HT &
     "mod4/sub1/file46.ext" & LF & "M" & HT & "mod4/sub3/file53.ext" & LF &
     "M" & HT & "mod2/sub0/file100.ext" & LF & "M" & HT &
     "mod0/sub0/file70.ext" & LF & "M" & HT & "mod2/sub2/file2.ext" & LF &
     "M" & HT & "mod2/sub1/file51.ext" & LF & "R100" & HT &
     "mod3/sub3/file108.ext" & HT & "moved/mod3/sub3/file108.ext" & LF & "M" &
     HT & "mod0/sub1/file91.ext" & LF & "A" & HT & "mod5/sub0/file5.ext" & LF &
     "A" & HT & "mod2/sub0/file65.ext" & LF & "M" & HT &
     "mod0/sub4/file14.ext" & LF & "A" & HT & "mod3/sub0/file45.ext" & LF &
     "M" & HT & "mod1/sub0/file120.ext" & LF & "D" & HT &
     "mod3/sub1/file136.ext" & LF & "R100" & HT & "mod5/sub2/file47.ext" & HT &
     "moved/mod5/sub2/file47.ext" & LF & "M" & HT & "mod3/sub0/file80.ext" &
     LF & "M" & HT & "mod4/sub3/file123.ext" & LF & "R95" & HT &
     "mod1/sub3/file78.ext" & HT & "moved/mod1/sub3/file78.ext" & LF & "M" &
     HT & "mod6/sub0/file90.ext" & LF & "T" & HT & "mod2/sub4/file79.ext" &
     LF & "A" & HT & "mod5/sub0/file145.ext" & LF & "D" & HT &
     "mod2/sub1/file86.ext" & LF & "M" & HT & "mod0/sub0/file0.ext" & LF &
     "R100" & HT & "mod0/sub2/file77.ext" & HT & "moved/mod0/sub2/file77.ext" &
     LF & "M" & HT & "mod0/sub4/file84.ext" & LF & "D" & HT &
     "mod2/sub1/file16.ext" & LF & "R100" & HT & "mod4/sub2/file67.ext" & HT &
     "moved/mod4/sub2/file67.ext" & LF & "R100" & HT & "mod2/sub2/file37.ext" &
     HT & "moved/mod2/sub2/file37.ext" & LF & "M" & HT &
     "mod0/sub2/file42.ext" & LF & "D" & HT & "mod1/sub1/file106.ext" & LF;

   function Class_Digest (Raw : String) return String is
      Changes : constant Diff := Parse_Name_Status (Raw);
      Text    : Unbounded_String;

      procedure Class (Letter : Character; Paths : Text_Lists.Vector) is
      begin
         for P of Paths loop
            Append (Text, Letter & HT & P & LF);
         end loop;
      end Class;
   begin
      Class ('M', Changes.Modified);
      Class ('D', Changes.Deleted);
      Class ('R', Changes.Renamed_From);
      Class ('A', Changes.Added);
      return Hashing.Sha256_Hex (To_String (Text));
   end Class_Digest;

   procedure A_Large_Listing_Matches_The_Pipeline_It_Replaces
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Diff := Parse_Name_Status (Name_Status);
   begin
      Assert
        (Natural (Got.Modified.Length) = 75
         and then Natural (Got.Deleted.Length) = 15
         and then Natural (Got.Renamed_From.Length) = 30
         and then Natural (Got.Added.Length) = 15,
         "the class counts");
      Assert
        (Class_Digest (Name_Status) =
         "c0541f1601f0a7f5844ef9f50ad31174d71441d971beb286f9583570903daee1",
         "one digest stands for every path in every class: two paths " &
         "swapped between classes would change it");
   end A_Large_Listing_Matches_The_Pipeline_It_Replaces;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Drift");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Name_Status_Parsing_Splits_The_Four_Classes_And_Sorts_Each'Access,
         "Name-status parsing splits the four classes and sorts each");
      Register_Routine
        (T, A_Status_Letter_With_A_Score_Is_Still_Its_Class'Access,
         "A status letter with a score is still its class");
      Register_Routine
        (T, Classes_That_Are_Not_Reported_Are_Ignored_Not_Invented'Access,
         "Classes that are not reported are ignored, not invented");
      Register_Routine
        (T, Odd_Lines_Are_Skipped_And_A_Tab_In_A_Path_Survives'Access,
         "Odd lines are skipped and a tab in a path survives");
      Register_Routine
        (T, Count_Intersect_Is_A_Merge_Pass_Over_Two_Sorted_Lists'Access,
         "Count_Intersect is a merge pass over two sorted lists");
      Register_Routine
        (T, A_Nodes_Drift_Counts_Each_Class_Separately'Access,
         "A node's drift counts each class separately");
      Register_Routine
        (T, Findings_Come_Out_Modified_Renamed_Deleted'Access,
         "Findings come out modified, renamed, deleted");
      Register_Routine
        (T, An_Undiffable_Node_Points_At_Stale'Access,
         "An undiffable node points at stale");
      Register_Routine
        (T, Short_Commit_Is_Twelve_Characters'Access,
         "Short_Commit is twelve characters");
      Register_Routine
        (T, A_Large_Listing_Matches_The_Pipeline_It_Replaces'Access,
         "A large listing matches the pipeline it replaces");
   end Register_Tests;

end Synapse.Core.Drift.Tests;
