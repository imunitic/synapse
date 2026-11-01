with Ada.Strings.Unbounded;

with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Search_Paths;

--  Finding a pipeline for a command that does not run it: the definitions are
--  loaded from the search directories, the pipeline is validated and then
--  resolved. A definition that does not load is a warning on standard error,
--  and every problem with the pipeline is an error on standard error.

package Synapse.Pipeline.Commands.Loading is

   --  Ok is False once an error has been reported. Otherwise Item is the
   --  resolved pipeline, File the file it was written in and Skill_Roots the
   --  directories skills are looked up in.
   procedure Load
     (Env         : Environment;
      Name        : String;
      Ok          : out Boolean;
      Item        : out Resolved.Pipeline;
      File        : out Ada.Strings.Unbounded.Unbounded_String;
      Skill_Roots : out Search_Paths.Root_Vectors.Vector);

end Synapse.Pipeline.Commands.Loading;
