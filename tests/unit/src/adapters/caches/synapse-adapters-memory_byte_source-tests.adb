with AUnit.Assertions;

package body Synapse.Adapters.Memory_Byte_Source.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Blocks_Are_Indexed_From_One_Whatever_Their_Position
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Src : Source := Create ("0123456789");
   begin
      Assert (Size (Src) = 10, "the size");
      declare
         Middle : constant String := Read (Src, 3, 4);
      begin
         Assert (Middle = "3456", "the bytes");
         Assert (Middle'First = 1, "indexed from one");
      end;
      Assert (Read (Src, 8, 5) = "89", "fewer at the end");
      Assert (Read (Src, 10, 5) = "", "none at the end");
      Assert (Read (Src, 0, 100) = "0123456789", "all of it");
      declare
         Empty : Source := Create ("");
      begin
         Assert (Read (Empty, 0, 5) = "", "an empty source");
      end;
   end Blocks_Are_Indexed_From_One_Whatever_Their_Position;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Memory_Byte_Source");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Blocks_Are_Indexed_From_One_Whatever_Their_Position'Access,
         "Blocks are indexed from one whatever their position");
   end Register_Tests;

end Synapse.Adapters.Memory_Byte_Source.Tests;
