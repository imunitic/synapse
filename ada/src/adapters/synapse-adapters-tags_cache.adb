with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Directories;
with Ada.Streams.Stream_IO;

with Synapse.Adapters.Replace_File;
with Synapse.Core.Byte_Window;
with Synapse.Core.Tag_Line;
with Synapse.Core.Tag_Payload;
with Synapse.Ports.Byte_Source;

package body Synapse.Adapters.Tags_Cache is

   package Format renames Core.Tags_Cache_Format;
   package SIO renames Ada.Streams.Stream_IO;

   --  Where an entry's payload comes from while a commit writes the file.
   type Item is record
      Hash        : Core.Graph_Model.Hash;
      Unsupported : Boolean;
      Kept        : Boolean;              --  still in the old file
      Old         : Format.Table_Record;  --  where, when Kept
      Fresh       : Unbounded_String;     --  the new payload, when not Kept
   end record;

   package Item_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Item);

   function Reason (E : Format.Parse_Error) return Issue is
     (case E is when Format.Not_A_Cache => Not_A_Cache,
        when Format.Version_Mismatch => Version_Mismatch,
        when Format.Truncated => Truncated,
        when Format.Checksum_Mismatch => Checksum_Mismatch,
        when Format.Offset_Out_Of_Range => Offset_Out_Of_Range);

   procedure Close (C : in out Cache) is
   begin
      File_Byte_Source.Close (C.Source);
      C.Opened := False;
      C.Why    := None;
   end Close;

   overriding procedure Finalize (C : in out Cache) is
   begin
      File_Byte_Source.Close (C.Source);
   end Finalize;

   procedure Open (C : in out Cache; Path : String) is
      use type Ada.Directories.File_Kind;
      use type Ada.Directories.File_Size;
   begin
      Close (C);
      C.Path := To_Unbounded_String (Path);
      if not Ada.Directories.Exists (Path)
        or else Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
        or else Ada.Directories.Size (Path) = 0
      then
         return;
      end if;
      begin
         File_Byte_Source.Open (C.Source, Path);
         declare
            Got : constant Format.Parse_Result := Format.Parse (C.Source);
         begin
            if Got.Ok then
               C.Head   := Got.Head;
               C.Opened := True;
            else
               C.Why := Reason (Got.Error);
               File_Byte_Source.Close (C.Source);
            end if;
         end;
      exception
         when Ports.Byte_Source.Source_Failure =>
            File_Byte_Source.Close (C.Source);
            C.Why := Unreadable;
      end;
   end Open;

   function Discarded (C : Cache) return Issue is (C.Why);

   function Count (C : Cache) return Natural is
     (if C.Opened then Natural (C.Head.Entry_Count) else 0);

   function Get (C : in out Cache; Path : String) return Maybe_Value is
   begin
      if not C.Opened then
         return (Found => False);
      end if;
      declare
         Where : constant Format.Maybe_Index :=
           Format.Find (C.Source, C.Head, Path);
      begin
         if not Where.Found then
            return (Found => False);
         end if;
         declare
            Rec : constant Format.Table_Record :=
              Format.Record_At (C.Source, C.Head, Where.Index);
         begin
            return
              (Found => True,
               Item  =>
                 (Hash        => Rec.Hash,
                  Tags        =>
                    To_Unbounded_String
                      (Format.Tags_Of (C.Source, C.Head, Rec)),
                  Unsupported => Format.Unsupported (Rec)));
         end;
      end;
   end Get;

   function Needs_Tagging
     (C : in out Cache; Requested : Path_Hash_Vectors.Vector)
      return Path_Hash_Vectors.Vector
   is
      Result : Path_Hash_Vectors.Vector;
      Seen   : Core.Text_Lists.Set;
   begin
      for Want of Requested loop
         declare
            Path : constant String := To_String (Want.Path);
         begin
            if not Seen.Contains (Path) then
               Seen.Insert (Path);
               declare
                  Current : Boolean := False;
               begin
                  if C.Opened then
                     declare
                        Where : constant Format.Maybe_Index :=
                          Format.Find (C.Source, C.Head, Path);
                     begin
                        Current :=
                          Where.Found
                          and then
                            Format.Record_At (C.Source, C.Head, Where.Index)
                              .Hash =
                            Want.Hash;
                     end;
                  end if;
                  if not Current then
                     Result.Append (Want);
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Needs_Tagging;

   --  Writes Text to the stream of File.
   procedure Put (File : SIO.File_Type; Text : String) is
   begin
      String'Write (SIO.Stream (File), Text);
   end Put;

   --  Copies Length bytes of the old file from Start.
   procedure Copy
     (C : in out Cache; File : SIO.File_Type; Start : Ports.Byte_Source.Offset;
      Length :        Natural)
   is
      Done : Natural := 0;
   begin
      while Done < Length loop
         declare
            Chunk : constant String :=
              C.Source.Read
                (Start + Ports.Byte_Source.Offset (Done),
                 Positive'Min (Core.Byte_Window.Default_Block, Length - Done));
         begin
            exit when Chunk'Length = 0;
            Put (File, Chunk);
            Done := Done + Chunk'Length;
         end;
      end loop;
   end Copy;

   --  The directory part of Path, or "" when it has none.
   function Directory_Of (Path : String) return String is
   begin
      return Ada.Directories.Containing_Directory (Path);
   exception
      when others =>
         return "";
   end Directory_Of;

   procedure Remove_Quietly (Path : String) is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   exception
      when others =>
         null;
   end Remove_Quietly;

   function Commit
     (C        : in out Cache; Updates : Update_Vectors.Vector;
      Removals :        Core.Text_Lists.Vector) return Natural
   is
      Path    : constant String := To_String (C.Path);
      Tmp     : constant String := Path & ".tmp";
      Merged  : Item_Maps.Map;
      Removed : Natural         := 0;
      File    : SIO.File_Type;
   begin
      if C.Why = Unreadable then
         raise Unreadable_Cache;
      end if;

      for I in 0 .. Count (C) - 1 loop
         declare
            Rec : constant Format.Table_Record :=
              Format.Record_At (C.Source, C.Head, I);
         begin
            Merged.Include
              (Format.Path_Of (C.Source, C.Head, Rec),
               (Hash => Rec.Hash, Unsupported => Format.Unsupported (Rec),
                Kept => True, Old => Rec, Fresh => Null_Unbounded_String));
         end;
      end loop;

      --  Updates before removals, so removing a path that is also being
      --  updated removes it.
      for U of Updates loop
         Merged.Include
           (To_String (U.Path),
            (Hash => U.Which.Hash, Unsupported => U.Which.Unsupported,
             Kept => False, Old => <>, Fresh => U.Which.Tags));
      end loop;
      for P of Removals loop
         if Merged.Contains (To_String (P)) then
            Merged.Delete (To_String (P));
            Removed := Removed + 1;
         end if;
      end loop;

      declare
         Sized : Format.Sized_Vectors.Vector;
         Dir   : constant String := Directory_Of (Path);
      begin
         for Place in Merged.Iterate loop
            declare
               Entry_Item : constant Item := Item_Maps.Element (Place);
            begin
               Sized.Append
                 (Format.Sized_Entry'
                    (Path => To_Unbounded_String (Item_Maps.Key (Place)),
                     Hash        => Entry_Item.Hash,
                     Tags_Length =>
                       (if Entry_Item.Kept then
                          Natural (Entry_Item.Old.Tags_Len)
                        else Length (Entry_Item.Fresh)),
                     Unsupported => Entry_Item.Unsupported));
            end;
         end loop;
         if Dir /= "" then
            Ada.Directories.Create_Path (Dir);
         end if;
         SIO.Create (File, SIO.Out_File, Tmp);
         Put (File, Format.Encode_Prefix (Sized));
         for Place in Merged.Iterate loop
            declare
               Entry_Item : constant Item := Item_Maps.Element (Place);
            begin
               if Entry_Item.Kept then
                  Copy
                    (C, File,
                     Ports.Byte_Source.Offset (C.Head.Blob_Off) +
                     Ports.Byte_Source.Offset (Entry_Item.Old.Tags_Off),
                     Natural (Entry_Item.Old.Tags_Len));
               else
                  Put (File, To_String (Entry_Item.Fresh));
               end if;
            end;
         end loop;
         SIO.Close (File);
      end;

      --  The old file is closed before it is replaced, which Windows needs.
      File_Byte_Source.Close (C.Source);
      C.Opened := False;
      Replace_File.Replace (Tmp, Path);
      Open (C, Path);
      return Removed;
   exception
      when others =>
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;
         Remove_Quietly (Tmp);
         if not C.Opened and then C.Why /= Unreadable then
            Open (C, Path);
         end if;
         raise;
   end Commit;

   function Write_Refs (C : in out Cache; Emit : Row_Sink) return Natural is
      Rows : Natural := 0;
   begin
      for I in 0 .. Count (C) - 1 loop
         declare
            Rec      : constant Format.Table_Record :=
              Format.Record_At (C.Source, C.Head, I);
            Path : constant String := Format.Path_Of (C.Source, C.Head, Rec);
            Payload  : constant String              :=
              Format.Tags_Of (C.Source, C.Head, Rec);
            Position : Integer                      := Payload'First;
            Next_Tag : Core.Tag_Payload.Maybe_Tag;
         begin
            loop
               Core.Tag_Payload.Next (Payload, Position, Next_Tag);
               exit when not Next_Tag.Found;
               Emit (Core.Tag_Line.Refs_Row (Path, Next_Tag.Value));
               Rows := Rows + 1;
            end loop;
         end;
      end loop;
      return Rows;
   end Write_Refs;

end Synapse.Adapters.Tags_Cache;
