
with AUnit.Assertions;

with Synapse.Core.Hashing;

package body Synapse.Core.Node_Format.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  Chains as a synthetic ecosystem might configure them.
   function Chains return Text_Lists.Vector is
      Result : Text_Lists.Vector;
   begin
      Result.Append (To_Unbounded_String ("lib/main/code"));
      Result.Append (To_Unbounded_String ("lib/test/code"));
      Result.Append (To_Unbounded_String ("lib/main/res"));
      return Result;
   end Chains;

   function Module (Path : String) return String is (Module_Of (Path, Chains));

   function Source (Path, Hex : String) return Graph_Model.Source_Ref is
     (Path  => To_Unbounded_String (Path),
      Which => Graph_Model.Hash_From_Hex (Hex).Value);

   procedure A_Boilerplate_Chain_Cuts_At_The_Segment_Before_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Module ("engine/lib/main/code/com/x/State.ext") = "engine",
         "a chain");
      Assert
        (Module ("core/sub/lib/test/code/com/x/StateTest.ext") = "core/sub",
         "nested, and any listed chain");
   end A_Boilerplate_Chain_Cuts_At_The_Segment_Before_It;

   procedure A_Flat_Src_Layout_Keeps_One_Segment_After_Src
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Module ("pkg-basis/src/rights/Rights.ext") = "pkg-basis/src/rights",
         "the subsystem under src");
   end A_Flat_Src_Layout_Keeps_One_Segment_After_Src;

   procedure A_Src_Directory_With_Nothing_After_It_Falls_Back_To_The_Base
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Module ("pkg/src/") = "pkg", "nothing after src");
      Assert (Module ("pkg/src/Thing.ext") = "pkg", "a file directly in src");
   end A_Src_Directory_With_Nothing_After_It_Falls_Back_To_The_Base;

   procedure No_Chain_And_No_Src_Falls_To_The_First_Component
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Module ("docs/guide.md") = "docs", "first component");
      Assert (Module ("a/b/c/d.txt") = "a", "deeper");
      Assert (Module ("README.md") = Repo_Root_Module, "the repo root");
      Assert (Module ("") = Repo_Root_Module, "empty");
   end No_Chain_And_No_Src_Falls_To_The_First_Component;

   procedure A_Chain_Matches_Only_On_Whole_Segments
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Module ("mysrc/maintenance/x.ext") = "mysrc", "src inside a name");
      Assert
        (Module ("a/notlib/main/code/x.ext") = "a", "a longer first segment");
   end A_Chain_Matches_Only_On_Whole_Segments;

   procedure An_Empty_Chain_List_Still_Groups (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      None : Text_Lists.Vector;
   begin
      Assert
        (Module_Of ("engine/src/main/code/com/x/State.ext", None) =
         "engine/src/main",
         "grouped, not collapsed");
      Assert (Module_Of ("docs/guide.md", None) = "docs", "a plain path");
      None.Append (To_Unbounded_String (""));
      Assert
        (Module_Of ("docs/guide.md", None) = "docs",
         "an empty chain is ignored");
   end An_Empty_Chain_List_Still_Groups;

   procedure The_First_Listed_Chain_Wins (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Two : Text_Lists.Vector;
   begin
      Two.Append (To_Unbounded_String ("src"));
      Two.Append (To_Unbounded_String ("src/main/code"));
      Assert (Module_Of ("pkg/src/main/code/X.ext", Two) = "pkg", "in order");
   end The_First_Listed_Chain_Wins;

   procedure The_Digest_Is_Sha256_Over_Sorted_Lines
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Ones                            : constant String := [1 .. 40 => '1'];
      Twos                            : constant String := [1 .. 40 => '2'];
      Threes                          : constant String := [1 .. 40 => '3'];
      Out_Of_Order, In_Order, Changed : Graph_Model.Source_Vectors.Vector;
   begin
      Out_Of_Order.Append (Source ("b.ext", Twos));
      Out_Of_Order.Append (Source ("a.ext", Ones));
      In_Order.Append (Source ("a.ext", Ones));
      In_Order.Append (Source ("b.ext", Twos));
      Changed.Append (Source ("a.ext", Ones));
      Changed.Append (Source ("b.ext", Threes));

      Assert
        (Sources_Digest (Out_Of_Order) = Sources_Digest (In_Order),
         "the digest sorts, so order does not matter");
      Assert
        (Sources_Digest (In_Order) /= Sources_Digest (Changed),
         "a changed hash changes the digest");
      Assert
        (Sources_Digest (In_Order) =
         Hashing.Sha256_Hex ("a.ext:" & Ones & LF & "b.ext:" & Twos),
         "sha256 of the lines joined by line feeds, none at the end");
      Assert
        (Sources_Digest (In_Order) =
         "6595b82be5c06b082c993db3da125495df73dc4ae0ce432076875ab63e93a407",
         "the value shasum gives for the same bytes");
   end The_Digest_Is_Sha256_Over_Sorted_Lines;

   procedure An_Empty_Source_List_Digests_To_The_Sha256_Of_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      None : Graph_Model.Source_Vectors.Vector;
   begin
      Assert
        (Sources_Digest (None) =
         "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
         "a defined digest and not an empty field");
   end An_Empty_Source_List_Digests_To_The_Sha256_Of_Nothing;

   procedure Split_Isolates_The_Generated_Region (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text  : constant String       :=
        "# Title" & LF & Generated_Start & LF & LF & "## Summary" & LF &
        "prose" & LF & Generated_End & LF & LF & "## Notes" & LF &
        "hand written" & LF;
      Found : constant Split_Result := Split (Text);
   begin
      Assert (Found.Fenced, "fenced");
      Assert
        (To_String (Found.Head) = "# Title" & LF & Generated_Start,
         "the head runs through the start marker");
      Assert
        (To_String (Found.Tail) =
         Generated_End & LF & LF & "## Notes" & LF & "hand written" & LF,
         "the tail is kept byte for byte");
   end Split_Isolates_The_Generated_Region;

   procedure A_Node_With_No_Fence_Is_A_Whole_Body_Rewrite
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text  : constant String       :=
        "# Title" & LF & LF & "## Summary" & LF & "old" & LF;
      Found : constant Split_Result := Split (Text);
   begin
      Assert (not Found.Fenced, "unfenced");
      Assert (To_String (Found.Tail) = "", "no tail");
      Assert (To_String (Found.Head) = Text, "the head is all of it");
   end A_Node_With_No_Fence_Is_A_Whole_Body_Rewrite;

   procedure A_Start_Marker_With_No_End_Marker_Is_Unfenced
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Split
           ("# T" & LF & Generated_Start & LF & "## Summary" & LF & "x" & LF)
           .Fenced,
         "no end");
      Assert
        (not Split (Generated_Start).Fenced, "the marker is the whole text");
      Assert (not Split ("").Fenced, "empty");
      Assert
        (Split (Generated_Start & Generated_End).Fenced,
         "the markers touching");
   end A_Start_Marker_With_No_End_Marker_Is_Unfenced;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Node_Format");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Boilerplate_Chain_Cuts_At_The_Segment_Before_It'Access,
         "A boilerplate chain cuts at the segment before it");
      Register_Routine
        (T, A_Flat_Src_Layout_Keeps_One_Segment_After_Src'Access,
         "A flat src layout keeps one segment after src");
      Register_Routine
        (T,
         A_Src_Directory_With_Nothing_After_It_Falls_Back_To_The_Base'Access,
         "A src directory with nothing after it falls back to the base");
      Register_Routine
        (T, No_Chain_And_No_Src_Falls_To_The_First_Component'Access,
         "No chain and no src falls to the first component");
      Register_Routine
        (T, A_Chain_Matches_Only_On_Whole_Segments'Access,
         "A chain matches only on whole segments");
      Register_Routine
        (T, An_Empty_Chain_List_Still_Groups'Access,
         "An empty chain list still groups");
      Register_Routine
        (T, The_First_Listed_Chain_Wins'Access, "The first listed chain wins");
      Register_Routine
        (T, The_Digest_Is_Sha256_Over_Sorted_Lines'Access,
         "The digest is SHA-256 over sorted lines");
      Register_Routine
        (T, An_Empty_Source_List_Digests_To_The_Sha256_Of_Nothing'Access,
         "An empty source list digests to the SHA-256 of nothing");
      Register_Routine
        (T, Split_Isolates_The_Generated_Region'Access,
         "Split isolates the generated region");
      Register_Routine
        (T, A_Node_With_No_Fence_Is_A_Whole_Body_Rewrite'Access,
         "A node with no fence is a whole-body rewrite");
      Register_Routine
        (T, A_Start_Marker_With_No_End_Marker_Is_Unfenced'Access,
         "A start marker with no end marker is unfenced");
   end Register_Tests;

end Synapse.Core.Node_Format.Tests;
