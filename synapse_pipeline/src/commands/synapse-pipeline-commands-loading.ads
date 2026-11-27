with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Resolved;

--  Finding a pipeline for a command that does not run it: the definitions are
--  loaded from the search directories, the pipeline is validated and then
--  resolved. A definition that does not load is a warning on standard error,
--  and every problem with the pipeline is an error on standard error.

package Synapse.Pipeline.Commands.Loading is

   --  Ok is False once an error has been reported. Otherwise Item is the
   --  resolved pipeline and File the file it was written in. With Advise,
   --  what is worth saying about a pipeline that can run is a warning on
   --  standard error too.
   procedure Load
     (Env    : Environment;
      Name   : String;
      Ok     : out Boolean;
      Item   : out Resolved.Pipeline;
      File   : out Ada.Strings.Unbounded.Unbounded_String;
      Advise : Boolean := False);

   --  The value of an `--input` option: the JSON in the file at Path, or on
   --  standard input for `-`. Ok is False once an error has been reported.
   procedure Read_Input
     (Env   : Environment;
      Path  : String;
      Input : out Synapse.Core.JSON.Value;
      Ok    : out Boolean);

end Synapse.Pipeline.Commands.Loading;
