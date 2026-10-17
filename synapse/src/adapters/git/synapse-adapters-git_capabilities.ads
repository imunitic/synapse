with Ada.Strings.Unbounded;

with Synapse.Ports.Deleter;
with Synapse.Ports.Process_Runner;
with Synapse.Ports.Renamer;

--  The capabilities that change the vault, under version control. Each does
--  what the capability it wraps does, then commits under the sync lock, or
--  skips the commit when another holder has it: the change is already on disk
--  and the next commit or the pusher sweeps it up. Neither checks whether a
--  push is due: a rename or delete between two writes is pushed once either
--  side's commit count crosses the threshold.

package Synapse.Adapters.Git_Capabilities is

   type Git_Renamer is limited new Ports.Renamer.Renamer with private;

   function Create
     (Inner  : not null access Ports.Renamer.Renamer'Class;
      Runner : not null access Ports.Process_Runner.Runner'Class;
      Vault  : String) return Git_Renamer;

   overriding
   procedure Rename (R : in out Git_Renamer; Old_Path, New_Path : String);

   type Git_Deleter is limited new Ports.Deleter.Deleter with private;

   function Create
     (Inner  : not null access Ports.Deleter.Deleter'Class;
      Runner : not null access Ports.Process_Runner.Runner'Class;
      Vault  : String) return Git_Deleter;

   overriding
   procedure Delete (D : in out Git_Deleter; Path : String);

private

   type Git_Renamer is limited new Ports.Renamer.Renamer with record
      Inner  : not null access Ports.Renamer.Renamer'Class;
      Runner : not null access Ports.Process_Runner.Runner'Class;
      Vault  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Git_Deleter is limited new Ports.Deleter.Deleter with record
      Inner  : not null access Ports.Deleter.Deleter'Class;
      Runner : not null access Ports.Process_Runner.Runner'Class;
      Vault  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Synapse.Adapters.Git_Capabilities;
