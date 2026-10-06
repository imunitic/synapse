with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.Refs;
with Synapse.Ports.Byte_Source;
with Synapse.Test_Scratch;

package body Synapse.Adapters.File_Byte_Source.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Blocks_Come_Back_From_Where_They_Are_Asked
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Src : Source;
   begin
      File_Bytes.Write (Path (Dir, "f"), "0123456789");
      Open (Src, Path (Dir, "f"));
      Assert (Size (Src) = 10, "the size");
      Assert (Read (Src, 0, 4) = "0123", "the start");
      Assert (Read (Src, 6, 4) = "6789", "the end");
      Assert (Read (Src, 8, 5) = "89", "fewer at the end");
      Assert (Read (Src, 10, 5) = "", "none at the end");
      Assert (Read (Src, 99, 5) = "", "none past it");
      Assert (Read (Src, 2, 3) = "234", "and back again");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Blocks_Come_Back_From_Where_They_Are_Asked;

   procedure An_Empty_File_Has_No_Bytes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Src : Source;
   begin
      File_Bytes.Write (Path (Dir, "f"), "");
      Open (Src, Path (Dir, "f"));
      Assert (Size (Src) = 0, "empty");
      Assert (Read (Src, 0, 10) = "", "nothing to read");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Empty_File_Has_No_Bytes;

   procedure A_Missing_File_Is_A_Source_Failure (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Src    : Source;
      Raised : Boolean := False;
   begin
      begin
         Open (Src, "/synapse/no/such/file");
      exception
         when Ports.Byte_Source.Source_Failure =>
            Raised := True;
      end;
      Assert (Raised, "Source_Failure");
   end A_Missing_File_Is_A_Source_Failure;

   procedure An_Index_On_Disk_Is_Searched_Without_Reading_It_All
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch   := Make;
      Src  : Source;
      LF   : constant Character := Character'Val (10);
      HT   : constant Character := Character'Val (9);
      Text : Ada.Strings.Unbounded.Unbounded_String;
   begin
      for I in 1 .. 2_000 loop
         declare
            Image : constant String := Integer'Image (100_000 + I);
            Name  : constant String :=
              "n" & Image (Image'First + 1 .. Image'Last);
         begin
            Ada.Strings.Unbounded.Append
              (Text,
               Name & HT & "ref" & HT & "call" & HT & "p/f.ext:" & Image & HT &
               "call();" & LF);
         end;
      end loop;
      File_Bytes.Write
        (Path (Dir, "_refs.tsv"), Ada.Strings.Unbounded.To_String (Text));
      Open (Src, Path (Dir, "_refs.tsv"));
      declare
         Found : constant Core.Refs.Row_Vectors.Vector :=
           Core.Refs.Find (Src, "n101000", 256);
         Last  : constant Core.Refs.Row_Vectors.Vector :=
           Core.Refs.Find (Src, "n102000", 100);
         None  : constant Core.Refs.Row_Vectors.Vector :=
           Core.Refs.Find (Src, "n101000x", 256);
      begin
         Assert (Natural (Found.Length) = 1, "one row in the middle");
         Assert
           (Ada.Strings.Unbounded.To_String (Found (1).Site) =
            "p/f.ext: 101000",
            "and it is the right one");
         Assert (Natural (Last.Length) = 1, "the last row");
         Assert (None.Is_Empty, "a name that is not there");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Index_On_Disk_Is_Searched_Without_Reading_It_All;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.File_Byte_Source");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Blocks_Come_Back_From_Where_They_Are_Asked'Access,
         "Blocks come back from where they are asked");
      Register_Routine
        (T, An_Empty_File_Has_No_Bytes'Access, "An empty file has no bytes");
      Register_Routine
        (T, A_Missing_File_Is_A_Source_Failure'Access,
         "A missing file is a source failure");
      Register_Routine
        (T, An_Index_On_Disk_Is_Searched_Without_Reading_It_All'Access,
         "An index on disk is searched");
   end Register_Tests;

end Synapse.Adapters.File_Byte_Source.Tests;
