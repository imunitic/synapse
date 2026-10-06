with Ada.Assertions;

with AUnit.Assertions;

package body Synapse.Core.Arith.Tests is

   procedure Saturates_At_The_Top
     (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Adds_Below_The_Top
     (T : in out AUnit.Test_Cases.Test_Case'Class);
   procedure Violated_Precondition_Raises
     (T : in out AUnit.Test_Cases.Test_Case'Class);

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Arith");
   end Name;

   procedure Saturates_At_The_Top
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      AUnit.Assertions.Assert
        (Saturating_Add (Natural'Last, 1) = Natural'Last,
         "A + B past the top clamps to Natural'Last");
   end Saturates_At_The_Top;

   procedure Adds_Below_The_Top
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      AUnit.Assertions.Assert
        (Saturating_Add (2, 3) = 5 and then Checked_Add (2, 3) = 5,
         "small sums are exact");
   end Adds_Below_The_Top;

   procedure Violated_Precondition_Raises
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
      Ignored : Natural;
   begin
      begin
         Ignored := Checked_Add (Natural'Last, 1);
      exception
         when Ada.Assertions.Assertion_Error =>
            Raised := True;
      end;
      AUnit.Assertions.Assert
        (Raised, "a violated Pre raises Assertion_Error under -gnata");
   end Violated_Precondition_Raises;

   overriding procedure Register_Tests (T : in out Test_Case) is
   begin
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Saturates_At_The_Top'Access, "Saturates at the top");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Adds_Below_The_Top'Access, "Adds below the top");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Violated_Precondition_Raises'Access,
         "Violated precondition raises");
   end Register_Tests;

end Synapse.Core.Arith.Tests;
