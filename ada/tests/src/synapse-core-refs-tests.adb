with Ada.Numerics.Discrete_Random;

with AUnit.Assertions;

with Synapse.Adapters.Memory_Byte_Source;

package body Synapse.Core.Refs.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function Row_Line (Name, Dir, Kind, Site, Expr : String) return String is
     (Name & HT & Dir & HT & Kind & HT & Site & HT & Expr);

   --  Rows in bytewise order, as Sort_Unique leaves them. `bet` sits before
   --  `beta`, the pair that breaks a prefix match.
   Sample : constant String :=
     Row_Line ("bet", "ref", "call", "src/a.ext:10", "bet();") & LF &
     Row_Line ("beta", "def", "method", "src/b.ext:3", "void beta() {") & LF &
     Row_Line ("beta", "ref", "call", "src/a.ext:20", "beta(1);") & LF &
     Row_Line
       ("beta", "ref", "implementation", "src/c.ext:5",
        "class X implements beta {") &
     LF & Row_Line ("zeta", "ref", "call", "src/z.ext:1", "zeta();") & LF;

   function Lookup
     (Index : String; Name : String; Block : Positive := Default_Block)
      return Row_Vectors.Vector
   is
      Source : Adapters.Memory_Byte_Source.Source :=
        Adapters.Memory_Byte_Source.Create (Index);
   begin
      return Find (Source, Name, Block);
   end Lookup;

   function Sites (Rows : Row_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for R of Rows loop
         Append (Result, R.Site & ";");
      end loop;
      return To_String (Result);
   end Sites;

   procedure An_Exact_Name_Is_Found_And_A_Prefix_Is_Not_Swept_In
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Sites (Lookup (Sample, "bet")) = "src/a.ext:10;", "bet, and no beta");
   end An_Exact_Name_Is_Found_And_A_Prefix_Is_Not_Swept_In;

   procedure Every_Row_For_A_Name_Comes_Back_In_Index_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Rows : constant Row_Vectors.Vector := Lookup (Sample, "beta");
   begin
      Assert (Natural (Rows.Length) = 3, "three rows");
      Assert (To_String (Rows (1).Dir) = "def", "the def first");
      Assert (To_String (Rows (2).Kind) = "call", "then the call");
      Assert (To_String (Rows (3).Kind) = "implementation", "then the other");
   end Every_Row_For_A_Name_Comes_Back_In_Index_Order;

   procedure An_Implements_Clause_Is_A_Ref_But_Not_A_Call
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Calls : Natural := 0;
   begin
      for R of Lookup (Sample, "beta") loop
         if Is_Call (R) then
            Calls := Calls + 1;
         end if;
      end loop;
      Assert (Calls = 1, "one of three is a call");
   end An_Implements_Clause_Is_A_Ref_But_Not_A_Call;

   procedure Names_Outside_The_Index_Find_Nothing (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Lookup (Sample, "aaa").Is_Empty, "before the first row");
      Assert (Lookup (Sample, "zzz").Is_Empty, "after the last");
      Assert (Lookup (Sample, "gamma").Is_Empty, "between two");
      Assert (Lookup (Sample, "").Is_Empty, "an empty name");
      Assert (Lookup ("", "anything").Is_Empty, "an empty index");
   end Names_Outside_The_Index_Find_Nothing;

   procedure The_First_And_Last_Rows_Are_Reachable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Sites (Lookup (Sample, "bet")) /= "", "the first");
      Assert (Sites (Lookup (Sample, "zeta")) = "src/z.ext:1;", "the last");
   end The_First_And_Last_Rows_Are_Reachable;

   procedure A_Truncated_Final_Line_Is_Skipped_Not_Fatal
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Cut : constant String :=
        Row_Line ("beta", "def", "method", "src/b.ext:3", "void beta() {") &
        LF & "beta" & HT & "ref";
   begin
      Assert (Natural (Lookup (Cut, "beta").Length) = 1, "the whole row only");
   end A_Truncated_Final_Line_Is_Skipped_Not_Fatal;

   procedure An_Index_With_No_Trailing_Newline_Yields_Its_Last_Row
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Sites
           (Lookup
              (Row_Line ("beta", "ref", "call", "src/a.ext:1", "beta();"),
               "beta")) =
         "src/a.ext:1;",
         "the last line without a line feed");
   end An_Index_With_No_Trailing_Newline_Yields_Its_Last_Row;

   procedure Row_Fields_Are_Split_And_The_Expression_Is_The_Remainder
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Maybe_Row :=
        Parse_Row
          ("n" & HT & "ref" & HT & "call" & HT & "C:/x/y.ext:42" & HT & "a" &
           HT & "b");
   begin
      Assert (Got.Found, "found");
      Assert
        (To_String (Got.Value.Site) = "C:/x/y.ext:42",
         "a drive letter stays in the site");
      Assert
        (To_String (Got.Value.Expr) = "a" & HT & "b",
         "the whole remainder, a tab included");
      Assert
        (not Parse_Row ("n" & HT & "ref" & HT & "call").Found,
         "too few fields");
      Assert
        (To_String
           (Parse_Row ("n" & HT & "ref" & HT & "call" & HT & "s").Value.Expr) =
         "",
         "no expression is an empty one");
      Assert (not Parse_Row ("").Found, "empty");
   end Row_Fields_Are_Split_And_The_Expression_Is_The_Remainder;

   procedure Sort_Unique_Drops_Duplicates_And_Counts_What_Survives
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Sorted : constant Sorted_Index :=
        Sort_Unique
          (Row_Line ("zeta", "ref", "call", "src/z.ext:1", "zeta();") & LF &
           Row_Line ("beta", "def", "method", "src/b.ext:3", "void beta() {") &
           LF & Row_Line ("zeta", "ref", "call", "src/z.ext:1", "zeta();") &
           LF & LF &
           Row_Line ("beta", "ref", "call", "src/a.ext:20", "beta(1);") & LF);
   begin
      Assert
        (To_String (Sorted.Text) =
         Row_Line ("beta", "def", "method", "src/b.ext:3", "void beta() {") &
         LF & Row_Line ("beta", "ref", "call", "src/a.ext:20", "beta(1);") &
         LF & Row_Line ("zeta", "ref", "call", "src/z.ext:1", "zeta();") & LF,
         "sorted, each once");
      Assert
        (Sorted.Tally.Tags = 3 and then Sorted.Tally.Defs = 1
         and then Sorted.Tally.Refs = 2,
         "tags, defs and refs");
      Assert (Sorted.Tally.Files = 3, "three distinct paths");
   end Sort_Unique_Drops_Duplicates_And_Counts_What_Survives;

   procedure The_File_Count_Is_Distinct_Paths_Not_Distinct_Rows
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Sorted : constant Sorted_Index :=
        Sort_Unique
          (Row_Line ("aaa", "ref", "call", "src/one.ext:1", "a();") & LF &
           Row_Line ("zzz", "ref", "call", "src/one.ext:9", "z();") & LF);
   begin
      Assert
        (Sorted.Tally.Tags = 2 and then Sorted.Tally.Files = 1,
         "two names in one file, which sort apart");
      Assert (Sort_Unique ("").Tally.Tags = 0, "nothing");
      Assert
        (Sort_Unique ("not a row" & LF).Tally.Tags = 1
         and then Sort_Unique ("not a row" & LF).Tally.Files = 0,
         "a line that is not a row counts as a tag and as no file");
   end The_File_Count_Is_Distinct_Paths_Not_Distinct_Rows;

   --  The bisection against a plain scan, on indexes of random names, at
   --  block sizes that cut lines everywhere.
   package Draw is new Ada.Numerics.Discrete_Random (Natural);

   procedure The_Bisection_Agrees_With_A_Plain_Scan
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Gen      : Draw.Generator;
      Alphabet : constant String := "abc";

      function Pick (Limit : Positive) return Natural is
        (Draw.Random (Gen) mod Limit);

      function Random_Name return String is
         Name : String (1 .. 1 + Pick (4));
      begin
         for C of Name loop
            C := Alphabet (Alphabet'First + Pick (Alphabet'Length));
         end loop;
         return Name;
      end Random_Name;

      Blocks : constant array (1 .. 5) of Positive := [1, 3, 7, 64, 100_000];
   begin
      Draw.Reset (Gen, 3);
      for Round in 1 .. 60 loop
         declare
            Unsorted : Unbounded_String;
         begin
            for Line in 1 .. Pick (40) loop
               Append
                 (Unsorted,
                  Row_Line
                    (Random_Name, (if Pick (2) = 0 then "def" else "ref"),
                     "call",
                     "p/" & Random_Name & ".ext:" & Integer'Image (Pick (99)),
                     "x" & Random_Name) &
                  LF);
            end loop;
            if Pick (3) = 0 then
               Append (Unsorted, "torn" & HT & "ref");
            end if;
            declare
               Text : constant String :=
                 To_String (Sort_Unique (To_String (Unsorted)).Text);
            begin
               for Name_Length in 1 .. 5 loop
                  for Query_Number in 1 .. 6 loop
                     declare
                        Query    : constant String :=
                          (if Name_Length = 5 then "zzz" else Random_Name);
                        Expected : Natural         := 0;
                        Start    : Positive        := Text'First;
                     begin
                        for I in Text'Range loop
                           if Text (I) = LF then
                              declare
                                 Parsed : constant Maybe_Row :=
                                   Parse_Row (Text (Start .. I - 1));
                              begin
                                 if Parsed.Found
                                   and then To_String (Parsed.Value.Name) =
                                     Query
                                 then
                                    Expected := Expected + 1;
                                 end if;
                              end;
                              Start := I + 1;
                           end if;
                        end loop;
                        for Block of Blocks loop
                           Assert
                             (Natural (Lookup (Text, Query, Block).Length) =
                              Expected,
                              "round" & Round'Image & " query " & Query &
                              " block" & Block'Image);
                        end loop;
                     end;
                  end loop;
               end loop;
            end;
         end;
      end loop;
   end The_Bisection_Agrees_With_A_Plain_Scan;

   procedure A_Line_Longer_Than_The_Block_Is_Still_Read
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Long  : constant String             := [1 .. 5_000 => 'x'];
      Text  : constant String             :=
        Row_Line ("a", "def", "k", "p:1", Long) & LF &
        Row_Line ("b", "def", "k", "p:2", Long) & LF &
        Row_Line ("b", "ref", "call", "p:3", "short") & LF &
        Row_Line ("c", "def", "k", "p:4", Long) & LF;
      Found : constant Row_Vectors.Vector := Lookup (Text, "b", 16);
   begin
      Assert (Sites (Found) = "p:2;p:3;", "both rows of b, past a block");
      Assert (Length (Found (1).Expr) = 5_000, "the whole expression");
      Assert (Sites (Lookup (Text, "c", 16)) = "p:4;", "the last, long one");
   end A_Line_Longer_Than_The_Block_Is_Still_Read;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Refs");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, An_Exact_Name_Is_Found_And_A_Prefix_Is_Not_Swept_In'Access,
         "An exact name is found and a prefix is not swept in");
      Register_Routine
        (T, Every_Row_For_A_Name_Comes_Back_In_Index_Order'Access,
         "Every row for a name comes back in index order");
      Register_Routine
        (T, An_Implements_Clause_Is_A_Ref_But_Not_A_Call'Access,
         "An implements clause is a ref but not a call");
      Register_Routine
        (T, Names_Outside_The_Index_Find_Nothing'Access,
         "Names outside the index find nothing");
      Register_Routine
        (T, The_First_And_Last_Rows_Are_Reachable'Access,
         "The first and last rows are reachable");
      Register_Routine
        (T, A_Truncated_Final_Line_Is_Skipped_Not_Fatal'Access,
         "A truncated final line is skipped, not fatal");
      Register_Routine
        (T, An_Index_With_No_Trailing_Newline_Yields_Its_Last_Row'Access,
         "An index with no trailing newline yields its last row");
      Register_Routine
        (T, Row_Fields_Are_Split_And_The_Expression_Is_The_Remainder'Access,
         "Row fields are split and the expression is the remainder");
      Register_Routine
        (T, Sort_Unique_Drops_Duplicates_And_Counts_What_Survives'Access,
         "Sort_Unique drops duplicates and counts what survives");
      Register_Routine
        (T, The_File_Count_Is_Distinct_Paths_Not_Distinct_Rows'Access,
         "The file count is distinct paths, not distinct rows");
      Register_Routine
        (T, The_Bisection_Agrees_With_A_Plain_Scan'Access,
         "The bisection agrees with a plain scan");
      Register_Routine
        (T, A_Line_Longer_Than_The_Block_Is_Still_Read'Access,
         "A line longer than the block is still read");
   end Register_Tests;

end Synapse.Core.Refs.Tests;
