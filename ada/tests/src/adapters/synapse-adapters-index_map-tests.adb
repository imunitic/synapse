with Ada.Directories;
with GNAT.OS_Lib;

with AUnit.Assertions;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.Index_Map;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Index_Map.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Joined (V : Core.Text_Lists.Vector) return String is
      Result : Unbounded_String;
   begin
      for Item of V loop
         Append (Result, Item & ";");
      end loop;
      return To_String (Result);
   end Joined;

   function Claim (Path, Node : String) return Core.Index_Map.Pair is
     (Path => To_Unbounded_String (Path), Node => To_Unbounded_String (Node));

   function Sample_Bytes return String is
      Pairs  : Core.Index_Map.Pair_Vectors.Vector;
      Listed : Core.Text_Lists.Vector;
   begin
      Pairs.Append (Claim ("src/a.wdg", "Engine.md"));
      Pairs.Append (Claim ("src/a.wdg", "Zeta.md"));
      Pairs.Append (Claim ("src/b.wdg", "Engine.md"));
      Listed.Append (To_Unbounded_String ("docs/x.md"));
      return Core.Index_Map.Build (Pairs, Listed);
   end Sample_Bytes;

   function Nodes (M : in out Map; Path : String) return String is
      Got : constant Maybe_Nodes := Nodes_For (M, Path);
   begin
      return (if Got.Found then Joined (Got.Value) else "none");
   end Nodes;

   procedure An_Absent_File_Opens_As_An_Empty_Index
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      M   : Map;
   begin
      Open (M, Path (Dir, "_index.bin"));
      Assert
        (Count (M) = 0 and then Node_Count (M) = 0
         and then Unassigned_Count (M) = 0,
         "empty");
      Assert (Discarded (M) = None, "and not discarded: there was no file");
      Assert (Nodes (M, "src/a.wdg") = "none", "nothing resolves");
      Assert (Unassigned (M).Is_Empty, "no unassigned");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Absent_File_Opens_As_An_Empty_Index;

   procedure Written_And_Reopened_A_Path_Resolves_To_Its_Nodes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "work/_index.bin");
      M   : Map;
   begin
      Write_File (P, Sample_Bytes);
      Assert (not Ada.Directories.Exists (P & ".tmp"), "no temporary file");
      Open (M, P);
      Assert
        (Count (M) = 2 and then Node_Count (M) = 2
         and then Unassigned_Count (M) = 1,
         "counts");
      Assert (Nodes (M, "src/a.wdg") = "Engine.md;Zeta.md;", "two nodes");
      Assert (Nodes (M, "src/b.wdg") = "Engine.md;", "one node");
      Assert (Nodes (M, "src/missing.wdg") = "none", "a miss");
      Assert
        (Nodes (M, "docs/x.md") = "none"
         and then Joined (Unassigned (M)) = "docs/x.md;",
         "an unassigned path has no node and is in the list");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Written_And_Reopened_A_Path_Resolves_To_Its_Nodes;

   procedure Adding_An_Unassigned_Path_Preserves_Every_Claim
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "_index.bin");
      M   : Map;
   begin
      Write_File (P, Sample_Bytes);
      Open (M, P);
      Assert (Add_Unassigned (M, "new/file.wdg"), "written");
      Assert (Unassigned_Count (M) = 2, "two unassigned now");
      Assert
        (Nodes (M, "src/a.wdg") = "Engine.md;Zeta.md;", "every claim kept");
      Assert (Joined (Unassigned (M)) = "docs/x.md;new/file.wdg;", "appended");
      Assert
        (not Add_Unassigned (M, "new/file.wdg"),
         "adding it again writes nothing");
      Assert (Unassigned_Count (M) = 2, "so the count is the same");
      Assert (not Ada.Directories.Exists (P & ".tmp"), "no temporary file");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Adding_An_Unassigned_Path_Preserves_Every_Claim;

   procedure Adding_To_An_Absent_Index_Creates_It (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "deep/er/_index.bin");
      M   : Map;
   begin
      Open (M, P);
      Assert (Add_Unassigned (M, "only.wdg"), "written");
      Assert (Ada.Directories.Exists (P), "the file is there");
      Assert (Joined (Unassigned (M)) = "only.wdg;", "its one path");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Adding_To_An_Absent_Index_Creates_It;

   procedure A_Leftover_Json_Index_Is_Discarded_Not_Misread
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "_index.bin");
      M   : Map;
   begin
      File_Bytes.Write
        (P, "{""src/a.wdg"": [""Engine.md""]}" & [1 .. 80 => ' ']);
      Open (M, P);
      Assert
        (Count (M) = 0 and then Discarded (M) = Not_An_Index, "not an index");
      Assert (Add_Unassigned (M, "x.wdg"), "and the next write replaces it");
      Assert
        (Discarded (M) = None and then Unassigned_Count (M) = 1,
         "with a real index");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Leftover_Json_Index_Is_Discarded_Not_Misread;

   procedure A_Corrupt_Index_Is_Discarded (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      P     : constant String  := Path (Dir, "_index.bin");
      Bytes : String           := Sample_Bytes;
      M     : Map;
   begin
      Bytes (Bytes'Last - 3) := 'Z';
      File_Bytes.Write (P, Bytes);
      Open (M, P);
      Assert
        (Count (M) = 0 and then Discarded (M) = Checksum_Mismatch,
         "a flipped byte is caught");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Corrupt_Index_Is_Discarded;

   procedure An_Unreadable_File_Opens_Empty_And_Says_So
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "_index.bin");
      M   : Map;
   begin
      Write_File (P, Sample_Bytes);
      GNAT.OS_Lib.Set_Non_Readable (P);
      Open (M, P);
      if Discarded (M) = Unreadable then
         Assert (Count (M) = 0, "empty");
      end if;
      --  A process that can read any file, as a superuser can, reads it.
      GNAT.OS_Lib.Set_Readable (P);
      Remove (Dir);
   exception
      when others =>
         GNAT.OS_Lib.Set_Readable (P);
         Remove (Dir);
         raise;
   end An_Unreadable_File_Opens_Empty_And_Says_So;

   procedure Names_And_Paths_Are_Listed_In_Order (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      M   : Map;
   begin
      Open (M, Path (Dir, "_index.bin"));
      Assert (not Is_Open (M), "an absent file is not open");
      Assert (Node_Names (M).Is_Empty and then Paths (M).Is_Empty, "no lists");
      Write_File (Path (Dir, "_index.bin"), Sample_Bytes);
      Open (M, Path (Dir, "_index.bin"));
      Assert (Is_Open (M), "open");
      Assert (Joined (Node_Names (M)) = "Engine.md;Zeta.md;", "node names");
      Assert (Joined (Paths (M)) = "src/a.wdg;src/b.wdg;", "claimed paths");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Names_And_Paths_Are_Listed_In_Order;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Index_Map");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, An_Absent_File_Opens_As_An_Empty_Index'Access,
         "An absent file opens as an empty index");
      Register_Routine
        (T, Written_And_Reopened_A_Path_Resolves_To_Its_Nodes'Access,
         "Written and reopened, a path resolves to its nodes");
      Register_Routine
        (T, Adding_An_Unassigned_Path_Preserves_Every_Claim'Access,
         "Adding an unassigned path preserves every claim");
      Register_Routine
        (T, Adding_To_An_Absent_Index_Creates_It'Access,
         "Adding to an absent index creates it");
      Register_Routine
        (T, A_Leftover_Json_Index_Is_Discarded_Not_Misread'Access,
         "A leftover JSON index is discarded, not misread");
      Register_Routine
        (T, A_Corrupt_Index_Is_Discarded'Access,
         "A corrupt index is discarded");
      Register_Routine
        (T, An_Unreadable_File_Opens_Empty_And_Says_So'Access,
         "An unreadable file opens empty and says so");
      Register_Routine
        (T, Names_And_Paths_Are_Listed_In_Order'Access,
         "Names and paths are listed in order");
   end Register_Tests;

end Synapse.Adapters.Index_Map.Tests;
