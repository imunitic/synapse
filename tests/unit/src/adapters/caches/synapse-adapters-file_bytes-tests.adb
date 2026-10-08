with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;

with AUnit.Assertions;

with Synapse.Test_Scratch;

package body Synapse.Adapters.File_Bytes.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;
   use type Ada.Directories.File_Size;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  Larger than the 8 MiB stack a main thread gets by default.
   Big : constant := 16 * 1024 * 1024;

   type String_Access is access String;
   procedure Free is new Ada.Unchecked_Deallocation (String, String_Access);

   procedure A_Content_Larger_Than_The_Stack_Is_Written_Whole
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      P       : constant String  := Path (Dir, "big.bin");
      Content : String_Access    := new String (1 .. Big);
      File    : Ada.Streams.Stream_IO.File_Type;
      Byte    : Ada.Streams.Stream_Element_Array (1 .. 1);
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      for I in Content'Range loop
         Content (I) := Character'Val (I mod 256);
      end loop;
      Write (P, Content.all);
      Assert
        (Ada.Directories.Size (P) = Ada.Directories.File_Size (Big),
         "every byte is written");
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, P);
      Ada.Streams.Stream_IO.Set_Index
        (File, Ada.Streams.Stream_IO.Count (Big));
      Ada.Streams.Stream_IO.Read (File, Byte, Last);
      Ada.Streams.Stream_IO.Close (File);
      Assert
        (Last = 1 and then Byte (1) = Character'Pos (Content (Big)),
         "the last byte is the last byte of the content");
      Free (Content);
      Remove (Dir);
   exception
      when others =>
         Free (Content);
         Remove (Dir);
         raise;
   end A_Content_Larger_Than_The_Stack_Is_Written_Whole;

   procedure An_Empty_Content_Makes_An_Empty_File (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "empty.bin");
   begin
      Write (P, "");
      Assert (Ada.Directories.Size (P) = 0, "created and empty");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Empty_Content_Makes_An_Empty_File;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.File_Bytes");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Content_Larger_Than_The_Stack_Is_Written_Whole'Access,
         "A content larger than the stack is written whole");
      Register_Routine
        (T, An_Empty_Content_Makes_An_Empty_File'Access,
         "An empty content makes an empty file");
   end Register_Tests;

end Synapse.Adapters.File_Bytes.Tests;
