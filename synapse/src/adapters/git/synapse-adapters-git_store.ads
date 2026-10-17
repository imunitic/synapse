with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Ports.Process_Runner;
with Synapse.Ports.Store;

--  A store that keeps the vault under version control: every write is
--  committed. It wraps another store; reading, listing and searching are the
--  inner store's own, and nothing about git changes what they answer.

package Synapse.Adapters.Git_Store is

   package Port renames Synapse.Ports.Store;

   --  How a push gets started in the background. The command line provides
   --  this: a process that outlives the call cannot be started through a
   --  runner, which waits for what it runs.
   type Pusher_Spawner is limited interface;

   procedure Spawn_Pusher (S : in out Pusher_Spawner; Vault : String)
   is abstract;

   type Git_Store is limited new Port.Store with private;

   --  Push_Every is how many commits ahead of the upstream make a push due,
   --  checked after each commit of a write; zero never asks for one. Without
   --  a Spawner nothing is ever asked for either.
   function Create
     (Inner      : not null access Port.Store'Class;
      Runner     : not null access Ports.Process_Runner.Runner'Class;
      Vault      : String;
      Push_Every : Natural := 0;
      Spawner    : access Pusher_Spawner'Class := null) return Git_Store;

   overriding
   function Read (S : in out Git_Store; Node : String) return Port.Maybe_Text;

   --  The inner write first and unconditionally, so nothing waits on git or
   --  the network for the data to land; its refusal is returned as it is.
   --  Then the commit under the sync lock, skipped when someone else holds
   --  it. A failure of git is reported on standard error and the write stays
   --  local: it never fails the write.
   overriding
   function Write
     (S : in out Git_Store; Node, Content : String) return Port.Write_Result;

   overriding
   function List (S : in out Git_Store) return Core.Text_Lists.Vector;

   overriding
   function Search
     (S : in out Git_Store; Query : String) return Port.Hit_Vectors.Vector;

private

   type Git_Store is limited new Port.Store with record
      Inner      : not null access Port.Store'Class;
      Runner     : not null access Ports.Process_Runner.Runner'Class;
      Vault      : Ada.Strings.Unbounded.Unbounded_String;
      Push_Every : Natural;
      Spawner    : access Pusher_Spawner'Class;
   end record;

end Synapse.Adapters.Git_Store;
