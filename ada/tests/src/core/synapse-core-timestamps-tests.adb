with AUnit.Assertions;

package body Synapse.Core.Timestamps.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Built_At_Keeps_The_Local_Digits_And_Drops_The_Rest
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Built_At ("2026-09-07T14:32:05+02:00") = "2026-09-07 14:32",
         "an offset");
      Assert (Built_At ("2026-09-07T14:32:05Z") = "2026-09-07 14:32", "UTC");
      Assert
        (Built_At ("2026-01-02T03:04:05-11:30") = "2026-01-02 03:04",
         "a negative offset, not converted");
      Assert
        (Built_At ("2026-09-07T14:32") = "2026-09-07 14:32",
         "no seconds at all");
   end Built_At_Keeps_The_Local_Digits_And_Drops_The_Rest;

   procedure A_String_With_Other_Bounds_Gives_The_Same_Result
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Stamp : constant String (10 .. 34) := "2026-09-07T14:32:05+02:00";
   begin
      Assert (Built_At (Stamp) = "2026-09-07 14:32", "bounds do not matter");
   end A_String_With_Other_Bounds_Gives_The_Same_Result;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Timestamps");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Built_At_Keeps_The_Local_Digits_And_Drops_The_Rest'Access,
         "Built_At keeps the local digits and drops the rest");
      Register_Routine
        (T, A_String_With_Other_Bounds_Gives_The_Same_Result'Access,
         "A string with other bounds gives the same result");
   end Register_Tests;

end Synapse.Core.Timestamps.Tests;
