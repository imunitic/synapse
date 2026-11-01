with Ada.Containers.Vectors;

with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Namespaces;
with Synapse.Pipeline.Search_Paths;
with Synapse.Pipeline.Source_Errors;

--  Every definition the search directories hold, in one namespace. A
--  definition file ends in `.synapse`, holds one pipeline, system or agent,
--  and is named after what it declares. A name belongs to exactly one
--  definition whatever its kind, so two files claiming one name make that
--  name unusable and nothing shadows anything.
--
--  Only the files directly in a directory are read. Reading them is all
--  that happens here: that a definition refers to others that exist, or
--  that its attributes are real, is for the validation that follows.
--
--  A file that does not load does not stop the others. What went wrong is a
--  problem, reported as a warning, and the name the file stood for is marked
--  failed in the namespace. It is validating a pipeline that refers to such a
--  name that fails, before anything runs.

package Synapse.Pipeline.Definitions is

   Extension : constant String := ".synapse";

   package Problem_Vectors is new Ada.Containers.Vectors
     (Positive, Source_Errors.Source_Error, Source_Errors."=");

   type Load_Report is record
      Definitions : Namespaces.Namespace;

      --  In the order found. Each names its file.
      Problems    : Problem_Vectors.Vector;
   end record;

   --  The definitions in the files of Roots, in order. The problems are: a
   --  required directory that is not there, a file that cannot be read, one
   --  that does not parse, one named other than what it declares, and a name
   --  claimed by more than one file, which then belongs to none of them. The
   --  same file reached by two roots counts once.
   function Load
     (Files : File_System.File_System'Class;
      Roots : Search_Paths.Root_Vectors.Vector) return Load_Report;

   --  A problem as the one line of a warning: `warning: ` and the error's
   --  image, with its file.
   function Warning (Problem : Source_Errors.Source_Error) return String;

end Synapse.Pipeline.Definitions;
