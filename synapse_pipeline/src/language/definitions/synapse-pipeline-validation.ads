with Synapse.Pipeline.Definitions;
with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Namespaces;
with Synapse.Pipeline.Search_Paths;

--  Whether a pipeline can run: everything about it and what it refers to
--  that can be known before a session starts. Nothing is stopped at the
--  first problem; every one is returned, each in the file it is in, so that
--  one pass says all that is wrong.
--
--  Checked, for the pipeline and for each system and agent it reaches:
--    * every attribute is a real one, in a place it may be, holding what it
--      may hold, and none is given twice;
--    * a `Prompt` and a `Skill` are not both given, and every skill named
--      exists in one of the skill roots;
--    * every `System =>` and `Agent =>` names a definition of that kind, and
--      not one that failed to load, in which case the reason is given;
--    * every step ends up with instructions, from itself, its system or its
--      agent, and with a harness, from itself, its system or the default
--      harness;
--    * a step is declared once, every edge joins steps of the pipeline, and
--      every edge back to an earlier step or to its own step says how many
--      times it may fire, so that every cycle is bounded.

package Synapse.Pipeline.Validation is

   --  What is wrong with the pipeline called Name, which is empty when it can
   --  run. Default_Harness is the harness a step uses when neither it nor its
   --  system names one, nothing when there is none.
   function Validate
     (Defs        : Namespaces.Namespace;
      Files       : File_System.File_System'Class;
      Skill_Roots : Search_Paths.Root_Vectors.Vector;
      Name        : String;
      Default_Harness : Harnesses.Kind_Options.Option)
      return Definitions.Problem_Vectors.Vector;

end Synapse.Pipeline.Validation;
