with AUnit.Assertions;

with Synapse.Core.Graph_Model;
with Synapse.Core.Hashing;
with Synapse.Core.Node_Format;

package body Synapse.Core.Verify.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Listed (A, B, C : String := "") return Text_Lists.Vector is
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
      return Result;
   end Listed;

   No_Paths : Text_Lists.Vector;

   function Why
     (Present                : Boolean; Has : Boolean; Stored : String;
      Paths, Missing, Hashes : Text_Lists.Vector) return String is
     (Reason (Check (Present, Has, Stored, Paths, Missing, Hashes)));

   procedure Staleness_Checks_Run_In_An_Order_That_Makes_Each_Answer_Meaningful
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Check (False, False, "", No_Paths, No_Paths, No_Paths).Kind =
         Node_File_Missing,
         "no node file");
      Assert
        (Check (True, False, "", Listed ("a"), No_Paths, No_Paths).Kind =
         No_Digest,
         "no stored digest");
      Assert
        (Check (True, True, "", Listed ("a"), No_Paths, No_Paths).Kind =
         No_Digest,
         "an empty one");
      Assert
        (Check (True, True, "d", No_Paths, No_Paths, No_Paths).Kind =
         No_Sources,
         "no sources");
      Assert
        (Check (False, True, "d", Listed ("a"), Listed ("a"), No_Paths).Kind =
         Node_File_Missing,
         "the node file comes first");
      Assert
        (Check (True, True, "d", Listed ("a"), Listed ("a"), No_Paths).Kind =
         Sources_Gone,
         "gone before hashes are compared");
      Assert
        (Check
           (True, True, "d", Listed ("a", "b"), No_Paths,
            Listed ("1" & [1 .. 39 => '1']))
           .Kind =
         Hashing_Failed,
         "fewer hashes than paths");
   end Staleness_Checks_Run_In_An_Order_That_Makes_Each_Answer_Meaningful;

   procedure A_Gone_Source_Is_Named_Rather_Than_Hashed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Why
           (True, True, "d", Listed ("a.ext", "b.ext"), Listed ("b.ext"),
            No_Paths) =
         "source files gone: b.ext",
         "one");
      Assert
        (Why
           (True, True, "d", Listed ("a.ext", "b.ext", "c.ext"),
            Listed ("a.ext", "b.ext", "c.ext"), No_Paths) =
         "source files gone: a.ext b.ext c.ext",
         "several, space separated, no trailing space");
   end A_Gone_Source_Is_Named_Rather_Than_Hashed;

   procedure Reasons_Are_Fixed_Texts_And_Clean_Is_Empty
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Reason ((Kind => Clean)) = "", "clean says nothing");
      Assert
        (Reason ((Kind => Node_File_Missing)) =
         "node file missing from the vault",
         "missing");
      Assert
        (Reason ((Kind => No_Digest)) =
         "no sources_digest (built before the digest existed)",
         "no digest");
      Assert
        (Reason ((Kind => No_Sources)) = "no sources listed", "no sources");
      Assert (Reason ((Kind => Hashing_Failed)) = "hashing failed", "failed");
      Assert
        (Reason ((Kind => Content_Changed)) = "content changed", "changed");
   end Reasons_Are_Fixed_Texts_And_Clean_Is_Empty;

   procedure Matching_Hashes_Are_Clean_And_One_Changed_Hash_Is_Content_Changed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      One     : constant String := [1 .. 40 => '1'];
      Two     : constant String := [1 .. 40 => '2'];
      Nine    : constant String := [1 .. 40 => '9'];
      Sources : Graph_Model.Source_Vectors.Vector;
   begin
      Sources.Append
        (Graph_Model.Source_Ref'
           (Path  => To_Unbounded_String ("a.ext"),
            Which => Graph_Model.Hash_From_Hex (One).Value));
      Sources.Append
        (Graph_Model.Source_Ref'
           (Path  => To_Unbounded_String ("b.ext"),
            Which => Graph_Model.Hash_From_Hex (Two).Value));
      declare
         Digest : constant String := Node_Format.Sources_Digest (Sources);
         Paths  : constant Text_Lists.Vector := Listed ("a.ext", "b.ext");
      begin
         Assert
           (Check (True, True, Digest, Paths, No_Paths, Listed (One, Two))
              .Kind =
            Clean,
            "the hashes the node recorded");
         Assert
           (Check (True, True, Digest, Paths, No_Paths, Listed (One, Nine))
              .Kind =
            Content_Changed,
            "one moved on");
         Assert
           (Check
              (True, True, Digest, Paths, No_Paths, Listed (One, "not a hash"))
              .Kind =
            Hashing_Failed,
            "a hash that is not one");
      end;
   end Matching_Hashes_Are_Clean_And_One_Changed_Hash_Is_Content_Changed;

   Grounded_Sample : constant String :=
     "---" & LF & "title: ""Premium""" & LF & "sources:" & LF &
     "  - path: lib/calc.ext" & LF &
     "    hash: 1111111111111111111111111111111111111111" & LF &
     "grounded_in:" & LF & "  - path: lib/calc.ext" & LF &
     "    lines: ""1-2""" & LF & "    digest: aaaa" & LF &
     "  - path: lib/other.ext" & LF & "    lines: ""10-12""" & LF &
     "    digest: bbbb" & LF & "stale: false" & LF & "---" & LF & LF &
     "# Premium" & LF;

   procedure Groundings_Are_Read_From_Their_Own_Block
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Grounding_Vectors.Vector := Groundings (Grounded_Sample);
   begin
      Assert
        (Natural (Got.Length) = 2, "two, and the sources are not among them");
      Assert
        (To_String (Got (1).Path) = "lib/calc.ext"
         and then To_String (Got (1).Lines) = "1-2"
         and then To_String (Got (1).Digest) = "aaaa",
         "the first");
      Assert
        (To_String (Got (2).Path) = "lib/other.ext"
         and then To_String (Got (2).Lines) = "10-12",
         "the second");
      declare
         Span : constant Maybe_Range := Range_Of (Got (2));
      begin
         Assert
           (Span.Found and then Span.Value.First = 10
            and then Span.Value.Last = 12,
            "its range");
      end;
   end Groundings_Are_Read_From_Their_Own_Block;

   procedure A_Node_With_No_Grounded_In_Block_Yields_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Groundings
           ("---" & LF & "title: t" & LF & "sources:" & LF & "  - path: a" &
            LF & "    hash: b" & LF & "---" & LF & LF & "# T" & LF)
           .Is_Empty,
         "none");
      Assert
        (Groundings ("# T" & LF & "grounded_in:" & LF & "  - path: a" & LF)
           .Is_Empty,
         "no frontmatter");
      Assert (Groundings ("").Is_Empty, "empty");
   end A_Node_With_No_Grounded_In_Block_Yields_None;

   procedure Grounding_Fields_Are_Trimmed_Unquoted_And_Optional
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Grounding_Vectors.Vector :=
        Groundings
          ("---" & LF & "grounded_in:" & LF & "  -   path:   ""a b.ext""" &
           LF & "    lines:  3-4" & LF & "  - lines: 5-6" & LF & "other: x" &
           LF & "---" & LF);
   begin
      Assert (Natural (Got.Length) = 2, "two items");
      Assert
        (To_String (Got (1).Path) = "a b.ext"
         and then To_String (Got (1).Lines) = "3-4"
         and then Length (Got (1).Digest) = 0,
         "blanks and quotes trimmed");
      Assert
        (Length (Got (2).Path) = 0 and then Length (Got (2).Lines) = 0,
         "only the path is read from the line that opens an item");
   end Grounding_Fields_Are_Trimmed_Unquoted_And_Optional;

   procedure A_Malformed_Range_Is_None (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Found (Lines : String) return Boolean is
        (Range_Of
           ((Path   => Null_Unbounded_String,
             Lines  => To_Unbounded_String (Lines),
             Digest => Null_Unbounded_String))
           .Found);
   begin
      Assert (Found ("1-2") and then Found ("5-5"), "good ones");
      Assert
        (not Found ("") and then not Found ("5") and then not Found ("-5")
         and then not Found ("5-"),
         "missing a bound");
      Assert (not Found ("0-3"), "a zero line");
      Assert (not Found ("5-3"), "an end before its start");
      Assert (not Found ("a-b") and then not Found ("1-2-3"), "not numbers");
   end A_Malformed_Range_Is_None;

   procedure Find_Moved_Locates_A_Range_That_Shifted
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Digest  : constant String      :=
        Hashing.Sha256_Hex ("alpha" & LF & "beta" & LF);
      Shifted : constant String      :=
        "new" & LF & "lines" & LF & "alpha" & LF & "beta" & LF & "tail" & LF;
      Edited  : constant String      :=
        "new" & LF & "lines" & LF & "alpha" & LF & "BETA" & LF & "tail" & LF;
      Moved   : constant Maybe_Range := Find_Moved (Shifted, 2, Digest);
   begin
      Assert
        (Moved.Found and then Moved.Value.First = 3
         and then Moved.Value.Last = 4,
         "two lines inserted above");
      Assert
        (not Find_Moved (Edited, 2, Digest).Found,
         "edited and not moved: no window matches");
   end Find_Moved_Locates_A_Range_That_Shifted;

   procedure Find_Moved_Finds_A_Range_In_Place_And_The_Last_Line
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Middle : constant Maybe_Range :=
        Find_Moved
          ("a" & LF & "b" & LF & "c" & LF, 1, Hashing.Sha256_Hex ("b" & LF));
      Last   : constant Maybe_Range :=
        Find_Moved ("a" & LF & "b" & LF & "c", 1, Hashing.Sha256_Hex ("c"));
   begin
      Assert (Middle.Found and then Middle.Value.First = 2, "in place");
      Assert
        (Last.Found and then Last.Value.First = 3 and then Last.Value.Last = 3,
         "a match on the last line, which has no trailing line feed");
   end Find_Moved_Finds_A_Range_In_Place_And_The_Last_Line;

   procedure Find_Moved_Refuses_What_Cannot_Fit (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Digest : constant String := Hashing.Sha256_Hex ("a" & LF);
   begin
      Assert (not Find_Moved ("a" & LF, 0, Digest).Found, "an empty span");
      Assert
        (not Find_Moved ("a" & LF, 2, Digest).Found, "longer than the text");
      Assert
        (not Find_Moved ("b" & LF & "c" & LF, 1, Digest).Found,
         "content that is not there");
      Assert
        (Find_Moved ("a" & LF & "a" & LF, 1, Digest).Value.First = 1,
         "the first of two matches");
      Assert
        (Find_Moved
           ("a" & LF & "b" & LF, 2, Hashing.Sha256_Hex ("a" & LF & "b" & LF))
           .Value
           .Last =
         2,
         "a span of the whole text");
   end Find_Moved_Refuses_What_Cannot_Fit;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Verify");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T,
         Staleness_Checks_Run_In_An_Order_That_Makes_Each_Answer_Meaningful'
           Access,
         "Staleness checks run in an order that makes each answer meaningful");
      Register_Routine
        (T, A_Gone_Source_Is_Named_Rather_Than_Hashed'Access,
         "A gone source is named rather than hashed");
      Register_Routine
        (T, Reasons_Are_Fixed_Texts_And_Clean_Is_Empty'Access,
         "Reasons are fixed texts and clean is empty");
      Register_Routine
        (T,
         Matching_Hashes_Are_Clean_And_One_Changed_Hash_Is_Content_Changed'
           Access,
         "Matching hashes are clean and one changed hash is content changed");
      Register_Routine
        (T, Groundings_Are_Read_From_Their_Own_Block'Access,
         "Groundings are read from their own block");
      Register_Routine
        (T, A_Node_With_No_Grounded_In_Block_Yields_None'Access,
         "A node with no grounded_in block yields none");
      Register_Routine
        (T, Grounding_Fields_Are_Trimmed_Unquoted_And_Optional'Access,
         "Grounding fields are trimmed, unquoted and optional");
      Register_Routine
        (T, A_Malformed_Range_Is_None'Access, "A malformed range is none");
      Register_Routine
        (T, Find_Moved_Locates_A_Range_That_Shifted'Access,
         "Find_Moved locates a range that shifted");
      Register_Routine
        (T, Find_Moved_Finds_A_Range_In_Place_And_The_Last_Line'Access,
         "Find_Moved finds a range in place and on the last line");
      Register_Routine
        (T, Find_Moved_Refuses_What_Cannot_Fit'Access,
         "Find_Moved refuses what cannot fit");
   end Register_Tests;

end Synapse.Core.Verify.Tests;
