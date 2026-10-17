with Interfaces;
with Ada.Containers.Ordered_Maps;
with Ada.Containers.Ordered_Sets;
with Ada.Directories;

with Synapse.Adapters.Atomic_File;
with Synapse.Ports.Byte_Source;

package body Synapse.Adapters.Docstring_Cache is

   package Format renames Core.Docstring_Index_Format;

   use type Core.Hashing.Digest;
   use type Interfaces.Unsigned_32;

   function "<" (Left, Right : Key) return Boolean is
     (if Left.Path /= Right.Path then Left.Path < Right.Path
      elsif Left.Name /= Right.Name then Left.Name < Right.Name
      else Left.Kind < Right.Kind);

   package Value_Maps is new Ada.Containers.Ordered_Maps (Key, Value);
   package Key_Sets is new Ada.Containers.Ordered_Sets (Key);

   function Enabled (V : Conf_Files.Variables) return Boolean is
     (Conf_Files.Resolve (V, "SYNAPSE_DOCSTRING_STALENESS_DETECTION").Found);

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
            if Core.Docstring_Index_Format.Parse_Results.Is_Success (Got) then
               C.Head := Core.Docstring_Index_Format.Parse_Results.Value (Got);
               C.Opened := True;
            else
               C.Why :=
                 Reason
                   (Core.Docstring_Index_Format.Parse_Results.Error (Got));
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

   function Natural_Of (Value : Interfaces.Unsigned_32) return Natural is
     (if Value > Interfaces.Unsigned_32 (Natural'Last) then Natural'Last
      else Natural (Value));

   function Value_Of (Item : Format.Table_Record) return Value is
     (Docstring_Hash  => Item.Docstring_Hash, Decl_Hash => Item.Decl_Hash,
      Docstring_Start => Natural_Of (Item.Docstring_Start),
      Docstring_End   => Natural_Of (Item.Docstring_End),
      Decl_Start      => Natural_Of (Item.Decl_Start),
      Decl_End        => Natural_Of (Item.Decl_End));

   function Get (C : in out Cache; Where : Key) return Maybe_Value is
   begin
      if not C.Opened then
         return (Found => False);
      end if;
      declare
         Found : constant Format.Maybe_Index :=
           Format.Find
             (C.Source, C.Head, To_String (Where.Path), To_String (Where.Name),
              To_String (Where.Kind));
      begin
         if not Found.Found then
            return (Found => False);
         end if;
         return
           (Found => True,
            Value =>
              Value_Of (Format.Record_At (C.Source, C.Head, Found.Value)));
      end;
   end Get;

   function Entries_For_Path
     (C : in out Cache; Path : String) return File_Entry_Vectors.Vector
   is
      Result : File_Entry_Vectors.Vector;
   begin
      if not C.Opened then
         return Result;
      end if;
      declare
         Span : constant Format.Range_Of_Entries :=
           Format.Path_Range (C.Source, C.Head, Path);
      begin
         for I in Span.From .. Span.To - 1 loop
            declare
               Item : constant Format.Table_Record :=
                 Format.Record_At (C.Source, C.Head, I);
            begin
               Result.Append
                 (File_Entry'
                    (Name  =>
                       To_Unbounded_String
                         (Format.Name_Of (C.Source, C.Head, Item)),
                     Kind  =>
                       To_Unbounded_String
                         (Format.Kind_Of (C.Source, C.Head, Item)),
                     Which => Value_Of (Item)));
            end;
         end loop;
      end;
      return Result;
   end Entries_For_Path;

   function Needs_Check
     (C : in out Cache; Requested : Update_Vectors.Vector)
      return Update_Vectors.Vector
   is
      Result : Update_Vectors.Vector;
      Seen   : Key_Sets.Set;
   begin
      for Want of Requested loop
         if not Seen.Contains (Want.Where) then
            Seen.Insert (Want.Where);
            declare
               Have : constant Maybe_Value := Get (C, Want.Where);
            begin
               if not Have.Found
                 or else Have.Value.Docstring_Hash /= Want.Which.Docstring_Hash
                 or else Have.Value.Decl_Hash /= Want.Which.Decl_Hash
               then
                  Result.Append (Want);
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Needs_Check;

   function Commit
     (C        : in out Cache; Updates : Update_Vectors.Vector;
      Removals :        Key_Vectors.Vector) return Natural
   is
      Merged  : Value_Maps.Map;
      Removed : Natural := 0;
      Entries : Format.Entry_Vectors.Vector;
   begin
      if C.Why = Unreadable then
         raise Unreadable_Cache;
      end if;
      for I in 0 .. Count (C) - 1 loop
         declare
            Item : constant Format.Table_Record :=
              Format.Record_At (C.Source, C.Head, I);
         begin
            Merged.Include
              ((Path =>
                  To_Unbounded_String
                    (Format.Path_Of (C.Source, C.Head, Item)),
                Name =>
                  To_Unbounded_String
                    (Format.Name_Of (C.Source, C.Head, Item)),
                Kind =>
                  To_Unbounded_String
                    (Format.Kind_Of (C.Source, C.Head, Item))),
               Value_Of (Item));
         end;
      end loop;

      --  Updates before removals, so removing a triple that is also being
      --  updated removes it.
      for U of Updates loop
         Merged.Include (U.Where, U.Which);
      end loop;
      for K of Removals loop
         if Merged.Contains (K) then
            Merged.Delete (K);
            Removed := Removed + 1;
         end if;
      end loop;

      for Place in Merged.Iterate loop
         declare
            K : constant Key   := Value_Maps.Key (Place);
            V : constant Value := Value_Maps.Element (Place);
         begin
            Entries.Append
              (Format.Entry_Type'
                 (Path            => K.Path, Name => K.Name, Kind => K.Kind,
                  Docstring_Hash => V.Docstring_Hash, Decl_Hash => V.Decl_Hash,
                  Docstring_Start => V.Docstring_Start,
                  Docstring_End => V.Docstring_End, Decl_Start => V.Decl_Start,
                  Decl_End        => V.Decl_End));
         end;
      end loop;

      --  The old file is closed before it is replaced, which Windows needs.
      File_Byte_Source.Close (C.Source);
      C.Opened := False;
      begin
         Atomic_File.Write (To_String (C.Path), Format.Encode (Entries));
      exception
         when others =>
            Open (C, To_String (C.Path));
            raise;
      end;
      Open (C, To_String (C.Path));
      return Removed;
   end Commit;

end Synapse.Adapters.Docstring_Cache;
