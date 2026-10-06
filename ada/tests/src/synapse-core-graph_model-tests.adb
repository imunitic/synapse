with AUnit.Assertions;

package body Synapse.Core.Graph_Model.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   Sample : constant String := "45bc6ae64517e43785674ddad8b92e89b4a8fb4a";

   procedure A_Hash_Round_Trips_Through_Hex (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Parsed : constant Hash_Result := Hash_From_Hex (Sample);
   begin
      Assert (Parsed.Valid, "valid");
      Assert (Hash_To_Hex (Parsed.Value) = Sample, "and back");
      Assert (Parsed.Value (1) = 16#45# and then Parsed.Value (20) = 16#4A#,
              "as bytes");
      Assert (Hash_From_Hex ("45BC6AE64517E43785674DDAD8B92E89B4A8FB4A").Valid,
              "uppercase digits are digits");
      Assert (Hash_To_Hex (Hash_From_Hex
                             ("45BC6AE64517E43785674DDAD8B92E89B4A8FB4A")
                               .Value) = Sample, "written in lowercase");
      Assert (Hash_To_Hex ([others => 0]) = [1 .. 40 => '0'], "all zero");
      Assert (Hash_To_Hex ([others => 255]) = [1 .. 40 => 'f'], "all ones");
   end A_Hash_Round_Trips_Through_Hex;

   procedure A_Short_Or_Malformed_Hash_Is_Refused (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (not Hash_From_Hex ("45bc6ae6").Valid, "short, not padded");
      Assert (not Hash_From_Hex ("").Valid, "empty");
      Assert (not Hash_From_Hex ([1 .. 40 => 'z']).Valid, "not hex");
      Assert (not Hash_From_Hex (Sample & "0").Valid, "long");
      Assert (not Hash_From_Hex (Sample (1 .. 39) & "g").Valid,
              "one bad digit at the end");
      Assert (not Hash_From_Hex (" " & Sample (2 .. 40)).Valid, "a blank");
   end A_Short_Or_Malformed_Hash_Is_Refused;

   procedure Roles_Have_Their_Wire_Spelling (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Image (Def) = "def" and then Image (Ref) = "ref", "spelled");
      Assert (Parse ("ref").Found and then Parse ("ref").Value = Ref, "ref");
      Assert (Parse ("def").Found and then Parse ("def").Value = Def, "def");
      Assert (not Parse ("defs").Found, "a near miss");
      Assert (not Parse ("").Found, "empty");
      Assert (not Parse ("Def").Found, "case matters");
   end Roles_Have_Their_Wire_Spelling;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Graph_Model");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Hash_Round_Trips_Through_Hex'Access,
         "A hash round-trips through hex");
      Register_Routine
        (T, A_Short_Or_Malformed_Hash_Is_Refused'Access,
         "A short or malformed hash is refused");
      Register_Routine
        (T, Roles_Have_Their_Wire_Spelling'Access,
         "Roles have their wire spelling");
   end Register_Tests;

end Synapse.Core.Graph_Model.Tests;
