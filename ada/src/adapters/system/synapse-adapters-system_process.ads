with Synapse.Core.Text_Lists;
with Synapse.Ports.Process_Runner;

--  Runs programs through the operating system. The streams go through
--  temporary files, so a program that fills a pipe cannot deadlock the
--  caller whatever it does with its input and output.

package Synapse.Adapters.System_Process is

   package Port renames Synapse.Ports.Process_Runner;

   type System_Runner is limited new Port.Runner with null record;

   overriding
   function Run
     (R       : in out System_Runner;
      Program : String;
      Args    : Core.Text_Lists.Vector;
      Opts    : Port.Options) return Port.Result;

end Synapse.Adapters.System_Process;
