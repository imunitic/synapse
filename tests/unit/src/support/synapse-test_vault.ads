with Synapse.Test_Environment;
with Synapse.Test_Scratch;

--  A vault on disk for a command under test: notes written under
--  `Dir/vault`, a home under `Dir/home` that holds no configuration, and
--  schemas under `Dir/content/schema`.
package Synapse.Test_Vault is

   --  Points the variables of F at the vault, the home and the schemas of
   --  Dir.
   procedure Use_Vault
     (F   : in out Synapse.Test_Environment.Fixture;
      Dir :        Synapse.Test_Scratch.Scratch);

   --  The note Name (a path under the vault), with its directories.
   procedure Put (Dir : Synapse.Test_Scratch.Scratch; Name, Text : String);

   --  The schema Id (`kind/version`).
   procedure Put_Schema
     (Dir : Synapse.Test_Scratch.Scratch; Id, Text : String);

   --  A file of the home's `.claude` directory, where the configuration
   --  files are found.
   procedure Put_Config
     (Dir : Synapse.Test_Scratch.Scratch; Name, Text : String);

end Synapse.Test_Vault;
