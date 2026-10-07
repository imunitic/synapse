with Ada.Directories;

with Synapse.Adapters.File_Bytes;

package body Synapse.Test_Vault is

   procedure Write_File (Full : String; Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Full));
      Synapse.Adapters.File_Bytes.Write (Full, Text);
   end Write_File;

   procedure Use_Vault
     (F   : in out Synapse.Test_Environment.Fixture;
      Dir :        Synapse.Test_Scratch.Scratch)
   is
   begin
      Ada.Directories.Create_Path (Synapse.Test_Scratch.Path (Dir, "vault"));
      F.Vars.Set
        ("SYNAPSE_VAULT_DIR", Synapse.Test_Scratch.Path (Dir, "vault"));
      F.Vars.Set ("HOME", Synapse.Test_Scratch.Path (Dir, "home"));
      F.Vars.Set
        ("SYNAPSE_CONTENT_ROOT", Synapse.Test_Scratch.Path (Dir, "content"));
   end Use_Vault;

   procedure Put (Dir : Synapse.Test_Scratch.Scratch; Name, Text : String) is
   begin
      Write_File (Synapse.Test_Scratch.Path (Dir, "vault/" & Name), Text);
   end Put;

   procedure Put_Schema (Dir : Synapse.Test_Scratch.Scratch; Id, Text : String)
   is
   begin
      Write_File
        (Synapse.Test_Scratch.Path (Dir, "content/schema/" & Id & ".yaml"),
         Text);
   end Put_Schema;

   procedure Put_Config
     (Dir : Synapse.Test_Scratch.Scratch; Name, Text : String)
   is
   begin
      Write_File
        (Synapse.Test_Scratch.Path (Dir, "home/.claude/" & Name), Text);
   end Put_Config;

end Synapse.Test_Vault;
