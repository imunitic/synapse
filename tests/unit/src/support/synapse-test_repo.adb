with Ada.Directories;

with Synapse.Adapters.File_Bytes;

package body Synapse.Test_Repo is

   procedure Use_Work
     (F   : in out Synapse.Test_Environment.Fixture;
      Dir :        Synapse.Test_Scratch.Scratch)
   is
   begin
      F.Vars.Set ("HOME", Synapse.Test_Scratch.Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_WORK_DIR", Synapse.Test_Scratch.Path (Dir, "work"));
   end Use_Work;

   function Repo (Dir : Synapse.Test_Scratch.Scratch) return String is
     (Synapse.Test_Scratch.Path (Dir, "repo"));

   procedure Put_File (Dir : Synapse.Test_Scratch.Scratch; Name, Text : String)
   is
      Full : constant String := Repo (Dir) & "/" & Name;
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Full));
      Synapse.Adapters.File_Bytes.Write (Full, Text);
   end Put_File;

   procedure Commit_All (Dir : Synapse.Test_Scratch.Scratch) is
   begin
      Synapse.Test_Scratch.Init_Repo (Repo (Dir));
      Synapse.Test_Scratch.Git (Repo (Dir), "add", "-A");
      Synapse.Test_Scratch.Git (Repo (Dir), "commit", "-q", "-m", "files");
   end Commit_All;

   function Work_File
     (Dir : Synapse.Test_Scratch.Scratch; Name : String) return String is
     (Synapse.Adapters.File_Bytes.Read
        (Synapse.Test_Scratch.Path (Dir, "work/" & Name), 10_000_000));

end Synapse.Test_Repo;
