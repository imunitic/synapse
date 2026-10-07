with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Interfaces;

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

   procedure Decodes_Leniently
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Value : Natural;
      Width : Positive;
      Mixed : constant String :=
        Bytes ([16#C3#, 16#A9#, 16#FF#, 16#E2#, 16#82#, 16#61#]);
   begin
      Decode_Lenient (Mixed, 1, Value, Width);
      Assert (Value = 16#E9# and then Width = 2, "a well-formed sequence");
      Decode_Lenient (Mixed, 3, Value, Width);
      Assert (Value = Invalid_Byte_Base + 16#FF# and then Width = 1,
              "a stray byte is its own atom");
      Decode_Lenient (Mixed, 4, Value, Width);
      Assert (Value = Invalid_Byte_Base + 16#E2# and then Width = 1,
              "a cut sequence starts with its lead byte alone");
      Decode_Lenient (Mixed, 5, Value, Width);
      Assert (Value = Invalid_Byte_Base + 16#82# and then Width = 1,
              "and its continuation byte follows alone");
      Decode_Lenient (Mixed, 6, Value, Width);
      Assert (Value = 16#61# and then Width = 1, "ASCII");
   end Decodes_Leniently;

   procedure Steps_Back_One_Atom
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Text : constant String := Bytes ([16#61#, 16#C3#, 16#A9#, 16#FF#]);
   begin
      Assert (Previous_Start (Text, 1, 5) = 4, "the stray byte");
      Assert (Previous_Start (Text, 1, 4) = 2, "the 2-byte character");
      Assert (Previous_Start (Text, 1, 2) = 1, "the ASCII byte");
      Assert (Previous_Start (Text, 2, 4) = 2, "never before the floor");
      Assert (Previous_Start (Text, 3, 4) = 3, "even inside a character");
   end Steps_Back_One_Atom;

   Seed : Interfaces.Unsigned_64 := 20_261_009;

   function Next (Limit : Positive) return Natural is
      use type Interfaces.Unsigned_64;
   begin
      Seed := Seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Natural ((Seed / 2**20) mod Interfaces.Unsigned_64 (Limit));
   end Next;

   --  Text mixing ASCII, well-formed sequences, stray bytes and cut sequences.
   function Random_Bytes return String is
      use Ada.Strings.Unbounded;
      Result : Unbounded_String;
   begin
      for I in 1 .. Next (14) loop
         case Next (6) is
            when 0 =>
               Append (Result, Character'Val (Next (128)));

            when 1 =>
               Append (Result, Encode (16#80# + Next (16#7F80#)));

            when 2 =>
               Append (Result, Encode (16#1_0000# + Next (16#F_0000#)));

            when 3 =>
               Append (Result, Character'Val (16#80# + Next (128)));

            when 4 =>
               Append (Result, Character'Val (16#C0# + Next (64)));

            when others =>
               Append (Result, Encode (16#800# + Next (16#D000#)));
         end case;
      end loop;
      return To_String (Result);
   end Random_Bytes;

   procedure Backward_Steps_Retrace_The_Forward_Segmentation
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      for Case_No in 1 .. 20_000 loop
         declare
            Text      : constant String := Random_Bytes;
            Value     : Natural;
            Width     : Positive;
            Pos       : Positive := Text'First;
            Previous  : Natural := 0;
         begin
            while Pos <= Text'Last loop
               if Previous /= 0
                 and then Previous_Start (Text, Text'First, Pos) /= Previous
               then
                  Assert (False, "case" & Case_No'Image
                          & ": boundary" & Pos'Image & " steps back to"
                          & Previous_Start (Text, Text'First, Pos)'Image
                          & " not" & Previous'Image);
               end if;
               Previous := Pos;
               Decode_Lenient (Text, Pos, Value, Width);
               Pos := Pos + Width;
            end loop;
            if Previous /= 0
              and then Previous_Start (Text, Text'First, Pos) /= Previous
            then
               Assert (False, "case" & Case_No'Image & ": the end");
            end if;
         end;
      end loop;
   end Backward_Steps_Retrace_The_Forward_Segmentation;

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
      Register_Routine (T, Decodes_Leniently'Access, "Decodes leniently");
      Register_Routine
        (T, Steps_Back_One_Atom'Access, "Steps back one atom");
      Register_Routine
        (T, Backward_Steps_Retrace_The_Forward_Segmentation'Access,
         "Backward steps retrace the forward segmentation");
   end Register_Tests;

end Synapse.Core.UTF8.Tests;
