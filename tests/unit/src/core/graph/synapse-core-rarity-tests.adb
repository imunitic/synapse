with AUnit.Assertions;

package body Synapse.Core.Rarity.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure The_Floor_Is_Two_And_Grows_With_The_Count
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Rare_Max (0) = 2 and then Rare_Max (10) = 2
         and then Rare_Max (39) = 2,
         "a floor of two");
      Assert (Rare_Max (40) = 2, "40 / 20 is two");
      Assert
        (Rare_Max (60) = 3 and then Rare_Max (200) = 10,
         "one in twenty above that");
      Assert (Rare_Max (400) = 20, "the divisor is twenty");
   end The_Floor_Is_Two_And_Grows_With_The_Count;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Rarity");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Floor_Is_Two_And_Grows_With_The_Count'Access,
         "The floor is two and grows with the count");
   end Register_Tests;

end Synapse.Core.Rarity.Tests;
