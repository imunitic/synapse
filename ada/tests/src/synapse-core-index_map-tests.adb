with Interfaces;

with AUnit.Assertions;

with Synapse.Adapters.Memory_Byte_Source;

package body Synapse.Core.Index_Map.Tests is

   use AUnit.Assertions;
   use type Interfaces.Unsigned_32;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package Memory renames Adapters.Memory_Byte_Source;

   function Claim (Path, Node : String) return Pair is
     (Path => To_Unbounded_String (Path), Node => To_Unbounded_String (Node));

   No_Paths : Text_Lists.Vector;

   function Listed (A, B : String := "") return Text_Lists.Vector is
      Result : Text_Lists.Vector;
   begin
      if A /= "" then
         Result.Append (To_Unbounded_String (A));
      end if;
      if B /= "" then
         Result.Append (To_Unbounded_String (B));
      end if;
      return Result;
   end Listed;

   function Joined (V : Text_Lists.Vector) return String is
      Result : Unbounded_String;
   begin
      for Item of V loop
         Append (Result, Item & ";");
      end loop;
      return To_String (Result);
   end Joined;

   procedure Pairs_In_Any_Order_Group_Into_A_Valid_Index
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Pairs : Pair_Vectors.Vector;
   begin
      Pairs.Append (Claim ("z.wdg", "Zeta.md"));
      Pairs.Append (Claim ("a.wdg", "Zeta.md"));
      Pairs.Append (Claim ("m.wdg", "Alpha.md"));
      Pairs.Append (Claim ("a.wdg", "Alpha.md"));
      declare
         Src  : Memory.Source := Memory.Create (Build (Pairs, No_Paths));
         Got  : constant Index_Map_Format.Parse_Result :=
           Index_Map_Format.Parse (Src);
         Back : constant Index_Map_Format.Decoded      :=
           Index_Map_Format.Decode (Src, Got.Head);
      begin
         Assert (Got.Ok, "valid");
         Assert
           (Got.Head.Entry_Count = 3 and then Got.Head.Node_Count = 2,
            "three paths, two nodes");
         Assert
           (To_String (Back.Entries (1).Path) = "a.wdg", "the first path");
         Assert
           (Joined (Back.Entries (1).Nodes) = "Alpha.md;Zeta.md;",
            "it came in under Zeta then Alpha and comes out ascending");
         Assert
           (To_String (Back.Entries (2).Path) = "m.wdg"
            and then To_String (Back.Entries (3).Path) = "z.wdg",
            "paths ascending");
      end;
   end Pairs_In_Any_Order_Group_Into_A_Valid_Index;

   procedure A_Repeated_Pair_Is_One_Claim (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Pairs : Pair_Vectors.Vector;
   begin
      Pairs.Append (Claim ("a.wdg", "N.md"));
      Pairs.Append (Claim ("a.wdg", "N.md"));
      declare
         Src  : Memory.Source := Memory.Create (Build (Pairs, No_Paths));
         Head : constant Index_Map_Format.Header :=
           Index_Map_Format.Parse (Src).Head;
      begin
         Assert
           (Joined
              (Index_Map_Format.Nodes_Of
                 (Src, Head, Index_Map_Format.Record_At (Src, Head, 0))) =
            "N.md;",
            "one claim");
      end;
   end A_Repeated_Pair_Is_One_Claim;

   procedure An_Index_With_No_Pairs_Is_Buildable (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      None : Pair_Vectors.Vector;
      Src  : Memory.Source                          :=
        Memory.Create (Build (None, Listed ("a.wdg", "b.wdg")));
      Got  : constant Index_Map_Format.Parse_Result :=
        Index_Map_Format.Parse (Src);
   begin
      Assert
        (Got.Ok and then Got.Head.Entry_Count = 0
         and then Got.Head.Unassigned_Count = 2,
         "two unassigned");
   end An_Index_With_No_Pairs_Is_Buildable;

   function Decoded_Of (Bytes : String) return Index_Map_Format.Decoded is
      Src : Memory.Source := Memory.Create (Bytes);
   begin
      return Index_Map_Format.Decode (Src, Index_Map_Format.Parse (Src).Head);
   end Decoded_Of;

   procedure Adding_An_Unassigned_Path_Keeps_Every_Claim_And_Is_Idempotent
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Pairs : Pair_Vectors.Vector;
   begin
      Pairs.Append (Claim ("a.wdg", "N.md"));
      Pairs.Append (Claim ("b.wdg", "N.md"));
      Pairs.Append (Claim ("b.wdg", "O.md"));
      declare
         First : constant Index_Map_Format.Decoded :=
           Decoded_Of (Build (Pairs, Listed ("old.wdg")));
         Next  : constant Maybe_Bytes := With_Unassigned (First, "new.wdg");
      begin
         Assert (Next.Found, "it was new");
         declare
            After : constant Index_Map_Format.Decoded :=
              Decoded_Of (To_String (Next.Bytes));
         begin
            Assert
              (Joined (After.Unassigned) = "old.wdg;new.wdg;",
               "appended after what was there");
            Assert (Natural (After.Entries.Length) = 2, "both paths");
            Assert
              (Joined (After.Entries (2).Nodes) = "N.md;O.md;",
               "every claim kept");
            Assert
              (not With_Unassigned (After, "new.wdg").Found,
               "adding it again changes nothing");
            Assert
              (not With_Unassigned (After, "old.wdg").Found,
               "nor an older one");
         end;
      end;
   end Adding_An_Unassigned_Path_Keeps_Every_Claim_And_Is_Idempotent;

   procedure Adding_To_An_Empty_Index_Works (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Empty : Index_Map_Format.Decoded;
      Next  : constant Maybe_Bytes := With_Unassigned (Empty, "only.wdg");
   begin
      Assert (Next.Found, "written");
      Assert
        (Joined (Decoded_Of (To_String (Next.Bytes)).Unassigned) = "only.wdg;",
         "the one path");
   end Adding_To_An_Empty_Index_Works;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Index_Map");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Pairs_In_Any_Order_Group_Into_A_Valid_Index'Access,
         "Pairs in any order group into a valid index");
      Register_Routine
        (T, A_Repeated_Pair_Is_One_Claim'Access,
         "A repeated pair is one claim");
      Register_Routine
        (T, An_Index_With_No_Pairs_Is_Buildable'Access,
         "An index with no pairs is buildable");
      Register_Routine
        (T,
         Adding_An_Unassigned_Path_Keeps_Every_Claim_And_Is_Idempotent'Access,
         "Adding an unassigned path keeps every claim and is idempotent");
      Register_Routine
        (T, Adding_To_An_Empty_Index_Works'Access,
         "Adding to an empty index works");
   end Register_Tests;

end Synapse.Core.Index_Map.Tests;
