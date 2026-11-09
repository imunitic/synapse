with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

--  The projects of `synapse-projects.conf`: one `name=prefix` line for each.
--  The name is the folder a project's notes are in (`tasks/<name>/`) and the
--  prefix starts the id of each of its notes (`sb-001`).

package Synapse.Core.Projects is

   type Project is record
      Name   : Ada.Strings.Unbounded.Unbounded_String;
      Prefix : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Project_Vectors is new Ada.Containers.Vectors (Positive, Project);

   subtype Project_List is Project_Vectors.Vector;

   --  The pairs a file's text holds, in order. A blank line, a `#` line and
   --  a line with nothing before its `=` or nothing after it hold none.
   function Parse (Text : String) return Project_List;

   --  Why a project cannot be added to Known, or nothing when it can. A name
   --  is lower case letters, digits, dots, underscores and hyphens, starts
   --  with a letter or a digit and is at most 64 long. A prefix is lower
   --  case letters, digits and hyphens, starts with a letter, does not end
   --  with a hyphen and is at most 32 long. Neither may be one already
   --  taken.
   function Refusal
     (Name, Prefix : String; Known : Project_List) return String;

   --  Text with the pair added as a last line, every other byte as it was.
   function With_Added (Text, Name, Prefix : String) return String;

end Synapse.Core.Projects;
