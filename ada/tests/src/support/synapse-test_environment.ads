with Synapse.Adapters.Fake_Clock;
with Synapse.Adapters.Fake_Console;
with Synapse.Adapters.Fake_Extractors;
with Synapse.Adapters.Fake_Variables;
with Synapse.Adapters.System_Process;
with Synapse.Commands;

--  An environment for a command under test: a console that keeps what was
--  written, variables from a table, a fixed clock, and the real process
--  runner for the commands that start git.

package Synapse.Test_Environment is

   type Fixture is limited record
      Console    : aliased Synapse.Adapters.Fake_Console.Fake;
      Vars       : aliased Synapse.Adapters.Fake_Variables.Fake_Variables;
      Runner     : aliased Synapse.Adapters.System_Process.System_Runner;
      Clock      : aliased Synapse.Adapters.Fake_Clock.Fake_Clock;
      Extractors : aliased Synapse.Adapters.Fake_Extractors.Fake_Factory;
   end record;

   function Env
     (F : aliased in out Fixture) return Synapse.Commands.Environment is
     (Console    => F.Console'Access, Vars => F.Vars'Access,
      Runner     => F.Runner'Access, Clock => F.Clock'Access,
      Extractors => F.Extractors'Access, Argv0 => <>);

   --  The arguments as a list.
   function Args
     (A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12 : String := "")
      return Synapse.Commands.Lists.Vector;

end Synapse.Test_Environment;
