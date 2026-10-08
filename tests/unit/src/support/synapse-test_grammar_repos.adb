with Ada.Directories;

with Synapse.Adapters.File_Bytes;
with Synapse.Test_Scratch;

package body Synapse.Test_Grammar_Repos is

   procedure Copy_If_Present (From, To : String) is
   begin
      if Ada.Directories.Exists (From) then
         Ada.Directories.Copy_File (From, To);
      end if;
   end Copy_If_Present;

   procedure Make
     (Dir : String; Name : String; Fixture : String; Tags_Scm : String := "";
      Locals_Scm : String := "")
   is
      Repo   : constant String := Dir & "/" & Name;
      Source : constant String := "fixtures/" & Fixture & "/src";
   begin
      Ada.Directories.Create_Path (Repo & "/src/tree_sitter");
      Ada.Directories.Copy_File (Source & "/parser.c", Repo & "/src/parser.c");
      Copy_If_Present
        (Source & "/node-types.json", Repo & "/src/node-types.json");
      Ada.Directories.Copy_File
        (Source & "/tree_sitter/alloc.h", Repo & "/src/tree_sitter/alloc.h");
      Ada.Directories.Copy_File
        (Source & "/tree_sitter/array.h", Repo & "/src/tree_sitter/array.h");
      Ada.Directories.Copy_File
        (Source & "/tree_sitter/parser.h", Repo & "/src/tree_sitter/parser.h");
      if Tags_Scm /= "" or else Locals_Scm /= "" then
         Ada.Directories.Create_Path (Repo & "/queries");
      end if;
      if Tags_Scm /= "" then
         Adapters.File_Bytes.Write (Repo & "/queries/tags.scm", Tags_Scm);
      end if;
      if Locals_Scm /= "" then
         Adapters.File_Bytes.Write (Repo & "/queries/locals.scm", Locals_Scm);
      end if;
      Test_Scratch.Init_Repo (Repo);
      Test_Scratch.Git (Repo, "add", "-A");
      Test_Scratch.Git (Repo, "commit", "-q", "-m", "grammar");
   end Make;

end Synapse.Test_Grammar_Repos;
