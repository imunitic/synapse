with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Unbounded;

with Synapse.Core.Results;
with Synapse.Pipeline.Harnesses;
with Synapse.Ports.Variables;

--  What a run is configured with, settled once before its first session and
--  then plain data: the environment its sessions are given, the limits, which
--  runner runs them, and the harness used when a step names none. Every step
--  of a run is given the same configuration, so what changes afterwards, in a
--  variable, a configuration file or the vault directory, reaches no run that
--  has begun.

package Synapse.Pipeline.Configs is

   --  The variables a configuration is read from.
   Timeout_Variable : constant String := "SYNAPSE_PIPELINE_TIMEOUT";
   Ceiling_Variable : constant String := "SYNAPSE_PIPELINE_MAX_STEPS";
   Runner_Variable  : constant String := "SYNAPSE_PIPELINE_RUNNER";
   Script_Variable  : constant String := "SYNAPSE_PIPELINE_SCRIPT";

   --  Synapse's own settings that a session is given, so that it works in the
   --  same vault and work directory as the run that started it. Each is the
   --  variable of that name or else the setting the configuration files give.
   Vault_Dir_Key     : constant String := "SYNAPSE_VAULT_DIR";
   Work_Dir_Key      : constant String := "SYNAPSE_WORK_DIR";
   Content_Root_Key  : constant String := "SYNAPSE_CONTENT_ROOT";

   type Runner_Kind is (Process_Runner, Scripted_Runner);

   package Environment_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, String);

   Default_Timeout : constant := 30 * 60;
   Default_Ceiling : constant := 50;

   type Config is record
      --  The variables sessions are started with, by name.
      Environment             : Environment_Maps.Map;

      --  How long a session may take when its step does not say.
      Default_Timeout_Seconds : Positive := Default_Timeout;

      --  How many steps a run may take in all.
      Step_Ceiling            : Positive := Default_Ceiling;

      Runner                  : Runner_Kind := Process_Runner;

      --  The file a scripted runner reads its answers from.
      Script                  : Ada.Strings.Unbounded.Unbounded_String;

      --  The harness for a step that has none of its own.
      Default_Harness         : Harnesses.Kind_Options.Option;

      --  Where sessions run.
      Working_Directory       : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Config_Results is new Synapse.Core.Results
     (Config, Ada.Strings.Unbounded.Unbounded_String);

   --  The configuration the variables give, or what is wrong with them. The
   --  timeout is a duration such as `30m`, the ceiling a positive whole
   --  number, the runner `process` or `scripted`, and a scripted runner needs
   --  a script. Working_Directory is where the caller is.
   function Resolve
     (V : Synapse.Ports.Variables.Variables'Class; Working_Directory : String)
      return Config_Results.Result;

end Synapse.Pipeline.Configs;
