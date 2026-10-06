with Ada.Strings.Unbounded;

with AUnit.Assertions;

package body Synapse.Core.Identity.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function Shown (Found : Maybe_Text) return String
   is (if Found.Found then "<" & To_String (Found.Text) & ">" else "none");

   procedure The_Repo_Name_Comes_Off_Every_Form_Of_Remote
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Repo_Name ("ssh://git@git.example.com:7999/team/widget-core.git")
              = "widget-core", "ssh with a port");
      Assert (Repo_Name ("git@github.com:org/widget-core.git") = "widget-core",
              "scp-like");
      Assert (Repo_Name ("https://github.com/org/widget-core") = "widget-core",
              "https");
      Assert (Repo_Name ("/home/x/Development/widget-core") = "widget-core",
              "a path");
      Assert (Repo_Name ("host:repo.git") = "repo", "no slash at all");
      Assert (Repo_Name ("https://github.com/org/widget-core/")
              = "widget-core", "a trailing slash");
      Assert (Repo_Name ("repo") = "repo", "just a name");
      Assert (Repo_Name ("") = "", "empty");
      Assert (Repo_Name ("/") = "", "the root");
      Assert (Repo_Name ("a/.git") = "", "only the suffix");
   end The_Repo_Name_Comes_Off_Every_Form_Of_Remote;

   procedure A_Name_Containing_Git_Only_Loses_A_Trailing_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Repo_Name ("/x/dot.git.inside") = "dot.git.inside", "inside");
      Assert (Repo_Name ("/x/.gitignore-tools") = ".gitignore-tools",
              "a leading dot");
      Assert (Repo_Name ("/x/a.git.git") = "a.git", "only one suffix");
   end A_Name_Containing_Git_Only_Loses_A_Trailing_One;

   procedure A_Branch_Is_Sanitized_To_One_Directory_Name
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Sanitize_Branch ("feature/CORE-101490-deployment-mode")
              = "feature-CORE-101490-deployment-mode", "a slash");
      Assert (Sanitize_Branch ("a:b*c?d""e<f>g|h") = "a-b-c-d-e-f-g-h",
              "every illegal character");
      Assert (Sanitize_Branch ("main") = "main", "nothing to do");
      Assert (Sanitize_Branch ("") = "", "empty");
      Assert (Namespace ("widget-core", "master") = "widget-core@master",
              "the key is repo@branch");
      Assert (Namespace (Repo_Name ("git@host:org/r.git"),
                         Sanitize_Branch ("fix/x")) = "r@fix-x",
              "composed");
   end A_Branch_Is_Sanitized_To_One_Directory_Name;

   procedure A_Git_File_Names_The_Worktree_Git_Dir (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Shown (Parse_Git_Dir_File
                       ("gitdir: /home/x/src/repo/.git/worktrees/wt" & LF))
              = "</home/x/src/repo/.git/worktrees/wt>", "absolute");
      Assert (Shown (Parse_Git_Dir_File ("gitdir: ../.git/worktrees/wt"))
              = "<../.git/worktrees/wt>", "relative");
      Assert (Shown (Parse_Git_Dir_File ("gitdir:" & LF)) = "none",
              "empty path");
      Assert (Shown (Parse_Git_Dir_File ("something else" & LF)) = "none",
              "not a gitdir file");
      Assert (Shown (Parse_Git_Dir_File
                       ("junk" & LF & "  gitdir:   p q  " & Character'Val (13)
                        & LF)) = "<p q>", "a later line, trimmed");
      Assert (Shown (Parse_Git_Dir_File ("")) = "none", "empty");
   end A_Git_File_Names_The_Worktree_Git_Dir;

   procedure HEAD_Names_A_Branch_And_A_Detached_One_Names_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Shown (Parse_Head ("ref: refs/heads/master" & LF)) = "<master>",
              "a branch");
      Assert (Shown (Parse_Head ("ref: refs/heads/feature/CORE-1" & LF))
              = "<feature/CORE-1>", "with a slash");
      Assert (Shown (Parse_Head ("9f1c2b3d4e5f60718293a4b5c6d7e8f901234567"
                                 & LF)) = "none", "detached");
      Assert (Shown (Parse_Head ("ref: refs/remotes/origin/master" & LF))
              = "none", "not a branch");
      Assert (Shown (Parse_Head ("ref: refs/heads/" & LF)) = "none",
              "an empty branch");
      Assert (Shown (Parse_Head ("")) = "none", "empty");
   end HEAD_Names_A_Branch_And_A_Detached_One_Names_None;

   procedure The_Remote_Url_Comes_Out_Of_A_Real_Configs_Shape
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Config : constant String :=
        "[core]" & LF & HT & "repositoryformatversion = 0" & LF & HT
        & "bare = false" & LF
        & "[remote ""upstream""]" & LF & HT & "url = ssh://git@host/other.git"
        & LF & HT & "fetch = +refs/heads/*:refs/remotes/upstream/*" & LF
        & "[remote ""origin""]" & LF
        & HT & "url = ssh://git@host:7999/team/widget-core.git" & LF & HT
        & "fetch = +refs/heads/*:refs/remotes/origin/*" & LF
        & "[branch ""master""]" & LF & HT & "remote = origin" & LF;
   begin
      Assert (Shown (Remote_Url_From_Config (Config, "origin"))
              = "<ssh://git@host:7999/team/widget-core.git>",
              "the preferred remote, not the first");
      Assert (Shown (Remote_Url_From_Config (Config, "upstream"))
              = "<ssh://git@host/other.git>", "any named remote");
   end The_Remote_Url_Comes_Out_Of_A_Real_Configs_Shape;

   procedure Without_Origin_The_First_Remote_Is_Used
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Shown (Remote_Url_From_Config
                       ("[remote ""beta""]" & LF & HT
                        & "url = ssh://git@host/beta.git" & LF
                        & "[remote ""alpha""]" & LF & HT
                        & "url = ssh://git@host/alpha.git" & LF, "origin"))
              = "<ssh://git@host/beta.git>", "in file order");
      Assert (Shown (Remote_Url_From_Config
                       ("[core]" & LF & HT & "bare = false" & LF, "origin"))
              = "none", "no remote at all");
      Assert (Shown (Remote_Url_From_Config ("", "origin")) = "none", "empty");
   end Without_Origin_The_First_Remote_Is_Used;

   procedure Comments_Quotes_And_The_Old_Form_Are_Understood
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      function Url (Config : String) return String
      is (Shown (Remote_Url_From_Config (Config, "origin")));
   begin
      Assert (Url ("# a comment" & LF & "[remote ""origin""]" & LF & HT
                   & "url = ssh://h/r.git ; trailing" & LF) = "<ssh://h/r.git>",
              "a trailing comment");
      Assert (Url ("[remote ""origin""]" & LF & HT & "url = ""ssh://h/r.git"""
                   & LF) = "<ssh://h/r.git>", "quotes");
      Assert (Url ("[remote.origin]" & LF & HT & "URL = ssh://h/r.git" & LF)
              = "<ssh://h/r.git>", "the old form, any case of the key");
      Assert (Url ("[gui]" & LF & HT & "url = ssh://h/wrong.git" & LF)
              = "none", "a url outside a remote");
      Assert (Url ("[remote ""origin""]" & LF & HT & "url =" & LF) = "none",
              "an empty url");
      Assert (Url ("[remote ""origin""]" & LF & "; url = ssh://h/c.git" & LF
                   & HT & "url = ssh://h/r.git" & LF) = "<ssh://h/r.git>",
              "a commented-out url");
      Assert (Url ("[remote ""origin""]" & LF & HT & "fetch = x" & LF) = "none",
              "a remote with no url");
      Assert (Url ("[remote ""origin""]" & LF & HT & "url = a" & LF
                   & "[remote ""other""]" & LF & HT & "url = b" & LF)
              = "<a>", "the first of two");
      Assert (Url ("[remote ""origin""" & LF & HT & "url = a" & LF) = "none",
              "a header with no closing bracket is skipped");
   end Comments_Quotes_And_The_Old_Form_Are_Understood;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Identity");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Repo_Name_Comes_Off_Every_Form_Of_Remote'Access,
         "The repo name comes off every form of remote");
      Register_Routine
        (T, A_Name_Containing_Git_Only_Loses_A_Trailing_One'Access,
         "A name containing .git only loses a trailing one");
      Register_Routine
        (T, A_Branch_Is_Sanitized_To_One_Directory_Name'Access,
         "A branch is sanitized to one directory name");
      Register_Routine
        (T, A_Git_File_Names_The_Worktree_Git_Dir'Access,
         "A .git file names the worktree git dir");
      Register_Routine
        (T, HEAD_Names_A_Branch_And_A_Detached_One_Names_None'Access,
         "HEAD names a branch and a detached one names none");
      Register_Routine
        (T, The_Remote_Url_Comes_Out_Of_A_Real_Configs_Shape'Access,
         "The remote url comes out of a real config's shape");
      Register_Routine
        (T, Without_Origin_The_First_Remote_Is_Used'Access,
         "Without origin the first remote is used");
      Register_Routine
        (T, Comments_Quotes_And_The_Old_Form_Are_Understood'Access,
         "Comments, quotes and the old form are understood");
   end Register_Tests;

end Synapse.Core.Identity.Tests;
