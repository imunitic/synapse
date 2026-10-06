with AUnit.Assertions;

package body Synapse.Core.Gate.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function Row (Cluster, Word : String; Count : Natural) return String is
      Text : constant String := Natural'Image (Count);
   begin
      return
        Cluster & HT & Word & HT & Text (Text'First + 1 .. Text'Last) & LF;
   end Row;

   function Top (V : Verdict; I : Positive) return String is
     (To_String (V.Top (I)));

   function Name_Of (V : Verdict) return String is (To_String (V.Cluster));

   procedure A_Cluster_Whose_Top_Words_Are_All_Common_Is_Flagged
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Verdict_Vectors.Vector :=
        Judge
          (Row ("a", "service", 10) & Row ("a", "impl", 9) &
           Row ("b", "service", 8) & Row ("b", "impl", 7) &
           Row ("c", "service", 6) & Row ("c", "impl", 5));
   begin
      Assert (Natural (Got.Length) = 3, "three clusters");
      for V of Got loop
         Assert (V.Rare = 0 and then V.State = Flagged, "common: flagged");
      end loop;
   end A_Cluster_Whose_Top_Words_Are_All_Common_Is_Flagged;

   procedure One_Distinctive_Word_Is_Not_Enough_Two_Are
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Verdict_Vectors.Vector :=
        Judge
          (Row ("one", "service", 10) & Row ("one", "unique1", 9) &
           Row ("two", "service", 8) & Row ("two", "uniqueA", 7) &
           Row ("two", "uniqueB", 6) & Row ("three", "service", 5));
   begin
      Assert
        (Name_Of (Got (1)) = "one" and then Got (1).Rare = 1
         and then Got (1).State = Flagged,
         "one rare word");
      Assert
        (Name_Of (Got (2)) = "two" and then Got (2).Rare = 2
         and then Got (2).State = Ok,
         "two rare words");
   end One_Distinctive_Word_Is_Not_Enough_Two_Are;

   procedure Clusters_Keep_The_Order_The_Table_Listed_Them_In
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Verdict_Vectors.Vector :=
        Judge
          (Row ("zeta", "w", 1) & Row ("alpha", "w", 1) & Row ("mid", "w", 1));
   begin
      Assert
        (Name_Of (Got (1)) = "zeta" and then Name_Of (Got (2)) = "alpha"
         and then Name_Of (Got (3)) = "mid",
         "first appearance");
   end Clusters_Keep_The_Order_The_Table_Listed_Them_In;

   procedure A_Repeated_Pair_Counts_Once_And_Keeps_The_Larger_Count
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Verdict_Vectors.Vector :=
        Judge
          (Row ("a", "w", 3) & Row ("a", "w", 9) & Row ("a", "other", 1) &
           Row ("b", "z", 1));
   begin
      Assert
        (Got (1).Rare = 2 and then Got (1).State = Ok,
         "w counts once toward its document frequency");
      Assert (Top (Got (1), 1) = "w", "the larger count won");
      Assert (Got (2).Rare = 1, "the other cluster");
   end A_Repeated_Pair_Counts_Once_And_Keeps_The_Larger_Count;

   procedure A_Smaller_Repeat_Does_Not_Lower_The_Count
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Verdict_Vectors.Vector :=
        Judge (Row ("a", "w", 9) & Row ("a", "w", 3) & Row ("a", "x", 5));
   begin
      Assert (Top (Got (1), 1) = "w", "9 stays above 5");
   end A_Smaller_Repeat_Does_Not_Lower_The_Count;

   procedure Ties_Break_By_Name_So_A_Run_Is_Reproducible
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Verdict_Vectors.Vector :=
        Judge
          (Row ("a", "beta", 5) & Row ("a", "alpha", 5) &
           Row ("a", "gamma", 5),
           (Top => 3, others => <>));
   begin
      Assert
        (Top (Got (1), 1) = "alpha" and then Top (Got (1), 2) = "beta"
         and then Top (Got (1), 3) = "gamma",
         "by name ascending");
   end Ties_Break_By_Name_So_A_Run_Is_Reproducible;

   procedure Top_Is_A_Cap_Not_A_Requirement (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Table : constant String := Row ("a", "one", 1) & Row ("a", "two", 2);
   begin
      Assert
        (Natural (Judge (Table) (1).Top.Length) = 2, "fewer than the cap");
      Assert (Top (Judge (Table) (1), 1) = "two", "highest first");
      Assert
        (Natural (Judge (Table, (Top => 1, others => <>)) (1).Top.Length) = 1,
         "capped");
      Assert
        (Judge (Table, (Top => 0, others => <>)) (1).Top.Is_Empty,
         "a cap of none");
   end Top_Is_A_Cap_Not_A_Requirement;

   procedure The_Rare_Threshold_Scales_Past_Forty_Clusters
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Table : Unbounded_String;
   begin
      for I in 0 .. 59 loop
         declare
            Image : constant String := Natural'Image (I);
            Name  : constant String :=
              "c" & Image (Image'First + 1 .. Image'Last);
         begin
            Append (Table, Row (Name, "common", 5));
            if I < 3 then
               Append (Table, Row (Name, "triple", 9));
            end if;
         end;
      end loop;
      declare
         Got : constant Verdict_Vectors.Vector := Judge (To_String (Table));
      begin
         Assert (Natural (Got.Length) = 60, "sixty clusters");
         Assert
           (Got (1).Rare = 1 and then Got (1).State = Flagged,
            "triple is in 3 clusters, the threshold: one rare word");
         Assert (Got (60).Rare = 0, "common is in all sixty");
      end;
   end The_Rare_Threshold_Scales_Past_Forty_Clusters;

   procedure Odd_Rows_Are_Skipped_Rather_Than_Fatal
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Verdict_Vectors.Vector :=
        Judge
          ("a" & HT & "w" & HT & "1" & LF & "not-a-row" & LF & "a" & HT &
           "only-two-fields" & LF & HT & "w" & HT & "1" & LF & "a" & HT & HT &
           "1" & LF);
   begin
      Assert (Natural (Got.Length) = 1, "one cluster");
      Assert (Natural (Got (1).Top.Length) = 1, "from the one good row");
   end Odd_Rows_Are_Skipped_Rather_Than_Fatal;

   procedure A_Count_That_Is_Not_A_Number_Reads_As_Zero
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Verdict_Vectors.Vector :=
        Judge
          ("a" & HT & "bad" & HT & "x" & LF & "a" & HT & "neg" & HT & "-4" &
           LF & "a" & HT & "plus" & HT & " +7 " & LF & "a" & HT & "good" & HT &
           "2" & LF & "a" & HT & "huge" & HT & "99999999999999999999999" & LF &
           "a" & HT & "extra" & HT & "3" & HT & "more" & LF & "a" & HT & "cr" &
           HT & "1" & Character'Val (13) & LF);
   begin
      Assert (Top (Got (1), 1) = "plus", "a leading plus parses");
      Assert (Top (Got (1), 2) = "extra", "a fourth field is ignored");
      Assert (Top (Got (1), 3) = "good", "two");
      Assert (Top (Got (1), 4) = "cr", "a carriage return is dropped");
      Assert
        (Natural (Got (1).Top.Length) = 7,
         "a row with a bad count is kept: it still proves the word");
   end A_Count_That_Is_Not_A_Number_Reads_As_Zero;

   procedure Leading_Zeros_Do_Not_Change_A_Count (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Verdict_Vectors.Vector :=
        Judge (Row ("a", "a", 7) & "a" & HT & "b" & HT & "007" & LF);
   begin
      Assert (Top (Got (1), 1) = "a", "equal counts: the name decides");
   end Leading_Zeros_Do_Not_Change_A_Count;

   procedure An_Empty_Table_Judges_Nothing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Judge ("").Is_Empty, "no verdicts");
      Assert (Judge_Distinctiveness ("").Is_Empty, "no rows");
   end An_Empty_Table_Judges_Nothing;

   procedure A_Flagged_Cluster_With_No_Parseable_File_Is_Unparseable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Table    : constant String :=
        Row ("a", "service", 10) & Row ("b", "service", 8) &
        Row ("c", "service", 6);
      Settings : Options;
   begin
      Settings.Unparseable.Include ("a");
      declare
         Got : constant Verdict_Vectors.Vector := Judge (Table, Settings);
      begin
         Assert (Got (1).State = Unparseable, "a: nothing parses");
         Assert (Got (2).State = Flagged, "b: not listed, judged by words");
      end;
   end A_Flagged_Cluster_With_No_Parseable_File_Is_Unparseable;

   procedure A_Cluster_That_Passes_Is_Ok_Whatever_Its_Parseability
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Settings : Options;
   begin
      Settings.Unparseable.Include ("a");
      Assert
        (Judge (Row ("a", "w", 3) & Row ("a", "x", 2), Settings) (1).State =
         Ok,
         "two rare words");
   end A_Cluster_That_Passes_Is_Ok_Whatever_Its_Parseability;

   procedure The_Line_Shape_Is_The_Same_For_Every_Status
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Words_1 : Text_Lists.Vector;
      Words_2 : Text_Lists.Vector;
   begin
      Words_1.Append (To_Unbounded_String ("service"));
      Words_1.Append (To_Unbounded_String ("impl"));
      Words_2.Append (To_Unbounded_String ("statemachine"));
      Assert
        (Verdict_Line
           ((To_Unbounded_String ("lists/01"), 0, Flagged, Words_1)) =
         "lists/01" & HT & "0" & HT & "flagged" & HT & "service impl" & LF,
         "flagged");
      Assert
        (Verdict_Line ((To_Unbounded_String ("lists/02"), 4, Ok, Words_2)) =
         "lists/02" & HT & "4" & HT & "ok" & HT & "statemachine" & LF,
         "ok");
      Assert
        (Verdict_Line
           ((To_Unbounded_String ("c"), 0, Unparseable,
             Text_Lists.Vector'(Text_Lists.Vectors.Empty_Vector))) =
         "c" & HT & "0" & HT & "unparseable" & HT & LF,
         "unparseable, with no words");
   end The_Line_Shape_Is_The_Same_For_Every_Status;

   procedure A_Word_Shared_By_Every_Group_Is_Not_Distinctive
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Row_Vectors.Vector :=
        Judge_Distinctiveness
          (Row ("a", "service", 10) & Row ("a", "impl", 9) &
           Row ("b", "service", 8) & Row ("b", "impl", 7) &
           Row ("c", "service", 6) & Row ("c", "impl", 5));
   begin
      Assert (Natural (Got.Length) = 3, "every group");
      for R of Got loop
         Assert
           (R.Distinctive = 0 and then R.Considered = 2,
            "score 0.4, below the half");
      end loop;
   end A_Word_Shared_By_Every_Group_Is_Not_Distinctive;

   procedure A_Word_Unique_To_One_Group_Is_Distinctive
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Row_Vectors.Vector :=
        Judge_Distinctiveness
          (Row ("a", "service", 10) & Row ("a", "unique1", 9) &
           Row ("b", "service", 8) & Row ("b", "uniqueA", 7) &
           Row ("b", "uniqueB", 6) & Row ("c", "service", 5));
   begin
      Assert
        (To_String (Got (1).Group) = "a" and then Got (1).Distinctive = 1,
         "one");
      Assert
        (To_String (Got (2).Group) = "b" and then Got (2).Distinctive = 2,
         "two");
      Assert (Got (3).Distinctive = 0, "none");
   end A_Word_Unique_To_One_Group_Is_Distinctive;

   procedure Groups_Keep_Their_Order_And_Every_One_Appears
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Row_Vectors.Vector :=
        Judge_Distinctiveness
          (Row ("zeta", "w", 1) & Row ("alpha", "w", 1) & Row ("mid", "w", 1));
   begin
      Assert
        (To_String (Got (1).Group) = "zeta"
         and then To_String (Got (2).Group) = "alpha"
         and then To_String (Got (3).Group) = "mid"
         and then Got (1).Distinctive = 0,
         "order and a zero score");
   end Groups_Keep_Their_Order_And_Every_One_Appears;

   procedure Top_Caps_How_Many_Words_Are_Considered
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Table : constant String :=
        Row ("a", "one", 5) & Row ("a", "two", 4) & Row ("a", "three", 3) &
        Row ("a", "four", 2);
   begin
      Assert
        (Judge_Distinctiveness (Table, (Top => 2, K => 20)) (1).Considered = 2,
         "capped");
      Assert (Judge_Distinctiveness (Table) (1).Considered = 4, "all four");
   end Top_Caps_How_Many_Words_Are_Considered;

   procedure A_Larger_K_Asks_A_Word_To_Be_Rarer (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Table : Unbounded_String;
   begin
      for I in 0 .. 19 loop
         declare
            Image : constant String := Natural'Image (I);
            Name  : constant String :=
              "c" & Image (Image'First + 1 .. Image'Last);
         begin
            Append (Table, Row (Name, "filler", 1));
            if I < 3 then
               Append (Table, Row (Name, "rare3", 9));
            end if;
         end;
      end loop;
      Assert
        (Judge_Distinctiveness (To_String (Table), (Top => 1, K => 20)) (1)
           .Distinctive =
         0,
         "K 20: D is 2 and a word in 3 scores 0.4");
      Assert
        (Judge_Distinctiveness (To_String (Table), (Top => 1, K => 5)) (1)
           .Distinctive =
         1,
         "K 5: D is 4 and the same word scores 0.57");
   end A_Larger_K_Asks_A_Word_To_Be_Rarer;

   procedure A_Word_Exactly_At_The_Half_Point_Is_Not_Distinctive
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Table : Unbounded_String;
   begin
      for I in 0 .. 39 loop
         declare
            Image : constant String := Natural'Image (I);
            Name  : constant String :=
              "c" & Image (Image'First + 1 .. Image'Last);
         begin
            Append (Table, Row (Name, "filler", 1));
            if I < 2 then
               Append (Table, Row (Name, "pair", 9));
            end if;
         end;
      end loop;
      Assert
        (Judge_Distinctiveness (To_String (Table), (Top => 1, K => 20)) (1)
           .Distinctive =
         0,
         "40 groups, K 20: D is 2 and a word in 2 scores exactly one half");
   end A_Word_Exactly_At_The_Half_Point_Is_Not_Distinctive;

   procedure The_Distinctiveness_Line_Is_Group_Then_Count_Then_Considered
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Distinctiveness_Line ((To_Unbounded_String ("core/src"), 3, 8)) =
         "core/src" & HT & "3" & HT & "8" & LF,
         "the line");
   end The_Distinctiveness_Line_Is_Group_Then_Count_Then_Considered;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Gate");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Cluster_Whose_Top_Words_Are_All_Common_Is_Flagged'Access,
         "A cluster whose top words are all common is flagged");
      Register_Routine
        (T, One_Distinctive_Word_Is_Not_Enough_Two_Are'Access,
         "One distinctive word is not enough, two are");
      Register_Routine
        (T, Clusters_Keep_The_Order_The_Table_Listed_Them_In'Access,
         "Clusters keep the order the table listed them in");
      Register_Routine
        (T, A_Repeated_Pair_Counts_Once_And_Keeps_The_Larger_Count'Access,
         "A repeated pair counts once and keeps the larger count");
      Register_Routine
        (T, A_Smaller_Repeat_Does_Not_Lower_The_Count'Access,
         "A smaller repeat does not lower the count");
      Register_Routine
        (T, Ties_Break_By_Name_So_A_Run_Is_Reproducible'Access,
         "Ties break by name so a run is reproducible");
      Register_Routine
        (T, Top_Is_A_Cap_Not_A_Requirement'Access,
         "Top is a cap, not a requirement");
      Register_Routine
        (T, The_Rare_Threshold_Scales_Past_Forty_Clusters'Access,
         "The rare threshold scales past forty clusters");
      Register_Routine
        (T, Odd_Rows_Are_Skipped_Rather_Than_Fatal'Access,
         "Odd rows are skipped rather than fatal");
      Register_Routine
        (T, A_Count_That_Is_Not_A_Number_Reads_As_Zero'Access,
         "A count that is not a number reads as zero");
      Register_Routine
        (T, Leading_Zeros_Do_Not_Change_A_Count'Access,
         "Leading zeros do not change a count");
      Register_Routine
        (T, An_Empty_Table_Judges_Nothing'Access,
         "An empty table judges nothing");
      Register_Routine
        (T, A_Flagged_Cluster_With_No_Parseable_File_Is_Unparseable'Access,
         "A flagged cluster with no parseable file is unparseable");
      Register_Routine
        (T, A_Cluster_That_Passes_Is_Ok_Whatever_Its_Parseability'Access,
         "A cluster that passes is ok whatever its parseability");
      Register_Routine
        (T, The_Line_Shape_Is_The_Same_For_Every_Status'Access,
         "The line shape is the same for every status");
      Register_Routine
        (T, A_Word_Shared_By_Every_Group_Is_Not_Distinctive'Access,
         "A word shared by every group is not distinctive");
      Register_Routine
        (T, A_Word_Unique_To_One_Group_Is_Distinctive'Access,
         "A word unique to one group is distinctive");
      Register_Routine
        (T, Groups_Keep_Their_Order_And_Every_One_Appears'Access,
         "Groups keep their order and every one appears");
      Register_Routine
        (T, Top_Caps_How_Many_Words_Are_Considered'Access,
         "Top caps how many words are considered");
      Register_Routine
        (T, A_Larger_K_Asks_A_Word_To_Be_Rarer'Access,
         "A larger K asks a word to be rarer");
      Register_Routine
        (T, A_Word_Exactly_At_The_Half_Point_Is_Not_Distinctive'Access,
         "A word exactly at the half point is not distinctive");
      Register_Routine
        (T,
         The_Distinctiveness_Line_Is_Group_Then_Count_Then_Considered'Access,
         "The distinctiveness line is group, count, considered");
   end Register_Tests;

end Synapse.Core.Gate.Tests;
