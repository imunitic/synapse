with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
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

   procedure A_New_File_Is_Never_Made_Over_One_That_Is_There
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "taken.tmp");
   begin
      Assert (Create_New (P), "a path with nothing at it is made");
      Assert
        (Ada.Directories.Exists (P) and then Ada.Directories.Size (P) = 0,
         "as an empty file");
      Write (P, "what another process put there");
      Assert (not Create_New (P), "a path that is taken is not made again");
      Assert
        (Ada.Directories.Size (P) = 30,
         "and what is there is left as it was");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_New_File_Is_Never_Made_Over_One_That_Is_There;

   --  The number between the last two dashes of a temporary file's name, and
   --  the one before it: the `Stamp` and `Counter` of
   --  `synapse-<Stamp>-<Counter>.tmp`.
   procedure Parts_Of
     (Path : String; Stamp, Counter : out Natural)
   is
      Dash_2 : Natural := 0;
      Dash_1 : Natural := 0;
      Dot    : constant Natural := Path'Last - 3;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '-' then
            if Dash_2 = 0 then
               Dash_2 := I;
            else
               Dash_1 := I;
               exit;
            end if;
         end if;
      end loop;
      Stamp := Natural'Value (Path (Dash_1 + 1 .. Dash_2 - 1));
      Counter := Natural'Value (Path (Dash_2 + 1 .. Dot - 1));
   end Parts_Of;

   procedure A_Temporary_File_Never_Reuses_A_Name_Another_Process_Took
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      use Ada.Environment_Variables;
      Dir        : constant Scratch := Make;
      Had_Tmpdir : constant Boolean := Exists ("TMPDIR");
      Old_Tmpdir : constant String :=
        (if Had_Tmpdir then Value ("TMPDIR") else "");
      Window     : constant := 1_000;
      Stamp      : Natural;
      Counter    : Natural;
   begin
      Set ("TMPDIR", Path (Dir));
      Parts_Of (Temp_File, Stamp, Counter);

      --  Every name the next call could pick within a second is taken, as
      --  another process starting at the same moment would have taken it.
      for Later in Stamp .. Stamp + Window loop
         Write
           (Path
              (Dir, "synapse-" & Ada.Strings.Fixed.Trim
                 (Natural'Image (Later), Ada.Strings.Left) & "-"
               & Ada.Strings.Fixed.Trim
                   (Natural'Image (Counter + 1), Ada.Strings.Left) & ".tmp"),
            "taken");
      end loop;

      declare
         Mine : constant String := Temp_File;
         Search : Ada.Directories.Search_Type;
         Entry_Found : Ada.Directories.Directory_Entry_Type;
         Intact : Natural := 0;
      begin
         Ada.Directories.Start_Search (Search, Path (Dir), "synapse-*");
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Entry_Found);
            if Ada.Directories.Size (Ada.Directories.Full_Name (Entry_Found))
               = 5
            then
               Intact := Intact + 1;
            end if;
         end loop;
         Ada.Directories.End_Search (Search);
         Assert
           (Intact = Window + 1,
            "the files another process had taken are left as they were:"
            & Natural'Image (Intact) & " of" & Natural'Image (Window + 1));
         Assert
           (Ada.Directories.Exists (Mine) and then Mine /= "",
            "and the file made is one of its own");
      end;
      if Had_Tmpdir then
         Set ("TMPDIR", Old_Tmpdir);
      else
         Clear ("TMPDIR");
      end if;
      Remove (Dir);
   exception
      when others =>
         if Had_Tmpdir then
            Set ("TMPDIR", Old_Tmpdir);
         else
            Clear ("TMPDIR");
         end if;
         Remove (Dir);
         raise;
   end A_Temporary_File_Never_Reuses_A_Name_Another_Process_Took;

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
        (T, A_New_File_Is_Never_Made_Over_One_That_Is_There'Access,
         "A new file is never made over one that is there");
      Register_Routine
        (T, A_Temporary_File_Never_Reuses_A_Name_Another_Process_Took'Access,
         "A temporary file never reuses a name another process took");
      Register_Routine
        (T, An_Empty_Content_Makes_An_Empty_File'Access,
         "An empty content makes an empty file");
   end Register_Tests;

end Synapse.Adapters.File_Bytes.Tests;
