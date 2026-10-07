with GNAT.CRC32;

with Synapse.Core.Byte_Window;

package body Synapse.Core.Tags_Cache_Format is

   use Ports.Byte_Source;
   use type Interfaces.Unsigned_64;

   Longest_Path : constant := 65_535;

   function Hash_Of (Bytes : String) return Graph_Model.Hash is
      Result : Graph_Model.Hash;
   begin
      for I in Result'Range loop
         Result (I) := Character'Pos (Bytes (Bytes'First + I - 1));
      end loop;
      return Result;
   end Hash_Of;

   function Hash_Bytes (Value : Graph_Model.Hash) return String is
      Result : String (1 .. 20);
   begin
      for I in Result'Range loop
         Result (I) := Character'Val (Value (I));
      end loop;
      return Result;
   end Hash_Bytes;

   function Record_Bytes
     (Path_Off : U64; Item : Sized_Entry; Tags_Off : U64) return String is
     (Put_U64 (Path_Off) & Put_U16 (U16 (Length (Item.Path))) &
      Hash_Bytes (Item.Hash) & Put_U64 (Tags_Off) &
      Put_U32 (U32 (Item.Tags_Length)) &
      Character'Val (if Item.Unsupported then Flag_Unsupported else 0));

   function Encode_Prefix (Entries : Sized_Vectors.Vector) return String is
      Paths_Length : Natural          := 0;
      Count        : constant Natural := Natural (Entries.Length);
   begin
      for I in 1 .. Count loop
         declare
            Path : constant String := To_String (Entries (I).Path);
         begin
            if Path'Length > Longest_Path then
               raise Path_Too_Long;
            end if;
            if I > 1 and then not (To_String (Entries (I - 1).Path) < Path)
            then
               raise Unsorted;
            end if;
            Paths_Length := Paths_Length + Path'Length;
         end;
      end loop;

      declare
         Paths_Off : constant Natural := Header_Size + Count * Record_Size;
         Blob_Off  : constant Natural       := Paths_Off + Paths_Length;
         Prefix    : String (1 .. Blob_Off) := [others => Character'Val (0)];
         Path_At   : Natural                := 0;
         Tags_At   : Long_Long_Integer      := 0;
      begin
         for I in 1 .. Count loop
            declare
               Item  : Sized_Entry renames Entries (I);
               Path  : constant String  := To_String (Item.Path);
               Where : constant Natural :=
                 Header_Size + (I - 1) * Record_Size + 1;
            begin
               Prefix (Where .. Where + Record_Size - 1) :=
                 Record_Bytes (U64 (Path_At), Item, U64 (Tags_At));
               Prefix
                 (Paths_Off + Path_At + 1 ..
                      Paths_Off + Path_At + Path'Length) :=
                 Path;
               Path_At := Path_At + Path'Length;
               Tags_At := Tags_At + Long_Long_Integer (Item.Tags_Length);
            end;
         end loop;

         declare
            Crc : GNAT.CRC32.CRC32;
         begin
            GNAT.CRC32.Initialize (Crc);
            GNAT.CRC32.Update (Crc, Prefix (Header_Size + 1 .. Blob_Off));
            Prefix (1 .. Header_Size) :=
              Magic & Put_U32 (Version) & Put_U32 (U32 (Count)) &
              Put_U64 (U64 (Paths_Off)) & Put_U64 (U64 (Blob_Off)) &
              Put_U32 (U32 (GNAT.CRC32.Get_Value (Crc))) & Put_U32 (0);
         end;
         return Prefix;
      end;
   end Encode_Prefix;

   function Encode_Prefix (Entries : Entry_Vectors.Vector) return String is
      Sized : Sized_Vectors.Vector;
   begin
      for Item of Entries loop
         Sized.Append
           (Sized_Entry'
              (Path        => Item.Path, Hash => Item.Hash,
               Tags_Length => Length (Item.Tags),
               Unsupported => Item.Unsupported));
      end loop;
      return Encode_Prefix (Sized);
   end Encode_Prefix;

   function Encode (Entries : Entry_Vectors.Vector) return String is
      Result : Unbounded_String :=
        To_Unbounded_String (Encode_Prefix (Entries));
   begin
      for Item of Entries loop
         Append (Result, Item.Tags);
      end loop;
      return To_String (Result);
   end Encode;

   --  A + B, or None on overflow.
   procedure Add (A, B : U64; Sum : out U64; Overflow : out Boolean) is
   begin
      Overflow := A > U64'Last - B;
      Sum      := (if Overflow then 0 else A + B);
   end Add;

   function Header_Of (Bytes : String) return Header is
     (Version     => Get_U32 (Bytes, Bytes'First + 8),
      Entry_Count => Get_U32 (Bytes, Bytes'First + 12),
      Paths_Off   => Get_U64 (Bytes, Bytes'First + 16),
      Blob_Off    => Get_U64 (Bytes, Bytes'First + 24),
      Crc32       => Get_U32 (Bytes, Bytes'First + 32));

   function Record_Of (Bytes : String) return Table_Record is
     (Path_Off => Get_U64 (Bytes, Bytes'First),
      Path_Len => Natural (Get_U16 (Bytes, Bytes'First + 8)),
      Hash     => Hash_Of (Bytes (Bytes'First + 10 .. Bytes'First + 29)),
      Tags_Off => Get_U64 (Bytes, Bytes'First + 30),
      Tags_Len => Get_U32 (Bytes, Bytes'First + 38),
      Flags    => Character'Pos (Bytes (Bytes'First + 42)));

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

   function Path_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String
   is
   begin
      if Item.Path_Len = 0 then
         return "";
      end if;
      return
        Source.Read
          (Offset (Head.Paths_Off) + Offset (Item.Path_Off), Item.Path_Len);
   end Path_Of;

   function Tags_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String
   is
   begin
      if Item.Tags_Len = 0 then
         return "";
      end if;
      return
        Source.Read
          (Offset (Head.Blob_Off) + Offset (Item.Tags_Off),
           Positive (Item.Tags_Len));
   end Tags_Of;

   function Parse
     (Source : in out Ports.Byte_Source.Source'Class) return Parse_Result
   is
      Size : constant Offset       := Source.Size;
      Fail : constant Parse_Result := Parse_Results.Failure (Truncated);
   begin
      if Size < Header_Size then
         return Fail;
      end if;
      declare
         Raw : constant String := Source.Read (0, Header_Size);
      begin
         if Raw (Raw'First .. Raw'First + 7) /= Magic then
            return Parse_Results.Failure (Not_A_Cache);
         end if;
         declare
            Head      : constant Header := Header_Of (Raw);
            Table_End : constant U64    :=
              U64 (Header_Size) + U64 (Head.Entry_Count) * Record_Size;
            Window    : Byte_Window.Window;
            Paths     : Byte_Window.Window;
         begin
            if Head.Version /= Version then
               return Parse_Results.Failure (Version_Mismatch);
            end if;
            if Table_End > U64 (Size) then
               return Fail;
            end if;
            --  Before the checksum: a corrupt blob_off would otherwise run
            --  the checksum's own range out of the file.
            if Head.Blob_Off > U64 (Size) or else Head.Blob_Off < Header_Size
            then
               return Parse_Results.Failure (Offset_Out_Of_Range);
            end if;

            declare
               Crc  : GNAT.CRC32.CRC32;
               Here : Offset          := Header_Size;
               Stop : constant Offset := Offset (Head.Blob_Off);
            begin
               GNAT.CRC32.Initialize (Crc);
               while Here < Stop loop
                  declare
                     Chunk : constant String :=
                       Source.Read
                         (Here,
                          Positive'Min
                            (Byte_Window.Default_Block,
                              Positive (Stop - Here)));
                  begin
                     exit when Chunk'Length = 0;
                     GNAT.CRC32.Update (Crc, Chunk);
                     Here := Here + Offset (Chunk'Length);
                  end;
               end loop;
               if U32 (GNAT.CRC32.Get_Value (Crc)) /= Head.Crc32 then
                  return Parse_Results.Failure (Checksum_Mismatch);
               end if;
            end;

            --  A gap between the table and the paths is fine.
            if Head.Paths_Off < Table_End
              or else Head.Blob_Off < Head.Paths_Off
            then
               return Parse_Results.Failure (Offset_Out_Of_Range);
            end if;

            declare
               Previous : Unbounded_String;
               Region   : constant U64 := Head.Blob_Off - Head.Paths_Off;
            begin
               for I in 0 .. Natural (Head.Entry_Count) - 1 loop
                  declare
                     Item                           : constant Table_Record :=
                       Record_Of
                         (Byte_Window.Read
                            (Window, Source,
                             Offset (Header_Size) + Offset (I) * Record_Size,
                             Record_Size));
                     Path_End, Tags_Start, Tags_End : U64;
                     Bad                            : Boolean;
                  begin
                     Add (Item.Path_Off, U64 (Item.Path_Len), Path_End, Bad);
                     if Bad or else Path_End > Region then
                        return Parse_Results.Failure (Offset_Out_Of_Range);
                     end if;
                     Add (Head.Blob_Off, Item.Tags_Off, Tags_Start, Bad);
                     if Bad then
                        return Parse_Results.Failure (Offset_Out_Of_Range);
                     end if;
                     Add (Tags_Start, U64 (Item.Tags_Len), Tags_End, Bad);
                     if Bad or else Tags_End > U64 (Size) then
                        return Parse_Results.Failure (Offset_Out_Of_Range);
                     end if;
                     declare
                        Path : constant String :=
                          (if Item.Path_Len = 0 then ""
                           else Byte_Window.Read
                               (Paths, Source,
                                Offset (Head.Paths_Off) +
                                Offset (Item.Path_Off),
                                Item.Path_Len));
                     begin
                        --  Find rests on this order.
                        if I > 0 and then not (Previous < Path) then
                           return Parse_Results.Failure (Offset_Out_Of_Range);
                        end if;
                        Previous := To_Unbounded_String (Path);
                     end;
                  end;
               end loop;
            end;
            return Parse_Results.Success (Head);
         end;
      end;
   end Parse;

   function Find
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Path   :        String) return Maybe_Index
   is
      Low  : Natural := 0;
      High : Natural := Natural (Head.Entry_Count);   --  exclusive
   begin
      while Low < High loop
         declare
            Mid   : constant Natural      := Low + (High - Low) / 2;
            Item  : constant Table_Record := Record_At (Source, Head, Mid);
            Found : constant String       := Path_Of (Source, Head, Item);
         begin
            if Found < Path then
               Low := Mid + 1;
            elsif Found > Path then
               High := Mid;
            else
               return (Found => True, Value => Mid);
            end if;
         end;
      end loop;
      return (Found => False);
   end Find;

end Synapse.Core.Tags_Cache_Format;
