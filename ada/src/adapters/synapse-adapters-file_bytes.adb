with Ada.Calendar;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;

with Synapse.Core.Decimal_Image;

package body Synapse.Adapters.File_Bytes is

   package IO renames Ada.Streams.Stream_IO;

   use type Ada.Streams.Stream_Element_Offset;
   use type IO.Count;

   function Read (Path : String; Limit : Natural) return String is
      File : IO.File_Type;
   begin
      --  Shared: tasks may read the same file at once.
      IO.Open (File, IO.In_File, Path, Form => "shared=yes");
      declare
         Length : constant IO.Count := IO.Size (File);
      begin
         if Length > IO.Count (Limit) then
            IO.Close (File);
            raise Too_Large with Path;
         end if;
         declare
            --  On the heap: a file can be larger than the stack.
            type Data_Access is access Ada.Streams.Stream_Element_Array;
            procedure Free is new Ada.Unchecked_Deallocation
              (Ada.Streams.Stream_Element_Array, Data_Access);
            Data : Data_Access :=
              new Ada.Streams.Stream_Element_Array
                (1 .. Ada.Streams.Stream_Element_Offset (Length));
            Last : Ada.Streams.Stream_Element_Offset;
         begin
            begin
               IO.Read (File, Data.all, Last);
               IO.Close (File);
               if Last /= Data'Last then
                  raise Ada.Streams.Stream_IO.Data_Error
                    with "short read: " & Path;
               end if;
               return Text : String (1 .. Natural (Length)) do
                  for I in Text'Range loop
                     Text (I) :=
                       Character'Val
                         (Data (Ada.Streams.Stream_Element_Offset (I)));
                  end loop;
                  Free (Data);
               end return;
            exception
               when others =>
                  Free (Data);
                  raise;
            end;
         end;
      end;
   exception
      when Too_Large =>
         raise;
      when others    =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         raise;
   end Read;

   procedure Write (Path, Content : String) is
      File : IO.File_Type;
      Data :
        Ada.Streams.Stream_Element_Array
          (1 .. Ada.Streams.Stream_Element_Offset (Content'Length));
   begin
      for I in Data'Range loop
         Data (I) :=
           Ada.Streams.Stream_Element
             (Character'Pos (Content (Content'First + Natural (I) - 1)));
      end loop;
      IO.Create (File, IO.Out_File, Path);
      IO.Write (File, Data);
      IO.Close (File);
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         raise;
   end Write;

   --  The value of an environment variable naming an existing directory,
   --  without trailing separators, or "".
   function Directory_Named (Variable : String) return String is
   begin
      if not Ada.Environment_Variables.Exists (Variable) then
         return "";
      end if;
      declare
         Value : constant String := Ada.Environment_Variables.Value (Variable);
         Last  : Natural         := Value'Last;
      begin
         while Last > Value'First and then Value (Last) in '/' | '\' loop
            Last := Last - 1;
         end loop;
         if Value'Length > 0
           and then Ada.Directories.Exists (Value (Value'First .. Last))
         then
            return Value (Value'First .. Last);
         end if;
         return "";
      end;
   end Directory_Named;

   function Temp_Dir return String is
      Tmpdir : constant String := Directory_Named ("TMPDIR");
      Tmp    : constant String := Directory_Named ("TMP");
      Temp   : constant String := Directory_Named ("TEMP");
   begin
      if Tmpdir /= "" then
         return Tmpdir;
      elsif Tmp /= "" then
         return Tmp;
      elsif Temp /= "" then
         return Temp;
      elsif Ada.Directories.Exists ("/tmp") then
         return "/tmp";
      end if;
      return Ada.Directories.Current_Directory;
   end Temp_Dir;

   --  Tasks may ask for temporary files at once.
   protected Sequence is
      procedure Next (Value : out Natural);
   private
      Last : Natural := 0;
   end Sequence;

   protected body Sequence is
      procedure Next (Value : out Natural) is
      begin
         Last  := Last + 1;
         Value := Last;
      end Next;
   end Sequence;

   function Temp_File (Content : String := "") return String is
      Stamp   : constant Natural :=
        Natural (Ada.Calendar.Seconds (Ada.Calendar.Clock) * 1_000.0);
      Counter : Natural;
   begin
      Sequence.Next (Counter);
      return
        Path : constant String :=
          Ada.Directories.Full_Name
            (Temp_Dir & "/synapse-" & Core.Decimal_Image.Image (Stamp) & "-" &
             Core.Decimal_Image.Image (Counter) & ".tmp")
      do
         Write (Path, Content);
      end return;
   end Temp_File;

end Synapse.Adapters.File_Bytes;
