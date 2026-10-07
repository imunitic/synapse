with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Git_Identity.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Tail (Text, Suffix : String) return Boolean
   is (Text'Length >= Suffix'Length
       and then Text (Text'Last - Suffix'Length + 1 .. Text'Last) = Suffix);

   function Parent_Of (Path : String) return String is
   begin
      return Ada.Directories.Containing_Directory (Path);
   exception
      when others =>
         return "";
   end Parent_Of;

   procedure A_Repository_With_A_Remote_Is_Named_From_The_Remote
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Init_Repo (Path (Dir));
      Git (Path (Dir), "remote", "add", "origin",
           "git@git.example.com:team/widget-core.git");
      declare
         Found : constant Core.Identity.Resolved := Resolve (Path (Dir));
      begin
         Assert (To_String (Found.Key) = "widget-core@main", "the key");
         Assert (To_String (Found.Branch) = "main"
                 and then To_String (Found.Branch_Key) = "main", "the branch");
         Assert (To_String (Found.Remote)
                 = "git@git.example.com:team/widget-core.git", "the remote");
         Assert (Tail (To_String (Found.Where.Repo_Root),
                       Ada.Directories.Simple_Name (Path (Dir))),
                 "the root is the repository");
         Assert (To_String (Found.Where.Git_Dir)
                 = To_String (Found.Where.Common_Dir), "no worktree");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Repository_With_A_Remote_Is_Named_From_The_Remote;

   procedure Resolving_Works_From_A_Subdirectory (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Init_Repo (Path (Dir));
      Git (Path (Dir), "remote", "add", "origin", "https://example.com/o/r");
      Ada.Directories.Create_Path (Path (Dir, "a/b/c"));
      Assert (To_String (Resolve (Path (Dir, "a/b/c")).Key) = "r@main",
              "found by walking up");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Resolving_Works_From_A_Subdirectory;

   procedure Without_A_Remote_The_Root_Gives_The_Name (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Init_Repo (Path (Dir));
      declare
         Found : constant Core.Identity.Resolved := Resolve (Path (Dir));
      begin
         Assert (To_String (Found.Remote) = To_String (Found.Where.Repo_Root),
                 "the root stands in for the remote");
         Assert (Tail (To_String (Found.Key),
                       "@main"), "and the key has its branch");
         Assert (Remote_Of (Found.Where) = To_String (Found.Remote),
                 "Remote_Of agrees");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Without_A_Remote_The_Root_Gives_The_Name;

   procedure Without_Origin_The_First_Remote_Is_Used (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Init_Repo (Path (Dir));
      Git (Path (Dir), "remote", "add", "upstream", "ssh://h/x/up.git");
      Assert (To_String (Resolve (Path (Dir)).Key) = "up@main", "upstream");
      Git (Path (Dir), "remote", "add", "origin", "ssh://h/x/mine.git");
      Assert (To_String (Resolve (Path (Dir)).Key) = "mine@main",
              "and then origin wins");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Without_Origin_The_First_Remote_Is_Used;

   procedure A_Branch_With_A_Slash_Gets_A_Safe_Key (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Init_Repo (Path (Dir));
      Git (Path (Dir), "remote", "add", "origin", "https://example.com/o/r");
      File_Bytes.Write (Path (Dir, "a.md"), "x");
      Git (Path (Dir), "add", "-A");
      Git (Path (Dir), "commit", "-q", "-m", "one");
      Git (Path (Dir), "checkout", "-q", "-b", "feature/CORE-1");
      declare
         Found : constant Core.Identity.Resolved := Resolve (Path (Dir));
      begin
         Assert (To_String (Found.Branch) = "feature/CORE-1",
                 "the branch as HEAD names it");
         Assert (To_String (Found.Key) = "r@feature-CORE-1", "the key");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Branch_With_A_Slash_Gets_A_Safe_Key;

   procedure A_Detached_Head_Has_No_Namespace (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      Raised : Boolean := False;
   begin
      Init_Repo (Path (Dir));
      File_Bytes.Write (Path (Dir, "a.md"), "x");
      Git (Path (Dir), "add", "-A");
      Git (Path (Dir), "commit", "-q", "-m", "one");
      Git (Path (Dir), "checkout", "-q", "--detach");
      begin
         declare
            Ignore : constant Core.Identity.Resolved := Resolve (Path (Dir));
         begin
            null;
         end;
      exception
         when Core.Identity.Detached_Head =>
            Raised := True;
      end;
      Assert (Raised, "Detached_Head");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Detached_Head_Has_No_Namespace;

   procedure A_Linked_Worktree_Resolves_To_Its_Own_Branch
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Ada.Directories.Create_Path (Path (Dir, "main"));
      Init_Repo (Path (Dir, "main"));
      Git (Path (Dir, "main"), "remote", "add", "origin",
           "https://example.com/o/widget.git");
      File_Bytes.Write (Path (Dir, "main/a.md"), "x");
      Git (Path (Dir, "main"), "add", "-A");
      Git (Path (Dir, "main"), "commit", "-q", "-m", "one");
      Git (Path (Dir, "main"), "worktree", "add", "-q", "-b", "side/branch",
           Path (Dir, "wt"));

      declare
         Parent   : constant Core.Identity.Resolved :=
           Resolve (Path (Dir, "main"));
         Worktree : constant Core.Identity.Resolved :=
           Resolve (Path (Dir, "wt"));
      begin
         Assert (To_String (Parent.Key) = "widget@main", "the parent");
         Assert (To_String (Worktree.Key) = "widget@side-branch",
                 "the worktree has its own branch: "
                 & To_String (Worktree.Key));
         Assert (To_String (Worktree.Remote)
                 = "https://example.com/o/widget.git",
                 "and the remote from the shared config");
         Assert (To_String (Worktree.Where.Git_Dir)
                 /= To_String (Worktree.Where.Common_Dir),
                 "its git dir is not the common one");
         Assert (Tail (To_String (Worktree.Where.Common_Dir), "/main/.git"),
                 "which is the parent's: "
                 & To_String (Worktree.Where.Common_Dir));
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Linked_Worktree_Resolves_To_Its_Own_Branch;

   procedure A_Directory_That_Is_Not_In_A_Repository_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Base    : constant String := File_Bytes.Temp_Dir;
      Where   : constant String := Base & "/synapse-no-repo-test";
      Inside  : Boolean := False;
      Raised  : Boolean := False;
      Cursor  : Unbounded_String := To_Unbounded_String (Base);
   begin
      --  Only meaningful where no parent of the temporary directory is a
      --  repository.
      loop
         exit when Length (Cursor) = 0;
         if Ada.Directories.Exists (To_String (Cursor) & "/.git") then
            Inside := True;
         end if;
         declare
            Parent : constant String := Parent_Of (To_String (Cursor));
         begin
            exit when Parent = To_String (Cursor) or else Parent = "";
            Cursor := To_Unbounded_String (Parent);
         end;
      end loop;
      if Inside then
         return;
      end if;
      Ada.Directories.Create_Path (Where);
      begin
         declare
            Ignore : constant Core.Identity.Layout := Find_Layout (Where);
         begin
            null;
         end;
      exception
         when Core.Identity.Not_A_Git_Repo =>
            Raised := True;
      end;
      Ada.Directories.Delete_Tree (Where);
      Assert (Raised, "Not_A_Git_Repo");

      Raised := False;
      begin
         declare
            Ignore : constant Core.Identity.Layout :=
              Find_Layout ("/synapse/no/such/directory");
         begin
            null;
         end;
      exception
         when Core.Identity.Not_A_Git_Repo =>
            Raised := True;
      end;
      Assert (Raised, "a directory that does not exist");
   end A_Directory_That_Is_Not_In_A_Repository_Is_Refused;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Git_Identity");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Repository_With_A_Remote_Is_Named_From_The_Remote'Access,
         "A repository with a remote is named from the remote");
      Register_Routine
        (T, Resolving_Works_From_A_Subdirectory'Access,
         "Resolving works from a subdirectory");
      Register_Routine
        (T, Without_A_Remote_The_Root_Gives_The_Name'Access,
         "Without a remote the root gives the name");
      Register_Routine
        (T, Without_Origin_The_First_Remote_Is_Used'Access,
         "Without origin the first remote is used");
      Register_Routine
        (T, A_Branch_With_A_Slash_Gets_A_Safe_Key'Access,
         "A branch with a slash gets a safe key");
      Register_Routine
        (T, A_Detached_Head_Has_No_Namespace'Access,
         "A detached HEAD has no namespace");
      Register_Routine
        (T, A_Linked_Worktree_Resolves_To_Its_Own_Branch'Access,
         "A linked worktree resolves to its own branch");
      Register_Routine
        (T, A_Directory_That_Is_Not_In_A_Repository_Is_Refused'Access,
         "A directory that is not in a repository is refused");
   end Register_Tests;

end Synapse.Adapters.Git_Identity.Tests;
