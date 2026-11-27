with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Resolved;

--  The definition files a run was made from, read as they are when the run
--  starts, to be kept with its record: the `.synapse` file of the pipeline
--  and of every system, agent and prompt a step was built from. Each is named
--  by the path it has in a configuration directory,
--  `synapse-pipeline/Name.synapse`, so that a directory made of them can be
--  given to the program as its configuration. A file that cannot be read is
--  left out.

package Synapse.Pipeline.Definition_Copies is

   type Copy is record
      Path    : Ada.Strings.Unbounded.Unbounded_String;
      Content : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Copy_Vectors is new Ada.Containers.Vectors (Positive, Copy);

   --  Pipeline_File is where the pipeline was loaded from.
   function Collect
     (Files         : File_System.File_System'Class;
      Item          : Resolved.Pipeline;
      Pipeline_File : String)
      return Copy_Vectors.Vector;

end Synapse.Pipeline.Definition_Copies;
