with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with AUnit.Assertions;

package body Synapse.Core.Options_Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Core.Optional_Text;

   procedure None_Has_No_Value (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not None.Found, "not found");
      Assert (None = Option'(Found => False), "equal to another none");
   end None_Has_No_Value;

   procedure Of_Value_Holds_Its_Value (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      declare
         Got : constant Option := Of_Value (To_Unbounded_String ("text"));
      begin
         Assert (Got.Found, "found");
         Assert (To_String (Got.Value) = "text", "the value");
         Assert (Got = Option'(Found => True, Value => Got.Value), "equal");
         Assert (Got /= None, "not none");
      end;
   end Of_Value_Holds_Its_Value;

   procedure Reading_The_Value_Of_None_Fails (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      declare
         Nothing : Option  := None;
         Raised  : Boolean := False;
      begin
         begin
            Nothing := (Found => False);
            Assert (Length (Nothing.Value) = 0, "unreachable");
         exception
            when Constraint_Error =>
               Raised := True;
         end;
         Assert (Raised, "the discriminant refuses it");
      end;
   end Reading_The_Value_Of_None_Fails;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Options");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, None_Has_No_Value'Access, "None has no value");
      Register_Routine
        (T, Of_Value_Holds_Its_Value'Access, "Of_Value holds its value");
      Register_Routine
        (T, Reading_The_Value_Of_None_Fails'Access,
         "Reading the value of none fails");
   end Register_Tests;

end Synapse.Core.Options_Tests;
