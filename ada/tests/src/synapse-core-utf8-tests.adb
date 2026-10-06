with AUnit.Assertions;

package body Synapse.Core.UTF8.Tests is

   use AUnit.Assertions;

   type Byte_Array is array (Positive range <>) of Natural;

   function Bytes (V : Byte_Array) return String is
      Result : String (1 .. V'Length);
   begin
      for I in V'Range loop
         Result (I - V'First + 1) := Character'Val (V (I));
      end loop;
      return Result;
   end Bytes;

   procedure Every_Scalar_Value_Round_Trips
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      for CP in Code_Point loop
         if CP not in 16#D800# .. 16#DFFF# then
            declare
               Encoded : constant String := Encode (CP);
               Pos     : Positive := 1;
               Decoded : Scalar_Value;
            begin
               if not Is_Valid (Encoded) then
                  Assert (False, "Encode yields invalid UTF-8 for" & CP'Image);
               end if;
               Decode (Encoded, Pos, Decoded);
               if Decoded /= CP or else Pos /= Encoded'Last + 1 then
                  Assert (False, "round trip failed for" & CP'Image);
               end if;
            end;
         end if;
      end loop;
   end Every_Scalar_Value_Round_Trips;

   procedure Encoded_Lengths_Switch_At_The_Boundaries
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Encoded_Length (16#7F#) = 1, "U+007F is 1 byte");
      Assert (Encoded_Length (16#80#) = 2, "U+0080 is 2 bytes");
      Assert (Encoded_Length (16#7FF#) = 2, "U+07FF is 2 bytes");
      Assert (Encoded_Length (16#800#) = 3, "U+0800 is 3 bytes");
      Assert (Encoded_Length (16#D7FF#) = 3, "U+D7FF is 3 bytes");
      Assert (Encoded_Length (16#E000#) = 3, "U+E000 is 3 bytes");
      Assert (Encoded_Length (16#FFFF#) = 3, "U+FFFF is 3 bytes");
      Assert (Encoded_Length (16#1_0000#) = 4, "U+10000 is 4 bytes");
      Assert (Encoded_Length (16#10_FFFF#) = 4, "U+10FFFF is 4 bytes");
   end Encoded_Lengths_Switch_At_The_Boundaries;

   procedure Known_Encodings
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Encode (16#E9#) = Bytes ([16#C3#, 16#A9#]), "U+00E9");
      Assert (Encode (16#20AC#) = Bytes ([16#E2#, 16#82#, 16#AC#]), "U+20AC");
      Assert
        (Encode (16#1F600#) = Bytes ([16#F0#, 16#9F#, 16#98#, 16#80#]),
         "U+1F600");
   end Known_Encodings;

   procedure Malformed_Sequences_Are_Rejected
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      procedure Reject (Input : String; What : String) is
      begin
         Assert (not Is_Valid (Input), What & " must be rejected");
      end Reject;
   begin
      Reject (Bytes ([16#80#]), "lone continuation byte");
      Reject (Bytes ([16#BF#]), "lone continuation byte BF");
      Reject (Bytes ([16#C0#, 16#80#]), "overlong U+0000 (C0 80)");
      Reject (Bytes ([16#C1#, 16#BF#]), "overlong U+007F (C1 BF)");
      Reject (Bytes ([16#E0#, 16#80#, 16#80#]), "overlong 3-byte (E0 80 80)");
      Reject (Bytes ([16#E0#, 16#9F#, 16#BF#]), "overlong 3-byte (E0 9F BF)");
      Reject (Bytes ([16#ED#, 16#A0#, 16#80#]), "surrogate U+D800");
      Reject (Bytes ([16#ED#, 16#BF#, 16#BF#]), "surrogate U+DFFF");
      Reject
        (Bytes ([16#F0#, 16#80#, 16#80#, 16#80#]), "overlong 4-byte (F0 80)");
      Reject
        (Bytes ([16#F0#, 16#8F#, 16#BF#, 16#BF#]), "overlong 4-byte (F0 8F)");
      Reject (Bytes ([16#F4#, 16#90#, 16#80#, 16#80#]), "above U+10FFFF");
      Reject (Bytes ([16#F5#, 16#80#, 16#80#, 16#80#]), "lead byte F5");
      Reject (Bytes ([16#FF#]), "byte FF");
      Reject (Bytes ([16#FE#]), "byte FE");
      Reject ("a" & Bytes ([16#C3#]), "2-byte sequence cut short");
      Reject (Bytes ([16#E2#, 16#82#]), "3-byte sequence cut short");
      Reject (Bytes ([16#F0#, 16#9F#, 16#98#]), "4-byte sequence cut short");
      Reject (Bytes ([16#C3#, 16#28#]), "continuation byte replaced");
      Reject ("ok" & Bytes ([16#FF#]) & "ok", "bad byte after valid text");
   end Malformed_Sequences_Are_Rejected;

   procedure Empty_And_Ascii_Are_Valid
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Is_Valid (""), "empty string");
      Assert (Is_Valid ("plain ascii text"), "ascii");
   end Empty_And_Ascii_Are_Valid;

   procedure Slices_With_Any_First_Index_Work
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Text : constant String := "ab" & Bytes ([16#C3#, 16#A9#]) & "cd";
      Tail : constant String := Text (3 .. 4);
   begin
      Assert (Tail'First = 3, "slice keeps its own first index");
      Assert (Is_Valid (Tail), "slice holding one 2-byte sequence is valid");
      Assert (not Is_Valid (Text (3 .. 3)), "slice cut inside a sequence");
      Assert (Scalar_At (Tail, 3) = 16#E9#, "Scalar_At addresses by 'Range");
   end Slices_With_Any_First_Index_Work;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.UTF8");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Every_Scalar_Value_Round_Trips'Access,
         "Every scalar value round-trips");
      Register_Routine
        (T, Encoded_Lengths_Switch_At_The_Boundaries'Access,
         "Encoded lengths switch at the boundaries");
      Register_Routine (T, Known_Encodings'Access, "Known encodings");
      Register_Routine
        (T, Malformed_Sequences_Are_Rejected'Access,
         "Malformed sequences are rejected");
      Register_Routine
        (T, Empty_And_Ascii_Are_Valid'Access, "Empty and ASCII are valid");
      Register_Routine
        (T, Slices_With_Any_First_Index_Work'Access,
         "Slices with any first index work");
   end Register_Tests;

end Synapse.Core.UTF8.Tests;
