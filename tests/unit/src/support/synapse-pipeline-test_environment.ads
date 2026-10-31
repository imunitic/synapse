with Synapse.Pipeline.Commands;
with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Fake_Process;
with Synapse.Pipeline.Fake_Transport;
with Synapse.Test_Environment;

--  An environment for a pipeline command under test: the fixture the other
--  commands' tests use, a console that keeps what was written, variables from
--  a table, a fixed clock and the real process runner, and an in-memory file
--  system for the definitions and skills.

package Synapse.Pipeline.Test_Environment is

   type Fixture is limited record
      Base  : aliased Synapse.Test_Environment.Fixture;
      Files : aliased Synapse.Pipeline.Fake_Files.Fake_Files;
      Inspector : aliased Synapse.Pipeline.Fake_Transport.Fake_Transport;
      Sessions  : aliased Synapse.Pipeline.Fake_Process.Fake_Process;
   end record;

   function Env
     (F : aliased in out Fixture) return Synapse.Pipeline.Commands.Environment
   is
     (Console => F.Base.Console'Access, Vars => F.Base.Vars'Access,
      Runner  => F.Base.Runner'Access, Clock => F.Base.Clock'Access,
      Files   => F.Files'Access, Inspector => F.Inspector'Access,
      Sessions => F.Sessions'Access,
      Argv0   => <>);

   --  The arguments as a list.
   function Args
     (A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12 : String := "")
      return Synapse.Pipeline.Commands.Lists.Vector
   renames Synapse.Test_Environment.Args;

end Synapse.Pipeline.Test_Environment;
