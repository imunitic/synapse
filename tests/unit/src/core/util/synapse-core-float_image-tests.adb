with Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;

with AUnit.Assertions;

package body Synapse.Core.Float_Image.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;

   type Unsigned_32 is mod 2**32;

   function To_Float is new Ada.Unchecked_Conversion (Unsigned_32, Float);

   type Case_Row is record
      Bits     : Unsigned_32;
      Expected : Unbounded_String;
   end record;

   --  The shortest digits that read back as the same single, written without
   --  an exponent, from an independent implementation (NumPy).
   Table : constant array (Positive range <>) of Case_Row :=
     [(16#4006_6666#, To_Unbounded_String ("2.1")),
     (16#3F1E_79E8#, To_Unbounded_String ("0.61904764")),
     (16#3F4C_CCCD#, To_Unbounded_String ("0.8")),
     (16#40A0_0000#, To_Unbounded_String ("5")),
     (16#3F21_AF28#, To_Unbounded_String ("0.6315789")),
     (16#3DF8_3E10#, To_Unbounded_String ("0.121212125")),
     (16#4095_5555#, To_Unbounded_String ("4.6666665")),
     (16#3E5B_6DB7#, To_Unbounded_String ("0.21428572")),
     (16#40AC_CCCD#, To_Unbounded_String ("5.4")),
     (16#402A_AAAB#, To_Unbounded_String ("2.6666667")),
     (16#3FA4_9249#, To_Unbounded_String ("1.2857143")),
     (16#3DDD_67C9#, To_Unbounded_String ("0.10810811")),
     (16#3F08_8889#, To_Unbounded_String ("0.53333336")),
     (16#3F80_0000#, To_Unbounded_String ("1")),
     (16#4118_0000#, To_Unbounded_String ("9.5")),
     (16#3F79_435E#, To_Unbounded_String ("0.9736842")),
     (16#40D0_0000#, To_Unbounded_String ("6.5")),
     (16#40A0_0000#, To_Unbounded_String ("5")),
     (16#4080_0000#, To_Unbounded_String ("4")),
     (16#3F34_25ED#, To_Unbounded_String ("0.7037037")),
     (16#3E92_4925#, To_Unbounded_String ("0.2857143")),
     (16#3E5D_67C9#, To_Unbounded_String ("0.21621622")),
     (16#3F0E_38E4#, To_Unbounded_String ("0.5555556")),
     (16#406A_AAAB#, To_Unbounded_String ("3.6666667")),
     (16#3E3C_A1AF#, To_Unbounded_String ("0.18421052")),
     (16#3F67_063E#, To_Unbounded_String ("0.902439")),
     (16#3F0A_AAAB#, To_Unbounded_String ("0.5416667")),
     (16#3E47_1C72#, To_Unbounded_String ("0.19444445")),
     (16#4113_3333#, To_Unbounded_String ("9.2")),
     (16#4114_0000#, To_Unbounded_String ("9.25")),
     (16#4036_DB6E#, To_Unbounded_String ("2.857143")),
     (16#3F3A_2E8C#, To_Unbounded_String ("0.72727275")),
     (16#3FA0_0000#, To_Unbounded_String ("1.25")),
     (16#4018_6186#, To_Unbounded_String ("2.3809524")),
     (16#3F4A_1AF3#, To_Unbounded_String ("0.7894737")),
     (16#3FA0_0000#, To_Unbounded_String ("1.25")),
     (16#3FA0_0000#, To_Unbounded_String ("1.25")),
     (16#3E88_8889#, To_Unbounded_String ("0.26666668")),
     (16#4048_0000#, To_Unbounded_String ("3.125")),
     (16#3E26_0DD6#, To_Unbounded_String ("0.16216215")),
     (16#3F16_9697#, To_Unbounded_String ("0.5882353")),
     (16#3FBA_2E8C#, To_Unbounded_String ("1.4545455")),
     (16#3FCF_72C2#, To_Unbounded_String ("1.6206896")),
     (16#3EF9_6F97#, To_Unbounded_String ("0.4871795")),
     (16#3F20_0000#, To_Unbounded_String ("0.625")),
     (16#3F9C_71C7#, To_Unbounded_String ("1.2222222")),
     (16#3E65_E0A7#, To_Unbounded_String ("0.2244898")),
     (16#400C_CCCD#, To_Unbounded_String ("2.2")),
     (16#3F97_B426#, To_Unbounded_String ("1.1851852")),
     (16#3D8E_E23C#, To_Unbounded_String ("0.069767445")),
     (16#3DD0_FAC7#, To_Unbounded_String ("0.10204082")),
     (16#3F79_14C2#, To_Unbounded_String ("0.972973")),
     (16#3F74_5D17#, To_Unbounded_String ("0.95454544")),
     (16#3FFA_6F4E#, To_Unbounded_String ("1.9565217")),
     (16#3F9C_0000#, To_Unbounded_String ("1.21875")),
     (16#3FA2_2222#, To_Unbounded_String ("1.2666667")),
     (16#3F55_5555#, To_Unbounded_String ("0.8333333")),
     (16#3F14_A529#, To_Unbounded_String ("0.58064514")),
     (16#3F85_F418#, To_Unbounded_String ("1.0465117")),
     (16#3FA0_0000#, To_Unbounded_String ("1.25")),
     (16#3F85_B05B#, To_Unbounded_String ("1.0444444")),
     (16#3EF3_CF3D#, To_Unbounded_String ("0.47619048")),
     (16#3F57_45D1#, To_Unbounded_String ("0.84090906")),
     (16#3FC3_5E51#, To_Unbounded_String ("1.5263158")),
     (16#3FEB_851F#, To_Unbounded_String ("1.84")),
     (16#3FEF_4DEA#, To_Unbounded_String ("1.8695652")),
     (16#3D88_8889#, To_Unbounded_String ("0.06666667")),
     (16#4005_D174#, To_Unbounded_String ("2.090909")),
     (16#40A0_0000#, To_Unbounded_String ("5")),
     (16#4100_0000#, To_Unbounded_String ("8")),
     (16#3E8F_5C29#, To_Unbounded_String ("0.28")),
     (16#4007_1C72#, To_Unbounded_String ("2.1111112")),
     (16#4040_0000#, To_Unbounded_String ("3")),
     (16#3F80_0000#, To_Unbounded_String ("1")),
     (16#40AA_AAAB#, To_Unbounded_String ("5.3333335")),
     (16#3EC2_34F7#, To_Unbounded_String ("0.37931034")),
     (16#3F38_E38E#, To_Unbounded_String ("0.7222222")),
     (16#4000_0000#, To_Unbounded_String ("2")),
     (16#3F47_1C72#, To_Unbounded_String ("0.7777778")),
     (16#3EC8_590B#, To_Unbounded_String ("0.39130434")),
     (16#3F96_42C8#, To_Unbounded_String ("1.173913")),
     (16#3FE1_47AE#, To_Unbounded_String ("1.76")),
     (16#3FC0_0000#, To_Unbounded_String ("1.5")),
     (16#3F00_0000#, To_Unbounded_String ("0.5")),
     (16#3F2A_AAAB#, To_Unbounded_String ("0.6666667")),
     (16#4037_7777#, To_Unbounded_String ("2.8666666")),
     (16#3D00_0000#, To_Unbounded_String ("0.03125")),
     (16#404A_AAAB#, To_Unbounded_String ("3.1666667")),
     (16#3F65_0D79#, To_Unbounded_String ("0.8947368")),
     (16#3DCC_CCCD#, To_Unbounded_String ("0.1")),
     (16#3F45_7C58#, To_Unbounded_String ("0.7714286")),
     (16#3F19_999A#, To_Unbounded_String ("0.6")),
     (16#3FE1_8618#, To_Unbounded_String ("1.7619047")),
     (16#3E4C_CCCD#, To_Unbounded_String ("0.2")),
     (16#3F53_3333#, To_Unbounded_String ("0.825")),
     (16#3F74_5D17#, To_Unbounded_String ("0.95454544")),
     (16#4140_0000#, To_Unbounded_String ("12")),
     (16#3F19_999A#, To_Unbounded_String ("0.6")),
     (16#3F9C_71C7#, To_Unbounded_String ("1.2222222")),
     (16#3F80_0000#, To_Unbounded_String ("1")),
     (16#3F80_0000#, To_Unbounded_String ("1")),
     (16#3E67_39CE#, To_Unbounded_String ("0.22580644")),
     (16#3FC9_D89E#, To_Unbounded_String ("1.5769231")),
     (16#3E9D_89D9#, To_Unbounded_String ("0.30769232")),
     (16#3EB6_DB6E#, To_Unbounded_String ("0.35714287")),
     (16#4028_BA2F#, To_Unbounded_String ("2.6363637")),
     (16#3EBA_2E8C#, To_Unbounded_String ("0.36363637")),
     (16#411C_0000#, To_Unbounded_String ("9.75")),
     (16#40E0_0000#, To_Unbounded_String ("7")),
     (16#406C_CCCD#, To_Unbounded_String ("3.7")),
     (16#40A0_0000#, To_Unbounded_String ("5")),
     (16#3F19_999A#, To_Unbounded_String ("0.6")),
     (16#3ECC_CCCD#, To_Unbounded_String ("0.4")),
     (16#3EB3_3333#, To_Unbounded_String ("0.35")),
     (16#4020_0000#, To_Unbounded_String ("2.5")),
     (16#401A_5A5A#, To_Unbounded_String ("2.4117646")),
     (16#3F16_F970#, To_Unbounded_String ("0.5897436")),
     (16#3F46_318C#, To_Unbounded_String ("0.7741935")),
     (16#3F80_0000#, To_Unbounded_String ("1")),
     (16#3F88_8889#, To_Unbounded_String ("1.0666667")),
     (16#3B9D_6A76#, To_Unbounded_String ("0.004803951")),
     (16#3566_8B7D#, To_Unbounded_String ("0.0000008588466")),
     (16#4792_6BB2#, To_Unbounded_String ("74967.39")),
     (16#46CE_D761#, To_Unbounded_String ("26475.69")),
     (16#342D_57E8#, To_Unbounded_String ("0.0000001614386")),
     (16#41A4_2C09#, To_Unbounded_String ("20.521502")),
     (16#470D_4F3F#, To_Unbounded_String ("36175.246")),
     (16#3511_CE86#, To_Unbounded_String ("0.0000005431724")),
     (16#3BF8_6DA4#, To_Unbounded_String ("0.0075814296")),
     (16#3724_2A4F#, To_Unbounded_String ("0.0000097850125")),
     (16#3BE4_2138#, To_Unbounded_String ("0.006961968")),
     (16#3859_6E70#, To_Unbounded_String ("0.000051839685")),
     (16#39BA_7CBB#, To_Unbounded_String ("0.00035569616")),
     (16#4902_0706#, To_Unbounded_String ("532592.4")),
     (16#459D_17C3#, To_Unbounded_String ("5026.97")),
     (16#4859_D06B#, To_Unbounded_String ("223041.67")),
     (16#4940_7AF4#, To_Unbounded_String ("788399.25")),
     (16#4950_294D#, To_Unbounded_String ("852628.8")),
     (16#3E75_220B#, To_Unbounded_String ("0.23938768")),
     (16#3A41_F40A#, To_Unbounded_String ("0.00073987304")),
     (16#3FFF_E520#, To_Unbounded_String ("1.9991798")),
     (16#34BE_E425#, To_Unbounded_String ("0.00000035556255")),
     (16#4971_9A39#, To_Unbounded_String ("989603.56")),
     (16#3B37_1EA7#, To_Unbounded_String ("0.0027941854")),
     (16#4341_A51B#, To_Unbounded_String ("193.64494")),
     (16#4119_0ADC#, To_Unbounded_String ("9.565151")),
     (16#479D_EC4A#, To_Unbounded_String ("80856.58")),
     (16#3DCA_59A6#, To_Unbounded_String ("0.0988038")),
     (16#3558_3161#, To_Unbounded_String ("0.00000080538126")),
     (16#396D_DD77#, To_Unbounded_String ("0.00022684583")),
     (16#4058_26E9#, To_Unbounded_String ("3.377375")),
     (16#441C_0440#, To_Unbounded_String ("624.0664")),
     (16#4106_783D#, To_Unbounded_String ("8.404355")),
     (16#3DBA_3439#, To_Unbounded_String ("0.09091992")),
     (16#3706_2870#, To_Unbounded_String ("0.0000079964375")),
     (16#370C_07E5#, To_Unbounded_String ("0.000008346488")),
     (16#495E_1D12#, To_Unbounded_String ("909777.1")),
     (16#3A3A_837C#, To_Unbounded_String ("0.00071149296")),
     (16#3848_8060#, To_Unbounded_String ("0.000047803274")),
     (16#4587_9A02#, To_Unbounded_String ("4339.251")),
     (16#48A2_5CA6#, To_Unbounded_String ("332517.2")),
     (16#47B8_CC44#, To_Unbounded_String ("94616.53")),
     (16#3ECA_AB58#, To_Unbounded_String ("0.3958385")),
     (16#36F9_6D83#, To_Unbounded_String ("0.000007433527")),
     (16#3898_0055#, To_Unbounded_String ("0.00007247987")),
     (16#3585_4B15#, To_Unbounded_String ("0.0000009931124")),
     (16#3FC1_7910#, To_Unbounded_String ("1.511507")),
     (16#38A9_22BF#, To_Unbounded_String ("0.0000806502")),
     (16#4418_E4B2#, To_Unbounded_String ("611.57336")),
     (16#4619_2C3D#, To_Unbounded_String ("9803.06")),
     (16#38C4_99E7#, To_Unbounded_String ("0.00009374675")),
     (16#3866_1FEC#, To_Unbounded_String ("0.000054866003")),
     (16#46A7_2959#, To_Unbounded_String ("21396.674")),
     (16#4617_B39B#, To_Unbounded_String ("9708.901")),
     (16#4620_94D2#, To_Unbounded_String ("10277.205")),
     (16#3F6F_0209#, To_Unbounded_String ("0.9336248")),
     (16#3A81_4F1B#, To_Unbounded_String ("0.0009865494")),
     (16#3A58_9257#, To_Unbounded_String ("0.00082615524")),
     (16#37EA_D411#, To_Unbounded_String ("0.000027993725")),
     (16#3999_9952#, To_Unbounded_String ("0.00029296667")),
     (16#4380_84A0#, To_Unbounded_String ("257.03613")),
     (16#1620_BF0D#,
      To_Unbounded_String ("0.00000000000000000000000012984982")),
     (16#5374_0902#, To_Unbounded_String ("1048123150000")),
     (16#4265_BB31#, To_Unbounded_String ("57.432804")),
     (16#0B5A_B3EE#,
      To_Unbounded_String ("0.000000000000000000000000000000042120637")),
     (16#6B44_6806#, To_Unbounded_String ("237440700000000000000000000")),
     (16#558D_CDB4#, To_Unbounded_String ("19489328000000")),
     (16#218E_0B7B#, To_Unbounded_String ("0.0000000000000000009625333")),
     (16#0F97_7044#,
      To_Unbounded_String ("0.000000000000000000000000000014932993")),
     (16#68F6_E0BD#, To_Unbounded_String ("9326783000000000000000000")),
     (16#3D6B_881A#, To_Unbounded_String ("0.057502843")),
     (16#5A91_96F0#, To_Unbounded_String ("20489915000000000")),
     (16#65CF_EDFA#, To_Unbounded_String ("122739970000000000000000")),
     (16#754A_09CD#,
      To_Unbounded_String ("256113950000000000000000000000000")),
     (16#2997_F351#, To_Unbounded_String ("0.00000000000006747956")),
     (16#1556_585E#,
      To_Unbounded_String ("0.000000000000000000000000043286665")),
     (16#50A6_EC17#, To_Unbounded_String ("22403922000")),
     (16#677F_FE48#, To_Unbounded_String ("1208894100000000000000000")),
     (16#044A_7034#,
      To_Unbounded_String ("0.0000000000000000000000000000000000023796507")),
     (16#6BAE_4B5B#, To_Unbounded_String ("421417900000000000000000000")),
     (16#53BF_6D01#, To_Unbounded_String ("1644335100000")),
     (16#6AEF_C4D2#, To_Unbounded_String ("144931360000000000000000000")),
     (16#60CF_AB4C#, To_Unbounded_String ("119713100000000000000")),
     (16#2179_B37D#, To_Unbounded_String ("0.0000000000000000008460203")),
     (16#0825_AE56#,
      To_Unbounded_String ("0.0000000000000000000000000000000004985781")),
     (16#26DE_BFDB#, To_Unbounded_String ("0.0000000000000015456347")),
     (16#0604_8719#,
      To_Unbounded_String ("0.000000000000000000000000000000000024925695")),
     (16#02B3_3599#,
      To_Unbounded_String ("0.0000000000000000000000000000000000002633245")),
     (16#04C9_D78D#,
      To_Unbounded_String ("0.0000000000000000000000000000000000047452825")),
     (16#5F70_3017#, To_Unbounded_String ("17307359000000000000")),
     (16#70AC_06AC#, To_Unbounded_String ("425915900000000000000000000000")),
     (16#46C9_1B92#, To_Unbounded_String ("25741.785")),
     (16#2EE0_289D#, To_Unbounded_String ("0.00000000010193555")),
     (16#1BCA_3CB7#, To_Unbounded_String ("0.00000000000000000000033457333")),
     (16#0101_B811#,
      To_Unbounded_String ("0.00000000000000000000000000000000000002382562")),
     (16#46AA_7D55#, To_Unbounded_String ("21822.666")),
     (16#4C96_6F46#, To_Unbounded_String ("78871090")),
     (16#2659_74A7#, To_Unbounded_String ("0.0000000000000007544509")),
     (16#2C1E_EA1F#, To_Unbounded_String ("0.0000000000022583114")),
     (16#243D_3570#, To_Unbounded_String ("0.000000000000000041028105")),
     (16#7936_D536#,
      To_Unbounded_String ("59332654000000000000000000000000000")),
     (16#1E7D_6B37#, To_Unbounded_String ("0.00000000000000000001341588")),
     (16#39A6_442E#, To_Unbounded_String ("0.00031712785")),
     (16#1ECE_615D#, To_Unbounded_String ("0.000000000000000000021851367")),
     (16#0E75_2FDF#,
      To_Unbounded_String ("0.000000000000000000000000000003022163")),
     (16#0FCF_31CA#,
      To_Unbounded_String ("0.000000000000000000000000000020430954")),
     (16#5373_90E5#, To_Unbounded_String ("1046108000000")),
     (16#2EAD_44B0#, To_Unbounded_String ("0.000000000078793305")),
     (16#04B2_8054#,
      To_Unbounded_String ("0.000000000000000000000000000000000004196545")),
     (16#07DD_AEB7#,
      To_Unbounded_String ("0.00000000000000000000000000000000033355072")),
     (16#0E31_7041#,
      To_Unbounded_String ("0.0000000000000000000000000000021870983")),
     (16#7B84_44D1#,
      To_Unbounded_String ("1373557900000000000000000000000000000")),
     (16#48C6_14B2#, To_Unbounded_String ("405669.56")),
     (16#46C8_0E2B#, To_Unbounded_String ("25607.084")),
     (16#1B29_FC99#, To_Unbounded_String ("0.00000000000000000000014060971")),
     (16#621B_37CA#, To_Unbounded_String ("715816340000000000000")),
     (16#0F6F_915F#,
      To_Unbounded_String ("0.000000000000000000000000000011811607")),
     (16#0E8B_EC94#,
      To_Unbounded_String ("0.0000000000000000000000000000034493962")),
     (16#3F9D_52F9#, To_Unbounded_String ("1.2290946"))];

   procedure Whole_Numbers_Have_No_Fraction (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Shortest (3.0) = "3", "3");
      Assert (Shortest (16_777_216.0) = "16777216", "2**24");
      Assert (Shortest (1.0E10) = "10000000000", "ten digits, no exponent");
      Assert (Shortest (1.5E20) = "150000000000000000000", "large");
   end Whole_Numbers_Have_No_Fraction;

   procedure Fractions_Use_The_Fewest_Digits_That_Read_Back
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Shortest (2.5) = "2.5", "2.5");
      Assert (Shortest (0.1) = "0.1", "0.1");
      Assert (Shortest (1.0 / 3.0) = "0.33333334", "a third");
      Assert (Shortest (123_456.789) = "123456.79", "nine digits at most");
   end Fractions_Use_The_Fewest_Digits_That_Read_Back;

   procedure Small_Numbers_Are_Written_Without_An_Exponent
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Shortest (1.0E-5) = "0.00001", "1e-5");
      Assert
        (Shortest (1.175_494_4E-38) =
         "0.000000000000000000000000000000000000011754944",
         "the smallest normal single");
   end Small_Numbers_Are_Written_Without_An_Exponent;

   procedure Zero_And_Negatives (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Shortest (0.0) = "0", "zero");
      Assert (Shortest (-2.5) = "-2.5", "negative");
      Assert (Shortest (-0.000_01) = "-0.00001", "negative and small");
   end Zero_And_Negatives;

   procedure Every_Row_Of_The_Table_Matches_The_Independent_Implementation
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      for Row of Table loop
         Assert
           (Shortest (To_Float (Row.Bits)) = To_String (Row.Expected),
            "bits" & Unsigned_32'Image (Row.Bits) & " want " &
            To_String (Row.Expected) & " got " &
            Shortest (To_Float (Row.Bits)));
      end loop;
   end Every_Row_Of_The_Table_Matches_The_Independent_Implementation;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Float_Image");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Whole_Numbers_Have_No_Fraction'Access,
         "Whole numbers have no fraction");
      Register_Routine
        (T, Fractions_Use_The_Fewest_Digits_That_Read_Back'Access,
         "Fractions use the fewest digits that read back");
      Register_Routine
        (T, Small_Numbers_Are_Written_Without_An_Exponent'Access,
         "Small numbers are written without an exponent");
      Register_Routine (T, Zero_And_Negatives'Access, "Zero and negatives");
      Register_Routine
        (T,
         Every_Row_Of_The_Table_Matches_The_Independent_Implementation'Access,
         "Every row of the table matches the independent implementation");
   end Register_Tests;

end Synapse.Core.Float_Image.Tests;
