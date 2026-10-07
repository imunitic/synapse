with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;

package body Synapse.Commands.Context.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  A fixture whose variables pin everything, so no checkout is read.
   procedure Pin
     (F : in out Fixture; Dir : Scratch; Namespace : String := "widget@main")
   is
   begin
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "vault"));
      F.Vars.Set ("HOME", Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_NAMESPACE", Namespace);
      F.Vars.Set ("SYNAPSE_REPO_ROOT", "/work/widget");
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", "https://host.example/org/widget.git");
   end Pin;

   procedure Write_Index (Dir : Scratch; Namespace, Branch, Remote : String) is
   begin
      Ada.Directories.Create_Path (Path (Dir, "vault/synapse/" & Namespace));
      Adapters.File_Bytes.Write
        (Path (Dir, "vault/synapse/" & Namespace & "/Index.md"),
         "---" & LF & "branch: " & Branch & LF & "remote: " & Remote & LF &
         "---" & LF & "# Index" & LF);
   end Write_Index;

   procedure Everything_Pinned_Resolves_Without_A_Checkout
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      declare
         Got : constant Maybe_Context := Resolve (Env (F), "synapse-x");
      begin
         Assert (Got.Found, "found");
         Assert
           (To_String (Got.Value.Namespace) = "widget@main"
            and then To_String (Got.Value.Repo_Root) = "/work/widget"
            and then To_String (Got.Value.Branch) = "main",
            "the pinned values");
         Assert
           (To_String (Got.Value.Dir) = "synapse/widget@main"
            and then To_String (Got.Value.Abs_Dir) =
              Path (Dir, "vault") & "/synapse/widget@main",
            "its directory");
         Assert
           (To_String (Got.Value.Work_Dir) =
            Path (Dir, "home") & "/.cache/synapse/work/widget@main",
            "the default work directory");
         Assert (not Got.Value.Namespace_Explicit, "derived, not named");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Everything_Pinned_Resolves_Without_A_Checkout;

   procedure The_Work_Directory_Can_Be_Set (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      F.Vars.Set ("SYNAPSE_WORK_DIR", "/elsewhere");
      Assert
        (Ada.Strings.Unbounded.To_String
           (Resolve (Env (F), "p").Value.Work_Dir) =
         "/elsewhere",
         "the variable wins");
      F.Vars.Set ("SYNAPSE_WORK_DIR", "");
      Assert
        (Ada.Strings.Unbounded.To_String
           (Resolve (Env (F), "p").Value.Work_Dir) /=
         "",
         "empty counts as unset");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Work_Directory_Can_Be_Set;

   procedure No_Vault_Is_Explained_And_Is_None (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Vars.Set ("HOME", "/nonexistent-home");
      Assert (not Resolve (Env (F), "synapse-query").Found, "none");
      Assert
        (F.Console.Err_Text = "synapse-query: no vault" & LF,
         "named with the program's prefix");
   end No_Vault_Is_Explained_And_Is_None;

   procedure Outside_A_Checkout_It_Is_Explained_And_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make_Outside_Git;
      F   : aliased Fixture;
      Was : constant String  := Ada.Directories.Current_Directory;
   begin
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "vault"));
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Ada.Directories.Set_Directory (Path (Dir));
      declare
         Got : constant Maybe_Context := Resolve (Env (F), "synapse-q");
      begin
         Ada.Directories.Set_Directory (Was);
         Assert (not Got.Found, "none");
         Assert
           (F.Console.Err_Text = "synapse-q: not inside a git repo" & LF,
            "and why");
      end;
      Remove (Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Was);
         Remove (Dir);
         raise;
   end Outside_A_Checkout_It_Is_Explained_And_None;

   procedure Only_A_Partly_Pinned_Environment_Reads_The_Checkout
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make_Outside_Git;
      Was : constant String  := Ada.Directories.Current_Directory;

      procedure Without (Missing : String) is
         F : aliased Fixture;
      begin
         Pin (F, Dir);
         F.Vars.Set (Missing, "");
         Assert
           (not Resolve (Env (F), "p").Found,
            "without " & Missing &
            " the checkout is consulted, and there is none");
      end Without;
   begin
      Ada.Directories.Set_Directory (Path (Dir));
      Without ("SYNAPSE_NAMESPACE");
      Without ("SYNAPSE_REPO_ROOT");
      Without ("SYNAPSE_BRANCH");
      Ada.Directories.Set_Directory (Was);
      Remove (Dir);
   exception
      when others =>
         Ada.Directories.Set_Directory (Was);
         Remove (Dir);
         raise;
   end Only_A_Partly_Pinned_Environment_Reads_The_Checkout;

   procedure A_Named_Namespace_Needs_No_Checkout (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "vault"));
      F.Vars.Set ("HOME", Path (Dir, "home"));
      declare
         Got : constant Maybe_Context :=
           Resolve_Explicit (Env (F), "p", "other@feature-y");
      begin
         Assert (Got.Found and then Got.Value.Namespace_Explicit, "explicit");
         Assert
           (To_String (Got.Value.Branch) = "feature-y"
            and then To_String (Got.Value.Repo_Root) = ""
            and then To_String (Got.Value.Remote) = "",
            "the branch from the name, the rest empty");
      end;
      F.Vars.Set ("SYNAPSE_REPO_ROOT", "/r");
      Assert
        (To_String (Resolve_Explicit (Env (F), "p", "a@b").Value.Repo_Root) =
         "/r",
         "a repository root from the environment");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Named_Namespace_Needs_No_Checkout;

   procedure A_Named_Namespace_Must_Have_An_At_Sign
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Vars.Set ("SYNAPSE_VAULT_DIR", "/v");
      Assert (not Resolve_Explicit (Env (F), "p", "justarepo").Found, "none");
      Assert
        (F.Console.Err_Text =
         "p: --namespace expects <repo>@<branch>, got 'justarepo'" & LF,
         "and the message");
   end A_Named_Namespace_Must_Have_An_At_Sign;

   procedure The_Boilerplate_Conf_Gives_Chains_Without_Comments
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Ada.Directories.Create_Path (Path (Dir, "home/.claude"));
      Adapters.File_Bytes.Write
        (Path (Dir, "home/.claude/synapse-module-boilerplate.conf"),
         "# a comment" & LF & "src/main/java  # trailing" & LF & LF &
         "   src/lib   " & Character'Val (13) & LF);
      declare
         Got : constant Maybe_Context := Resolve (Env (F), "p");
      begin
         Assert (Natural (Got.Value.Chains.Length) = 2, "two chains");
         Assert
           (To_String (Got.Value.Chains (1)) = "src/main/java"
            and then To_String (Got.Value.Chains (2)) = "src/lib",
            "trimmed, comments cut");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Boilerplate_Conf_Gives_Chains_Without_Comments;

   procedure A_Conf_Named_By_The_Environment_Wins (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Adapters.File_Bytes.Write (Path (Dir, "chains.txt"), "a/b" & LF);
      F.Vars.Set ("SYNAPSE_MODULE_BOILERPLATE_CONF", Path (Dir, "chains.txt"));
      Assert
        (Natural (Resolve (Env (F), "p").Value.Chains.Length) = 1,
         "read from the named file");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Conf_Named_By_The_Environment_Wins;

   procedure A_Missing_Boilerplate_Conf_Is_Not_An_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Assert (Resolve (Env (F), "p").Value.Chains.Is_Empty, "no chains");
      Assert (F.Console.Err_Text = "", "and nothing said");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Missing_Boilerplate_Conf_Is_Not_An_Error;

   procedure A_Namespace_Is_Verified_Against_Its_Index
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Write_Index
        (Dir, "widget@main", "main", "https://host.example/org/widget.git");
      Assert
        (Verify_Namespace (Env (F), Resolve (Env (F), "p").Value, "p"),
         "agrees");
      Assert (F.Console.Err_Text = "", "nothing said");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Namespace_Is_Verified_Against_Its_Index;

   procedure A_Branch_That_Disagrees_Is_Reported (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Write_Index
        (Dir, "widget@main", "other", "https://host.example/org/widget.git");
      Assert
        (not Verify_Namespace (Env (F), Resolve (Env (F), "p").Value, "p"),
         "refused");
      Assert
        (F.Console.Err_Text =
         "p: synapse/widget@main/ records branch 'other', not 'main'" & LF,
         "and says which");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Branch_That_Disagrees_Is_Reported;

   procedure A_Remote_That_Disagrees_Is_Refused_Without_A_Message
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Write_Index (Dir, "widget@main", "main", "https://elsewhere/x.git");
      Assert
        (not Verify_Namespace (Env (F), Resolve (Env (F), "p").Value, "p"),
         "refused");
      Assert (F.Console.Err_Text = "", "the caller reports it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Remote_That_Disagrees_Is_Refused_Without_A_Message;

   procedure An_Empty_Remote_Matches_An_Absent_Field_And_Not_A_Present_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      F.Vars.Set ("SYNAPSE_REMOTE", "");
      Ada.Directories.Create_Path (Path (Dir, "vault/synapse/widget@main"));
      Adapters.File_Bytes.Write
        (Path (Dir, "vault/synapse/widget@main/Index.md"),
         "---" & LF & "branch: main" & LF & "---" & LF);
      Assert
        (Verify_Namespace (Env (F), Resolve (Env (F), "p").Value, "p"),
         "no remote on either side: both read as empty, which is equal");
      Adapters.File_Bytes.Write
        (Path (Dir, "vault/synapse/widget@main/Index.md"),
         "---" & LF & "branch: main" & LF & "remote: https://x/y.git" & LF &
         "---" & LF);
      Assert
        (not Verify_Namespace (Env (F), Resolve (Env (F), "p").Value, "p"),
         "an index that names a remote does not match a context with none");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Empty_Remote_Matches_An_Absent_Field_And_Not_A_Present_One;

   procedure A_Missing_Index_Is_Explained (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Assert
        (not Verify_Namespace (Env (F), Resolve (Env (F), "p").Value, "p"),
         "refused");
      Assert
        (F.Console.Err_Text =
         "p: no namespace covers synapse/widget@main/ -- this branch " &
         "has no graph" & LF,
         "no graph");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Missing_Index_Is_Explained;

   procedure An_Explicit_Namespace_Skips_The_Remote_Check
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "vault"));
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Write_Index (Dir, "widget@dev", "dev", "https://whatever/x.git");
      Assert
        (Verify_Namespace
           (Env (F), Resolve_Explicit (Env (F), "p", "widget@dev").Value, "p"),
         "there is no remote of the current directory to compare");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Explicit_Namespace_Skips_The_Remote_Check;

   procedure Node_Paths_Take_The_Title_With_Or_Without_Md
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      Ctx : Context;
   begin
      Pin (F, Dir);
      Ctx := Resolve (Env (F), "p").Value;
      Assert
        (Node_Path (Ctx, "State machine") =
         Path (Dir, "vault") & "/synapse/widget@main/State machine.md",
         "a title");
      Assert
        (Node_Path (Ctx, "State machine.md") =
         Node_Path (Ctx, "State machine"),
         "with the extension");
      Assert
        (Strip_Md ("A.md") = "A" and then Strip_Md ("A") = "A"
         and then Strip_Md (".md") = "",
         "stripping");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Node_Paths_Take_The_Title_With_Or_Without_Md;

   procedure A_Node_Is_Read_Or_Reported_Absent (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      Ctx : Context;
   begin
      Pin (F, Dir);
      Ctx := Resolve (Env (F), "p").Value;
      Ada.Directories.Create_Path (Path (Dir, "vault/synapse/widget@main"));
      Adapters.File_Bytes.Write
        (Path (Dir, "vault/synapse/widget@main/State.md"), "body" & LF);
      Assert
        (Read_Node (Ctx, "State").Found
         and then
           Ada.Strings.Unbounded.To_String
             (Read_Node (Ctx, "State.md").Value) =
           "body" & LF,
         "with and without the extension");
      Assert (not Read_Node (Ctx, "Missing").Found, "absent");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Node_Is_Read_Or_Reported_Absent;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Context");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Everything_Pinned_Resolves_Without_A_Checkout'Access,
         "Everything pinned resolves without a checkout");
      Register_Routine
        (T, The_Work_Directory_Can_Be_Set'Access,
         "The work directory can be set");
      Register_Routine
        (T, No_Vault_Is_Explained_And_Is_None'Access,
         "No vault is explained and is none");
      Register_Routine
        (T, Outside_A_Checkout_It_Is_Explained_And_None'Access,
         "Outside a checkout it is explained and none");
      Register_Routine
        (T, Only_A_Partly_Pinned_Environment_Reads_The_Checkout'Access,
         "A partly pinned environment reads the checkout");
      Register_Routine
        (T, A_Named_Namespace_Needs_No_Checkout'Access,
         "A named namespace needs no checkout");
      Register_Routine
        (T, A_Named_Namespace_Must_Have_An_At_Sign'Access,
         "A named namespace must have an at sign");
      Register_Routine
        (T, The_Boilerplate_Conf_Gives_Chains_Without_Comments'Access,
         "The boilerplate conf gives chains without comments");
      Register_Routine
        (T, A_Conf_Named_By_The_Environment_Wins'Access,
         "A conf named by the environment wins");
      Register_Routine
        (T, A_Missing_Boilerplate_Conf_Is_Not_An_Error'Access,
         "A missing boilerplate conf is not an error");
      Register_Routine
        (T, A_Namespace_Is_Verified_Against_Its_Index'Access,
         "A namespace is verified against its index");
      Register_Routine
        (T, A_Branch_That_Disagrees_Is_Reported'Access,
         "A branch that disagrees is reported");
      Register_Routine
        (T, A_Remote_That_Disagrees_Is_Refused_Without_A_Message'Access,
         "A remote that disagrees is refused without a message");
      Register_Routine
        (T,
         An_Empty_Remote_Matches_An_Absent_Field_And_Not_A_Present_One'Access,
         "An empty remote matches an absent field and not a present one");
      Register_Routine
        (T, A_Missing_Index_Is_Explained'Access,
         "A missing index is explained");
      Register_Routine
        (T, An_Explicit_Namespace_Skips_The_Remote_Check'Access,
         "An explicit namespace skips the remote check");
      Register_Routine
        (T, Node_Paths_Take_The_Title_With_Or_Without_Md'Access,
         "Node paths take the title with or without md");
      Register_Routine
        (T, A_Node_Is_Read_Or_Reported_Absent'Access,
         "A node is read or reported absent");
   end Register_Tests;

end Synapse.Commands.Context.Tests;
