with Synapse.Core.Text_Lists;
with Synapse.Pipeline.File_System;

--  The file system of the machine the program runs on.

package Synapse.Pipeline.System_Files is

   type System_Files is limited new File_System.File_System with null record;

   overriding
   function Is_Directory (F : System_Files; Path : String) return Boolean;

   overriding
   function Is_File (F : System_Files; Path : String) return Boolean;

   overriding
   function List
     (F : System_Files; Directory, Extension : String)
      return Synapse.Core.Text_Lists.Vector;

   overriding
   function Current_Directory (F : System_Files) return String;

   overriding
   function Read
     (F : System_Files; Path : String) return File_System.Maybe_Content;

   overriding
   function Subdirectories
     (F : System_Files; Directory : String)
      return Synapse.Core.Text_Lists.Vector;

   overriding
   procedure Write
     (F : in out System_Files; Path, Text : String; Done : out Boolean);

   overriding
   procedure Replace_Tree
     (F : in out System_Files; Source, Destination : String;
      Done : out Boolean);

   overriding
   procedure Remove_Tree (F : in out System_Files; Path : String);

end Synapse.Pipeline.System_Files;
