with Ada.Numerics.Discrete_Random;

with AUnit.Assertions;

with Synapse.Adapters.Memory_Byte_Source;

package body Synapse.Core.Links.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package Memory renames Adapters.Memory_Byte_Source;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   --  One refs row.
   function Row (Name, Dir, Site : String) return String is
     (Name & HT & Dir & HT & "k" & HT & Site & HT & "x" & LF);

   function Def (Name, Site : String) return String is
     (Row (Name, "def", Site));

   function Ref (Name, Site : String) return String is
     (Row (Name, "ref", Site));

   function Nodes_Of (A : String; B : String := "") return Text_Lists.Vector is
      Result : Text_Lists.Vector;
   begin
      Result.Append (To_Unbounded_String (A));
      if B /= "" then
         Result.Append (To_Unbounded_String (B));
      end if;
      return Result;
   end Nodes_Of;

   function Edges_Of
     (Table : String; Map : Path_Nodes.Map; Count : Natural := 10;
      Opts  : Options := Default_Options) return Edge_Vectors.Vector
   is
      Source : Memory.Source := Memory.Create (Table);
   begin
      return Compute (Source, Map, Count, Opts);
   end Edges_Of;

   function Shown (V : Edge_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for E of V loop
         Append (Result, E.From & ">" & E.To & ":" & Natural'Image (E.Weight));
         for S of E.Symbols loop
            Append (Result, " " & S);
         end loop;
         Append (Result, ";");
      end loop;
      return To_String (Result);
   end Shown;

   procedure A_Ref_In_A_To_A_Def_In_B_Is_An_Edge (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("a/widget.ext", Nodes_Of ("A"));
      Map.Insert ("b/gadget.ext", Nodes_Of ("B"));
      Assert
        (Shown
           (Edges_Of
              (Def ("Helper", "b/gadget.ext:1") &
               Ref ("Helper", "a/widget.ext:5"),
               Map)) =
         "A>B: 1 Helper;",
         "A references what B defines");
   end A_Ref_In_A_To_A_Def_In_B_Is_An_Edge;

   procedure A_Ref_And_A_Def_In_The_Same_Node_Make_No_Self_Edge
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("a/one.ext", Nodes_Of ("A"));
      Map.Insert ("a/two.ext", Nodes_Of ("A"));
      Assert
        (Edges_Of
           (Def ("Local", "a/one.ext:1") & Ref ("Local", "a/two.ext:2"), Map)
           .Is_Empty,
         "no self-edge");
   end A_Ref_And_A_Def_In_The_Same_Node_Make_No_Self_Edge;

   procedure A_Symbol_Referenced_From_Too_Many_Nodes_Is_Not_Rare
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map   : Path_Nodes.Map;
      Table : constant String :=
        Def ("Common", "d/def.ext:1") & Ref ("Common", "a/a.ext:1") &
        Ref ("Common", "b/b.ext:1") & Ref ("Common", "c/c.ext:1");
   begin
      Map.Insert ("d/def.ext", Nodes_Of ("D"));
      Map.Insert ("a/a.ext", Nodes_Of ("A"));
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Map.Insert ("c/c.ext", Nodes_Of ("C"));
      --  With ten nodes the floor is two, and three readers exceed it.
      Assert (Edges_Of (Table, Map, 10).Is_Empty, "no edge");
      --  With sixty it is three, and three readers are rare.
      Assert
        (Natural (Edges_Of (Table, Map, 60).Length) = 3,
         "three edges once the floor allows it");
   end A_Symbol_Referenced_From_Too_Many_Nodes_Is_Not_Rare;

   procedure A_Symbol_Defined_In_Two_Nodes_Makes_No_Edge_To_Either
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("a/a.ext", Nodes_Of ("A"));
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Map.Insert ("c/c.ext", Nodes_Of ("C"));
      Assert
        (Edges_Of
           (Def ("run", "a/a.ext:1") & Def ("run", "b/b.ext:1") &
            Ref ("run", "c/c.ext:1"),
            Map)
           .Is_Empty,
         "ambiguous: without the one-definer rule this would fan out");
   end A_Symbol_Defined_In_Two_Nodes_Makes_No_Edge_To_Either;

   procedure Weight_Counts_Distinct_Symbols_Not_Occurrences
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Map.Insert ("a/a.ext", Nodes_Of ("A"));
      Assert
        (Shown
           (Edges_Of
              (Def ("Widget", "b/b.ext:1") & Ref ("Widget", "a/a.ext:3") &
               Ref ("Widget", "a/a.ext:9"),
               Map)) =
         "A>B: 1 Widget;",
         "two calls, one symbol");
   end Weight_Counts_Distinct_Symbols_Not_Occurrences;

   procedure An_Edge_Is_Supported_By_Every_Rare_Symbol_That_Crosses_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Map.Insert ("a/a.ext", Nodes_Of ("A"));
      Assert
        (Shown
           (Edges_Of
              (Def ("Beta", "b/b.ext:2") & Ref ("Beta", "a/a.ext:2") &
               Def ("Alpha", "b/b.ext:1") & Ref ("Alpha", "a/a.ext:1"),
               Map)) =
         "A>B: 2 Alpha Beta;",
         "the weight is the count, symbols sorted");
   end An_Edge_Is_Supported_By_Every_Rare_Symbol_That_Crosses_It;

   procedure A_Path_No_List_Claims_Contributes_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Assert
        (Edges_Of
           (Def ("Alpha", "b/b.ext:1") & Ref ("Alpha", "unclaimed/x.ext:1"),
            Map)
           .Is_Empty,
         "no crash and no edge");
   end A_Path_No_List_Claims_Contributes_Nothing;

   procedure A_Path_Claimed_By_Two_Nodes_Fans_Out_From_Both
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Map.Insert ("shared/s.ext", Nodes_Of ("A", "C"));
      Assert
        (Shown
           (Edges_Of
              (Def ("Alpha", "b/b.ext:1") & Ref ("Alpha", "shared/s.ext:1"),
               Map)) =
         "A>B: 1 Alpha;C>B: 1 Alpha;",
         "both claimants");
   end A_Path_Claimed_By_Two_Nodes_Fans_Out_From_Both;

   procedure Output_Is_Sorted_By_From_Then_Weight_Then_To
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Map.Insert ("c/c.ext", Nodes_Of ("C"));
      Map.Insert ("a/a.ext", Nodes_Of ("A"));
      Assert
        (Shown
           (Edges_Of
              (Def ("One", "b/b.ext:1") & Ref ("One", "a/a.ext:1") &
               Def ("Two", "c/c.ext:1") & Ref ("Two", "a/a.ext:2") &
               Ref ("Two", "a/a.ext:3") & Def ("Three", "c/c.ext:2") &
               Ref ("Three", "a/a.ext:4"),
               Map)) =
         "A>C: 2 Three Two;A>B: 1 One;",
         "two symbols outrank one, whatever the node names");
   end Output_Is_Sorted_By_From_Then_Weight_Then_To;

   procedure Top_Caps_Edges_Per_From_Node_Strongest_Kept
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map   : Path_Nodes.Map;
      Table : constant String :=
        Def ("X", "b/b.ext:1") & Ref ("X", "a/a.ext:1") &
        Def ("Y", "c/c.ext:1") & Ref ("Y", "a/a.ext:2") &
        Def ("Z", "d/d.ext:1") & Ref ("Z", "a/a.ext:3") &
        Def ("W", "d/d.ext:2") & Ref ("W", "a/a.ext:4");
   begin
      Map.Insert ("a/a.ext", Nodes_Of ("A"));
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Map.Insert ("c/c.ext", Nodes_Of ("C"));
      Map.Insert ("d/d.ext", Nodes_Of ("D"));
      Assert
        (Shown (Edges_Of (Table, Map, 10, (Top => 2, Symbols_Shown => 5))) =
         "A>D: 2 W Z;A>B: 1 X;",
         "the two strongest");
      Assert
        (Natural
           (Edges_Of (Table, Map, 10, (Top => 0, Symbols_Shown => 5)).Length) =
         3,
         "no cap");
   end Top_Caps_Edges_Per_From_Node_Strongest_Kept;

   procedure Symbols_Shown_Caps_The_List_Not_The_Weight
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map   : Path_Nodes.Map;
      Table : constant String :=
        Def ("A1", "b/b.ext:1") & Ref ("A1", "a/a.ext:1") &
        Def ("A2", "b/b.ext:2") & Ref ("A2", "a/a.ext:2") &
        Def ("A3", "b/b.ext:3") & Ref ("A3", "a/a.ext:3");
   begin
      Map.Insert ("a/a.ext", Nodes_Of ("A"));
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Assert
        (Shown (Edges_Of (Table, Map, 10, (Top => 8, Symbols_Shown => 2))) =
         "A>B: 3 A1 A2;",
         "two shown, weight three");
      Assert
        (Shown (Edges_Of (Table, Map, 10, (Top => 8, Symbols_Shown => 0))) =
         "A>B: 3 A1 A2 A3;",
         "zero means all");
   end Symbols_Shown_Caps_The_List_Not_The_Weight;

   procedure A_Symbol_With_No_Def_Contributes_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("a/a.ext", Nodes_Of ("A"));
      Assert (Edges_Of (Ref ("Ghost", "a/a.ext:1"), Map).Is_Empty, "none");
      Assert (Edges_Of ("", Map).Is_Empty, "an empty table");
      Assert
        (Edges_Of ("not a row" & LF & "x" & HT & "y" & LF, Map).Is_Empty,
         "lines that are not rows");
      Assert
        (Edges_Of (Row ("Q", "other", "a/a.ext:1"), Map).Is_Empty,
         "a role that is neither def nor ref");
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Assert
        (Edges_Of
           (Def ("Q", "b/b.ext:1") & Row ("Q", "other", "a/a.ext:1"), Map)
           .Is_Empty,
         "a row of another role is not a reference");
   end A_Symbol_With_No_Def_Contributes_Nothing;

   procedure A_Site_Keeps_A_Drive_Letter_In_Its_Path
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("C:/x/a.ext", Nodes_Of ("A"));
      Map.Insert ("C:/x/b.ext", Nodes_Of ("B"));
      Assert
        (Shown
           (Edges_Of
              (Def ("S", "C:/x/b.ext:7") & Ref ("S", "C:/x/a.ext:9"), Map)) =
         "A>B: 1 S;",
         "the path is cut at the last colon");
   end A_Site_Keeps_A_Drive_Letter_In_Its_Path;

   procedure An_Image_Is_Tab_Separated_With_A_Space_Joined_List
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Image
           ((From    => To_Unbounded_String ("A"),
             To      => To_Unbounded_String ("B"), Weight => 2,
             Symbols => Nodes_Of ("Alpha", "Beta"))) =
         "A" & HT & "B" & HT & "2" & HT & "Alpha Beta" & LF,
         "one line");
      Assert
        (Image
           ((From    => To_Unbounded_String ("A"),
             To      => To_Unbounded_String ("B"), Weight => 0,
             Symbols => Text_Lists.Vectors.Empty_Vector)) =
         "A" & HT & "B" & HT & "0" & HT & LF,
         "no symbols");
   end An_Image_Is_Tab_Separated_With_A_Space_Joined_List;

   package Draw is new Ada.Numerics.Discrete_Random (Natural);

   procedure No_Edge_Is_A_Self_Edge_And_Weight_Covers_The_Symbols_Shown
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Gen : Draw.Generator;
   begin
      Draw.Reset (Gen, 13);
      for Round in 1 .. 200 loop
         declare
            Nodes   : constant Positive := 2 + Draw.Random (Gen) mod 3;
            Symbols : constant Positive := 1 + Draw.Random (Gen) mod 3;
            Map     : Path_Nodes.Map;
            Table   : Unbounded_String;
         begin
            for I in 0 .. Nodes - 1 loop
               declare
                  Image : constant String := Integer'Image (I);
                  Digit : constant String :=
                    Image (Image'First + 1 .. Image'Last);
               begin
                  Map.Insert ("n" & Digit & ".ext", Nodes_Of ("N" & Digit));
               end;
            end loop;
            for S in 0 .. Symbols - 1 loop
               for I in 0 .. Nodes - 1 loop
                  declare
                     Image : constant String := Integer'Image (I);
                     Digit : constant String :=
                       Image (Image'First + 1 .. Image'Last);
                     Name  : constant String :=
                       "S" & Integer'Image (S) (2 .. Integer'Image (S)'Last);
                  begin
                     if Draw.Random (Gen) mod 2 = 0 then
                        Append (Table, Def (Name, "n" & Digit & ".ext:1"));
                     end if;
                     if Draw.Random (Gen) mod 2 = 0 then
                        Append (Table, Ref (Name, "n" & Digit & ".ext:1"));
                     end if;
                  end;
               end loop;
            end loop;
            for E of Edges_Of (To_String (Table), Map, Nodes) loop
               Assert (E.From /= E.To, "no self-edge");
               Assert
                 (E.Weight >= Natural (E.Symbols.Length),
                  "the weight covers the symbols shown");
            end loop;
         end;
      end loop;
   end No_Edge_Is_A_Self_Edge_And_Weight_Covers_The_Symbols_Shown;

   --  ------------------------------------------------------------------

   function Sets_Of (Pairs : String) return Path_Sets.Map is
      Result : Path_Sets.Map;
   begin
      --  "path=value,value;path=value".
      declare
         Start : Natural := Pairs'First;
      begin
         for I in Pairs'First .. Pairs'Last + 1 loop
            if I > Pairs'Last or else Pairs (I) = ';' then
               declare
                  Item : constant String := Pairs (Start .. I - 1);
                  Eq   : Natural         := 0;
               begin
                  for K in Item'Range loop
                     if Item (K) = '=' then
                        Eq := K;
                        exit;
                     end if;
                  end loop;
                  if Eq > 0 then
                     declare
                        Values : Text_Lists.Set;
                        First  : Natural := Eq + 1;
                     begin
                        for K in Eq + 1 .. Item'Last + 1 loop
                           if K > Item'Last or else Item (K) = ',' then
                              Values.Include (Item (First .. K - 1));
                              First := K + 1;
                           end if;
                        end loop;
                        Result.Include (Item (Item'First .. Eq - 1), Values);
                     end;
                  end if;
               end;
               Start := I + 1;
            end if;
         end loop;
      end;
      return Result;
   end Sets_Of;

   function Resolved
     (Table, Namespaces, Deps : String; Map : Path_Nodes.Map;
      Opts : Options := Default_Options) return Edge_Vectors.Vector
   is
      Source : Memory.Source := Memory.Create (Table);
   begin
      return
        Resolve_Ambiguous
          (Source, Map, Sets_Of (Namespaces), Sets_Of (Deps), Opts);
   end Resolved;

   function Three_Nodes return Path_Nodes.Map is
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("a/a.ext", Nodes_Of ("A"));
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Map.Insert ("c/c.ext", Nodes_Of ("C"));
      return Map;
   end Three_Nodes;

   Shared_Table : constant String :=
     Def ("Shared", "b/b.ext:1") & Def ("Shared", "c/c.ext:1") &
     Ref ("Shared", "a/a.ext:5");

   procedure A_Reference_Resolves_To_The_Candidate_Its_File_Depends_On
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown
           (Resolved
              (Shared_Table, "b/b.ext=lib_b;c/c.ext=lib_c", "a/a.ext=lib_b",
               Three_Nodes)) =
         "A>B: 1 Shared;",
         "A depends on B's library and not C's");
   end A_Reference_Resolves_To_The_Candidate_Its_File_Depends_On;

   procedure No_Matching_Dependency_Leaves_The_Reference_Ambiguous
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Resolved
           (Shared_Table, "b/b.ext=lib_b;c/c.ext=lib_c",
            "a/a.ext=lib_unrelated", Three_Nodes)
           .Is_Empty,
         "neither candidate's library");
      Assert
        (Resolved (Shared_Table, "", "", Three_Nodes).Is_Empty,
         "no dependency data at all");
      Assert
        (Resolved
           (Shared_Table, "b/b.ext=lib_b;c/c.ext=lib_c", "z/z.ext=lib_b",
            Three_Nodes)
           .Is_Empty,
         "dependency data for another file only");
      Assert
        (Resolved (Shared_Table, "", "a/a.ext=lib_b", Three_Nodes).Is_Empty,
         "dependencies but no declared identities");
   end No_Matching_Dependency_Leaves_The_Reference_Ambiguous;

   procedure A_Candidate_In_The_References_Own_Node_Is_Never_A_Target
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map;
   begin
      Map.Insert ("a/a.ext", Nodes_Of ("A"));
      Map.Insert ("b/b.ext", Nodes_Of ("B"));
      Assert
        (Resolved
           (Def ("Shared", "a/a.ext:1") & Def ("Shared", "b/b.ext:1") &
            Ref ("Shared", "a/a.ext:5"),
            "a/a.ext=lib_a;b/b.ext=lib_b", "a/a.ext=lib_a,lib_b", Map)
           .Is_Empty,
         "the definition in the same node is the answer");
   end A_Candidate_In_The_References_Own_Node_Is_Never_A_Target;

   procedure More_Than_One_Qualifying_Candidate_Stays_Ambiguous
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Resolved
           (Shared_Table, "b/b.ext=lib_b;c/c.ext=lib_c", "a/a.ext=lib_b,lib_c",
            Three_Nodes)
           .Is_Empty,
         "both libraries are depended on");
   end More_Than_One_Qualifying_Candidate_Stays_Ambiguous;

   procedure Two_Aliases_For_One_Candidate_Resolve_To_A_Single_Edge
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Shown
           (Resolved
              (Shared_Table, "b/b.ext=lib_b,lib_b_pub;c/c.ext=lib_c",
               "a/a.ext=lib_b_pub", Three_Nodes)) =
         "A>B: 1 Shared;",
         "once");
      Assert
        (Shown
           (Resolved
              (Shared_Table, "b/b.ext=lib_b,lib_b_pub;c/c.ext=lib_c",
               "a/a.ext=lib_b,lib_b_pub", Three_Nodes)) =
         "A>B: 1 Shared;",
         "a file that depends on both names");
   end Two_Aliases_For_One_Candidate_Resolve_To_A_Single_Edge;

   procedure Several_Files_In_One_Candidate_Node_Are_One_Candidate
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map : Path_Nodes.Map := Three_Nodes;
   begin
      Map.Insert ("b/b2.ext", Nodes_Of ("B"));
      Assert
        (Shown
           (Resolved
              (Def ("Shared", "b/b.ext:1") & Def ("Shared", "b/b2.ext:1") &
               Def ("Shared", "c/c.ext:1") & Ref ("Shared", "a/a.ext:5"),
               "b/b.ext=lib_b;b/b2.ext=lib_b;c/c.ext=lib_c", "a/a.ext=lib_b",
               Map)) =
         "A>B: 1 Shared;",
         "two files of one node are not two nodes");
   end Several_Files_In_One_Candidate_Node_Are_One_Candidate;

   procedure A_Name_With_One_Definer_Node_Is_Computes_Job
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Resolved
           (Def ("Only", "b/b.ext:1") & Def ("Only", "b/b.ext:2") &
            Ref ("Only", "a/a.ext:1"),
            "b/b.ext=lib_b", "a/a.ext=lib_b", Three_Nodes)
           .Is_Empty,
         "not ambiguous, so nothing to recover");
   end A_Name_With_One_Definer_Node_Is_Computes_Job;

   procedure Recovered_Edges_Count_Symbols_Once_And_Have_No_Rarity_Ceiling
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Map   : Path_Nodes.Map   := Three_Nodes;
      Table : Unbounded_String :=
        To_Unbounded_String (Shared_Table & Ref ("Shared", "a/a.ext:9"));
   begin
      for I in 1 .. 5 loop
         declare
            Image : constant String := Integer'Image (I);
            Path  : constant String :=
              "r" & Image (Image'First + 1 .. Image'Last) & "/r.ext";
         begin
            Map.Insert
              (Path, Nodes_Of ("R" & Image (Image'First + 1 .. Image'Last)));
            Append (Table, Ref ("Shared", Path & ":1"));
         end;
      end loop;
      Assert
        (Natural
           (Resolved
              (To_String (Table), "b/b.ext=lib_b;c/c.ext=lib_c",
               "a/a.ext=lib_b;r1/r.ext=lib_b;r2/r.ext=lib_b" &
               ";r3/r.ext=lib_c",
               Map)
              .Length) =
         4,
         "readers from six nodes would not be rare, and are resolved " &
         "by their dependencies all the same");
      Assert
        (Shown
           (Resolved
              (Shared_Table & Ref ("Shared", "a/a.ext:9"),
               "b/b.ext=lib_b;c/c.ext=lib_c", "a/a.ext=lib_b", Three_Nodes)) =
         "A>B: 1 Shared;",
         "two references, one symbol");
   end Recovered_Edges_Count_Symbols_Once_And_Have_No_Rarity_Ceiling;

   function One_Edge
     (From, To : String; Weight : Natural; Name : String)
      return Edge_Vectors.Vector
   is
      Result : Edge_Vectors.Vector;
   begin
      Result.Append
        (Edge'
           (From => To_Unbounded_String (From), To => To_Unbounded_String (To),
            Weight => Weight, Symbols => Nodes_Of (Name)));
      return Result;
   end One_Edge;

   procedure Merge_Concatenates_Resorts_And_Recaps
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Mine  : constant Edge_Vectors.Vector := One_Edge ("A", "B", 1, "One");
      Extra : constant Edge_Vectors.Vector := One_Edge ("A", "C", 5, "Two");
   begin
      Assert
        (Shown (Merge_Edges (Mine, Extra, 0)) = "A>C: 5 Two;A>B: 1 One;",
         "from ascending, weight descending, to ascending");
      Assert
        (Shown (Merge_Edges (Mine, Extra, 1)) = "A>C: 5 Two;",
         "a nonzero top re-applies the cap across the combined set");
      Assert
        (Natural (Mine.Length) = 1 and then Natural (Extra.Length) = 1,
         "neither input is changed");
      Assert
        (Merge_Edges (Edge_Vectors.Empty_Vector, Edge_Vectors.Empty_Vector, 3)
           .Is_Empty,
         "nothing merged is nothing");
   end Merge_Concatenates_Resorts_And_Recaps;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Links");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Ref_In_A_To_A_Def_In_B_Is_An_Edge'Access,
         "A ref in A to a def in B is an edge");
      Register_Routine
        (T, A_Ref_And_A_Def_In_The_Same_Node_Make_No_Self_Edge'Access,
         "A ref and a def in the same node make no self-edge");
      Register_Routine
        (T, A_Symbol_Referenced_From_Too_Many_Nodes_Is_Not_Rare'Access,
         "A symbol referenced from too many nodes is not rare");
      Register_Routine
        (T, A_Symbol_Defined_In_Two_Nodes_Makes_No_Edge_To_Either'Access,
         "A symbol defined in two nodes makes no edge to either");
      Register_Routine
        (T, Weight_Counts_Distinct_Symbols_Not_Occurrences'Access,
         "Weight counts distinct symbols, not occurrences");
      Register_Routine
        (T, An_Edge_Is_Supported_By_Every_Rare_Symbol_That_Crosses_It'Access,
         "An edge is supported by every rare symbol that crosses it");
      Register_Routine
        (T, A_Path_No_List_Claims_Contributes_Nothing'Access,
         "A path no list claims contributes nothing");
      Register_Routine
        (T, A_Path_Claimed_By_Two_Nodes_Fans_Out_From_Both'Access,
         "A path claimed by two nodes fans out from both");
      Register_Routine
        (T, Output_Is_Sorted_By_From_Then_Weight_Then_To'Access,
         "Output is sorted by from, then weight, then to");
      Register_Routine
        (T, Top_Caps_Edges_Per_From_Node_Strongest_Kept'Access,
         "Top caps edges per from-node, strongest kept");
      Register_Routine
        (T, Symbols_Shown_Caps_The_List_Not_The_Weight'Access,
         "Symbols_Shown caps the list and not the weight");
      Register_Routine
        (T, A_Symbol_With_No_Def_Contributes_Nothing'Access,
         "A symbol with no def contributes nothing");
      Register_Routine
        (T, A_Site_Keeps_A_Drive_Letter_In_Its_Path'Access,
         "A site keeps a drive letter in its path");
      Register_Routine
        (T, An_Image_Is_Tab_Separated_With_A_Space_Joined_List'Access,
         "An image is tab-separated with a space-joined list");
      Register_Routine
        (T, No_Edge_Is_A_Self_Edge_And_Weight_Covers_The_Symbols_Shown'Access,
         "No edge is a self-edge and the weight covers the symbols shown");
      Register_Routine
        (T, A_Reference_Resolves_To_The_Candidate_Its_File_Depends_On'Access,
         "A reference resolves to the candidate its file depends on");
      Register_Routine
        (T, No_Matching_Dependency_Leaves_The_Reference_Ambiguous'Access,
         "No matching dependency leaves the reference ambiguous");
      Register_Routine
        (T, A_Candidate_In_The_References_Own_Node_Is_Never_A_Target'Access,
         "A candidate in the reference's own node is never a target");
      Register_Routine
        (T, More_Than_One_Qualifying_Candidate_Stays_Ambiguous'Access,
         "More than one qualifying candidate stays ambiguous");
      Register_Routine
        (T, Two_Aliases_For_One_Candidate_Resolve_To_A_Single_Edge'Access,
         "Two aliases for one candidate resolve to a single edge");
      Register_Routine
        (T, Several_Files_In_One_Candidate_Node_Are_One_Candidate'Access,
         "Several files in one candidate node are one candidate");
      Register_Routine
        (T, A_Name_With_One_Definer_Node_Is_Computes_Job'Access,
         "A name with one definer node is Compute's job");
      Register_Routine
        (T,
         Recovered_Edges_Count_Symbols_Once_And_Have_No_Rarity_Ceiling'Access,
         "Recovered edges count symbols once and have no rarity ceiling");
      Register_Routine
        (T, Merge_Concatenates_Resorts_And_Recaps'Access,
         "Merge concatenates, resorts and recaps");
   end Register_Tests;

end Synapse.Core.Links.Tests;
