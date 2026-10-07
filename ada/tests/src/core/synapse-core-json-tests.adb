with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;

with Interfaces;

with AUnit.Assertions;

with Synapse.Core.JSON_Lexical;

package body Synapse.Core.JSON.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   package Lexical renames Synapse.Core.JSON_Lexical;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   Suite_Dir : constant String := "../testdata/json";

   function Parses (Text : String) return Boolean is (Parse (Text).Ok);

   function Parsed (Text : String) return Value is
      Result : constant Parse_Result := Parse (Text);
   begin
      Assert (Result.Ok, "should parse: " & Text);
      return Result.Item;
   end Parsed;

   function Failure_Of (Text : String) return Parse_Result is
      Result : constant Parse_Result := Parse (Text);
   begin
      Assert (not Result.Ok, "should not parse: " & Text);
      return Result;
   end Failure_Of;

   function Byte (N : Natural) return String is [Character'Val (N)];

   --  A backslash-u escape, spelled without writing one in source.
   function Esc (Hex : String) return String is
     (Character'Val (92) & "u" & Hex);

   ---------------------------------------------------------------------------
   --  JSONTestSuite
   ---------------------------------------------------------------------------

   function Read_File (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      declare
         Size   : constant Natural :=
           Natural (Ada.Streams.Stream_IO.Size (File));
         Result : String (1 .. Size);
      begin
         String'Read (Ada.Streams.Stream_IO.Stream (File), Result);
         Ada.Streams.Stream_IO.Close (File);
         return Result;
      end;
   end Read_File;

   procedure Conforms_To_JSONTestSuite (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Search   : Ada.Directories.Search_Type;
      Item     : Ada.Directories.Directory_Entry_Type;
      Accepted : Natural := 0;
      Rejected : Natural := 0;
      Optional : Natural := 0;
      Wrong    : Unbounded_String;
      Wrong_N  : Natural := 0;

      procedure Record_Wrong (Name, Why : String) is
      begin
         Wrong_N := Wrong_N + 1;
         if Wrong_N <= 8 then
            Append (Wrong, Name & " (" & Why & ") ");
         end if;
      end Record_Wrong;
   begin
      if not Ada.Directories.Exists (Suite_Dir) then
         Assert (False, Suite_Dir & " is missing; run `just ada-json-suite`");
         return;
      end if;

      Ada.Directories.Start_Search (Search, Suite_Dir, "*.json");
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
            Text : constant String :=
              Read_File (Ada.Directories.Full_Name (Item));
         begin
            if Text'Last = Positive'Last then
               Record_Wrong (Name, "too large");
            else
               begin
                  case Name (Name'First) is
                     when 'y' =>
                        if Parses (Text) then
                           Accepted := Accepted + 1;
                        else
                           Record_Wrong (Name, "must parse");
                        end if;

                     when 'n' =>
                        if Parses (Text) then
                           Record_Wrong (Name, "must be rejected");
                        else
                           Rejected := Rejected + 1;
                        end if;

                     when others =>
                        --  Implementation-defined: only a crash is wrong.
                        if Parses (Text) then
                           null;
                        end if;
                        Optional := Optional + 1;
                  end case;
               exception
                  when E : others =>
                     Record_Wrong (Name, Ada.Exceptions.Exception_Name (E));
               end;
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);

      Assert (Wrong_N = 0, To_String (Wrong));
      Assert
        (Accepted + Rejected + Optional >= 300,
         "the suite was read in full:" &
         Natural'Image (Accepted + Rejected + Optional));
   end Conforms_To_JSONTestSuite;

   ---------------------------------------------------------------------------
   --  Values
   ---------------------------------------------------------------------------

   procedure Builds_And_Reads_Values (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Fields : constant Member_Array :=
        [(To_Unbounded_String ("b"), Make_Integer (2)),
        (To_Unbounded_String ("a"), Make_Boolean (True)),
        (To_Unbounded_String ("b"), Make_String ("two"))];
      Obj    : constant Value        := Make_Object (Fields);
      Arr    : constant Value        :=
        Make_Array ([Make_Integer (1), Null_Value, Make_Float (2.5)]);
   begin
      Assert (Kind_Of (Null_Value) = JSON_Null, "null");
      Assert
        (Kind_Of (Obj) = JSON_Object and then Length (Obj) = 2,
         "a repeated key does not add a member");
      Assert
        (Member_Key (Obj, 1) = "b" and then Member_Key (Obj, 2) = "a",
         "members keep source order");
      Assert
        (As_String (Member_Value (Obj, "b")) = "two",
         "the later value replaces the earlier one in place");
      Assert (As_Boolean (Member_At (Obj, 2)), "member by index");
      Assert (not Has_Member (Obj, "c"), "absent key");
      Assert
        (Length (Arr) = 3 and then Kind_Of (Element (Arr, 2)) = JSON_Null,
         "array elements");
      Assert (As_Integer (Element (Arr, 1)) = 1, "integer");
      Assert (As_Float (Element (Arr, 3)) = 2.5, "float");
   end Builds_And_Reads_Values;

   procedure Equality_Is_Structural (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Parsed ("{""a"":1,""b"":[true,null]}") =
         Parsed ("{""b"":[true,null],""a"":1}"),
         "object member order is ignored");
      Assert (Parsed ("[1,2]") /= Parsed ("[2,1]"), "array order counts");
      Assert (Parsed ("1") /= Parsed ("1.0"), "an integer is not a float");
      Assert (Parsed ("""a""") /= Parsed ("[""a""]"), "kinds differ");
      Assert
        (Parsed ("{""a"":1}") /= Parsed ("{""a"":1,""b"":2}"),
         "member counts differ");
      Assert (Parsed ("{""a"":1}") /= Parsed ("{""b"":1}"), "keys differ");
      Assert (Null_Value = Parsed ("null"), "null equals null");
   end Equality_Is_Structural;

   procedure Copies_Share_One_Tree (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Original : constant Value := Parsed ("[1,[2,3],{""k"":""v""}]");
   begin
      for I in 1 .. 1_000 loop
         declare
            Copy  : constant Value := Original;
            Inner : constant Value := Element (Copy, 2);
         begin
            if Length (Inner) /= 2 or else Copy /= Original then
               Assert (False, "copy" & I'Image & " differs");
            end if;
         end;
      end loop;
      Assert
        (To_String (Original) = "[1,[2,3],{""k"":""v""}]",
         "the original is intact after its copies are gone");
   end Copies_Share_One_Tree;

   ---------------------------------------------------------------------------
   --  Numbers
   ---------------------------------------------------------------------------

   procedure Classifies_Numbers (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Is_Kind (Text : String; K : Kind) return Boolean is
        (Kind_Of (Parsed (Text)) = K);
   begin
      Assert (Is_Kind ("0", JSON_Integer), "0");
      Assert (Is_Kind ("-0", JSON_Integer), "-0 is the integer 0");
      Assert (As_Integer (Parsed ("-0")) = 0, "-0 has value 0");
      Assert
        (Is_Kind ("9223372036854775807", JSON_Integer), "largest integer");
      Assert
        (Is_Kind ("9223372036854775808", JSON_Number_String),
         "one more keeps its digits");
      Assert
        (Is_Kind ("-9223372036854775808", JSON_Integer), "smallest integer");
      Assert
        (Is_Kind ("-9223372036854775809", JSON_Number_String),
         "one less keeps its digits");
      Assert
        (As_String (Parsed ("123456789012345678901234567890")) =
         "123456789012345678901234567890",
         "big integer digits");
      Assert (Is_Kind ("1.5", JSON_Float), "fraction");
      Assert (Is_Kind ("1e2", JSON_Float), "exponent");
      Assert (As_Float (Parsed ("1e2")) = 100.0, "1e2 is 100");
      Assert (As_Float (Parsed ("-1.5E-3")) = -0.001_5, "signed exponent");
      Assert
        (Is_Kind ("1E400", JSON_Number_String),
         "a float out of range keeps its digits");
      Assert (As_String (Parsed ("1E400")) = "1E400", "and its text");
      Assert
        (Is_Kind ("1e-400", JSON_Float)
         or else Is_Kind ("1e-400", JSON_Number_String),
         "tiny exponent");
   end Classifies_Numbers;

   ---------------------------------------------------------------------------
   --  Errors
   ---------------------------------------------------------------------------

   procedure Reports_Errors_With_Offsets (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      procedure Check
        (Text : String; Reason : Parse_Error_Kind; At_Offset : Natural)
      is
         R : constant Parse_Result := Failure_Of (Text);
      begin
         Assert
           (R.Error = Reason and then R.Offset = At_Offset,
            "for " & Text & " got " & R.Error'Image & R.Offset'Image);
      end Check;
   begin
      Check ("", Unexpected_End, 0);
      Check ("   ", Unexpected_End, 3);
      Check ("[1,]", Unexpected_Character, 3);
      Check ("[1", Unexpected_End, 2);
      Check ("{""a"":1} x", Trailing_Data, 8);
      Check ("01", Trailing_Data, 1);
      Check ("-", Invalid_Number, 0);
      Check ("""\x""", Invalid_Escape, 1);
      Check ("""" & Esc ("d800") & """", Invalid_Escape, 1);
      Check ("""" & Esc ("dc00") & """", Invalid_Escape, 1);
      Check ("""" & Esc ("12G4") & """", Invalid_Escape, 5);
      Check ("""" & Byte (16#FF#) & """", Invalid_UTF8, 1);
      Check ("""a" & Byte (10) & """", Unexpected_Character, 2);
      Check ("tru", Unexpected_End, 3);
      Check ("nul1", Unexpected_Character, 3);
      Check ("{1:2}", Unexpected_Character, 1);
      Check ("{""a"" 1}", Unexpected_Character, 5);
   end Reports_Errors_With_Offsets;

   procedure Limits_Nesting_Depth (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Nested (Depth : Natural) return String is
        (String'(1 .. Depth => '[') & String'(1 .. Depth => ']'));

      function Nested_Objects (Depth : Natural) return String is
         Result : Unbounded_String;
      begin
         for I in 1 .. Depth loop
            Append (Result, "{""k"":");
         end loop;
         Append (Result, "0");
         for I in 1 .. Depth loop
            Append (Result, "}");
         end loop;
         return To_String (Result);
      end Nested_Objects;
   begin
      Assert (Parses (Nested (Max_Depth)), "512 nested arrays parse");
      Assert
        (Failure_Of (Nested (Max_Depth + 1)).Error = Too_Deep,
         "513 nested arrays are too deep");
      Assert (Parses (Nested_Objects (Max_Depth)), "512 nested objects parse");
      Assert
        (Failure_Of (Nested_Objects (Max_Depth + 1)).Error = Too_Deep,
         "513 nested objects are too deep");
      Assert
        (Failure_Of (String'(1 .. 200_000 => '[')).Error = Too_Deep,
         "a huge opening run fails instead of overflowing the stack");
   end Limits_Nesting_Depth;

   ---------------------------------------------------------------------------
   --  Strings
   ---------------------------------------------------------------------------

   procedure Unescapes_Strings (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Short_Escapes : constant String :=
        Character'Val (92) & "n" & Character'Val (92) & """" &
        Character'Val (92) & Character'Val (92) & Character'Val (92) & "/" &
        Character'Val (92) & "b" & Character'Val (92) & "f" &
        Character'Val (92) & "r" & Character'Val (92) & "t";
      Expected      : constant String :=
        Byte (16#C3#) & Byte (16#A9#) & Byte (16#F0#) & Byte (16#9F#) &
        Byte (16#98#) & Byte (16#80#) & Byte (10) & """" & Character'Val (92) &
        "/" & Byte (8) & Byte (12) & Byte (13) & Byte (9) & Byte (0);
   begin
      Assert
        (As_String
           (Parsed
              ("""" & Esc ("00e9") & Esc ("d83d") & Esc ("de00") &
               Short_Escapes & Esc ("0000") & """")) =
         Expected,
         "escapes become UTF-8");
      Assert
        (As_String (Parsed ("""" & Esc ("D83D") & Esc ("DE00") & """")) =
         Byte (16#F0#) & Byte (16#9F#) & Byte (16#98#) & Byte (16#80#),
         "upper-case hex digits");
      Assert
        (As_String (Parsed ("""" & Byte (16#C3#) & Byte (16#A9#) & """")) =
         Byte (16#C3#) & Byte (16#A9#),
         "raw UTF-8 passes through");
   end Unescapes_Strings;

   ---------------------------------------------------------------------------
   --  Writer
   ---------------------------------------------------------------------------

   procedure Writes_Compact_JSON (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (To_String (Null_Value) = "null", "null");
      Assert (To_String (Make_Boolean (True)) = "true", "true");
      Assert (To_String (Make_Integer (-42)) = "-42", "integer");
      Assert (To_String (Parsed ("[ ]")) = "[]", "empty array");
      Assert (To_String (Parsed ("{ }")) = "{}", "empty object");
      Assert
        (To_String (Parsed (" { ""b"" : [ 1 , 2 ] , ""a"" : { } } ")) =
         "{""b"":[1,2],""a"":{}}",
         "no whitespace; members in source order");
      Assert
        (To_String (Make_Number_String ("12345678901234567890")) =
         "12345678901234567890",
         "number strings are verbatim");
   end Writes_Compact_JSON;

   procedure Escapes_Strings_When_Writing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Raw : constant String :=
        "q"" b\ s/ " & Byte (8) & Byte (12) & Byte (10) & Byte (13) &
        Byte (9) & Byte (1) & Byte (31) & Byte (127) & Byte (16#C3#) &
        Byte (16#A9#);
   begin
      Assert
        (To_String (Make_String (Raw)) =
         """q" & Character'Val (92) & """ b" & Character'Val (92) &
         Character'Val (92) & " s/ " & Character'Val (92) & "b" &
         Character'Val (92) & "f" & Character'Val (92) & "n" &
         Character'Val (92) & "r" & Character'Val (92) & "t" & Esc ("0001") &
         Esc ("001f") & Byte (127) & Byte (16#C3#) & Byte (16#A9#) & """",
         "short escapes, \u00XX, and everything else as is");
   end Escapes_Strings_When_Writing;

   procedure Writes_Floats_With_Fewest_Digits (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      procedure Check (F : Long_Float; Expected : String) is
      begin
         Assert
           (To_String (Make_Float (F)) = Expected,
            "got " & To_String (Make_Float (F)) & " expected " & Expected);
      end Check;
   begin
      Check (0.0, "0.0");
      Check (1.0, "1.0");
      Check (-2.5, "-2.5");
      Check (0.5, "0.5");
      Check (0.1, "0.1");
      Check (100.0, "100.0");
      Check (123_456_789.125, "123456789.125");
      Check (1.0 / 3.0, "0.3333333333333333");
      Check (0.000_1, "0.0001");
      Check (1.0e-7, "1.0e-7");
      Check (1.5e300, "1.5e+300");
      Check (-1.0e25, "-1.0e+25");
      Check (1.0e20, "100000000000000000000.0");
      Check (Long_Float'Last, "1.7976931348623157e+308");
   end Writes_Floats_With_Fewest_Digits;

   ---------------------------------------------------------------------------
   --  Properties
   ---------------------------------------------------------------------------

   --  A small deterministic generator, so a failure repeats.
   Seed : Interfaces.Unsigned_64 := 20_261_006;

   function Next (Limit : Positive) return Natural is
      use type Interfaces.Unsigned_64;
   begin
      --  A 64-bit linear congruential step; wrapping is intended.
      Seed := Seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Natural ((Seed / 2**20) mod Interfaces.Unsigned_64 (Limit));
   end Next;

   function Random_String return String is
      Result : Unbounded_String;
   begin
      for I in 1 .. Next (8) loop
         case Next (6) is
            when 0 =>
               Append (Result, Character'Val (32 + Next (95)));

            when 1 =>
               Append (Result, Character'Val (Next (32)));

            when 2 =>
               Append (Result, """");

            when 3 =>
               Append (Result, "\");

            when 4 =>
               Append (Result, UTF8.Encode (16#80# + Next (16#7F80#)));

            when others =>
               Append (Result, UTF8.Encode (16#1_0000# + Next (16#F_0000#)));
         end case;
      end loop;
      return To_String (Result);
   end Random_String;

   function Random_Value (Depth : Natural) return Value is
   begin
      case Next (if Depth >= 4 then 6 else 8) is
         when 0 =>
            return Null_Value;

         when 1 =>
            return Make_Boolean (Next (2) = 1);

         when 2 =>
            return
              Make_Integer (Long_Long_Integer (Next (1_000_000)) - 500_000);

         when 3 =>
            return
              Make_Float
                ((Long_Float (Next (2_000_000)) - 1_000_000.0) /
                 Long_Float (1 + Next (1_000)));

         when 4 =>
            return
              Make_Number_String ("1" & String'(1 .. 20 + Next (5) => '7'));

         when 5 =>
            return Make_String (Random_String);

         when 6 =>
            declare
               Items : Value_Array (1 .. Next (4));
            begin
               for I in Items'Range loop
                  Items (I) := Random_Value (Depth + 1);
               end loop;
               return Make_Array (Items);
            end;

         when others =>
            declare
               Fields : Member_Array (1 .. Next (4));
            begin
               for I in Fields'Range loop
                  Fields (I) :=
                    (To_Unbounded_String (Random_String),
                     Random_Value (Depth + 1));
               end loop;
               return Make_Object (Fields);
            end;
      end case;
   end Random_Value;

   procedure Written_Values_Parse_Back_Equal (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      for I in 1 .. 3_000 loop
         declare
            V    : constant Value        := Random_Value (0);
            Text : constant String       := To_String (V);
            R    : constant Parse_Result := Parse (Text);
         begin
            if not R.Ok then
               Assert (False, "value" & I'Image & " does not parse: " & Text);
            elsif R.Item /= V then
               Assert (False, "value" & I'Image & " changed: " & Text);
            elsif To_String (R.Item) /= Text then
               Assert (False, "value" & I'Image & " prints differently");
            end if;
         end;
      end loop;
   end Written_Values_Parse_Back_Equal;

   procedure Random_Input_Never_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Alphabet : constant String :=
        "{}[]:,""\ 0123456789.eE+-tfnrueasl" & ASCII.LF;
   begin
      for I in 1 .. 6_000 loop
         declare
            Source : constant String :=
              (if I mod 2 = 0 then To_String (Random_Value (0))
               else "[1,{""a"":""b""},null]");
            Text   : String          := Source;
         begin
            --  Mutate a few bytes, or truncate.
            for K in 1 .. 1 + Next (4) loop
               if Text'Length > 0 then
                  Text (Text'First + Next (Text'Length)) :=
                    (if Next (4) = 0 then Character'Val (Next (256))
                     else Alphabet (Alphabet'First + Next (Alphabet'Length)));
               end if;
            end loop;
            declare
               Cut   : constant Natural      := Next (Text'Length + 1);
               Probe : constant String       :=
                 (if Next (5) = 0 then
                    Text (Text'First .. Text'First + Cut - 1)
                  else Text);
               R     : constant Parse_Result := Parse (Probe);
            begin
               if R.Ok and then not Parse (To_String (R.Item)).Ok then
                  Assert (False, "an accepted input does not re-parse");
               end if;
            end;
         exception
            when E : others =>
               Assert (False, "raised " & Ada.Exceptions.Exception_Name (E));
         end;
      end loop;
   end Random_Input_Never_Raises;

   ---------------------------------------------------------------------------
   --  Lexical helpers
   ---------------------------------------------------------------------------

   procedure Scans_Numbers (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Scan (S : String) return Natural is
        (Lexical.Scan_Number (S, S'First));
   begin
      Assert (Scan ("0") = 1, "0");
      Assert (Scan ("-12.5e+3,") = 8, "full grammar, stops at the comma");
      Assert (Scan ("12abc") = 2, "stops at a letter");
      Assert (Scan ("1.") = 1, "a dot needs digits after it");
      Assert (Scan ("1e") = 1, "an exponent needs digits");
      Assert (Scan ("1e+") = 1, "even with a sign");
      Assert (Scan ("1.5e") = 3, "fraction kept, empty exponent dropped");
      Assert (Scan ("01") = 1, "no leading zeros");
      Assert (Scan ("-") = 0, "a bare minus");
      Assert (Scan ("-x") = 0, "minus then a letter");
      Assert (Scan (".5") = 0, "no integer part");
      Assert (Scan ("+1") = 0, "no plus sign");
      Assert (Lexical.Scan_Number ("x12", 2) = 3, "starts at Pos");
   end Scans_Numbers;

   procedure Decodes_Hex_And_Surrogates (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Lexical.Hex_Value ('0') = 0 and then Lexical.Hex_Value ('9') = 9,
         "digits");
      Assert
        (Lexical.Hex_Value ('a') = 10 and then Lexical.Hex_Value ('F') = 15,
         "letters");
      Assert
        (Lexical.Hex_Value ('g') = -1 and then Lexical.Hex_Value (' ') = -1,
         "not hex");
      Assert
        (Lexical.Combine_Surrogates (16#D83D#, 16#DE00#) = 16#1_F600#,
         "grinning face");
      Assert
        (Lexical.Combine_Surrogates (16#D800#, 16#DC00#) = 16#1_0000#,
         "first supplementary");
      Assert
        (Lexical.Combine_Surrogates (16#DBFF#, 16#DFFF#) = 16#10_FFFF#,
         "last scalar");
   end Decodes_Hex_And_Surrogates;

   procedure Measures_Escaped_Length (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Lexical.Escaped_Length ("") = 0, "empty");
      Assert (Lexical.Escaped_Length ("abc") = 3, "plain");
      Assert (Lexical.Escaped_Length ("a""b\") = 6, "quote and backslash");
      Assert
        (Lexical.Escaped_Length (Byte (10) & Byte (9)) = 4, "short forms");
      Assert (Lexical.Escaped_Length (Byte (1)) = 6, "a control character");
      Assert (Lexical.Escaped_Length (Byte (127)) = 1, "DEL is not escaped");
   end Measures_Escaped_Length;

   ---------------------------------------------------------------------------

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.JSON");
   end Name;

   Shared : Value;

   --  Copies and drops copies of Shared, as the tasks that tag do.
   task type Copier (Rounds : Positive) is
      entry Go;
   end Copier;

   task body Copier is
      Total : Natural := 0;
   begin
      accept Go;
      for I in 1 .. Rounds loop
         declare
            Mine  : constant Value := Shared;
            Again : constant Value := Mine;
         begin
            Total := Total + Length (Again);
         end;
      end loop;
   end Copier;

   procedure Tasks_Share_One_Value (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Shared := Parsed ("{""a"": [1, 2, 3], ""b"": {""c"": ""d""}}");
      declare
         Tasks : array (1 .. 8) of Copier (20_000);
      begin
         for Each of Tasks loop
            Each.Go;
         end loop;
      end;
      Assert (Length (Shared) = 2, "still whole after the copies");
      Assert (Length (Member_Value (Shared, "a")) = 3, "and its parts");
   end Tasks_Share_One_Value;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Conforms_To_JSONTestSuite'Access, "Conforms to JSONTestSuite");
      Register_Routine
        (T, Builds_And_Reads_Values'Access, "Builds and reads values");
      Register_Routine
        (T, Equality_Is_Structural'Access, "Equality is structural");
      Register_Routine
        (T, Copies_Share_One_Tree'Access, "Copies share one tree");
      Register_Routine (T, Classifies_Numbers'Access, "Classifies numbers");
      Register_Routine
        (T, Reports_Errors_With_Offsets'Access, "Reports errors with offsets");
      Register_Routine
        (T, Limits_Nesting_Depth'Access, "Limits nesting depth");
      Register_Routine (T, Unescapes_Strings'Access, "Unescapes strings");
      Register_Routine (T, Writes_Compact_JSON'Access, "Writes compact JSON");
      Register_Routine
        (T, Escapes_Strings_When_Writing'Access,
         "Escapes strings when writing");
      Register_Routine
        (T, Writes_Floats_With_Fewest_Digits'Access,
         "Writes floats with the fewest digits");
      Register_Routine
        (T, Written_Values_Parse_Back_Equal'Access,
         "Written values parse back equal");
      Register_Routine
        (T, Random_Input_Never_Raises'Access, "Random input never raises");
      Register_Routine (T, Scans_Numbers'Access, "Scans numbers");
      Register_Routine
        (T, Decodes_Hex_And_Surrogates'Access, "Decodes hex and surrogates");
      Register_Routine
        (T, Measures_Escaped_Length'Access, "Measures escaped length");
      Register_Routine
        (T, Tasks_Share_One_Value'Access, "Tasks share one value");
   end Register_Tests;

end Synapse.Core.JSON.Tests;
