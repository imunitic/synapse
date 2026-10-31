with AUnit.Assertions;

package body Synapse.Pipeline.Failures.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Every_Kind_Is_Found_By_Its_Name (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      for Kind in Failure_Kind loop
         Assert
           (Find (Name_Of (Kind)).Found
            and then Find (Name_Of (Kind)).Value = Kind,
            Name_Of (Kind) & " finds itself");
      end loop;
      Assert (Name_Of (Quota_Exhausted) = "quota_exhausted", "a name");
   end Every_Kind_Is_Found_By_Its_Name;

   procedure Names_Are_Exact (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Find ("").Found, "empty");
      Assert (not Find ("Quota_Exhausted").Found, "the Ada name");
      Assert (not Find ("quota").Found, "a prefix");
      Assert (not Find ("timeout").Found, "another word");
   end Names_Are_Exact;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Failures");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Every_Kind_Is_Found_By_Its_Name'Access,
         "Every kind is found by its name");
      Register_Routine (T, Names_Are_Exact'Access, "Names are exact");
   end Register_Tests;

end Synapse.Pipeline.Failures.Tests;
