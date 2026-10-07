with AUnit.Assertions;

with Synapse.Test_Bytes;

package body Synapse.Core.Little_Endian.Tests is

   use AUnit.Assertions;
   use Interfaces;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Hex (S : String) return String is (Test_Bytes.To_Hex (S));

   procedure The_Least_Significant_Byte_Comes_First
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Hex (Put_U16 (16#0102#)) = "0201", "16 bits");
      Assert (Hex (Put_U32 (16#0102_0304#)) = "04030201", "32 bits");
      Assert
        (Hex (Put_U64 (16#0102_0304_0506_0708#)) = "0807060504030201",
         "64 bits");
      Assert (Hex (Put_U32 (0)) = "00000000", "zero");
      Assert (Hex (Put_U64 (U64'Last)) = "ffffffffffffffff", "all ones");
   end The_Least_Significant_Byte_Comes_First;

   procedure Reading_Undoes_Writing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Padded : constant String :=
        "xx" & Put_U64 (16#8000_0000_0000_0001#) & "y";
   begin
      Assert
        (Get_U64 (Padded, 3) = 16#8000_0000_0000_0001#,
         "from the middle of a text, with the top bit set");
      Assert (Get_U32 (Put_U32 (U32'Last), 1) = U32'Last, "32 bits");
      Assert (Get_U16 (Put_U16 (16#BEEF#), 1) = 16#BEEF#, "16 bits");
      Assert
        (Get_U32 (Test_Bytes.From_Hex ("0100000002"), 1) = 1,
         "bytes past the field are not read");
   end Reading_Undoes_Writing;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Little_Endian");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Least_Significant_Byte_Comes_First'Access,
         "The least significant byte comes first");
      Register_Routine
        (T, Reading_Undoes_Writing'Access, "Reading undoes writing");
   end Register_Tests;

end Synapse.Core.Little_Endian.Tests;
