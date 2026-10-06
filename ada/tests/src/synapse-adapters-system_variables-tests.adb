with Ada.Environment_Variables;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

package body Synapse.Adapters.System_Variables.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Text (V : System_Variables; Name : String) return String is
      Found : constant Port.Maybe_Value := V.Get (Name);
   begin
      return (if Found.Found then "<" & To_String (Found.Text) & ">"
              else "none");
   end Text;

   procedure It_Reads_The_Real_Environment (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      V : System_Variables;
   begin
      Ada.Environment_Variables.Set ("SYNAPSE_TEST_VARIABLE", "value");
      Assert (Text (V, "SYNAPSE_TEST_VARIABLE") = "<value>", "a set variable");
      Ada.Environment_Variables.Set ("SYNAPSE_TEST_VARIABLE", "");
      Assert (Text (V, "SYNAPSE_TEST_VARIABLE") = "<>", "empty is found");
      Ada.Environment_Variables.Clear ("SYNAPSE_TEST_VARIABLE");
      Assert (Text (V, "SYNAPSE_TEST_VARIABLE") = "none", "an unset one");
   end It_Reads_The_Real_Environment;

   procedure Home_Falls_Back_To_The_User_Profile (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V        : System_Variables;
      Had_Home : constant Boolean := Ada.Environment_Variables.Exists ("HOME");
      Old_Home : constant String :=
        (if Had_Home then Ada.Environment_Variables.Value ("HOME") else "");
      Had_Prof : constant Boolean :=
        Ada.Environment_Variables.Exists ("USERPROFILE");
      Old_Prof : constant String :=
        (if Had_Prof then Ada.Environment_Variables.Value ("USERPROFILE")
         else "");
   begin
      Ada.Environment_Variables.Clear ("HOME");
      Ada.Environment_Variables.Set ("USERPROFILE", "C:\Users\x");
      Assert (Text (V, "HOME") = "<C:\Users\x>", "the profile stands in");
      Assert (Text (V, "OTHER_THAN_HOME_FOR_SURE") = "none",
              "only for HOME");
      Ada.Environment_Variables.Set ("HOME", "/home/x");
      Assert (Text (V, "HOME") = "</home/x>", "HOME wins when set");

      if Had_Home then
         Ada.Environment_Variables.Set ("HOME", Old_Home);
      else
         Ada.Environment_Variables.Clear ("HOME");
      end if;
      if Had_Prof then
         Ada.Environment_Variables.Set ("USERPROFILE", Old_Prof);
      else
         Ada.Environment_Variables.Clear ("USERPROFILE");
      end if;
   end Home_Falls_Back_To_The_User_Profile;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.System_Variables");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, It_Reads_The_Real_Environment'Access,
         "It reads the real environment");
      Register_Routine
        (T, Home_Falls_Back_To_The_User_Profile'Access,
         "HOME falls back to the user profile");
   end Register_Tests;

end Synapse.Adapters.System_Variables.Tests;
