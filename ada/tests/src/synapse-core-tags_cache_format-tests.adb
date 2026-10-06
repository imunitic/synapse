with Ada.Numerics.Discrete_Random;

with AUnit.Assertions;

with GNAT.CRC32;

with Synapse.Adapters.Memory_Byte_Source;
with Synapse.Core.Tag_Payload;
with Synapse.Test_Bytes;

package body Synapse.Core.Tags_Cache_Format.Tests is

   use AUnit.Assertions;
   use type Graph_Model.Hash;
   use type Interfaces.Unsigned_64;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package Memory renames Adapters.Memory_Byte_Source;

   function Hash (Hex : String) return Graph_Model.Hash is
     (Graph_Model.Hash_From_Hex (Hex).Value);

   function Make
     (Path : String; Hex, Tags : String; Unsupported : Boolean := False)
      return Entry_Type is
     (Path => To_Unbounded_String (Path), Hash => Hash (Hex),
      Tags => To_Unbounded_String (Tags), Unsupported => Unsupported);

   Ones : constant String := "0123456789abcdef0123456789abcdef01234567";

   function Error_Of (Bytes : String) return String is
      Src : Memory.Source         := Memory.Create (Bytes);
      Got : constant Parse_Result := Parse (Src);
   begin
      return (if Got.Ok then "ok" else Parse_Error'Image (Got.Error));
   end Error_Of;

   --  The checksum of a file's table and paths put back after a change to
   --  them, so that what is tested is the check that follows it.
   function With_Crc (Bytes : String) return String is
      Result : String (1 .. Bytes'Length) := Bytes;
      Blob   : constant Natural           := Natural (Get_U64 (Result, 25));
      Crc    : GNAT.CRC32.CRC32;
   begin
      GNAT.CRC32.Initialize (Crc);
      GNAT.CRC32.Update (Crc, Result (Header_Size + 1 .. Blob));
      Result (33 .. 36) := Put_U32 (U32 (GNAT.CRC32.Get_Value (Crc)));
      return Result;
   end With_Crc;

   function One_Entry return Entry_Vectors.Vector is
      Result : Entry_Vectors.Vector;
   begin
      Result.Append (Make ("a.wdg", Ones, "T"));
      return Result;
   end One_Entry;

   function Several return Entry_Vectors.Vector is
      Result : Entry_Vectors.Vector;
   begin
      Result.Append (Make ("a/one.wdg", Ones, "first tags"));
      Result.Append (Make ("b/two.wdg", Ones, "", False));
      Result.Append (Make ("c/three.bin", Ones, "", True));
      Result.Append (Make ("d/four.wdg", Ones, [1 .. 5_000 => 'p']));
      return Result;
   end Several;

   procedure One_Entry_Encodes_To_Exactly_The_Documented_Bytes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bytes : constant String := Encode (One_Entry);
      Crc   : GNAT.CRC32.CRC32;
   begin
      Assert (Bytes'Length = 40 + 43 + 5 + 1, "header, record, path, payload");
      Assert (Bytes (1 .. 8) = "SYNTAGS" & Character'Val (0), "magic");
      Assert (Test_Bytes.To_Hex (Bytes (9 .. 12)) = "02000000", "version 2");
      Assert (Test_Bytes.To_Hex (Bytes (13 .. 16)) = "01000000", "one entry");
      Assert
        (Test_Bytes.To_Hex (Bytes (17 .. 24)) = "5300000000000000",
         "paths_off, 40 and 43");
      Assert
        (Test_Bytes.To_Hex (Bytes (25 .. 32)) = "5800000000000000",
         "blob_off, 83 and 5");
      Assert (Test_Bytes.To_Hex (Bytes (37 .. 40)) = "00000000", "reserved");
      Assert
        (Test_Bytes.To_Hex (Bytes (41 .. 48)) = "0000000000000000",
         "path_off");
      Assert (Test_Bytes.To_Hex (Bytes (49 .. 50)) = "0500", "path_len");
      Assert (Test_Bytes.To_Hex (Bytes (51 .. 70)) = Ones, "the raw hash");
      Assert
        (Test_Bytes.To_Hex (Bytes (71 .. 78)) = "0000000000000000",
         "tags_off");
      Assert (Test_Bytes.To_Hex (Bytes (79 .. 82)) = "01000000", "tags_len");
      Assert (Character'Pos (Bytes (83)) = 0, "flags");
      Assert
        (Bytes (84 .. 88) = "a.wdg" and then Bytes (89) = 'T',
         "the path, then the payload");
      GNAT.CRC32.Initialize (Crc);
      GNAT.CRC32.Update (Crc, Bytes (41 .. 88));
      Assert
        (Get_U32 (Bytes, 33) = U32 (GNAT.CRC32.Get_Value (Crc)),
         "the checksum covers the table and the paths");
      GNAT.CRC32.Initialize (Crc);
      GNAT.CRC32.Update (Crc, Bytes (41 .. 89));
      Assert
        (Get_U32 (Bytes, 33) /= U32 (GNAT.CRC32.Get_Value (Crc)),
         "and not the payload");
   end One_Entry_Encodes_To_Exactly_The_Documented_Bytes;

   procedure The_Checksum_Is_The_Standard_One (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Crc : GNAT.CRC32.CRC32;
   begin
      GNAT.CRC32.Initialize (Crc);
      GNAT.CRC32.Update (Crc, "123456789");
      Assert
        (U32 (GNAT.CRC32.Get_Value (Crc)) = 16#CBF4_3926#,
         "the check value of CRC-32, which other tools compute too");
   end The_Checksum_Is_The_Standard_One;

   procedure Many_Entries_Round_Trip_With_Payload_And_Flags
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : constant Entry_Vectors.Vector := Several;
      Src     : Memory.Source := Memory.Create (Encode (Entries));
      Got     : constant Parse_Result         := Parse (Src);
   begin
      Assert (Got.Ok and then Got.Head.Entry_Count = 4, "four entries");
      for I in 1 .. 4 loop
         declare
            Item : constant Table_Record := Record_At (Src, Got.Head, I - 1);
         begin
            Assert
              (Path_Of (Src, Got.Head, Item) = To_String (Entries (I).Path),
               "path" & I'Image);
            Assert
              (Tags_Of (Src, Got.Head, Item) = To_String (Entries (I).Tags),
               "tags" & I'Image);
            Assert
              (Unsupported (Item) = Entries (I).Unsupported, "flag" & I'Image);
            Assert (Item.Hash = Entries (I).Hash, "hash" & I'Image);
         end;
      end loop;
   end Many_Entries_Round_Trip_With_Payload_And_Flags;

   procedure Unsupported_And_Parsed_To_Nothing_Stay_Distinguishable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
   begin
      Entries.Append (Make ("a", Ones, "", False));
      Entries.Append (Make ("b", Ones, "", True));
      declare
         Src : Memory.Source   := Memory.Create (Encode (Entries));
         H   : constant Header := Parse (Src).Head;
      begin
         Assert (not Unsupported (Record_At (Src, H, 0)), "parsed, no tags");
         Assert (Unsupported (Record_At (Src, H, 1)), "no grammar");
      end;
   end Unsupported_And_Parsed_To_Nothing_Stay_Distinguishable;

   procedure Lookup_Is_A_Binary_Search_And_A_Miss_Is_A_Miss
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
   begin
      Entries.Append (Make ("a", Ones, ""));
      Entries.Append (Make ("c", Ones, ""));
      Entries.Append (Make ("e", Ones, ""));
      Entries.Append (Make ("g", Ones, ""));
      Entries.Append (Make ("i", Ones, ""));
      declare
         Src : Memory.Source   := Memory.Create (Encode (Entries));
         H   : constant Header := Parse (Src).Head;

         function At_Of (Path : String) return Integer is
            Got : constant Maybe_Index := Find (Src, H, Path);
         begin
            return (if Got.Found then Got.Index else -1);
         end At_Of;
      begin
         Assert (At_Of ("a") = 0, "the first");
         Assert (At_Of ("e") = 2, "the middle");
         Assert (At_Of ("i") = 4, "the last");
         Assert (At_Of ("0") = -1, "before the first");
         Assert (At_Of ("d") = -1, "between two");
         Assert (At_Of ("z") = -1, "after the last");
         Assert (At_Of ("") = -1, "empty");
         Assert (At_Of ("aa") = -1, "a longer name with a prefix that is one");
      end;
   end Lookup_Is_A_Binary_Search_And_A_Miss_Is_A_Miss;

   procedure An_Empty_Cache_Is_A_Valid_Cache (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      None  : Entry_Vectors.Vector;
      Bytes : constant String       := Encode (None);
      Src   : Memory.Source         := Memory.Create (Bytes);
      Got   : constant Parse_Result := Parse (Src);
   begin
      Assert (Bytes'Length = 40, "just a header");
      Assert (Got.Ok and then Got.Head.Entry_Count = 0, "no entries");
      Assert (not Find (Src, Got.Head, "x").Found, "and nothing to find");
   end An_Empty_Cache_Is_A_Valid_Cache;

   procedure Unsorted_Input_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
      Raised  : Boolean := False;
   begin
      Entries.Append (Make ("b", Ones, ""));
      Entries.Append (Make ("a", Ones, ""));
      begin
         declare
            Ignore : constant String := Encode (Entries);
         begin
            null;
         end;
      exception
         when Unsorted =>
            Raised := True;
      end;
      Assert (Raised, "out of order");
      Raised := False;
      Entries.Clear;
      Entries.Append (Make ("a", Ones, ""));
      Entries.Append (Make ("a", Ones, ""));
      begin
         declare
            Ignore : constant String := Encode (Entries);
         begin
            null;
         end;
      exception
         when Unsorted =>
            Raised := True;
      end;
      Assert (Raised, "a duplicate path");
   end Unsorted_Input_Is_Refused;

   procedure A_Path_That_Does_Not_Fit_Its_Length_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
      Raised  : Boolean := False;
   begin
      Entries.Append (Make ([1 .. 65_536 => 'x'], Ones, ""));
      begin
         declare
            Ignore : constant String := Encode (Entries);
         begin
            null;
         end;
      exception
         when Path_Too_Long =>
            Raised := True;
      end;
      Assert (Raised, "65,536 bytes");
      Entries.Clear;
      Entries.Append (Make ([1 .. 65_535 => 'x'], Ones, ""));
      Assert (Error_Of (Encode (Entries)) = "ok", "65,535 is the most");
   end A_Path_That_Does_Not_Fit_Its_Length_Is_Refused;

   procedure A_Cache_Of_Another_Version_Is_Rebuilt_Not_Misread
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bytes : String := Encode (One_Entry);
   begin
      Bytes (9) := Character'Val (3);
      Assert (Error_Of (Bytes) = "VERSION_MISMATCH", "version 3");
      Bytes (9) := Character'Val (1);
      Assert (Error_Of (Bytes) = "VERSION_MISMATCH", "version 1");
   end A_Cache_Of_Another_Version_Is_Rebuilt_Not_Misread;

   procedure A_File_That_Is_Not_Ours_Or_Corrupt_Or_Short_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Good : constant String := Encode (One_Entry);
   begin
      Assert (Error_Of ("") = "TRUNCATED", "empty");
      Assert (Error_Of ("SYNTAGS") = "TRUNCATED", "shorter than a header");
      Assert
        (Error_Of ([1 .. 100 => 'x']) = "NOT_A_CACHE",
         "something else at the path");
      Assert
        (Error_Of ("{""a.wdg"": {}}" & [1 .. 40 => ' ']) = "NOT_A_CACHE",
         "the JSON the old cache was");
      Assert (Error_Of (Good (1 .. 60)) = "TRUNCATED", "cut inside the table");
      declare
         Flipped : String := Good;
      begin
         Flipped (45) := Character'Val (Character'Pos (Flipped (45)) + 1);
         Assert
           (Error_Of (Flipped) = "CHECKSUM_MISMATCH",
            "a flipped bit in the table");
      end;
      declare
         Flipped : String := Good;
      begin
         Flipped (86) := 'Z';
         Assert
           (Error_Of (Flipped) = "CHECKSUM_MISMATCH",
            "a flipped bit in a path");
      end;
      declare
         Flipped : String := Good;
      begin
         Flipped (89) := 'Z';
         Assert
           (Error_Of (Flipped) = "ok",
            "a flipped bit in the payload is not detected: the cost of " &
            "an open that does not read it");
      end;
      Assert
        (Error_Of (Good (1 .. 88)) = "OFFSET_OUT_OF_RANGE",
         "a payload cut short is found by the offsets, not read past");
   end A_File_That_Is_Not_Ours_Or_Corrupt_Or_Short_Is_Refused;

   procedure A_Record_Pointing_Outside_Its_Region_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Good : constant String := Encode (One_Entry);
      Far  : String          := Good;
   begin
      Far (71 .. 78) := Put_U64 (1_000_000);
      Assert
        (Error_Of (With_Crc (Far)) = "OFFSET_OUT_OF_RANGE",
         "tags_off past the file");
      Far            := Good;
      Far (79 .. 82) := Put_U32 (2);
      Assert
        (Error_Of (With_Crc (Far)) = "OFFSET_OUT_OF_RANGE",
         "tags_len past the file");
      Far            := Good;
      Far (49 .. 50) := Put_U16 (9);
      Assert
        (Error_Of (With_Crc (Far)) = "OFFSET_OUT_OF_RANGE",
         "path_len past the region");
      Far            := Good;
      Far (25 .. 32) := Put_U64 (16#FFFF_FFFF#);
      Assert
        (Error_Of (Far) = "OFFSET_OUT_OF_RANGE", "blob_off past the file");
      Far            := Good;
      Far (25 .. 32) := Put_U64 (10);
      Assert
        (Error_Of (Far) = "OFFSET_OUT_OF_RANGE", "blob_off inside the header");
      Far            := Good;
      Far (17 .. 24) := Put_U64 (50);
      Assert
        (Error_Of (With_Crc (Far)) = "OFFSET_OUT_OF_RANGE",
         "paths_off inside the table");
   end A_Record_Pointing_Outside_Its_Region_Is_Refused;

   procedure A_Duplicate_Or_Misordered_Path_Is_Refused_On_Open
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
   begin
      Entries.Append (Make ("a", Ones, ""));
      Entries.Append (Make ("b", Ones, ""));
      declare
         Good  : constant String := Encode (Entries);
         Twice : String          := Good;
         Back  : String          := Good;
      begin
         --  The path region follows the two records: "a" then "b".
         Twice (40 + 2 * 43 + 2) := 'a';
         Assert
           (Error_Of (With_Crc (Twice)) = "OFFSET_OUT_OF_RANGE",
            "two entries with one path");
         Back (40 + 2 * 43 + 1) := 'c';
         Assert
           (Error_Of (With_Crc (Back)) = "OFFSET_OUT_OF_RANGE",
            "paths out of order");
         Assert (Error_Of (With_Crc (Good)) = "ok", "the unchanged file");
      end;
   end A_Duplicate_Or_Misordered_Path_Is_Refused_On_Open;

   procedure Only_The_Unsupported_Bit_Of_The_Flags_Counts
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Good  : constant String := Encode (One_Entry);
      Other : String          := Good;
   begin
      Other (83) := Character'Val (2);
      declare
         Src : Memory.Source   := Memory.Create (With_Crc (Other));
         H   : constant Header := Parse (Src).Head;
      begin
         Assert
           (not Unsupported (Record_At (Src, H, 0)),
            "another bit set is not unsupported");
      end;
      Other (83) := Character'Val (3);
      declare
         Src : Memory.Source   := Memory.Create (With_Crc (Other));
         H   : constant Header := Parse (Src).Head;
      begin
         Assert
           (Unsupported (Record_At (Src, H, 0)),
            "the unsupported bit with another one");
      end;
   end Only_The_Unsupported_Bit_Of_The_Flags_Counts;

   procedure A_Gap_Between_The_Table_And_The_Paths_Is_Fine
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Good : constant String := Encode (One_Entry);
      --  Two spare bytes between the record table and the path region.
      Gap  : String          := Good (1 .. 83) & "xx" & Good (84 .. Good'Last);
   begin
      Gap (17 .. 24) := Put_U64 (85);
      Gap (25 .. 32) := Put_U64 (90);
      Assert (Error_Of (With_Crc (Gap)) = "ok", "a gap is not an error");
   end A_Gap_Between_The_Table_And_The_Paths_Is_Fine;

   procedure An_Offset_Made_To_Overflow_The_Arithmetic_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Good : constant String := Encode (One_Entry);
      Bad  : String          := Good;
   begin
      Bad (41 .. 48) := Put_U64 (U64'Last - 1);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "path_off near the top of 64 bits, path_off + len wraps");
      Bad            := Good;
      Bad (71 .. 78) := Put_U64 (U64'Last);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "tags_off at the top");
      Bad            := Good;
      Bad (13 .. 16) := Put_U32 (U32'Last);
      Assert
        (Error_Of (Bad) = "TRUNCATED", "an entry count no file could hold");
   end An_Offset_Made_To_Overflow_The_Arithmetic_Is_Refused;

   function Fixture return String is
     (Test_Bytes.From_Hex

        ("53594e54414753000200000003000000a900000000000000cf0000000000" &
         "00008f7245e40000000000000000000000000d0045bc6ae64517e4378567" &
         "4ddad8b92e89b4a8fb4a000000000000000024000000000d000000000000" &
         "000d000123456789abcdef0123456789abcdef0123456724000000000000" &
         "0000000000001a000000000000000c00ffffffffffffffffffffffffffff" &
         "ffffffffffff240000000000000000000000017372632f616c7068612e77" &
         "64677372632f656d7074792e7764677372632f6c6f676f2e62696e000000" &
         "00000500416c7068610500636c6173730d000000636c61737320416c7068" &
         "61207b"));

   procedure Encode_Reproduces_The_Independent_Fixture_Byte_For_Byte
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Alpha   : Tag_Payload.Tag_Vectors.Vector;
      Entries : Entry_Vectors.Vector;
   begin
      Alpha.Append
        (Graph_Model.Tag'
           (Name => To_Unbounded_String ("Alpha"),
            Kind => To_Unbounded_String ("class"), Which => Graph_Model.Def,
            Line => 0, Expression => To_Unbounded_String ("class Alpha {")));
      Entries.Append
        (Make
           ("src/alpha.wdg", "45bc6ae64517e43785674ddad8b92e89b4a8fb4a",
             Tag_Payload.Encode (Alpha)));
      Entries.Append (Make ("src/empty.wdg", Ones, ""));
      Entries.Append (Make ("src/logo.bin", [1 .. 40 => 'f'], "", True));
      Assert
        (Test_Bytes.To_Hex (Encode (Entries)) = Test_Bytes.To_Hex (Fixture),
         "generated from the layout by a separate implementation");
   end Encode_Reproduces_The_Independent_Fixture_Byte_For_Byte;

   procedure The_Fixture_Decodes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Src : Memory.Source         := Memory.Create (Fixture);
      Got : constant Parse_Result := Parse (Src);
   begin
      Assert (Got.Ok and then Got.Head.Entry_Count = 3, "three entries");
      declare
         H     : constant Header                         := Got.Head;
         First : constant Table_Record := Record_At (Src, H, 0);
         Tags  : constant Tag_Payload.Tag_Vectors.Vector :=
           Tag_Payload.Decode (Tags_Of (Src, H, First));
      begin
         Assert (Path_Of (Src, H, First) = "src/alpha.wdg", "the first path");
         Assert
           (Natural (Tags.Length) = 1
            and then To_String (Tags (1).Name) = "Alpha"
            and then To_String (Tags (1).Expression) = "class Alpha {",
            "its payload decodes as a tag");
         Assert
           (Test_Bytes.To_Hex
              (Test_Bytes.From_Hex
                 ("45bc6ae64517e43785674ddad8b92e89b4a8fb4a")) =
            "45bc6ae64517e43785674ddad8b92e89b4a8fb4a",
            "hex helper");
         Assert
           (Graph_Model.Hash_To_Hex (First.Hash) =
            "45bc6ae64517e43785674ddad8b92e89b4a8fb4a",
            "its hash");
         Assert
           (Tags_Of (Src, H, Record_At (Src, H, 1)) = ""
            and then not Unsupported (Record_At (Src, H, 1)),
            "parsed, nothing declared");
         Assert (Unsupported (Record_At (Src, H, 2)), "no grammar");
         Assert (Find (Src, H, "src/empty.wdg").Index = 1, "found by path");
         Assert (not Find (Src, H, "src/missing.wdg").Found, "a miss");
      end;
   end The_Fixture_Decodes;

   package Draw is new Ada.Numerics.Discrete_Random (Natural);

   procedure Random_Caches_Survive_Byte_For_Byte (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Gen : Draw.Generator;

      function Pick (Limit : Positive) return Natural is
        (Draw.Random (Gen) mod Limit);
   begin
      Draw.Reset (Gen, 99);
      for Round in 1 .. 100 loop
         declare
            Entries : Entry_Vectors.Vector;
            Count   : constant Natural := Pick (12);
         begin
            for I in 1 .. Count loop
               declare
                  Suffix : String (1 .. Pick (20));
                  Tags   : String (1 .. Pick (30));
                  Index  : constant String := Natural'Image (1_000 + I);
               begin
                  for C of Suffix loop
                     C := Character'Val (Character'Pos ('!') + Pick (90));
                  end loop;
                  for C of Tags loop
                     C := Character'Val (Pick (256));
                  end loop;
                  Entries.Append
                    (Make
                       (Index (Index'First + 1 .. Index'Last) & "-" & Suffix,
                        Ones, Tags, Pick (2) = 0));
               end;
            end loop;
            declare
               Src : Memory.Source         := Memory.Create (Encode (Entries));
               Got : constant Parse_Result := Parse (Src);
            begin
               Assert (Got.Ok, "parses");
               Assert (Natural (Got.Head.Entry_Count) = Count, "the count");
               for I in 1 .. Count loop
                  declare
                     Item : constant Table_Record :=
                       Record_At (Src, Got.Head, I - 1);
                  begin
                     Assert
                       (Path_Of (Src, Got.Head, Item) =
                        To_String (Entries (I).Path),
                        "path");
                     Assert
                       (Tags_Of (Src, Got.Head, Item) =
                        To_String (Entries (I).Tags),
                        "tags");
                     Assert
                       (Unsupported (Item) = Entries (I).Unsupported, "flag");
                     Assert
                       (Find (Src, Got.Head, To_String (Entries (I).Path))
                          .Index =
                        I - 1,
                        "found");
                  end;
               end loop;
            end;
         end;
      end loop;
   end Random_Caches_Survive_Byte_For_Byte;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Tags_Cache_Format");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, One_Entry_Encodes_To_Exactly_The_Documented_Bytes'Access,
         "One entry encodes to exactly the documented bytes");
      Register_Routine
        (T, The_Checksum_Is_The_Standard_One'Access,
         "The checksum is the standard one");
      Register_Routine
        (T, Many_Entries_Round_Trip_With_Payload_And_Flags'Access,
         "Many entries round-trip with payload and flags");
      Register_Routine
        (T, Unsupported_And_Parsed_To_Nothing_Stay_Distinguishable'Access,
         "Unsupported and parsed-to-nothing stay distinguishable");
      Register_Routine
        (T, Lookup_Is_A_Binary_Search_And_A_Miss_Is_A_Miss'Access,
         "Lookup is a binary search and a miss is a miss");
      Register_Routine
        (T, An_Empty_Cache_Is_A_Valid_Cache'Access,
         "An empty cache is a valid cache");
      Register_Routine
        (T, Unsorted_Input_Is_Refused'Access, "Unsorted input is refused");
      Register_Routine
        (T, A_Path_That_Does_Not_Fit_Its_Length_Is_Refused'Access,
         "A path that does not fit its length is refused");
      Register_Routine
        (T, A_Cache_Of_Another_Version_Is_Rebuilt_Not_Misread'Access,
         "A cache of another version is rebuilt, not misread");
      Register_Routine
        (T, A_File_That_Is_Not_Ours_Or_Corrupt_Or_Short_Is_Refused'Access,
         "A file that is not ours, or corrupt, or short, is refused");
      Register_Routine
        (T, A_Record_Pointing_Outside_Its_Region_Is_Refused'Access,
         "A record pointing outside its region is refused");
      Register_Routine
        (T, A_Duplicate_Or_Misordered_Path_Is_Refused_On_Open'Access,
         "A duplicate or misordered path is refused on open");
      Register_Routine
        (T, Only_The_Unsupported_Bit_Of_The_Flags_Counts'Access,
         "Only the unsupported bit of the flags counts");
      Register_Routine
        (T, A_Gap_Between_The_Table_And_The_Paths_Is_Fine'Access,
         "A gap between the table and the paths is fine");
      Register_Routine
        (T, An_Offset_Made_To_Overflow_The_Arithmetic_Is_Refused'Access,
         "An offset made to overflow the arithmetic is refused");
      Register_Routine
        (T, Encode_Reproduces_The_Independent_Fixture_Byte_For_Byte'Access,
         "Encode reproduces the independent fixture byte for byte");
      Register_Routine (T, The_Fixture_Decodes'Access, "The fixture decodes");
      Register_Routine
        (T, Random_Caches_Survive_Byte_For_Byte'Access,
         "Random caches survive byte for byte");
   end Register_Tests;

end Synapse.Core.Tags_Cache_Format.Tests;
