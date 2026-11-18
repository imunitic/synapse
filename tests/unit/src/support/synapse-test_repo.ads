with Synapse.Test_Environment;
with Synapse.Test_Scratch;

--  A repository of tracked files and a work directory for the commands that
--  list a checkout's files: the repository is `Dir/repo`, the work directory
--  root `Dir/wroot`, so that the work directory of the repository's namespace
--  is `Dir/wroot/widget@main`, and the home `Dir/home`.
package Synapse.Test_Repo is

   --  The root of the work directory, and the folder of the repository's
   --  namespace in it, under a scratch directory.
   Root_Rel : constant String := "wroot";
   Namespace : constant String := "widget@main";
   Work_Rel  : constant String := "wroot/" & Namespace;

   --  Points the variables of F at the work directory and the home of Dir.
   procedure Use_Work
     (F   : in out Synapse.Test_Environment.Fixture;
      Dir :        Synapse.Test_Scratch.Scratch);

   --  A file of the repository, with its directories.
   procedure Put_File
     (Dir : Synapse.Test_Scratch.Scratch; Name, Text : String);

   --  Makes the repository and tracks everything put in it.
   procedure Commit_All (Dir : Synapse.Test_Scratch.Scratch);

   --  The repository's directory.
   function Repo (Dir : Synapse.Test_Scratch.Scratch) return String;

   --  The text of a file of the work directory.
   function Work_File
     (Dir : Synapse.Test_Scratch.Scratch; Name : String) return String;

end Synapse.Test_Repo;
