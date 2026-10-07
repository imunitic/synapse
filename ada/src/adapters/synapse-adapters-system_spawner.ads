with Ada.Strings.Unbounded;

with Synapse.Adapters.Git_Store;

--  Starts the background push as a detached process of this same program:
--  `Program vault-git-pusher Vault`, with no input and no output, which
--  outlives the command that started it and is never waited for.
package Synapse.Adapters.System_Spawner is

   type System_Spawner is limited new Git_Store.Pusher_Spawner with record
      Program : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  A failure to start it is reported on standard error and is not an
   --  error of the write that asked: the change is already on disk.
   overriding procedure Spawn_Pusher
     (S : in out System_Spawner; Vault : String);

end Synapse.Adapters.System_Spawner;
