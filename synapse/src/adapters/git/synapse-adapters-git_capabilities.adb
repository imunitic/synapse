with Synapse.Adapters.Git_Sync;

package body Synapse.Adapters.Git_Capabilities is

   use Ada.Strings.Unbounded;

   function Create
     (Inner  : not null access Ports.Renamer.Renamer'Class;
      Runner : not null access Ports.Process_Runner.Runner'Class;
      Vault  : String) return Git_Renamer
   is (Ports.Renamer.Renamer
       with Inner  => Inner,
            Runner => Runner,
            Vault  => To_Unbounded_String (Vault));

   overriding
   procedure Rename (R : in out Git_Renamer; Old_Path, New_Path : String) is
      Committed : Boolean;
   begin
      R.Inner.Rename (Old_Path, New_Path);
      Git_Sync.Commit_Under_Lock
        (R.Runner.all, To_String (R.Vault), Committed);
   end Rename;

   function Create
     (Inner  : not null access Ports.Deleter.Deleter'Class;
      Runner : not null access Ports.Process_Runner.Runner'Class;
      Vault  : String) return Git_Deleter
   is (Ports.Deleter.Deleter
       with Inner  => Inner,
            Runner => Runner,
            Vault  => To_Unbounded_String (Vault));

   overriding
   procedure Delete (D : in out Git_Deleter; Path : String) is
      Committed : Boolean;
   begin
      D.Inner.Delete (Path);
      Git_Sync.Commit_Under_Lock
        (D.Runner.all, To_String (D.Vault), Committed);
   end Delete;

end Synapse.Adapters.Git_Capabilities;
