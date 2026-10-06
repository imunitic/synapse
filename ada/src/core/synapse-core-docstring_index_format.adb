with GNAT.CRC32;

with Synapse.Core.Byte_Window;

package body Synapse.Core.Docstring_Index_Format is

   use Ports.Byte_Source;
   use type Interfaces.Unsigned_64;

   Longest_Path : constant := 65_535;
   Longest_Name : constant := 65_535;
   Longest_Kind : constant := 255;

   function Clamped (Value : Natural) return U32 is (U32 (Value));

   function Natural_Of (Value : U32) return Natural is
     (if Value > U32 (Natural'Last) then Natural'Last else Natural (Value));

   function Digest_Bytes (Value : Hashing.Digest) return String is
      Result : String (1 .. 32);
   begin
      for I in Result'Range loop
         Result (I) := Character'Val (Value (I));
      end loop;
      return Result;
   end Digest_Bytes;

   function Digest_Of (Bytes : String) return Hashing.Digest is
      Result : Hashing.Digest;
   begin
      for I in Result'Range loop
         Result (I) := Character'Pos (Bytes (Bytes'First + I - 1));
      end loop;
      return Result;
   end Digest_Of;

   --  Strictly: whether the first key sorts before the second.
   function Before
     (A_Path, A_Name, A_Kind, B_Path, B_Name, B_Kind : String)
      return Boolean is
     (if A_Path /= B_Path then A_Path < B_Path
      elsif A_Name /= B_Name then A_Name < B_Name else A_Kind < B_Kind);

   function Encode (Entries : Entry_Vectors.Vector) return String is
      Count          : constant Natural := Natural (Entries.Length);
      Strings_Length : Natural          := 0;
   begin
      for I in 1 .. Count loop
         declare
            Item : Entry_Type renames Entries (I);
         begin
            if Length (Item.Path) > Longest_Path then
               raise Path_Too_Long;
            end if;
            if Length (Item.Name) > Longest_Name then
               raise Name_Too_Long;
            end if;
            if Length (Item.Kind) > Longest_Kind then
               raise Kind_Too_Long;
            end if;
            if I > 1
              and then not Before
                (To_String (Entries (I - 1).Path),
                 To_String (Entries (I - 1).Name),
                 To_String (Entries (I - 1).Kind), To_String (Item.Path),
                 To_String (Item.Name), To_String (Item.Kind))
            then
               raise Unsorted;
            end if;
            Strings_Length :=
              Strings_Length + Length (Item.Path) + Length (Item.Name) +
              Length (Item.Kind);
         end;
      end loop;

      declare
         Strings_Off : constant Natural := Header_Size + Count * Record_Size;
         Total       : constant Natural    := Strings_Off + Strings_Length;
         Bytes       : String (1 .. Total) := [others => Character'Val (0)];
         At_String   : Natural             := 0;
      begin
         for I in 1 .. Count loop
            declare
               Item  : Entry_Type renames Entries (I);
               Path  : constant String  := To_String (Item.Path);
               Name  : constant String  := To_String (Item.Name);
               Kind  : constant String  := To_String (Item.Kind);
               Where : constant Natural :=
                 Header_Size + (I - 1) * Record_Size + 1;
            begin
               Bytes (Where .. Where + Record_Size - 1) :=
                 Put_U64 (U64 (At_String)) & Put_U16 (U16 (Path'Length)) &
                 Put_U64 (U64 (At_String + Path'Length)) &
                 Put_U16 (U16 (Name'Length)) &
                 Put_U64 (U64 (At_String + Path'Length + Name'Length)) &
                 Character'Val (Kind'Length) &
                 Digest_Bytes (Item.Docstring_Hash) &
                 Digest_Bytes (Item.Decl_Hash) &
                 Put_U32 (Clamped (Item.Docstring_Start)) &
                 Put_U32 (Clamped (Item.Docstring_End)) &
                 Put_U32 (Clamped (Item.Decl_Start)) &
                 Put_U32 (Clamped (Item.Decl_End));
               Bytes
                 (Strings_Off + At_String + 1 ..
                      Strings_Off + At_String + Path'Length + Name'Length +
                      Kind'Length)                      :=
                 Path & Name & Kind;
               At_String                                :=
                 At_String + Path'Length + Name'Length + Kind'Length;
            end;
         end loop;

         declare
            Crc : GNAT.CRC32.CRC32;
         begin
            GNAT.CRC32.Initialize (Crc);
            GNAT.CRC32.Update (Crc, Bytes (Header_Size + 1 .. Total));
            Bytes (1 .. Header_Size) :=
              Magic & Put_U32 (Version) & Put_U32 (U32 (Count)) &
              Put_U64 (U64 (Strings_Off)) &
              Put_U32 (U32 (GNAT.CRC32.Get_Value (Crc))) & Put_U32 (0);
         end;
         return Bytes;
      end;
   end Encode;

   function Header_Of (Bytes : String) return Header is
     (Version     => Get_U32 (Bytes, Bytes'First + 8),
      Entry_Count => Get_U32 (Bytes, Bytes'First + 12),
      Strings_Off => Get_U64 (Bytes, Bytes'First + 16),
      Crc32       => Get_U32 (Bytes, Bytes'First + 24));

   function Record_Of (Bytes : String) return Table_Record is
     (Path_Off        => Get_U64 (Bytes, Bytes'First),
      Path_Len        => Natural (Get_U16 (Bytes, Bytes'First + 8)),
      Name_Off        => Get_U64 (Bytes, Bytes'First + 10),
      Name_Len        => Natural (Get_U16 (Bytes, Bytes'First + 18)),
      Kind_Off        => Get_U64 (Bytes, Bytes'First + 20),
      Kind_Len        => Character'Pos (Bytes (Bytes'First + 28)),
      Docstring_Hash  =>
        Digest_Of (Bytes (Bytes'First + 29 .. Bytes'First + 60)),
      Decl_Hash => Digest_Of (Bytes (Bytes'First + 61 .. Bytes'First + 92)),
      Docstring_Start => Get_U32 (Bytes, Bytes'First + 93),
      Docstring_End   => Get_U32 (Bytes, Bytes'First + 97),
      Decl_Start      => Get_U32 (Bytes, Bytes'First + 101),
      Decl_End        => Get_U32 (Bytes, Bytes'First + 105));

   procedure Add (A, B : U64; Sum : out U64; Overflow : out Boolean) is
   begin
      Overflow := A > U64'Last - B;
      Sum      := (if Overflow then 0 else A + B);
   end Add;

   function Record_At
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Index  :        Natural) return Table_Record
   is
      pragma Unreferenced (Head);
   begin
      return
        Record_Of
          (Source.Read
             (Offset (Header_Size) + Offset (Index) * Record_Size,
              Record_Size));
   end Record_At;

   function String_At
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Where  :        U64; Length : Natural) return String
   is
   begin
      if Length = 0 then
         return "";
      end if;
      return Source.Read (Offset (Head.Strings_Off) + Offset (Where), Length);
   end String_At;

   function Path_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String is
     (String_At (Source, Head, Item.Path_Off, Item.Path_Len));

   function Name_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String is
     (String_At (Source, Head, Item.Name_Off, Item.Name_Len));

   function Kind_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String is
     (String_At (Source, Head, Item.Kind_Off, Item.Kind_Len));

   function Entry_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return Entry_Type is
     (Path            => To_Unbounded_String (Path_Of (Source, Head, Item)),
      Name            => To_Unbounded_String (Name_Of (Source, Head, Item)),
      Kind            => To_Unbounded_String (Kind_Of (Source, Head, Item)),
      Docstring_Hash  => Item.Docstring_Hash, Decl_Hash => Item.Decl_Hash,
      Docstring_Start => Natural_Of (Item.Docstring_Start),
      Docstring_End   => Natural_Of (Item.Docstring_End),
      Decl_Start      => Natural_Of (Item.Decl_Start),
      Decl_End        => Natural_Of (Item.Decl_End));

   function Find
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Path   :        String; Name : String; Kind : String) return Maybe_Index
   is
      Low  : Natural := 0;
      High : Natural := Natural (Head.Entry_Count);
   begin
      while Low < High loop
         declare
            Mid  : constant Natural      := Low + (High - Low) / 2;
            Item : constant Table_Record := Record_At (Source, Head, Mid);
            P    : constant String       := Path_Of (Source, Head, Item);
            N    : constant String       := Name_Of (Source, Head, Item);
            K    : constant String       := Kind_Of (Source, Head, Item);
         begin
            if Before (P, N, K, Path, Name, Kind) then
               Low := Mid + 1;
            elsif Before (Path, Name, Kind, P, N, K) then
               High := Mid;
            else
               return (Found => True, Index => Mid);
            end if;
         end;
      end loop;
      return (Found => False);
   end Find;

   function Path_Range
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Path   :        String) return Range_Of_Entries
   is
      Low  : Natural := 0;
      High : Natural := Natural (Head.Entry_Count);
      From : Natural;
   begin
      while Low < High loop
         declare
            Mid : constant Natural := Low + (High - Low) / 2;
         begin
            if Path_Of (Source, Head, Record_At (Source, Head, Mid)) < Path
            then
               Low := Mid + 1;
            else
               High := Mid;
            end if;
         end;
      end loop;
      From := Low;
      High := Natural (Head.Entry_Count);
      while Low < High loop
         declare
            Mid : constant Natural := Low + (High - Low) / 2;
         begin
            if Path_Of (Source, Head, Record_At (Source, Head, Mid)) > Path
            then
               High := Mid;
            else
               Low := Mid + 1;
            end if;
         end;
      end loop;
      return (From => From, To => Low);
   end Path_Range;

   function Parse
     (Source : in out Ports.Byte_Source.Source'Class) return Parse_Result
   is
      Size : constant Offset := Source.Size;

      function Fail (Why : Parse_Error) return Parse_Result is
        ((Ok => False, Error => Why));
   begin
      if Size < Header_Size then
         return Fail (Truncated);
      end if;
      declare
         Raw : constant String := Source.Read (0, Header_Size);
      begin
         if Raw (Raw'First .. Raw'First + 7) /= Magic then
            return Fail (Not_A_Cache);
         end if;
         declare
            Head      : constant Header := Header_Of (Raw);
            Table_End : constant U64    :=
              U64 (Header_Size) + U64 (Head.Entry_Count) * Record_Size;
         begin
            if Head.Version /= Version then
               return Fail (Version_Mismatch);
            end if;
            if Table_End > U64 (Size) then
               return Fail (Truncated);
            end if;
            if Head.Strings_Off > U64 (Size)
              or else Head.Strings_Off < Table_End
            then
               return Fail (Offset_Out_Of_Range);
            end if;

            declare
               Crc  : GNAT.CRC32.CRC32;
               Here : Offset := Header_Size;
            begin
               GNAT.CRC32.Initialize (Crc);
               while Here < Size loop
                  declare
                     Chunk : constant String :=
                       Source.Read
                         (Here,
                          Positive'Min
                            (Byte_Window.Default_Block * 16,
                              Positive (Size - Here)));
                  begin
                     exit when Chunk'Length = 0;
                     GNAT.CRC32.Update (Crc, Chunk);
                     Here := Here + Offset (Chunk'Length);
                  end;
               end loop;
               if U32 (GNAT.CRC32.Get_Value (Crc)) /= Head.Crc32 then
                  return Fail (Checksum_Mismatch);
               end if;
            end;

            declare
               Region : constant U64 := U64 (Size) - Head.Strings_Off;
               Table                  : Byte_Window.Window;
               Text                   : Byte_Window.Window;
               Last_P, Last_N, Last_K : Unbounded_String;
            begin
               for I in 0 .. Natural (Head.Entry_Count) - 1 loop
                  declare
                     Item                         : constant Table_Record :=
                       Record_Of
                         (Byte_Window.Read
                            (Table, Source,
                             Offset (Header_Size) + Offset (I) * Record_Size,
                             Record_Size));
                     Path_End, Name_End, Kind_End : U64;
                     Overflow                     : Boolean;
                     Bad                          : Boolean := False;
                  begin
                     Add
                       (Item.Path_Off, U64 (Item.Path_Len), Path_End,
                        Overflow);
                     Bad := Overflow or else Path_End > Region;
                     Add
                       (Item.Name_Off, U64 (Item.Name_Len), Name_End,
                        Overflow);
                     Bad := Bad or else Overflow or else Name_End > Region;
                     Add
                       (Item.Kind_Off, U64 (Item.Kind_Len), Kind_End,
                        Overflow);
                     Bad := Bad or else Overflow or else Kind_End > Region;
                     if Bad then
                        return Fail (Offset_Out_Of_Range);
                     end if;
                     declare
                        function Part
                          (Where : U64; Length : Natural) return String is
                          (if Length = 0 then ""
                           else Byte_Window.Read
                               (Text, Source,
                                Offset (Head.Strings_Off) + Offset (Where),
                                Length));
                        P : constant String :=
                          Part (Item.Path_Off, Item.Path_Len);
                        N : constant String :=
                          Part (Item.Name_Off, Item.Name_Len);
                        K : constant String :=
                          Part (Item.Kind_Off, Item.Kind_Len);
                     begin
                        if I > 0
                          and then not Before
                            (To_String (Last_P), To_String (Last_N),
                             To_String (Last_K), P, N, K)
                        then
                           return Fail (Offset_Out_Of_Range);
                        end if;
                        Last_P := To_Unbounded_String (P);
                        Last_N := To_Unbounded_String (N);
                        Last_K := To_Unbounded_String (K);
                     end;
                  end;
               end loop;
            end;
            return (Ok => True, Head => Head);
         end;
      end;
   end Parse;

end Synapse.Core.Docstring_Index_Format;
