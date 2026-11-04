with AUnit.Assertions;

with Synapse.Pipeline.Registry_Contract;

package body Synapse.Pipeline.Fake_Registry.Tests is

   use AUnit.Assertions;
   use type Registry_Store.Create_Result;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure It_Meets_The_Contract (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Registry;
   begin
      Registry_Contract.Check (F, "x");
   end It_Meets_The_Contract;

   procedure An_Operation_Can_Be_Made_To_Fail (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Registry;
   begin
      Assert (F.Create ("a") = Registry_Store.Created, "made");
      F.Fail (Replace_Op, Times => 2);
      Assert
        (not F.Replace_Summary ("a", "1")
         and then not F.Replace_Summary ("a", "1"),
         "it fails the number of times it was told to");
      Assert (F.Replace_Summary ("a", "1"), "and then works");
      Assert (F.Attempts (Replace_Op) = 3, "every attempt is counted");
      F.Fail (Create_Op);
      Assert (F.Create ("b") = Registry_Store.Failed, "a create can fail");
      Assert (not F.Held.Contains ("b"), "and makes nothing");
      F.Mend (Create_Op);
      Assert (F.Create ("b") = Registry_Store.Created, "until it is mended");
   end An_Operation_Can_Be_Made_To_Fail;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Fake_Registry");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, It_Meets_The_Contract'Access, "It meets the registry contract");
      Register_Routine
        (T, An_Operation_Can_Be_Made_To_Fail'Access,
         "An operation can be made to fail");
   end Register_Tests;

end Synapse.Pipeline.Fake_Registry.Tests;
