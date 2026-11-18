with Ada.Strings.Unbounded;

with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Search_Paths;

--  What a step's role or assignment says, ready for a prompt: the text of a
--  prompt as written, or for a skill a line saying where its files are
--  followed by its `SKILL.md`.

package Synapse.Pipeline.Instructions is

   --  The text of Item, and the directory of the skill it names when it
   --  names one. Both are empty for an instruction that is not there.
   --  Problem is not empty when a skill cannot be read.
   procedure Text_Of
     (Files       : File_System.File_System'Class;
      Skill_Roots : Search_Paths.Root_Vectors.Vector;
      Item        : Resolved.Instruction;
      Text        : out Ada.Strings.Unbounded.Unbounded_String;
      Directory   : out Ada.Strings.Unbounded.Unbounded_String;
      Problem     : out Ada.Strings.Unbounded.Unbounded_String);

end Synapse.Pipeline.Instructions;
