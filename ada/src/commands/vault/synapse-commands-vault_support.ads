with Ada.Strings.Unbounded;

with Synapse.Adapters.Git_Store;
with Synapse.Adapters.Store_Resolve;

--  What every vault subcommand does before and around its own work: answer
--  `--help`, take its one path, find the vault and open the stores over it.
package Synapse.Commands.Vault_Support is

   package Store_Resolve renames Synapse.Adapters.Store_Resolve;

   --  The vault the environment names, or false after saying `Prog: no vault`
   --  on standard error.
   procedure Find_Vault
     (Env   :     Environment; Prog : String;
      Vault : out Ada.Strings.Unbounded.Unbounded_String; Found : out Boolean);

   --  The stores over Vault, each note addressed by its whole path under it.
   --  False when the settings are invalid, which Resolve has said. Spawner,
   --  when given, is how a write may start the background push; it must
   --  outlive the stack.
   procedure Open
     (Env     :        Environment; Prog : String; Vault : String;
      Stack   : in out Store_Resolve.Stack; Ok : out Boolean;
      Spawner :    access Synapse.Adapters.Git_Store.Pusher_Spawner'Class :=
        null);

   --  The code for an argument that is not what the subcommand takes: help
   --  asked for is answered with the usage and 0, anything else is a usage
   --  error.
   function Help_Or_Usage
     (Env : Environment; Arg, Usage_Text : String) return Exit_Code;

   --  The one `<path>` a subcommand takes. Done is true when the arguments
   --  were not exactly that, and Code is what to return.
   procedure One_Path
     (Env  :     Environment; Args : Lists.Vector; Usage_Text : String;
      Path : out Ada.Strings.Unbounded.Unbounded_String; Done : out Boolean;
      Code : out Exit_Code);

end Synapse.Commands.Vault_Support;
