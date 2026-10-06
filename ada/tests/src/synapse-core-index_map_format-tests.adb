with Ada.Numerics.Discrete_Random;

with AUnit.Assertions;

with GNAT.CRC32;

with Synapse.Adapters.Memory_Byte_Source;
with Synapse.Test_Bytes;

package body Synapse.Core.Index_Map_Format.Tests is

   use AUnit.Assertions;
   use type Interfaces.Unsigned_64;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package Memory renames Adapters.Memory_Byte_Source;

   LF : constant Character := Character'Val (10);

   function Names_Of
     (A : String := ""; B : String := ""; C : String := "")
      return Text_Lists.Vector
   is
      Result : Text_Lists.Vector;

      procedure Add (Name : String) is
      begin
         if Name /= "" then
            Result.Append (To_Unbounded_String (Name));
         end if;
      end Add;
   begin
      Add (A);
      Add (B);
      Add (C);
      return Result;
   end Names_Of;

   function Make
     (Path : String; Nodes : Text_Lists.Vector) return Entry_Type is
     (Path => To_Unbounded_String (Path), Nodes => Nodes);

   No_Paths : Text_Lists.Vector;

   function One return Entry_Vectors.Vector is
      Result : Entry_Vectors.Vector;
   begin
      Result.Append (Make ("a.wdg", Names_Of ("N.md")));
      return Result;
   end One;

   function Error_Of (Bytes : String) return String is
      Src : Memory.Source         := Memory.Create (Bytes);
      Got : constant Parse_Result := Parse (Src);
   begin
      return (if Got.Ok then "ok" else Parse_Error'Image (Got.Error));
   end Error_Of;

   --  The checksum put back after a change to what it covers, so that what
   --  is tested is the check that follows it.
   function With_Crc (Bytes : String) return String is
      Result : String (1 .. Bytes'Length) := Bytes;
      Crc    : GNAT.CRC32.CRC32;
   begin
      GNAT.CRC32.Initialize (Crc);
      GNAT.CRC32.Update (Crc, Result (Header_Size + 1 .. Result'Last));
      Result (57 .. 60) := Put_U32 (U32 (GNAT.CRC32.Get_Value (Crc)));
      return Result;
   end With_Crc;

   function Unassigned_Of
     (A : String := ""; B : String := "") return Text_Lists.Vector is
     (Names_Of (A, B));

   function Several return Entry_Vectors.Vector is
      Result : Entry_Vectors.Vector;
   begin
      Result.Append (Make ("a/one.wdg", Names_Of ("Alpha.md", "Zeta.md")));
      Result.Append (Make ("b/two.wdg", Names_Of ("Beta.md")));
      Result.Append (Make ("c/three.wdg", Names_Of ("Alpha.md")));
      Result.Append
        (Make ("d/four.wdg", Names_Of ("Alpha.md", "Beta.md", "Zeta.md")));
      return Result;
   end Several;

   procedure One_Entry_Encodes_To_Exactly_The_Documented_Bytes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bytes : constant String := Encode (One, Unassigned_Of ("u.wdg"));
      Crc   : GNAT.CRC32.CRC32;

      function Hex (First, Last : Positive) return String is
        (Test_Bytes.To_Hex (Bytes (First .. Last)));
   begin
      --  64 header, 15 record, 5 path, 4 ids, 6 node table, 4 name, 6 list.
      Assert (Bytes'Length = 104, "the length");
      Assert
        (Bytes (1 .. 8) = "SYNIDX" & Character'Val (0) & Character'Val (0),
         "magic");
      Assert (Hex (9, 12) = "01000000", "version 1");
      Assert (Hex (13, 16) = "01000000", "one entry");
      Assert (Hex (17, 20) = "01000000", "one node");
      Assert (Hex (21, 24) = "01000000", "one unassigned path");
      Assert (Hex (25, 32) = "4f00000000000000", "paths_off 79");
      Assert (Hex (33, 40) = "5400000000000000", "ids_off 84");
      Assert (Hex (41, 48) = "5800000000000000", "nodes_off 88");
      Assert (Hex (49, 56) = "6200000000000000", "unassigned_off 98");
      Assert (Hex (61, 64) = "00000000", "reserved");
      Assert (Hex (65, 72) = "0000000000000000", "path_off");
      Assert (Hex (73, 74) = "0500", "path_len");
      Assert (Hex (75, 78) = "00000000", "ids_at");
      Assert (Hex (79, 79) = "01", "ids_len");
      Assert (Bytes (80 .. 84) = "a.wdg", "the path");
      Assert (Hex (85, 88) = "00000000", "the node number");
      Assert (Hex (89, 94) = "000000000400", "the node: offset 0, length 4");
      Assert (Bytes (95 .. 98) = "N.md", "its name");
      Assert (Bytes (99 .. 104) = "u.wdg" & LF, "the unassigned path");
      GNAT.CRC32.Initialize (Crc);
      GNAT.CRC32.Update (Crc, Bytes (65 .. 104));
      Assert
        (Get_U32 (Bytes, 57) = U32 (GNAT.CRC32.Get_Value (Crc)),
         "the checksum covers everything after the header");
   end One_Entry_Encodes_To_Exactly_The_Documented_Bytes;

   function Parsed_Head (Src : in out Memory.Source) return Header is
     (Parse (Src).Head);

   procedure Many_Entries_Round_Trip_With_Multi_Node_Paths
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : constant Entry_Vectors.Vector := Several;
      Src     : Memory.Source := Memory.Create (Encode (Entries, No_Paths));
      H       : constant Header               := Parsed_Head (Src);
      Back    : constant Decoded              := Decode (Src, H);
   begin
      Assert
        (H.Entry_Count = 4 and then H.Node_Count = 3,
         "four paths, three nodes");
      Assert (Natural (Back.Entries.Length) = 4, "decoded");
      for I in 1 .. 4 loop
         Assert (Back.Entries (I).Path = Entries (I).Path, "path");
         Assert
           (Natural (Back.Entries (I).Nodes.Length) =
            Natural (Entries (I).Nodes.Length),
            "node count");
         for K in 1 .. Natural (Entries (I).Nodes.Length) loop
            Assert
              (Back.Entries (I).Nodes (K) = Entries (I).Nodes (K),
               "node order intact");
         end loop;
      end loop;
      Assert (Back.Unassigned.Is_Empty, "no unassigned");
   end Many_Entries_Round_Trip_With_Multi_Node_Paths;

   procedure Unassigned_Is_A_Separate_List_In_The_Order_Given
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Src  : Memory.Source              :=
        Memory.Create (Encode (One, Names_Of ("z.wdg", "a.wdg", "m.wdg")));
      H    : constant Header            := Parsed_Head (Src);
      List : constant Text_Lists.Vector := Unassigned (Src, H);
   begin
      Assert (H.Unassigned_Count = 3 and then H.Entry_Count = 1, "counts");
      Assert
        (To_String (List (1)) = "z.wdg" and then To_String (List (2)) = "a.wdg"
         and then To_String (List (3)) = "m.wdg",
         "stored as given, not sorted");
   end Unassigned_Is_A_Separate_List_In_The_Order_Given;

   procedure Lookup_Is_A_Binary_Search_And_A_Miss_Is_A_Miss
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
   begin
      for Path of Names_Of ("a", "c", "e") loop
         Entries.Append (Make (To_String (Path), Names_Of ("N")));
      end loop;
      Entries.Append (Make ("g", Names_Of ("N", "O")));
      Entries.Append (Make ("i", Names_Of ("O")));
      declare
         Src : Memory.Source   := Memory.Create (Encode (Entries, No_Paths));
         H   : constant Header := Parsed_Head (Src);

         function At_Of (Path : String) return Integer is
            Got : constant Maybe_Index := Find (Src, H, Path);
         begin
            return (if Got.Found then Got.Index else -1);
         end At_Of;

         function Node_At (Name : String) return Integer is
            Got : constant Maybe_Index := Find_Node (Src, H, Name);
         begin
            return (if Got.Found then Got.Index else -1);
         end Node_At;
      begin
         Assert
           (At_Of ("a") = 0 and then At_Of ("e") = 2 and then At_Of ("i") = 4,
            "first, middle, last");
         Assert
           (At_Of ("0") = -1 and then At_Of ("d") = -1
            and then At_Of ("z") = -1 and then At_Of ("") = -1,
            "misses");
         Assert (Node_At ("N") = 0 and then Node_At ("O") = 1, "nodes");
         Assert (Node_At ("M") = -1 and then Node_At ("P") = -1, "no node");
         Assert
           (Natural (Nodes_Of (Src, H, Record_At (Src, H, 3)).Length) = 2,
            "a path with two nodes");
      end;
   end Lookup_Is_A_Binary_Search_And_A_Miss_Is_A_Miss;

   procedure An_Empty_Index_And_One_Of_Only_Unassigned_Are_Valid
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      None : Entry_Vectors.Vector;
   begin
      declare
         Bytes : constant String := Encode (None, No_Paths);
      begin
         Assert (Bytes'Length = 64, "just a header");
         Assert (Error_Of (Bytes) = "ok", "valid");
      end;
      declare
         Src : Memory.Source   :=
           Memory.Create (Encode (None, Names_Of ("a", "b")));
         H   : constant Header := Parsed_Head (Src);
      begin
         Assert
           (H.Entry_Count = 0 and then H.Unassigned_Count = 2,
            "only unassigned paths");
         Assert (not Find (Src, H, "a").Found, "none of them is a record");
      end;
   end An_Empty_Index_And_One_Of_Only_Unassigned_Are_Valid;

   procedure Bad_Input_Is_Refused_And_Not_Encoded (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      function Refused
        (Entries : Entry_Vectors.Vector; Listed : Text_Lists.Vector)
         return String
      is
      begin
         declare
            Ignore : constant String := Encode (Entries, Listed);
         begin
            return "accepted";
         end;
      exception
         when Unsorted                =>
            return "Unsorted";
         when Unsorted_Nodes          =>
            return "Unsorted_Nodes";
         when No_Nodes                =>
            return "No_Nodes";
         when Path_Too_Long           =>
            return "Path_Too_Long";
         when Node_Name_Too_Long      =>
            return "Node_Name_Too_Long";
         when Path_Contains_Newline   =>
            return "Path_Contains_Newline";
         when Too_Many_Nodes_For_Path =>
            return "Too_Many_Nodes_For_Path";
      end Refused;

      Entries : Entry_Vectors.Vector;
   begin
      Entries.Append (Make ("b", Names_Of ("N")));
      Entries.Append (Make ("a", Names_Of ("N")));
      Assert (Refused (Entries, No_Paths) = "Unsorted", "paths out of order");
      Entries.Clear;
      Entries.Append (Make ("a", Names_Of ("N")));
      Entries.Append (Make ("a", Names_Of ("N")));
      Assert (Refused (Entries, No_Paths) = "Unsorted", "a repeated path");
      Entries.Clear;
      Entries.Append (Make ("a", Names_Of ("Z", "A")));
      Assert
        (Refused (Entries, No_Paths) = "Unsorted_Nodes", "nodes out of order");
      Entries.Clear;
      Entries.Append (Make ("a", Names_Of ("A", "A")));
      Assert
        (Refused (Entries, No_Paths) = "Unsorted_Nodes", "a repeated node");
      Entries.Clear;
      Entries.Append (Make ("a", Names_Of));
      Assert
        (Refused (Entries, No_Paths) = "No_Nodes",
         "a record with no owner: unassigned says it better");
      Assert
        (Refused (One, Names_Of ("a" & LF & "b")) = "Path_Contains_Newline",
         "a line feed in an unassigned path");
      Entries.Clear;
      Entries.Append (Make ([1 .. 65_536 => 'p'], Names_Of ("N")));
      Assert (Refused (Entries, No_Paths) = "Path_Too_Long", "a long path");
      Entries.Clear;
      Entries.Append (Make ("a", Names_Of ([1 .. 65_536 => 'n'])));
      Assert
        (Refused (Entries, No_Paths) = "Node_Name_Too_Long",
         "a long node name");
      declare
         Many : Text_Lists.Vector;
      begin
         for I in 1 .. 256 loop
            declare
               Image : constant String := Integer'Image (1_000 + I);
            begin
               Many.Append
                 (To_Unbounded_String
                    ("n" & Image (Image'First + 1 .. Image'Last)));
            end;
         end loop;
         Entries.Clear;
         Entries.Append (Make ("a", Many));
         Assert
           (Refused (Entries, No_Paths) = "Too_Many_Nodes_For_Path",
            "256 claimants");
         Many.Delete_Last;
         Entries.Clear;
         Entries.Append (Make ("a", Many));
         Assert (Refused (Entries, No_Paths) = "accepted", "255 are the most");
      end;
   end Bad_Input_Is_Refused_And_Not_Encoded;

   procedure A_Bumped_Version_Or_A_Foreign_File_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bytes : String := Encode (One, No_Paths);
   begin
      Bytes (9) := Character'Val (2);
      Assert (Error_Of (Bytes) = "VERSION_MISMATCH", "version 2");
      Assert (Error_Of ("") = "TRUNCATED", "empty");
      Assert (Error_Of ("SYNIDX") = "TRUNCATED", "shorter than a header");
      Assert
        (Error_Of ("{""a.wdg"": [""N.md""]}" & [1 .. 60 => ' ']) =
         "NOT_AN_INDEX",
         "the JSON this replaced");
      declare
         Good    : constant String := Encode (One, No_Paths);
         Flipped : String          := Good;
      begin
         Flipped (80) := 'Z';
         Assert
           (Error_Of (Flipped) = "CHECKSUM_MISMATCH",
            "a flipped bit anywhere after the header");
         Flipped      := Good;
         Flipped (95) := 'Q';
         Assert
           (Error_Of (Flipped) = "CHECKSUM_MISMATCH",
            "even in a node name: nothing is left unprotected");
      end;
   end A_Bumped_Version_Or_A_Foreign_File_Is_Refused;

   procedure A_Table_Longer_Than_The_File_Is_Truncated
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bad : String := Encode (One, No_Paths);
   begin
      Bad (13 .. 16) := Put_U32 (1_000_000);
      Assert
        (Error_Of (With_Crc (Bad)) = "TRUNCATED", "more entries than bytes");
   end A_Table_Longer_Than_The_File_Is_Truncated;

   procedure Offsets_And_Numbers_Pointing_Nowhere_Are_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Good : constant String := Encode (One, Names_Of ("u.wdg"));
      Bad  : String          := Good;
   begin
      Bad (73 .. 74) := Put_U16 (200);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "path_len past the path region");
      Bad            := Good;
      Bad (65 .. 72) := Put_U64 (U64'Last - 1);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "a path_off that overflows the arithmetic");
      Bad            := Good;
      Bad (75 .. 78) := Put_U32 (5);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "node-id slots past the region");
      Bad      := Good;
      Bad (79) := Character'Val (0);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "a record with no node");
      Bad            := Good;
      Bad (85 .. 88) := Put_U32 (7);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "a node number naming no node");
      Bad (85 .. 88) := Put_U32 (1);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "a node number one past the last node");
      Bad            := Good;
      Bad (93 .. 94) := Put_U16 (60);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "a node name past its region");
      Bad            := Good;
      Bad (25 .. 32) := Put_U64 (70);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "paths_off inside the table");
      Bad            := Good;
      Bad (49 .. 56) := Put_U64 (500);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "unassigned_off past the file");
      Bad            := Good;
      Bad (49 .. 56) := Put_U64 (60);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "regions out of order");
   end Offsets_And_Numbers_Pointing_Nowhere_Are_Refused;

   procedure An_Unassigned_Region_That_Disagrees_With_Its_Count_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Good : constant String := Encode (One, Names_Of ("u.wdg"));
      Bad  : String          := Good;
   begin
      Bad (21 .. 24) := Put_U32 (2);
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "a count of two for one path");
      Bad            := Good;
      Bad (Bad'Last) := 'x';
      Assert
        (Error_Of (With_Crc (Bad)) = "OFFSET_OUT_OF_RANGE",
         "an entry the line feed does not end");
      Assert
        (Error_Of (With_Crc (Good & "tail")) = "OFFSET_OUT_OF_RANGE",
         "unterminated text after the counted entries");
   end An_Unassigned_Region_That_Disagrees_With_Its_Count_Is_Refused;

   procedure Duplicate_Or_Misordered_Names_And_Paths_Are_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Two : Entry_Vectors.Vector;
   begin
      Two.Append (Make ("a", Names_Of ("N", "O")));
      Two.Append (Make ("b", Names_Of ("N")));
      declare
         Good : constant String := Encode (Two, No_Paths);
         Same : String          := Good;
         Back : String          := Good;
      begin
         --  The path region follows the table: "a" then "b".
         Same (64 + 2 * 15 + 2) := 'a';
         Assert
           (Error_Of (With_Crc (Same)) = "OFFSET_OUT_OF_RANGE",
            "two records with one path");
         Back (64 + 2 * 15 + 1) := 'c';
         Assert
           (Error_Of (With_Crc (Back)) = "OFFSET_OUT_OF_RANGE",
            "paths out of order");
         --  The node names follow the node table: "N" then "O".
         declare
            Names_At : constant Natural :=
              Natural (Get_U64 (Good, 41)) + 2 * Node_Size;
            Twin     : String           := Good;
         begin
            Twin (Names_At + 2) := 'N';
            Assert
              (Error_Of (With_Crc (Twin)) = "OFFSET_OUT_OF_RANGE",
               "two nodes with one name");
         end;
      end;
   end Duplicate_Or_Misordered_Names_And_Paths_Are_Refused;

   function Fixture return String is
     (Test_Bytes.From_Hex

        ("53594e4944580000010000000200000002000000020000005e0000000000" &
         "0000770000000000000083000000000000009f00000000000000d2c3bbac" &
         "0000000000000000000000000d0000000000020d000000000000000c0002" &
         "000000017372632f616c7068612e7764677372632f626574612e77646700" &
         "0000000100000000000000000000000900090000000700456e67696e652e" &
         "6d645a6574612e6d64646f63732f726561646d652e6d640a6e6f7465732e" &
         "7478740a"));

   procedure Encode_Reproduces_The_Independent_Fixture_Byte_For_Byte
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Entries : Entry_Vectors.Vector;
   begin
      Entries.Append
        (Make ("src/alpha.wdg", Names_Of ("Engine.md", "Zeta.md")));
      Entries.Append (Make ("src/beta.wdg", Names_Of ("Engine.md")));
      Assert
        (Test_Bytes.To_Hex
           (Encode (Entries, Names_Of ("docs/readme.md", "notes.txt"))) =
         Test_Bytes.To_Hex (Fixture),
         "generated from the layout by a separate implementation");
   end Encode_Reproduces_The_Independent_Fixture_Byte_For_Byte;

   procedure The_Fixture_Decodes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Src : Memory.Source         := Memory.Create (Fixture);
      Got : constant Parse_Result := Parse (Src);
   begin
      Assert (Got.Ok, "parses");
      declare
         H    : constant Header  := Got.Head;
         Back : constant Decoded := Decode (Src, H);
      begin
         Assert
           (H.Entry_Count = 2 and then H.Node_Count = 2
            and then H.Unassigned_Count = 2,
            "counts");
         Assert
           (To_String (Back.Entries (1).Path) = "src/alpha.wdg"
            and then To_String (Back.Entries (1).Nodes (2)) = "Zeta.md",
            "the first path and its second node");
         Assert (To_String (Back.Unassigned (2)) = "notes.txt", "unassigned");
         Assert (Find_Node (Src, H, "Zeta.md").Index = 1, "a node by name");
      end;
   end The_Fixture_Decodes;

   package Draw is new Ada.Numerics.Discrete_Random (Natural);

   procedure Random_Indexes_Survive_Byte_For_Byte (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Gen : Draw.Generator;

      function Pick (Limit : Positive) return Natural is
        (Draw.Random (Gen) mod Limit);

      function Name (Prefix : Character; N : Natural) return String is
         Image : constant String := Integer'Image (1_000 + N);
      begin
         return Prefix & Image (Image'First + 1 .. Image'Last);
      end Name;
   begin
      Draw.Reset (Gen, 31);
      for Round in 1 .. 80 loop
         declare
            Entries          : Entry_Vectors.Vector;
            Unassigned_Paths : Text_Lists.Vector;
         begin
            for I in 1 .. Pick (12) loop
               declare
                  Nodes : Text_Lists.Vector;
                  Next  : Natural := Pick (3);
               begin
                  for K in 1 .. 1 + Pick (4) loop
                     Nodes.Append (To_Unbounded_String (Name ('n', Next)));
                     Next := Next + 1 + Pick (3);
                  end loop;
                  Entries.Append (Make (Name ('p', I) & "/f", Nodes));
               end;
            end loop;
            for I in 1 .. Pick (5) loop
               Unassigned_Paths.Append
                 (To_Unbounded_String (Name ('u', Pick (50))));
            end loop;
            declare
               Src : Memory.Source         :=
                 Memory.Create (Encode (Entries, Unassigned_Paths));
               Got : constant Parse_Result := Parse (Src);
            begin
               Assert (Got.Ok, "parses");
               declare
                  Back : constant Decoded := Decode (Src, Got.Head);
               begin
                  Assert
                    (Natural (Back.Entries.Length) = Natural (Entries.Length),
                     "paths");
                  for I in 1 .. Natural (Entries.Length) loop
                     Assert (Back.Entries (I).Path = Entries (I).Path, "path");
                     Assert
                       (Natural (Back.Entries (I).Nodes.Length) =
                        Natural (Entries (I).Nodes.Length),
                        "node count");
                     for K in 1 .. Natural (Entries (I).Nodes.Length) loop
                        Assert
                          (Back.Entries (I).Nodes (K) = Entries (I).Nodes (K),
                           "node");
                     end loop;
                     Assert
                       (Find (Src, Got.Head, To_String (Entries (I).Path))
                          .Index =
                        I - 1,
                        "found");
                  end loop;
                  Assert
                    (Natural (Back.Unassigned.Length) =
                     Natural (Unassigned_Paths.Length),
                     "unassigned");
               end;
            end;
         end;
      end loop;
   end Random_Indexes_Survive_Byte_For_Byte;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Index_Map_Format");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, One_Entry_Encodes_To_Exactly_The_Documented_Bytes'Access,
         "One entry encodes to exactly the documented bytes");
      Register_Routine
        (T, Many_Entries_Round_Trip_With_Multi_Node_Paths'Access,
         "Many entries round-trip with multi-node paths");
      Register_Routine
        (T, Unassigned_Is_A_Separate_List_In_The_Order_Given'Access,
         "Unassigned is a separate list in the order given");
      Register_Routine
        (T, Lookup_Is_A_Binary_Search_And_A_Miss_Is_A_Miss'Access,
         "Lookup is a binary search and a miss is a miss");
      Register_Routine
        (T, An_Empty_Index_And_One_Of_Only_Unassigned_Are_Valid'Access,
         "An empty index and one of only unassigned paths are valid");
      Register_Routine
        (T, Bad_Input_Is_Refused_And_Not_Encoded'Access,
         "Bad input is refused and not encoded");
      Register_Routine
        (T, A_Bumped_Version_Or_A_Foreign_File_Is_Refused'Access,
         "A bumped version or a foreign file is refused");
      Register_Routine
        (T, A_Table_Longer_Than_The_File_Is_Truncated'Access,
         "A table longer than the file is truncated");
      Register_Routine
        (T, Offsets_And_Numbers_Pointing_Nowhere_Are_Refused'Access,
         "Offsets and numbers pointing nowhere are refused");
      Register_Routine
        (T,
         An_Unassigned_Region_That_Disagrees_With_Its_Count_Is_Refused'Access,
         "An unassigned region that disagrees with its count is refused");
      Register_Routine
        (T, Duplicate_Or_Misordered_Names_And_Paths_Are_Refused'Access,
         "Duplicate or misordered names and paths are refused");
      Register_Routine
        (T, Encode_Reproduces_The_Independent_Fixture_Byte_For_Byte'Access,
         "Encode reproduces the independent fixture byte for byte");
      Register_Routine (T, The_Fixture_Decodes'Access, "The fixture decodes");
      Register_Routine
        (T, Random_Indexes_Survive_Byte_For_Byte'Access,
         "Random indexes survive byte for byte");
   end Register_Tests;

end Synapse.Core.Index_Map_Format.Tests;
