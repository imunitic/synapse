with Ada.Directories;
with Ada.Strings.Unbounded;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with AUnit.Assertions;

package body Synapse.Commands.Graph_Support.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;

   LF : constant Character := Character'Val (10);

   procedure The_Configured_Work_Directory_Wins (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Vars.Set ("SYNAPSE_WORK_DIR", "/w/here");
      F.Vars.Set ("SYNAPSE_NAMESPACE", "x@y");
      declare
         Got : constant Maybe_Path := Work_Dir (Env (F), "p");
      begin
         Assert
           (Got.Found and then To_String (Got.Value) = "/w/here", "as set");
      end;
   end The_Configured_Work_Directory_Wins;

   procedure The_Work_Directory_Is_Named_For_The_Namespace_Under_The_Home
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Vars.Set ("HOME", "/home/u");
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      declare
         Got : constant Maybe_Path := Work_Dir (Env (F), "p");
      begin
         Assert
           (Got.Found
            and then To_String (Got.Value) =
              "/home/u/.cache/synapse/work/widget@main",
            "under the cache");
      end;
   end The_Work_Directory_Is_Named_For_The_Namespace_Under_The_Home;

   procedure Without_A_Home_There_Is_No_Work_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      Assert (not Work_Dir (Env (F), "p").Found, "none");
      Assert
        (F.Console.Err_Text = "p: no HOME, so no default work dir" & LF,
         "says so: " & F.Console.Err_Text);
   end Without_A_Home_There_Is_No_Work_Directory;

   procedure A_Directory_Outside_A_Repository_Has_No_Work_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make_Outside_Git;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", "/home/u");
      Assert (not Work_Dir (Env (F), "p", Path (Dir)).Found, "none");
      Assert (F.Console.Err_Text = "p: not inside a git repo" & LF, "says so");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Directory_Outside_A_Repository_Has_No_Work_Directory;

   procedure A_Namespace_Names_Its_Work_Directory_Without_A_Checkout
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Vars.Set ("HOME", "/home/u");
      declare
         Got : constant Maybe_Path :=
           Work_Dir_For_Namespace (Env (F), "a@b", "p");
      begin
         Assert
           (Got.Found
            and then To_String (Got.Value) = "/home/u/.cache/synapse/work/a@b",
            "named");
      end;
      F.Vars.Set ("SYNAPSE_WORK_DIR", "/w");
      Assert
        (To_String (Work_Dir_For_Namespace (Env (F), "a@b", "p").Value) = "/w",
         "the setting wins");
      Assert
        (not Work_Dir_For_Namespace (Env (F), "ab", "p").Found, "no at sign");
      Assert
        (F.Console.Err_Text =
         "p: --namespace expects <repo>@<branch>, got 'ab'" & LF,
         "says so");
   end A_Namespace_Names_Its_Work_Directory_Without_A_Checkout;

   procedure The_Repository_Root_Is_Found_From_A_Directory_Inside_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Ada.Directories.Create_Path (Path (Dir, "repo/sub/deep"));
      Synapse.Test_Scratch.Init_Repo (Path (Dir, "repo"));
      declare
         Root : constant String :=
           Repo_Root (Env (F), Path (Dir, "repo/sub/deep"));
      begin
         Assert
           (Root'Length >= 5
            and then Root (Root'Last - 4 .. Root'Last) = "/repo",
            "the top, whole: " & Root);
      end;
      Assert
        (Repo_Root (Env (F), Path (Dir, "none")) = "", "no such directory");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Repository_Root_Is_Found_From_A_Directory_Inside_It;

   procedure The_Listing_Limit_Comes_From_The_Variable_When_It_Is_A_Number
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Max_Listing_Bytes (Env (F), 7) = 7, "the default");
      F.Vars.Set ("SYNAPSE_MAX_LISTING_BYTES", "123");
      Assert (Max_Listing_Bytes (Env (F), 7) = 123, "the variable");
      F.Vars.Set ("SYNAPSE_MAX_LISTING_BYTES", "12x");
      Assert (Max_Listing_Bytes (Env (F), 7) = 7, "not a number");
      F.Vars.Set ("SYNAPSE_MAX_LISTING_BYTES", "");
      Assert (Max_Listing_Bytes (Env (F), 7) = 7, "empty");
      F.Vars.Set ("SYNAPSE_MAX_LISTING_BYTES", "99999999999999999999");
      Assert
        (Max_Listing_Bytes (Env (F), 7) = Natural'Last, "beyond the range");
   end The_Listing_Limit_Comes_From_The_Variable_When_It_Is_A_Number;

   procedure Files_Are_Written_With_Their_Directories_And_Read_Back
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      declare
         Text  : Unbounded_String;
         Found : Boolean;
      begin
         Write_File (Path (Dir, "a/b/c.txt"), "text" & LF);
         Read_File (Path (Dir, "a/b/c.txt"), 100, Text, Found);
         Assert (Found and then To_String (Text) = "text" & LF, "round trip");
         Read_File (Path (Dir, "a/b/c.txt"), 2, Text, Found);
         Assert (not Found, "over the limit");
         Read_File (Path (Dir, "gone"), 100, Text, Found);
         Assert (not Found and then Length (Text) = 0, "missing");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Files_Are_Written_With_Their_Directories_And_Read_Back;

   procedure Grep_Keeps_Or_Drops_The_Lines_That_Match
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      declare
         Output  : Unbounded_String;
         Outcome : Grep_Outcome;
      begin
         Grep
           (Env (F), "-E", "^a", "ab" & LF & "ba" & LF & "ac" & LF, Output,
            Outcome);
         Assert
           (Outcome = Matched
            and then To_String (Output) = "ab" & LF & "ac" & LF,
            "kept");
         Grep (Env (F), "-vE", "^a", "ab" & LF & "ba" & LF, Output, Outcome);
         Assert
           (Outcome = Matched and then To_String (Output) = "ba" & LF,
            "dropped");
         Grep (Env (F), "-E", "zz", "ab" & LF, Output, Outcome);
         Assert
           (Outcome = Nothing_Matched and then Length (Output) = 0, "nothing");
         Grep (Env (F), "-vE", "a", "ab" & LF, Output, Outcome);
         Assert (Outcome = Nothing_Matched, "everything dropped");
         Grep (Env (F), "-E", "(", "ab" & LF, Output, Outcome);
         Assert (Outcome = Failed, "a pattern grep cannot read");
      end;
   end Grep_Keeps_Or_Drops_The_Lines_That_Match;

   procedure Removal_Stays_Inside_The_Vault_Namespaces
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      F      : aliased Fixture;
      Vault  : constant String  := Path (Dir, "vault");
      Inside : constant String  := Vault & "/synapse/widget@main";
   begin
      Ada.Directories.Create_Path (Inside & "/deeper");
      Ada.Directories.Create_Path (Path (Dir, "elsewhere"));
      Assert
        (not Remove_Namespace
           (Env (F), Vault, Path (Dir, "elsewhere"), "prog"),
         "outside the vault");
      Assert
        (not Remove_Namespace (Env (F), Vault, Vault & "/synapse/", "prog"),
         "the namespaces' own directory");
      Assert
        (not Remove_Namespace (Env (F), Vault, Vault & "/synapse", "prog"),
         "without the slash");
      Assert
        (F.Console.Err_Text =
         "prog: refusing to remove " & Path (Dir, "elsewhere") &
         Character'Val (10) & "prog: refusing to remove " & Vault &
         "/synapse/" & Character'Val (10) & "prog: refusing to remove " &
         Vault & "/synapse" & Character'Val (10),
         "the messages: " & F.Console.Err_Text);
      Assert (Ada.Directories.Exists (Path (Dir, "elsewhere")), "left alone");
      Assert (Remove_Namespace (Env (F), Vault, Inside, "prog"), "inside");
      Assert (not Ada.Directories.Exists (Inside), "gone with what it held");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Removal_Stays_Inside_The_Vault_Namespaces;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Graph_Support");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Configured_Work_Directory_Wins'Access,
         "The configured work directory wins");
      Register_Routine
        (T,
         The_Work_Directory_Is_Named_For_The_Namespace_Under_The_Home'Access,
         "The work directory is named for the namespace under the home");
      Register_Routine
        (T, Without_A_Home_There_Is_No_Work_Directory'Access,
         "Without a home there is no work directory");
      Register_Routine
        (T, A_Directory_Outside_A_Repository_Has_No_Work_Directory'Access,
         "A directory outside a repository has no work directory");
      Register_Routine
        (T, A_Namespace_Names_Its_Work_Directory_Without_A_Checkout'Access,
         "A namespace names its work directory without a checkout");
      Register_Routine
        (T, The_Repository_Root_Is_Found_From_A_Directory_Inside_It'Access,
         "The repository root is found from a directory inside it");
      Register_Routine
        (T,
         The_Listing_Limit_Comes_From_The_Variable_When_It_Is_A_Number'Access,
         "The listing limit comes from the variable when it is a number");
      Register_Routine
        (T, Files_Are_Written_With_Their_Directories_And_Read_Back'Access,
         "Files are written with their directories and read back");
      Register_Routine
        (T, Grep_Keeps_Or_Drops_The_Lines_That_Match'Access,
         "Grep keeps or drops the lines that match");
      Register_Routine
        (T, Removal_Stays_Inside_The_Vault_Namespaces'Access,
         "Removal stays inside the vault namespaces");
   end Register_Tests;

end Synapse.Commands.Graph_Support.Tests;
