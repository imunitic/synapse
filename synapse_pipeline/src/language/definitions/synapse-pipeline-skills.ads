with Synapse.Core.Optional_Text;
with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Search_Paths;

--  Finding the skills a definition names. A skill is a directory holding a
--  `SKILL.md`, found through an ordered list of roots; the first root that
--  holds it wins.

package Synapse.Pipeline.Skills is

   --  The form the Agent Skills specification gives a skill's name: 1 to 64
   --  lowercase letters, digits and hyphens, with no hyphen at either end and
   --  none next to another.
   function Is_Valid_Name (Name : String) return Boolean;

   --  The directory of the skill called Name, or nothing when no root holds
   --  one. A root that is not there is skipped.
   function Find
     (Files : File_System.File_System'Class;
      Roots : Search_Paths.Root_Vectors.Vector; Name : String)
      return Synapse.Core.Optional_Text.Option;

   --  The roots, for saying where a skill was looked for.
   function Searched (Roots : Search_Paths.Root_Vectors.Vector) return String;

end Synapse.Pipeline.Skills;
