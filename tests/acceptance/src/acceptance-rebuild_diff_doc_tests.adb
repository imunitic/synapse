with Ada.Strings.Fixed;
with AUnit.Assertions;

with Acceptance.Fixtures;

package body Acceptance.Rebuild_Diff_Doc_Tests is

   use Acceptance.Fixtures;
   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  The fenced ```sh block under "Branch-identity check" in the shipped
   --  command text.
   function Snippet (Doc : String) return String is
      Anchor : constant Natural :=
        Ada.Strings.Fixed.Index (Doc, "Branch-identity check");
      Fence  : constant Natural :=
        Ada.Strings.Fixed.Index (Doc (Anchor .. Doc'Last), "```sh");
      Start  : constant Natural :=
        1 + Ada.Strings.Fixed.Index (Doc (Fence .. Doc'Last), "" & LF);
      Stop   : constant Natural :=
        Ada.Strings.Fixed.Index (Doc (Start .. Doc'Last), "```");
   begin
      Assert
        (Anchor > 0 and then Fence > 0 and then Stop > 0, "snippet found");
      return Doc (Start .. Stop - 1);
   end Snippet;

   --  Runs the snippet against `Ns_Dir/Index.md`, followed by the comparison
   --  the text describes in prose and does not fence as code. Real
   --  `git symbolic-ref`, real file read: what a reader following the text
   --  would run.
   function Branch_Identity_Holds (F : Fixture; Ns_Dir : String) return Boolean
   is
      Doc         : constant String  :=
        Read_File
          (Checkout & "/packages/synapse/commands/synapse-rebuild-diff.md");
      Code        : constant String  := Snippet (Doc);
      Placeholder : constant String  := """synapse/{repo}@{branch}/Index.md""";
      At_Index    : constant Natural :=
        Ada.Strings.Fixed.Index (Code, Placeholder);
   begin
      Assert (At_Index > 0, "the placeholder is in the snippet");
      declare
         Script : constant String :=
           Code (Code'First .. At_Index - 1) & """" & Ns_Dir & "/Index.md""" &
           Code (At_Index + Placeholder'Length .. Code'Last) & LF &
           "[ ""$current_branch"" = ""$ns_branch"" ]" & LF;
         R : constant Result := Run (F, "sh", Args ("-c", Script), Repo (F));
      begin
         return R.Exit_Code = 0;
      end;
   end Branch_Identity_Holds;

   procedure Passes_On_The_Described_Branch (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F);
      Write_Synapse_Index (F, Repo_Name (F), Repo_Remote_Or_Path (F));
      Assert
        (Branch_Identity_Holds (F, Vault (F) & "/synapse/" & Repo_Name (F)),
         "the namespace describes the checked-out branch");
   end Passes_On_The_Described_Branch;

   --  A namespace that exists (built on another branch, or copied by hand)
   --  but does not describe the branch checked out: two namespaces existing
   --  is what invites the mistake, so the check has to catch it whether or
   --  not the other is well formed.
   procedure Fails_On_Another_Branchs_Namespace (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F);
      declare
         Name : constant String := Ns_Repo (F) & "@other-branch";
      begin
         Write_File
           (Vault (F) & "/synapse/" & Name & "/Index.md",
            "---" & LF & "title: """ & Name & " " & Dash & " Synapse index""" &
            LF & "node_type: synapse-index" & LF & "project: " & Ns_Repo (F) &
            LF & "branch: other-branch" & LF & "remote: """ &
            Repo_Remote_Or_Path (F) & """" & LF & "built_at: ""test""" & LF &
            "---" & LF & "# " & Name & LF);
         Assert
           (not Branch_Identity_Holds (F, Vault (F) & "/synapse/" & Name),
            "a namespace of another branch is refused");
      end;
   end Fails_On_Another_Branchs_Namespace;

   --  The directory name is sanitized and not reversible, so only the field
   --  can answer: here it still says the old branch after HEAD moved.
   procedure Fails_After_A_Branch_Change (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F      : Fixture;
      Ignore : Result;
   begin
      Make_Repo (F);
      Ignore := Git (F, "checkout", "-q", "-b", "feature-a");
      Write_Synapse_Index (F, Repo_Name (F), Repo_Remote_Or_Path (F));
      declare
         Dir : constant String := Vault (F) & "/synapse/" & Repo_Name (F);
      begin
         Ignore := Git (F, "checkout", "-q", "-b", "feature-b");
         Assert
           (not Branch_Identity_Holds (F, Dir),
            "the field still names the old branch");
      end;
   end Fails_After_A_Branch_Change;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: the rebuild-diff branch check");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Passes_On_The_Described_Branch'Access,
         "passes when the namespace describes the checked-out branch");
      Register_Routine
        (T, Fails_On_Another_Branchs_Namespace'Access,
         "fails when the namespace describes a different branch");
      Register_Routine
        (T, Fails_After_A_Branch_Change'Access,
         "fails after a branch change: the directory key is not enough");
   end Register_Tests;

end Acceptance.Rebuild_Diff_Doc_Tests;
