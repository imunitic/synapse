with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.Graph_Model;
with Synapse.Test_Scratch;

package body Synapse.Core.Hashing.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure A_Blob_Hash_Is_Gits_Object_Hash (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Blob_Hash_Hex ("") = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
         "git's empty blob");
      Assert
        (Blob_Hash_Hex ("hello" & Character'Val (10)) =
         "ce013625030ba8dba906f756967f9e9ca394464a",
         "a short file");
      Assert
        (Blob_Hash_Hex ("a" & Character'Val (10) & "b") =
         "0a207c060e61f3b88eaee0a8cd0696f46fb155eb",
         "no trailing line feed");
      Assert
        (Blob_Hash_Hex ([1 .. 3_000 => 'x']) =
         "dac398e7951de502b5249b9fd3b5a37f3635ef85",
         "a longer one, past one SHA-1 block");
      Assert
        (Graph_Model.Hash_To_Hex (Blob_Hash ("hello" & Character'Val (10))) =
         "ce013625030ba8dba906f756967f9e9ca394464a",
         "the raw form is the same hash");
   end A_Blob_Hash_Is_Gits_Object_Hash;

   procedure A_Blob_Hash_Matches_Git_On_A_Real_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      Content : constant String  :=
        "line one" & Character'Val (10) & "  line two" & Character'Val (9) &
        Character'Val (10) & Character'Val (0) & "after a NUL";
   begin
      Init_Repo (Path (Dir));
      Adapters.File_Bytes.Write (Path (Dir, "f.bin"), Content);
      declare
         From_Git : constant String :=
           Git (Path (Dir), "hash-object", "f.bin");
      begin
         Assert
           (From_Git (From_Git'First .. From_Git'First + 39) =
            Blob_Hash_Hex (Content),
            "git hash-object agrees: " & From_Git);
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Blob_Hash_Matches_Git_On_A_Real_File;

   procedure Sha256_Is_The_Standard_Digest (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Sha256_Hex ("") =
         "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
         "of nothing");
      Assert
        (Sha256_Hex ("abc") =
         "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
         "of abc");
   end Sha256_Is_The_Standard_Digest;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Hashing");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Blob_Hash_Is_Gits_Object_Hash'Access,
         "A blob hash is git's object hash");
      Register_Routine
        (T, A_Blob_Hash_Matches_Git_On_A_Real_File'Access,
         "A blob hash matches git on a real file");
      Register_Routine
        (T, Sha256_Is_The_Standard_Digest'Access,
         "SHA-256 is the standard digest");
   end Register_Tests;

end Synapse.Core.Hashing.Tests;
