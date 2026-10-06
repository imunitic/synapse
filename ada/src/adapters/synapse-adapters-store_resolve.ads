with Ada.Finalization;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Disk_Store;
with Synapse.Adapters.Git_Store;
with Synapse.Adapters.Schema_Validation_Store;
with Synapse.Adapters.System_Clock;
with Synapse.Adapters.System_Process;
with Synapse.Core.Text_Lists;
with Synapse.Ports.Search_Filtered;
with Synapse.Ports.Store;
with Synapse.Ports.Variables;

--  The one place that decides which store a caller gets. The setting
--  SYNAPSE_VAULT_INTEGRATIONS lists, outer to inner, the integrations that
--  wrap the store; today that is `git` alone. Under them is always the
--  schema validation store, which is a correctness boundary and not a
--  choice, and under that the disk store, which is never named.

package Synapse.Adapters.Store_Resolve is

   package Port renames Synapse.Ports.Store;

   --  Eight is more than will ever exist.
   Max_Integrations : constant := 8;

   type Parse_Result (Ok : Boolean := False) is record
      case Ok is
         when True =>
            Names   : Core.Text_Lists.Vector;

         when False =>
            Message : Ada.Strings.Unbounded.Unbounded_String;
      end case;
   end record;

   --  The names in a SYNAPSE_VAULT_INTEGRATIONS value, in order. Empty is no
   --  integrations. Refused, with the message to show: `disk` named at all,
   --  an unknown name, a name twice, and more than Max_Integrations.
   function Parse_Integrations (Value : String) return Parse_Result;

   --  Whether Name is among the configured integrations: for a caller that
   --  only needs to know and has no use for the stores. A malformed setting
   --  answers no; reporting it is Resolve's job.
   function Has_Integration
     (Vars : Ports.Variables.Variables'Class; Name : String) return Boolean;

   --  A built store stack. It owns every layer and frees them when it goes
   --  out of scope.
   type Stack is limited private;

   --  Builds the stack for Vault, every node name prefixed by Namespace (empty
   --  addresses a note by its whole path under the vault). Vars outlives the
   --  stack. The disk store gets the stopwords of the configuration, and
   --  `git` the push threshold of the configuration; Spawner, when given, is
   --  how the git store starts a background push. An invalid setting leaves
   --  Valid False and builds nothing, printing `Prog: message` to standard
   --  error unless Prog is empty.
   procedure Resolve
     (S         : in out Stack;
      Vars      : not null access Ports.Variables.Variables'Class;
      Vault     : String;
      Namespace : String;
      Prog      : String;
      Spawner   : access Git_Store.Pusher_Spawner'Class;
      Valid     : out Boolean);

   --  The outermost layer. The stack must be valid.
   function Store (S : in out Stack) return not null access Port.Store'Class;

   --  Ranked search scoped by a path filter. It is the disk store's, whatever
   --  wraps it: no layer changes it.
   function Search_Filtered
     (S      : in out Stack;
      Query  : String;
      Filter : Ports.Search_Filtered.Path_Filter)
      return Port.Hit_Vectors.Vector;

private

   type Disk_Access is access Disk_Store.Disk_Store;
   type Validation_Access is
     access Schema_Validation_Store.Validation_Store;
   type Git_Access is access Git_Store.Git_Store;
   type Runner_Access is access System_Process.System_Runner;
   type Clock_Access is access System_Clock.System_Clock;

   type Stack is limited new Ada.Finalization.Limited_Controlled with record
      Disk       : Disk_Access;
      Validation : Validation_Access;
      Git        : Git_Access;
      Runner     : Runner_Access;
      Clock      : Clock_Access;
   end record;

   overriding
   procedure Finalize (S : in out Stack);

end Synapse.Adapters.Store_Resolve;
