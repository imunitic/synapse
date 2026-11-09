with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.File_System;

--  Files held in memory, for tests. A directory exists when a file is in it or
--  it was added; there is no tree to walk beyond the paths given.

package Synapse.Pipeline.Fake_Files is

   package Contents is new Ada.Containers.Indefinite_Ordered_Maps
     (String, String);

   package Names is new Ada.Containers.Indefinite_Ordered_Sets (String);

   type Fake_Files is limited new File_System.File_System with record
      Files       : Contents.Map;
      Directories : Names.Set;

      --  Paths that exist but cannot be read.
      Unreadable  : Names.Set;

      --  What Current_Directory says.
      Here        : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String ("/work");
   end record;

   --  Adds a file, and the directories above it.
   procedure Add_File (F : in out Fake_Files; Path, Content : String);

   procedure Add_Directory (F : in out Fake_Files; Path : String);

   overriding
   function Is_Directory (F : Fake_Files; Path : String) return Boolean;

   overriding
   function Is_File (F : Fake_Files; Path : String) return Boolean;

   overriding
   function List
     (F : Fake_Files; Directory, Extension : String)
      return Synapse.Core.Text_Lists.Vector;

   overriding
   function Current_Directory (F : Fake_Files) return String;

   overriding
   function Read
     (F : Fake_Files; Path : String) return File_System.Maybe_Content;

   overriding
   function Subdirectories
     (F : Fake_Files; Directory : String)
      return Synapse.Core.Text_Lists.Vector;

   overriding
   procedure Write
     (F : in out Fake_Files; Path, Text : String; Done : out Boolean);

   overriding
   procedure Replace_Tree
     (F : in out Fake_Files; Source, Destination : String;
      Done : out Boolean);

   overriding
   procedure Remove_Tree (F : in out Fake_Files; Path : String);

end Synapse.Pipeline.Fake_Files;
