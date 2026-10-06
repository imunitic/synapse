with Ada.Numerics.Discrete_Random;

with AUnit.Assertions;

with GNAT.CRC32;

with Synapse.Adapters.Memory_Byte_Source;
with Synapse.Test_Bytes;

package body Synapse.Core.Docstring_Index_Format.Tests is

   use AUnit.Assertions;
   use type Interfaces.Unsigned_64;
   use type Hashing.Digest;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package Memory renames Adapters.Memory_Byte_Source;

   function Filled (Byte : Natural) return Hashing.Digest is
     ([others => Byte]);

   function Make
     (Path, Name, Kind : String; Doc, Decl : Natural := 1) return Entry_Type is
     (Path => To_Unbounded_String (Path), Name => To_Unbounded_String (Name),
      Kind       => To_Unbounded_String (Kind), Docstring_Hash => Filled (Doc),
      Decl_Hash  => Filled (Decl), Docstring_Start => 1, Docstring_End => 2,
      Decl_Start => 3, Decl_End => 5);

   function Error_Of (Bytes : String) return String is
      Src : Memory.Source         := Memory.Create (Bytes);
      Got : constant Parse_Result := Parse (Src);
   begin
      return (if Got.Ok then "ok" else Parse_Error'Image (Got.Error));
   end Error_Of;

   function One return Entry_Vectors.Vector is
      Result : Entry_Vectors.Vector;
   begin
      Result.Append (Make ("a.wdg", "foo", "fn", 1, 2));
      return Result;
   end One;

   procedure One_Entry_Encodes_To_Exactly_The_Documented_Bytes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bytes : constant String := Encode (One);
      Crc   : GNAT.CRC32.CRC32;

      function Hex (First, Last : Positive) return String is
        (Test_Bytes.To_Hex (Bytes (First .. Last)));
   begin
      --  32 header, 109 record, 5 path, 3 name, 2 kind.
      Assert (Bytes'Length = 151, "the length");
      Assert (Bytes (1 .. 8) = "SYNDOCS" & Character'Val (0), "magic");
      Assert (Hex (9, 12) = "01000000", "version 1");
      Assert (Hex (13, 16) = "01000000", "one entry");
      Assert (Hex (17, 24) = "8d00000000000000", "strings_off, 32 and 109");
      Assert (Hex (29, 32) = "00000000", "reserved");
      Assert (Hex (33, 40) = "0000000000000000", "path_off");
      Assert (Hex (41, 42) = "0500", "path_len");
      Assert (Hex (43, 50) = "0500000000000000", "name_off");
      Assert (Hex (51, 52) = "0300", "name_len");
      Assert (Hex (53, 60) = "0800000000000000", "kind_off");
      Assert (Hex (61, 61) = "02", "kind_len");
      Assert
        (Hex (62, 93) =
         "01010101010101010101010101010101" &
         "01010101010101010101010101010101",
         "the docstring hash");
      Assert
        (Hex (94, 125) =
         "02020202020202020202020202020202" &
         "02020202020202020202020202020202",
         "the declaration hash");
      Assert (Hex (126, 129) = "01000000", "docstring start");
      Assert (Hex (130, 133) = "02000000", "docstring end");
      Assert (Hex (134, 137) = "03000000", "declaration start");
      Assert (Hex (138, 141) = "05000000", "declaration end");
      Assert (Bytes (142 .. 151) = "a.wdgfoofn", "the strings");
      GNAT.CRC32.Initialize (Crc);
      GNAT.CRC32.Update (Crc, Bytes (33 .. 151));
      Assert
        (Get_U32 (Bytes, 25) = U32 (GNAT.CRC32.Get_Value (Crc)),
         "the checksum covers everything after the header");
   end One_Entry_Encodes_To_Exactly_The_Documented_Bytes;

   procedure Many_Entries_Round_Trip_Keys_And_Hashes_Intact
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
   begin
      Entries.Append (Make ("a.wdg", "alpha", "fn", 1, 11));
      Entries.Append (Make ("a.wdg", "beta", "fn", 2, 12));
      Entries.Append (Make ("a.wdg", "beta", "type", 3, 13));
      Entries.Append (Make ("b.wdg", "gamma", "fn", 4, 14));
      declare
         Src : Memory.Source   := Memory.Create (Encode (Entries));
         H   : constant Header := Parse (Src).Head;
      begin
         Assert (H.Entry_Count = 4, "four entries");
         for I in 1 .. 4 loop
            declare
               Back : constant Entry_Type :=
                 Entry_Of (Src, H, Record_At (Src, H, I - 1));
            begin
               Assert
                 (Back.Path = Entries (I).Path
                  and then Back.Name = Entries (I).Name
                  and then Back.Kind = Entries (I).Kind,
                  "key" & I'Image);
               Assert
                 (Back.Docstring_Hash = Entries (I).Docstring_Hash
                  and then Back.Decl_Hash = Entries (I).Decl_Hash,
                  "hashes" & I'Image);
               Assert
                 (Back.Docstring_Start = 1 and then Back.Decl_End = 5,
                  "line ranges" & I'Image);
            end;
         end loop;
      end;
   end Many_Entries_Round_Trip_Keys_And_Hashes_Intact;

   procedure Find_Locates_The_Exact_Triple_And_A_Miss_Is_A_Miss
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
   begin
      Entries.Append (Make ("a.wdg", "alpha", "fn"));
      Entries.Append (Make ("a.wdg", "beta", "fn"));
      Entries.Append (Make ("a.wdg", "beta", "type"));
      Entries.Append (Make ("b.wdg", "gamma", "fn"));
      declare
         Src : Memory.Source   := Memory.Create (Encode (Entries));
         H   : constant Header := Parse (Src).Head;

         function At_Of (P, N, K : String) return Integer is
            Got : constant Maybe_Index := Find (Src, H, P, N, K);
         begin
            return (if Got.Found then Got.Index else -1);
         end At_Of;
      begin
         Assert (At_Of ("a.wdg", "alpha", "fn") = 0, "the first");
         Assert (At_Of ("a.wdg", "beta", "type") = 2, "the kind decides");
         Assert (At_Of ("b.wdg", "gamma", "fn") = 3, "the last");
         Assert (At_Of ("a.wdg", "beta", "const") = -1, "another kind");
         Assert (At_Of ("a.wdg", "gamma", "fn") = -1, "another name");
         Assert (At_Of ("c.wdg", "alpha", "fn") = -1, "another file");
         Assert (At_Of ("", "", "") = -1, "empty");
      end;
   end Find_Locates_The_Exact_Triple_And_A_Miss_Is_A_Miss;

   procedure Path_Range_Is_Every_Entry_For_One_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
   begin
      Entries.Append (Make ("a.wdg", "x", "fn"));
      Entries.Append (Make ("b.wdg", "x", "fn"));
      Entries.Append (Make ("b.wdg", "y", "fn"));
      Entries.Append (Make ("b.wdg", "z", "fn"));
      Entries.Append (Make ("d.wdg", "x", "fn"));
      declare
         Src : Memory.Source   := Memory.Create (Encode (Entries));
         H   : constant Header := Parse (Src).Head;

         function Span (Path : String) return String is
            R : constant Range_Of_Entries := Path_Range (Src, H, Path);
         begin
            return R.From'Image & R.To'Image;
         end Span;
      begin
         Assert (Span ("b.wdg") = " 1 4", "three contiguous entries");
         Assert (Span ("a.wdg") = " 0 1", "the first file");
         Assert (Span ("d.wdg") = " 4 5", "the last file");
         Assert (Span ("c.wdg") = " 4 4", "untracked, between two");
         Assert (Span ("0") = " 0 0", "untracked, before all");
         Assert (Span ("z") = " 5 5", "untracked, after all");
      end;
   end Path_Range_Is_Every_Entry_For_One_File;

   procedure Unsorted_Input_Is_Rejected_At_Encode_Time
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      function Refused (Entries : Entry_Vectors.Vector) return Boolean is
      begin
         declare
            Ignore : constant String := Encode (Entries);
         begin
            return False;
         end;
      exception
         when Unsorted =>
            return True;
      end Refused;

      Entries : Entry_Vectors.Vector;
   begin
      Entries.Append (Make ("b.wdg", "x", "fn"));
      Entries.Append (Make ("a.wdg", "x", "fn"));
      Assert (Refused (Entries), "paths out of order");
      Entries.Clear;
      Entries.Append (Make ("a.wdg", "y", "fn"));
      Entries.Append (Make ("a.wdg", "x", "fn"));
      Assert (Refused (Entries), "names out of order");
      Entries.Clear;
      Entries.Append (Make ("a.wdg", "x", "type"));
      Entries.Append (Make ("a.wdg", "x", "fn"));
      Assert (Refused (Entries), "kinds out of order");
      Entries.Clear;
      Entries.Append (Make ("a.wdg", "x", "fn"));
      Entries.Append (Make ("a.wdg", "x", "fn"));
      Assert (Refused (Entries), "a repeated triple");
   end Unsorted_Input_Is_Rejected_At_Encode_Time;

   procedure Strings_That_End_Exactly_At_The_Region_End_Are_Valid
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Only_Path, Path_And_Name : Entry_Vectors.Vector;
   begin
      Only_Path.Append (Make ("a.wdg", "", ""));
      Path_And_Name.Append (Make ("a.wdg", "name", ""));
      Assert
        (Error_Of (Encode (Only_Path)) = "ok",
         "a path with no name and no kind ends the region");
      Assert
        (Error_Of (Encode (Path_And_Name)) = "ok",
         "a name with no kind ends the region");
   end Strings_That_End_Exactly_At_The_Region_End_Are_Valid;

   procedure Over_Long_Fields_Are_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
      Raised  : Boolean := False;
   begin
      Entries.Append (Make ("a", "n", [1 .. 256 => 'k']));
      begin
         declare
            Ignore : constant String := Encode (Entries);
         begin
            null;
         end;
      exception
         when Kind_Too_Long =>
            Raised := True;
      end;
      Assert (Raised, "a kind of 256 bytes");
      Entries.Clear;
      Entries.Append (Make ("a", "n", [1 .. 255 => 'k']));
      Assert (Error_Of (Encode (Entries)) = "ok", "255 is the most");
   end Over_Long_Fields_Are_Refused;

   procedure A_Flipped_Byte_Or_A_Cut_File_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Good    : constant String := Encode (One);
      Flipped : String          := Good;
   begin
      Flipped (145) := 'Z';
      Assert
        (Error_Of (Flipped) = "CHECKSUM_MISMATCH",
         "a flipped byte in the string region");
      Flipped      := Good;
      Flipped (60) := Character'Val (9);
      Assert
        (Error_Of (Flipped) = "CHECKSUM_MISMATCH",
         "a flipped byte in the table");
      Assert
        (Error_Of (Good (1 .. 100)) = "TRUNCATED",
         "cut inside the record table");
      Assert
        (Error_Of (Good (1 .. 148)) = "CHECKSUM_MISMATCH",
         "cut inside the string region: the checksum covers it");
      Assert (Error_Of ("") = "TRUNCATED", "empty");
   end A_Flipped_Byte_Or_A_Cut_File_Is_Refused;

   procedure Wrong_Magic_Is_Not_A_Cache_Not_A_Version_Mismatch
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bad : String := Encode (One);
   begin
      Bad (1) := 'X';
      Assert (Error_Of (Bad) = "NOT_A_CACHE", "magic");
      Bad     := Encode (One);
      Bad (9) := Character'Val (2);
      Assert (Error_Of (Bad) = "VERSION_MISMATCH", "version");
   end Wrong_Magic_Is_Not_A_Cache_Not_A_Version_Mismatch;

   function With_Crc (Bytes : String) return String is
      Result : String (1 .. Bytes'Length) := Bytes;
      Crc    : GNAT.CRC32.CRC32;
   begin
      GNAT.CRC32.Initialize (Crc);
      GNAT.CRC32.Update (Crc, Result (Header_Size + 1 .. Result'Last));
      Result (25 .. 28) := Put_U32 (U32 (GNAT.CRC32.Get_Value (Crc)));
      return Result;
   end With_Crc;

   procedure Offsets_Pointing_Nowhere_Are_Refused (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Good : constant String := Encode (One);
      Bad  : String          := Good;
   begin
      Bad (41 .. 42) := Put_U16 (200);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "path_len past the region");
      Bad            := Good;
      Bad (51 .. 52) := Put_U16 (200);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "name_len past the region");
      Bad      := Good;
      Bad (61) := Character'Val (200);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "kind_len past the region");
      Bad            := Good;
      Bad (33 .. 40) := Put_U64 (U64'Last - 1);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "an offset that overflows the arithmetic");
      Bad            := Good;
      Bad (53 .. 60) := Put_U64 (U64'Last - 1);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "the kind's offset overflowing");
      Bad            := Good;
      Bad (17 .. 24) := Put_U64 (100);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "strings_off inside the table");
      Bad            := Good;
      Bad (17 .. 24) := Put_U64 (900);
      Assert
        (Error_Of (Bad) = "OFFSET_OUT_OF_RANGE", "strings_off past the file");
      Bad            := Good;
      Bad (13 .. 16) := Put_U32 (1_000_000);
      Assert (Error_Of (Bad) = "TRUNCATED", "more entries than bytes");
   end Offsets_Pointing_Nowhere_Are_Refused;

   procedure Duplicate_Or_Misordered_Keys_Are_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Two : Entry_Vectors.Vector;
   begin
      Two.Append (Make ("a", "x", "fn"));
      Two.Append (Make ("b", "x", "fn"));
      declare
         Good  : constant String := Encode (Two);
         Same  : String          := Good;
         Order : String          := Good;
      begin
         --  The strings follow the table: "a" "x" "fn" "b" "x" "fn".
         Same (Header_Size + 2 * Record_Size + 5) := 'a';
         Assert
           (Error_Of (With_Crc (Same)) = "OFFSET_OUT_OF_RANGE",
            "two records with one key");
         Order (Header_Size + 2 * Record_Size + 1) := 'c';
         Assert
           (Error_Of (With_Crc (Order)) = "OFFSET_OUT_OF_RANGE",
            "paths out of order");
      end;
   end Duplicate_Or_Misordered_Keys_Are_Refused;

   package Draw is new Ada.Numerics.Discrete_Random (Natural);

   procedure Random_Indexes_Survive_Byte_For_Byte (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Gen : Draw.Generator;

      function Pick (Limit : Positive) return Natural is
        (Draw.Random (Gen) mod Limit);

      function Word (Prefix : Character; N : Natural) return String is
         Image : constant String := Integer'Image (1_000 + N);
      begin
         return Prefix & Image (Image'First + 1 .. Image'Last);
      end Word;
   begin
      Draw.Reset (Gen, 41);
      for Round in 1 .. 60 loop
         declare
            Entries : Entry_Vectors.Vector;
         begin
            for P in 1 .. Pick (5) loop
               for N in 1 .. Pick (4) loop
                  Entries.Append
                    (Make
                       (Word ('p', P), Word ('n', N),
                        (if Pick (2) = 0 then "fn" else "type"), Pick (256),
                        Pick (256)));
               end loop;
            end loop;
            declare
               Sorted : Entry_Vectors.Vector;
            begin
               --  Entries are built ascending by path and name; the kind
               --  must be ascending too, so a repeated name keeps one kind.
               for E of Entries loop
                  if Sorted.Is_Empty or else Sorted.Last_Element.Path /= E.Path
                    or else Sorted.Last_Element.Name /= E.Name
                  then
                     Sorted.Append (E);
                  end if;
               end loop;
               declare
                  Src : Memory.Source := Memory.Create (Encode (Sorted));
                  Got : constant Parse_Result := Parse (Src);
               begin
                  Assert (Got.Ok, "parses");
                  for I in 1 .. Natural (Sorted.Length) loop
                     declare
                        Back : constant Entry_Type :=
                          Entry_Of
                            (Src, Got.Head, Record_At (Src, Got.Head, I - 1));
                     begin
                        Assert
                          (Back.Path = Sorted (I).Path
                           and then Back.Name = Sorted (I).Name
                           and then Back.Kind = Sorted (I).Kind
                           and then Back.Docstring_Hash =
                             Sorted (I).Docstring_Hash
                           and then Back.Decl_Hash = Sorted (I).Decl_Hash,
                           "entry" & I'Image);
                        Assert
                          (Find
                             (Src, Got.Head, To_String (Sorted (I).Path),
                              To_String (Sorted (I).Name),
                              To_String (Sorted (I).Kind))
                             .Index =
                           I - 1,
                           "found");
                     end;
                  end loop;
               end;
            end;
         end;
      end loop;
   end Random_Indexes_Survive_Byte_For_Byte;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Docstring_Index_Format");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, One_Entry_Encodes_To_Exactly_The_Documented_Bytes'Access,
         "One entry encodes to exactly the documented bytes");
      Register_Routine
        (T, Many_Entries_Round_Trip_Keys_And_Hashes_Intact'Access,
         "Many entries round-trip with keys and hashes intact");
      Register_Routine
        (T, Find_Locates_The_Exact_Triple_And_A_Miss_Is_A_Miss'Access,
         "Find locates the exact triple and a miss is a miss");
      Register_Routine
        (T, Path_Range_Is_Every_Entry_For_One_File'Access,
         "Path_Range is every entry for one file");
      Register_Routine
        (T, Unsorted_Input_Is_Rejected_At_Encode_Time'Access,
         "Unsorted input is rejected at encode time");
      Register_Routine
        (T, Strings_That_End_Exactly_At_The_Region_End_Are_Valid'Access,
         "Strings that end exactly at the region end are valid");
      Register_Routine
        (T, Over_Long_Fields_Are_Refused'Access,
         "Over-long fields are refused");
      Register_Routine
        (T, A_Flipped_Byte_Or_A_Cut_File_Is_Refused'Access,
         "A flipped byte or a cut file is refused");
      Register_Routine
        (T, Wrong_Magic_Is_Not_A_Cache_Not_A_Version_Mismatch'Access,
         "Wrong magic is not a cache, not a version mismatch");
      Register_Routine
        (T, Offsets_Pointing_Nowhere_Are_Refused'Access,
         "Offsets pointing nowhere are refused");
      Register_Routine
        (T, Duplicate_Or_Misordered_Keys_Are_Refused'Access,
         "Duplicate or misordered keys are refused");
      Register_Routine
        (T, Random_Indexes_Survive_Byte_For_Byte'Access,
         "Random indexes survive byte for byte");
   end Register_Tests;

end Synapse.Core.Docstring_Index_Format.Tests;
