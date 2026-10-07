with AUnit.Assertions;

package body Synapse.Core.Decimal_Image.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Positive_Numbers_Have_No_Leading_Blank
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Image (Integer'(0)) = "0", "zero");
      Assert (Image (Integer'(7)) = "7", "one digit");
      Assert (Image (Integer'(1_234_567)) = "1234567", "seven digits");
      Assert
        (Image (Integer'Last) = "2147483647"
         or else Image (Integer'Last) = "9223372036854775807",
         "the largest");
   end Positive_Numbers_Have_No_Leading_Blank;

   procedure Negative_Numbers_Keep_The_Minus_Sign (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Image (Integer'(-1)) = "-1", "minus one");
      Assert
        (Image (Integer'First) = Integer'Image (Integer'First),
         "the smallest");
   end Negative_Numbers_Keep_The_Minus_Sign;

   procedure Long_Numbers_Do_Not_Overflow (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Image (Long_Long_Integer'Last) = "9223372036854775807", "largest");
      Assert
        (Image (Long_Long_Integer'First) = "-9223372036854775808", "smallest");
   end Long_Numbers_Do_Not_Overflow;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Decimal_Image");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Positive_Numbers_Have_No_Leading_Blank'Access,
         "Positive numbers have no leading blank");
      Register_Routine
        (T, Negative_Numbers_Keep_The_Minus_Sign'Access,
         "Negative numbers keep the minus sign");
      Register_Routine
        (T, Long_Numbers_Do_Not_Overflow'Access,
         "Long numbers do not overflow");
   end Register_Tests;

end Synapse.Core.Decimal_Image.Tests;
