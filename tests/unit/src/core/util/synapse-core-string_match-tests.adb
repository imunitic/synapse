with AUnit.Assertions;

package body Synapse.Core.String_Match.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Starts_With_Compares_The_Front_Only (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Starts_With ("## Notes", "## "), "a prefix");
      Assert (Starts_With ("abc", "abc"), "the whole string");
      Assert (not Starts_With ("abc", "bc"), "a suffix");
      Assert (not Starts_With ("ab", "abc"), "a prefix longer than the string");
      Assert (not Starts_With ("", "a"), "an empty string");
      Assert (Starts_With ("", ""), "two empty strings");
      Assert (Starts_With ("abc", ""), "an empty prefix");
   end Starts_With_Compares_The_Front_Only;

   procedure Starts_With_Ignores_Where_The_Bounds_Begin
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String := "xxflag";
   begin
      Assert (Starts_With (Text (3 .. 6), "fla"), "a slice");
      Assert (not Starts_With (Text (2 .. 6), "fla"), "a slice that starts early");
   end Starts_With_Ignores_Where_The_Bounds_Begin;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.String_Match");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Starts_With_Compares_The_Front_Only'Access,
         "Starts_With compares the front only");
      Register_Routine
        (T, Starts_With_Ignores_Where_The_Bounds_Begin'Access,
         "Starts_With ignores where the bounds begin");
   end Register_Tests;

end Synapse.Core.String_Match.Tests;
