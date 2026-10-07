with Ada.Directories;

with Synapse.Adapters.Atomic_File;
with Synapse.Core.Index_Map;
with Synapse.Ports.Byte_Source;

package body Synapse.Adapters.Index_Map is

   package Format renames Core.Index_Map_Format;

   function Reason (E : Format.Parse_Error) return Issue is
     (case E is when Format.Not_An_Index => Not_An_Index,
        when Format.Version_Mismatch => Version_Mismatch,
        when Format.Truncated => Truncated,
        when Format.Checksum_Mismatch => Checksum_Mismatch,
        when Format.Offset_Out_Of_Range => Offset_Out_Of_Range);

   procedure Close (M : in out Map) is
   begin
      File_Byte_Source.Close (M.Source);
      M.Opened := False;
      M.Why    := None;
   end Close;

   overriding procedure Finalize (M : in out Map) is
   begin
      File_Byte_Source.Close (M.Source);
   end Finalize;

   procedure Open (M : in out Map; Path : String) is
      use type Ada.Directories.File_Kind;
      use type Ada.Directories.File_Size;
   begin
      Close (M);
      M.Path := To_Unbounded_String (Path);
      if not Ada.Directories.Exists (Path)
        or else Ada.Directories.Kind (Path) /= Ada.Directories.Ordinary_File
        or else Ada.Directories.Size (Path) = 0
      then
         return;
      end if;
      begin
         File_Byte_Source.Open (M.Source, Path);
         declare
            Got : constant Format.Parse_Result := Format.Parse (M.Source);
         begin
            if Core.Index_Map_Format.Parse_Results.Is_Success (Got) then
               M.Head   := Core.Index_Map_Format.Parse_Results.Value (Got);
               M.Opened := True;
            else
               M.Why :=
                 Reason (Core.Index_Map_Format.Parse_Results.Error (Got));
               File_Byte_Source.Close (M.Source);
            end if;
         end;
      exception
         when Ports.Byte_Source.Source_Failure =>
            File_Byte_Source.Close (M.Source);
            M.Why := Unreadable;
      end;
   end Open;

   function Discarded (M : Map) return Issue is (M.Why);

   function Count (M : Map) return Natural is
     (if M.Opened then Natural (M.Head.Entry_Count) else 0);

   function Node_Count (M : Map) return Natural is
     (if M.Opened then Natural (M.Head.Node_Count) else 0);

   function Unassigned_Count (M : Map) return Natural is
     (if M.Opened then Natural (M.Head.Unassigned_Count) else 0);

   function Nodes_For (M : in out Map; Path : String) return Maybe_Nodes is
   begin
      if not M.Opened then
         return (Found => False);
      end if;
      declare
         Where : constant Format.Maybe_Index :=
           Format.Find (M.Source, M.Head, Path);
      begin
         if not Where.Found then
            return (Found => False);
         end if;
         return
           (Found => True,
            Value =>
              Format.Nodes_Of
                (M.Source, M.Head,
                  Format.Record_At (M.Source, M.Head, Where.Value)));
      end;
   end Nodes_For;

   function Unassigned (M : in out Map) return Core.Text_Lists.Vector is
   begin
      if not M.Opened then
         return Core.Text_Lists.Vectors.Empty_Vector;
      end if;
      return Format.Unassigned (M.Source, M.Head);
   end Unassigned;

   procedure Write_File (Path : String; Bytes : String) is
   begin
      Atomic_File.Write (Path, Bytes);
   end Write_File;

   function Add_Unassigned (M : in out Map; Extra : String) return Boolean is
      Path : constant String := To_String (M.Path);
   begin
      if Path = "" then
         raise Program_Error with "the map was never opened";
      end if;
      declare
         Current : constant Format.Decoded             :=
           (if M.Opened then Format.Decode (M.Source, M.Head)
            else (others => <>));
         Next    : constant Core.Index_Map.Maybe_Bytes :=
           Core.Index_Map.With_Unassigned (Current, Extra);
      begin
         if not Next.Found then
            return False;
         end if;
         --  The old file is closed before it is replaced, which Windows needs.
         File_Byte_Source.Close (M.Source);
         M.Opened := False;
         Write_File (Path, To_String (Next.Value));
         Open (M, Path);
         return True;
      end;
   end Add_Unassigned;

end Synapse.Adapters.Index_Map;
