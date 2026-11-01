with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Ports.Variables;

--  Where definitions and skills are looked for. Where a variable comes from is
--  passed in, so none of this touches the real environment unless the caller
--  hands it the system's.

package Synapse.Pipeline.Search_Paths is

   --  A directory to look in. A Required one that is not there is an error;
   --  one that is not required, such as the default under the user's
   --  configuration directory, is skipped.
   type Root is record
      Path     : Ada.Strings.Unbounded.Unbounded_String;
      Required : Boolean := False;
   end record;

   package Root_Vectors is new Ada.Containers.Vectors (Positive, Root);

   --  The name of the variable that lists further definition directories,
   --  separated as the platform separates the directories of a path.
   Path_Variable : constant String := "SYNAPSE_PIPELINE_PATH";

   --  The directory that holds Synapse Pipeline's own files: the
   --  `synapse-pipeline` directory under `$XDG_CONFIG_HOME` when that is set
   --  and not empty, else under `~/.config`. Empty when there is no home.
   function Config_Directory
     (V : Synapse.Ports.Variables.Variables'Class) return String;

   --  The directories definitions are loaded from, in order: the configuration
   --  directory, then each directory `SYNAPSE_PIPELINE_PATH` lists.
   function Definition_Roots
     (V : Synapse.Ports.Variables.Variables'Class) return Root_Vectors.Vector;

   --  The directories skills are looked up in, first to last. For now the
   --  `skills` directory of the configuration directory; the harnesses' own
   --  directories and the application's join it later.
   function Skill_Roots
     (V : Synapse.Ports.Variables.Variables'Class) return Root_Vectors.Vector;

end Synapse.Pipeline.Search_Paths;
