with AUnit.Assertions;

package body Synapse.Pipeline.Durations.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure A_Number_And_A_Unit_Is_A_Duration (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Seconds ("90s") = 90, "seconds");
      Assert (Seconds ("30m") = 1800, "minutes");
      Assert (Seconds ("2h") = 7200, "hours");
      Assert (Seconds ("007s") = 7, "leading zeros");
      Assert (Seconds ("10000000s") = 10_000_000, "the largest count");
   end A_Number_And_A_Unit_Is_A_Duration;

   procedure Anything_Else_Is_Nothing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Seconds ("") = 0, "empty");
      Assert (Seconds ("m") = 0, "a unit alone");
      Assert (Seconds ("30") = 0, "a number alone");
      Assert (Seconds ("0s") = 0, "nothing");
      Assert (Seconds ("3x") = 0, "an unknown unit");
      Assert (Seconds ("-5m") = 0, "negative");
      Assert (Seconds ("1.5h") = 0, "fractional");
      Assert (Seconds ("5 m") = 0, "a space");
      Assert (Seconds ("10000001s") = 0, "past the largest count");
      Assert (Seconds ("99999999999999999999h") = 0, "far too large");
   end Anything_Else_Is_Nothing;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Durations");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Number_And_A_Unit_Is_A_Duration'Access,
         "A number and a unit is a duration");
      Register_Routine
        (T, Anything_Else_Is_Nothing'Access, "Anything else is nothing");
   end Register_Tests;

end Synapse.Pipeline.Durations.Tests;
