with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;

--  The part of the file system the program uses: which directories and files
--  there are, what is in a file, and the files that installing skills writes.
--  Passed in, never reached for, so finding definitions and skills, and
--  installing them, are tested without touching a disk.
--  Implementations are System_Files and, for tests, Fake_Files.

package Synapse.Pipeline.File_System is

   type File_System is limited interface;

   subtype Maybe_Content is Synapse.Core.Optional_Text.Option;

   function Is_Directory (F : File_System; Path : String) return Boolean
   is abstract;

   function Is_File (F : File_System; Path : String) return Boolean
   is abstract;

   --  The names, not the paths, of the ordinary files directly in Directory
   --  whose names end in Extension, in alphabetical order. Empty when there
   --  is no such directory.
   function List
     (F : File_System; Directory, Extension : String)
      return Synapse.Core.Text_Lists.Vector
   is abstract;

   --  The whole content of the file at Path, or nothing when it is missing,
   --  cannot be read, or is larger than Max_File_Size.
   function Read (F : File_System; Path : String) return Maybe_Content
   is abstract;

   --  The directory the program is running in.
   function Current_Directory (F : File_System) return String is abstract;

   --  The names, not the paths, of the directories directly in Directory, in
   --  alphabetical order. Empty when there is no such directory.
   function Subdirectories
     (F : File_System; Directory : String)
      return Synapse.Core.Text_Lists.Vector
   is abstract;

   --  Makes Text the whole content of the file at Path, making the
   --  directories above it. Done is False when it could not be done.
   procedure Write
     (F : in out File_System; Path, Text : String; Done : out Boolean)
   is abstract;

   --  Makes Destination a copy of the directory Source and everything in it,
   --  whatever was at Destination before being removed. Done is False when it
   --  could not be done.
   procedure Replace_Tree
     (F : in out File_System; Source, Destination : String;
      Done : out Boolean)
   is abstract;

   --  Removes the file or the directory with everything in it at Path, when
   --  there is one.
   procedure Remove_Tree (F : in out File_System; Path : String) is abstract;

   Max_File_Size : constant := 1024 * 1024;

end Synapse.Pipeline.File_System;
