with AUnit.Assertions;

package body Synapse.Core.Fault_Names.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Camel_Writes_A_Fault_As_Its_Contract_Names_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Camel ("EMPTY_DOCUMENT") = "EmptyDocument", "upper case");
      Assert (Camel ("Path_Too_Long") = "PathTooLong", "mixed case");
      Assert (Camel ("a") = "A", "one letter");
      Assert (Camel ("") = "", "empty");
      Assert (Camel ("X__Y") = "XY", "doubled separator");
   end Camel_Writes_A_Fault_As_Its_Contract_Names_It;

   procedure An_Exception_Is_Named_Without_Its_Package
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Caught : Boolean := False;
   begin
      begin
         raise Constraint_Error with "x";
      exception
         when E : Constraint_Error =>
            Assert (Of_Exception (E) = "ConstraintError", "predefined");
            Caught := True;
      end;
      Assert (Caught, "raised");
   end An_Exception_Is_Named_Without_Its_Package;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Fault_Names");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Camel_Writes_A_Fault_As_Its_Contract_Names_It'Access,
         "Camel writes a fault as its contract names it");
      Register_Routine
        (T, An_Exception_Is_Named_Without_Its_Package'Access,
         "An exception is named without its package");
   end Register_Tests;

end Synapse.Core.Fault_Names.Tests;
