with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.Fake_Variables;

package body Synapse.Pipeline.Harnesses.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Every_Harness_Is_Found_By_Its_Name (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      for Kind in Harness_Kind loop
         Assert
           (Find (Name_Of (Kind)).Found
            and then Find (Name_Of (Kind)).Value = Kind,
            Name_Of (Kind) & " finds itself");
      end loop;
      Assert (Name_Of (Claude) = "Claude", "Claude");
      Assert (Name_Of (Codex) = "Codex", "Codex");
      Assert (Name_Of (Opencode) = "Opencode", "Opencode");
   end Every_Harness_Is_Found_By_Its_Name;

   procedure Names_Are_Exact (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Find ("").Found, "empty");
      Assert (not Find ("claude").Found, "lower case");
      Assert (not Find ("CLAUDE").Found, "upper case");
      Assert (not Find ("OpenCode").Found, "another capital");
      Assert (not Find ("Cluade").Found, "a typo");
      Assert (not Find ("Scripted").Found, "not a harness");
      Assert (not Find ("Claude ").Found, "a trailing space");
   end Names_Are_Exact;

   procedure Names_Lists_Them_All (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Names = "Claude, Codex, Opencode", "in order");
   end Names_Lists_Them_All;

   procedure The_Default_Harness_Comes_From_One_Variable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      V : Synapse.Adapters.Fake_Variables.Fake_Variables;
   begin
      Assert
        (Default_Results.Is_Success (Default (V))
         and then not Default_Results.Value (Default (V)).Found,
         "unset: none");
      V.Set (Default_Variable, "");
      Assert
        (Default_Results.Is_Success (Default (V))
         and then not Default_Results.Value (Default (V)).Found,
         "empty: none");
      V.Set (Default_Variable, "Codex");
      Assert
        (Default_Results.Is_Success (Default (V))
         and then Default_Results.Value (Default (V)).Found
         and then Default_Results.Value (Default (V)).Value = Codex,
         "Codex");
      V.Set (Default_Variable, "codex");
      Assert
        (not Default_Results.Is_Success (Default (V))
         and then Ada.Strings.Fixed.Index
                    (Ada.Strings.Unbounded.To_String
                       (Default_Results.Error (Default (V))),
                     "SYNAPSE_PIPELINE_HARNESS is 'codex', which is not a "
                     & "harness; the harnesses are Claude, Codex, Opencode")
                  > 0,
         "a name that is not exact is refused, and said so");
   end The_Default_Harness_Comes_From_One_Variable;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Harnesses");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Every_Harness_Is_Found_By_Its_Name'Access,
         "Every harness is found by its name");
      Register_Routine (T, Names_Are_Exact'Access, "Names are exact");
      Register_Routine
        (T, Names_Lists_Them_All'Access, "Names lists them all");
      Register_Routine
        (T, The_Default_Harness_Comes_From_One_Variable'Access,
         "The default harness comes from one variable");
   end Register_Tests;

end Synapse.Pipeline.Harnesses.Tests;
