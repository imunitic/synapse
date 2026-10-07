with Ada.Assertions;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Results;

package body Synapse.Core.Results_Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package Numbers is new Synapse.Core.Results
     (Value_Type => Integer, Error_Type => Unbounded_String);

   function Raises_Contract_Violation (Probe : access procedure) return Boolean
   is
   begin
      Probe.all;
      return False;
   exception
      when Ada.Assertions.Assertion_Error =>
         return True;
   end Raises_Contract_Violation;

   procedure A_Success_Holds_Its_Value (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R : constant Numbers.Result := Numbers.Success (42);
   begin
      Assert (Numbers.Is_Success (R), "a success");
      Assert (Numbers.Value (R) = 42, "its value");
      Assert (Numbers.Value_Or (R, 7) = 42, "the default is not used");
   end A_Success_Holds_Its_Value;

   procedure A_Failure_Holds_Its_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R : constant Numbers.Result :=
        Numbers.Failure (To_Unbounded_String ("no good"));
   begin
      Assert (not Numbers.Is_Success (R), "a failure");
      Assert (To_String (Numbers.Error (R)) = "no good", "its error");
      Assert (Numbers.Value_Or (R, 7) = 7, "the default stands in");
   end A_Failure_Holds_Its_Error;

   procedure A_Default_Result_Is_A_Failure_And_Can_Be_Assigned_Either_Way
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : Numbers.Result;
   begin
      Assert (not Numbers.Is_Success (R), "unset is not a success");
      R := Numbers.Success (1);
      Assert
        (Numbers.Is_Success (R) and then Numbers.Value (R) = 1,
         "assigned a success");
      R := Numbers.Failure (To_Unbounded_String ("x"));
      Assert (not Numbers.Is_Success (R), "and then a failure");
   end A_Default_Result_Is_A_Failure_And_Can_Be_Assigned_Either_Way;

   procedure Asking_The_Wrong_Side_Fails_The_Contract
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      Good : constant Numbers.Result := Numbers.Success (1);
      Bad  : constant Numbers.Result :=
        Numbers.Failure (To_Unbounded_String ("x"));

      procedure Value_Of_A_Failure is
         Ignore : constant Integer := Numbers.Value (Bad);
      begin
         null;
      end Value_Of_A_Failure;

      procedure Error_Of_A_Success is
         Ignore : constant Unbounded_String := Numbers.Error (Good);
      begin
         null;
      end Error_Of_A_Success;
   begin
      Assert
        (Raises_Contract_Violation (Value_Of_A_Failure'Access),
         "the value of a failure");
      Assert
        (Raises_Contract_Violation (Error_Of_A_Success'Access),
         "the error of a success");
   end Asking_The_Wrong_Side_Fails_The_Contract;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Results");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Success_Holds_Its_Value'Access, "A success holds its value");
      Register_Routine
        (T, A_Failure_Holds_Its_Error'Access, "A failure holds its error");
      Register_Routine
        (T,
         A_Default_Result_Is_A_Failure_And_Can_Be_Assigned_Either_Way'Access,
         "A default result is a failure and can be assigned either way");
      Register_Routine
        (T, Asking_The_Wrong_Side_Fails_The_Contract'Access,
         "Asking the wrong side fails the contract");
   end Register_Tests;

end Synapse.Core.Results_Tests;
