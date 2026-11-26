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

   procedure A_Run_Name_Is_One_Short_Line (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      E_Acute : constant String :=
        Character'Val (16#C3#) & Character'Val (16#A9#);
      Accented_120 : String (1 .. 240);
      Plain_121    : constant String (1 .. 121) := [others => 'a'];
   begin
      for I in 0 .. 119 loop
         Accented_120 (2 * I + 1 .. 2 * I + 2) := E_Acute;
      end loop;
      Assert (Registry_Store.Is_Run_Name ("Fix login"), "Fix login is a name");
      Assert
        (Registry_Store.Is_Run_Name (Accented_120),
         "120 accented letters are a name, counted as characters");
      Assert (not Registry_Store.Is_Run_Name (""), "empty is not");
      Assert (not Registry_Store.Is_Run_Name ("   "), "nor only spaces");
      Assert
        (not Registry_Store.Is_Run_Name (Plain_121), "nor 121 characters");
      Assert
        (not Registry_Store.Is_Run_Name ("a" & Character'Val (10) & "b"),
         "nor a line feed");
      Assert
        (not Registry_Store.Is_Run_Name ("a" & Character'Val (9) & "b"),
         "nor a tab");
      Assert
        (not Registry_Store.Is_Run_Name ("a" & Character'Val (16#7F#)),
         "nor a delete character");
   end A_Run_Name_Is_One_Short_Line;

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
      Register_Routine
        (T, A_Run_Name_Is_One_Short_Line'Access,
         "A run name is one short line");
   end Register_Tests;

end Synapse.Pipeline.Fake_Registry.Tests;
