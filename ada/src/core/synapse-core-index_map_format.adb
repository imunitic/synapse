with Ada.Containers.Indefinite_Ordered_Maps;

with GNAT.CRC32;

with Synapse.Core.Byte_Window;

package body Synapse.Core.Index_Map_Format is

   use Ports.Byte_Source;
   use type Interfaces.Unsigned_64;

   LF : constant Character := Character'Val (10);

   Longest : constant := 65_535;

   package Id_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Natural);

   function Encode
     (Entries : Entry_Vectors.Vector; Unassigned : Text_Lists.Vector)
      return String
   is
      Names        : Text_Lists.Set;
      Paths_Length : Natural          := 0;
      Ids_Count    : Natural          := 0;
      Count        : constant Natural := Natural (Entries.Length);
   begin
      for I in 1 .. Count loop
         declare
            Path : constant String := To_String (Entries (I).Path);
         begin
            if Path'Length > Longest then
               raise Path_Too_Long;
            end if;
            if I > 1 and then not (To_String (Entries (I - 1).Path) < Path)
            then
               raise Unsorted;
            end if;
            if Entries (I).Nodes.Is_Empty then
               raise No_Nodes;
            end if;
            if Natural (Entries (I).Nodes.Length) > Max_Nodes_Per_Path then
               raise Too_Many_Nodes_For_Path;
            end if;
            for K in 1 .. Natural (Entries (I).Nodes.Length) loop
               declare
                  Name : constant String := To_String (Entries (I).Nodes (K));
               begin
                  if Name'Length > Longest then
                     raise Node_Name_Too_Long;
                  end if;
                  if K > 1
                    and then not (To_String (Entries (I).Nodes (K - 1)) < Name)
                  then
                     raise Unsorted_Nodes;
                  end if;
                  Names.Include (Name);
               end;
            end loop;
            Paths_Length := Paths_Length + Path'Length;
            Ids_Count    := Ids_Count + Natural (Entries (I).Nodes.Length);
         end;
      end loop;

      declare
         Unassigned_Length : Natural := 0;
         Ids               : Id_Maps.Map;
         Names_Length      : Natural := 0;
      begin
         for Path of Unassigned loop
            if (for some C of To_String (Path) => C = LF) then
               raise Path_Contains_Newline;
            end if;
            Unassigned_Length := Unassigned_Length + Length (Path) + 1;
         end loop;
         declare
            Next : Natural := 0;
         begin
            for Name of Names loop
               Ids.Insert (Name, Next);
               Next         := Next + 1;
               Names_Length := Names_Length + Name'Length;
            end loop;
         end;

         declare
            Table_Length   : constant Natural    := Count * Record_Size;
            Paths_Off      : constant Natural    := Header_Size + Table_Length;
            Ids_Off        : constant Natural    := Paths_Off + Paths_Length;
            Nodes_Off      : constant Natural    := Ids_Off + Ids_Count * 4;
            Names_Off      : constant Natural    :=
              Nodes_Off + Natural (Names.Length) * Node_Size;
            Unassigned_Off : constant Natural    := Names_Off + Names_Length;
            Total : constant Natural    := Unassigned_Off + Unassigned_Length;
            Bytes : String (1 .. Total) := [others => Character'Val (0)];
            Name_At        : Natural             := 0;
            Path_At        : Natural             := 0;
            Ids_At         : Natural             := 0;
            Node_Number    : Natural             := 0;
         begin
            for Name of Names loop
               Bytes
                 (Nodes_Off + Node_Number * Node_Size + 1 ..
                      Nodes_Off + (Node_Number + 1) * Node_Size) :=
                 Put_U32 (U32 (Name_At)) & Put_U16 (U16 (Name'Length));
               Bytes
                 (Names_Off + Name_At + 1 ..
                      Names_Off + Name_At + Name'Length)         :=
                 Name;
               Name_At := Name_At + Name'Length;
               Node_Number := Node_Number + 1;
            end loop;

            for I in 1 .. Count loop
               declare
                  Path  : constant String  := To_String (Entries (I).Path);
                  Where : constant Natural :=
                    Header_Size + (I - 1) * Record_Size + 1;
                  Nodes : Text_Lists.Vector renames Entries (I).Nodes;
               begin
                  Bytes (Where .. Where + Record_Size - 1)  :=
                    Put_U64 (U64 (Path_At)) & Put_U16 (U16 (Path'Length)) &
                    Put_U32 (U32 (Ids_At)) &
                    Character'Val (Natural (Nodes.Length));
                  Bytes
                    (Paths_Off + Path_At + 1 ..
                         Paths_Off + Path_At + Path'Length) :=
                    Path;
                  Path_At := Path_At + Path'Length;
                  for Name of Nodes loop
                     Bytes
                       (Ids_Off + Ids_At * 4 + 1 ..
                            Ids_Off + Ids_At * 4 + 4) :=
                       Put_U32 (U32 (Ids.Element (To_String (Name))));
                     Ids_At                           := Ids_At + 1;
                  end loop;
               end;
            end loop;

            declare
               Here : Natural := Unassigned_Off;
            begin
               for Path of Unassigned loop
                  Bytes (Here + 1 .. Here + Length (Path)) := To_String (Path);
                  Bytes (Here + Length (Path) + 1)         := LF;
                  Here := Here + Length (Path) + 1;
               end loop;
            end;

            declare
               Crc : GNAT.CRC32.CRC32;
            begin
               GNAT.CRC32.Initialize (Crc);
               GNAT.CRC32.Update (Crc, Bytes (Header_Size + 1 .. Total));
               Bytes (1 .. Header_Size) :=
                 Magic & Put_U32 (Version) & Put_U32 (U32 (Count)) &
                 Put_U32 (U32 (Names.Length)) &
                 Put_U32 (U32 (Unassigned.Length)) &
                 Put_U64 (U64 (Paths_Off)) & Put_U64 (U64 (Ids_Off)) &
                 Put_U64 (U64 (Nodes_Off)) & Put_U64 (U64 (Unassigned_Off)) &
                 Put_U32 (U32 (GNAT.CRC32.Get_Value (Crc))) & Put_U32 (0);
            end;
            return Bytes;
         end;
      end;
   end Encode;

   function Header_Of (Bytes : String) return Header is
     (Version          => Get_U32 (Bytes, Bytes'First + 8),
      Entry_Count      => Get_U32 (Bytes, Bytes'First + 12),
      Node_Count       => Get_U32 (Bytes, Bytes'First + 16),
      Unassigned_Count => Get_U32 (Bytes, Bytes'First + 20),
      Paths_Off        => Get_U64 (Bytes, Bytes'First + 24),
      Ids_Off          => Get_U64 (Bytes, Bytes'First + 32),
      Nodes_Off        => Get_U64 (Bytes, Bytes'First + 40),
      Unassigned_Off   => Get_U64 (Bytes, Bytes'First + 48),
      Crc32            => Get_U32 (Bytes, Bytes'First + 56));

   function Record_Of (Bytes : String) return Table_Record is
     (Path_Off => Get_U64 (Bytes, Bytes'First),
      Path_Len => Natural (Get_U16 (Bytes, Bytes'First + 8)),
      Ids_At   => Get_U32 (Bytes, Bytes'First + 10),
      Ids_Len  => Character'Pos (Bytes (Bytes'First + 14)));

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

   function Node_Name
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Id     :        Natural) return String
   is
      Node       : constant String  :=
        Source.Read
          (Offset (Head.Nodes_Off) + Offset (Id) * Node_Size, Node_Size);
      Name_Off   : constant Natural := Natural (Get_U32 (Node, Node'First));
      Name_Len : constant Natural := Natural (Get_U16 (Node, Node'First + 4));
      Names_Base : constant Offset  :=
        Offset (Head.Nodes_Off) + Offset (Head.Node_Count) * Node_Size;
   begin
      if Name_Len = 0 then
         return "";
      end if;
      return Source.Read (Names_Base + Offset (Name_Off), Name_Len);
   end Node_Name;

   function Nodes_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return Text_Lists.Vector
   is
      Result : Text_Lists.Vector;
      Ids    : constant String :=
        Source.Read
          (Offset (Head.Ids_Off) + Offset (Item.Ids_At) * 4, Item.Ids_Len * 4);
   begin
      for K in 0 .. Item.Ids_Len - 1 loop
         Result.Append
           (To_Unbounded_String
              (Node_Name
                 (Source, Head, Natural (Get_U32 (Ids, Ids'First + K * 4)))));
      end loop;
      return Result;
   end Nodes_Of;

   function Find
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Path   :        String) return Maybe_Index
   is
      Low  : Natural := 0;
      High : Natural := Natural (Head.Entry_Count);
   begin
      while Low < High loop
         declare
            Mid   : constant Natural := Low + (High - Low) / 2;
            Found : constant String  :=
              Path_Of (Source, Head, Record_At (Source, Head, Mid));
         begin
            if Found < Path then
               Low := Mid + 1;
            elsif Found > Path then
               High := Mid;
            else
               return (Found => True, Index => Mid);
            end if;
         end;
      end loop;
      return (Found => False);
   end Find;

   function Find_Node
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Name   :        String) return Maybe_Index
   is
      Low  : Natural := 0;
      High : Natural := Natural (Head.Node_Count);
   begin
      while Low < High loop
         declare
            Mid   : constant Natural := Low + (High - Low) / 2;
            Found : constant String  := Node_Name (Source, Head, Mid);
         begin
            if Found < Name then
               Low := Mid + 1;
            elsif Found > Name then
               High := Mid;
            else
               return (Found => True, Index => Mid);
            end if;
         end;
      end loop;
      return (Found => False);
   end Find_Node;

   function Unassigned
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header)
      return Text_Lists.Vector
   is
      Result : Text_Lists.Vector;
      Size   : constant Offset := Source.Size;
      Start  : constant Offset := Offset (Head.Unassigned_Off);
   begin
      if Size <= Start then
         return Result;
      end if;
      declare
         Region : constant String :=
           Source.Read (Start, Positive (Size - Start));
         First  : Natural         := Region'First;
      begin
         for I in Region'Range loop
            if Region (I) = LF then
               Result.Append (To_Unbounded_String (Region (First .. I - 1)));
               First := I + 1;
            end if;
         end loop;
      end;
      return Result;
   end Unassigned;

   function Decode
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header)
      return Decoded
   is
      Result : Decoded;
      Names  : Text_Lists.Vector;
   begin
      for Id in 0 .. Natural (Head.Node_Count) - 1 loop
         Names.Append (To_Unbounded_String (Node_Name (Source, Head, Id)));
      end loop;
      for I in 0 .. Natural (Head.Entry_Count) - 1 loop
         declare
            Item  : constant Table_Record := Record_At (Source, Head, I);
            Ids   : constant String       :=
              Source.Read
                (Offset (Head.Ids_Off) + Offset (Item.Ids_At) * 4,
                 Item.Ids_Len * 4);
            Nodes : Text_Lists.Vector;
         begin
            for K in 0 .. Item.Ids_Len - 1 loop
               Nodes.Append
                 (Names (Natural (Get_U32 (Ids, Ids'First + K * 4)) + 1));
            end loop;
            Result.Entries.Append
              (Entry_Type'
                 (Path  => To_Unbounded_String (Path_Of (Source, Head, Item)),
                  Nodes => Nodes));
         end;
      end loop;
      Result.Unassigned := Unassigned (Source, Head);
      return Result;
   end Decode;

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
            return Fail (Not_An_Index);
         end if;
         declare
            Head : constant Header := Header_Of (Raw);
         begin
            if Head.Version /= Version then
               return Fail (Version_Mismatch);
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
               Table_End : constant U64          :=
                 U64 (Header_Size) + U64 (Head.Entry_Count) * Record_Size;
               Bad       : constant Parse_Result := Fail (Offset_Out_Of_Range);
            begin
               if Table_End > U64 (Size) then
                  return Fail (Truncated);
               end if;
               --  A gap between regions is fine; none may overlap.
               if Head.Paths_Off < Table_End
                 or else Head.Ids_Off < Head.Paths_Off
                 or else Head.Nodes_Off < Head.Ids_Off
                 or else Head.Unassigned_Off < Head.Nodes_Off
                 or else Head.Unassigned_Off > U64 (Size)
               then
                  return Bad;
               end if;

               declare
                  Ids_Capacity : constant U64 :=
                    (Head.Nodes_Off - Head.Ids_Off) / 4;
                  Names_Off    : constant U64 :=
                    Head.Nodes_Off + U64 (Head.Node_Count) * Node_Size;
               begin
                  if Names_Off > Head.Unassigned_Off then
                     return Bad;
                  end if;
                  declare
                     Names_Length : constant U64 :=
                       Head.Unassigned_Off - Names_Off;
                     Paths_Length : constant U64 :=
                       Head.Ids_Off - Head.Paths_Off;
                     Previous     : Unbounded_String;
                  begin
                     --  Node names first: the records resolve numbers
                     --  through them.
                     for Id in 0 .. Natural (Head.Node_Count) - 1 loop
                        declare
                           Node     : constant String :=
                             Source.Read
                               (Offset (Head.Nodes_Off) +
                                Offset (Id) * Node_Size,
                                Node_Size);
                           Name_Off : constant U64    :=
                             U64 (Get_U32 (Node, Node'First));
                           Name_Len : constant U64    :=
                             U64 (Get_U16 (Node, Node'First + 4));
                        begin
                           if Name_Off + Name_Len > Names_Length then
                              return Bad;
                           end if;
                           declare
                              Name : constant String :=
                                Node_Name (Source, Head, Id);
                           begin
                              if Id > 0 and then not (Previous < Name) then
                                 return Bad;
                              end if;
                              Previous := To_Unbounded_String (Name);
                           end;
                        end;
                     end loop;

                     declare
                        Table : Byte_Window.Window;
                        Paths : Byte_Window.Window;
                        Ids   : Byte_Window.Window;
                     begin
                        Previous := Null_Unbounded_String;
                        for I in 0 .. Natural (Head.Entry_Count) - 1 loop
                           declare
                              Item     : constant Table_Record :=
                                Record_Of
                                  (Byte_Window.Read
                                     (Table, Source,
                                      Offset (Header_Size) +
                                      Offset (I) * Record_Size,
                                      Record_Size));
                              Path_End : U64;
                              Overflow : Boolean;
                           begin
                              if Item.Ids_Len = 0 then
                                 return Bad;
                              end if;
                              Add
                                (Item.Path_Off, U64 (Item.Path_Len), Path_End,
                                 Overflow);
                              if Overflow or else Path_End > Paths_Length then
                                 return Bad;
                              end if;
                              if U64 (Item.Ids_At) + U64 (Item.Ids_Len) >
                                Ids_Capacity
                              then
                                 return Bad;
                              end if;
                              for K in 0 .. Item.Ids_Len - 1 loop
                                 declare
                                    Slot : constant String :=
                                      Byte_Window.Read
                                        (Ids, Source,
                                         Offset (Head.Ids_Off) +
                                         (Offset (Item.Ids_At) + Offset (K)) *
                                           4,
                                         4);
                                 begin
                                    if Get_U32 (Slot, Slot'First) >=
                                      Head.Node_Count
                                    then
                                       return Bad;
                                    end if;
                                 end;
                              end loop;
                              declare
                                 Path : constant String :=
                                   (if Item.Path_Len = 0 then ""
                                    else Byte_Window.Read
                                        (Paths, Source,
                                         Offset (Head.Paths_Off) +
                                         Offset (Item.Path_Off),
                                         Item.Path_Len));
                              begin
                                 if I > 0 and then not (Previous < Path) then
                                    return Bad;
                                 end if;
                                 Previous := To_Unbounded_String (Path);
                              end;
                           end;
                        end loop;
                     end;
                  end;
               end;

               --  Exactly the count claimed, each ended by a line feed.
               declare
                  Start : constant Offset := Offset (Head.Unassigned_Off);
                  Lines : Natural         := 0;
                  Last  : Character       := LF;
                  Here  : Offset          := Start;
               begin
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
                        for C of Chunk loop
                           if C = LF then
                              Lines := Lines + 1;
                           end if;
                        end loop;
                        Last := Chunk (Chunk'Last);
                        Here := Here + Offset (Chunk'Length);
                     end;
                  end loop;
                  if (Size > Start and then Last /= LF)
                    or else U32 (Lines) /= Head.Unassigned_Count
                  then
                     return Bad;
                  end if;
               end;
            end;
            return (Ok => True, Head => Head);
         end;
      end;
   end Parse;

end Synapse.Core.Index_Map_Format;
