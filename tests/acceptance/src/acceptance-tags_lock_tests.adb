with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Acceptance.Fixtures;

package body Acceptance.Tags_Lock_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Registry : constant String :=
     "{""ml"": {""repo"": ""https://example.invalid/tree-sitter-ocaml"", " &
     """scope"": ""source.ocaml""}}";

   --  A sample file, a registry that names an extension no grammar was cloned
   --  for, and a lock directory with no repository next to it: what a worker
   --  in the middle of its clone leaves behind, whether that worker is real
   --  or, as here, played by the test.
   procedure Set_Up (F : in out Fixture) is
   begin
      Write_Root_File (F, "sample.ml", "let x = 1" & LF);
      Write_File (Home (F) & "/.claude/synapse-grammars.conf", Registry);
      Set_Env (F, "SYNAPSE_GRAMMARS_DIR", Root (F) & "/grammars");
      Make_Dir (Root (F) & "/grammars/repos/tree-sitter-ocaml.lock");
   end Set_Up;

   procedure Keep_A_Git_Log (F : in out Fixture) is
   begin
      Set_Env (F, "FAKE_GIT_LOG", Root (F) & "/git.log");
      Write_Root_File (F, "git.log", "");
   end Keep_A_Git_Log;

   procedure A_Waiter_Takes_Over_A_Finished_Clone (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F      : Fixture;
      Waiter : Background;
   begin
      Set_Up (F);
      Keep_A_Git_Log (F);
      Start
        (Waiter, Synapse_Fake_Bin, Args ("tags", Root (F) & "/sample.ml"),
         Repo (F));

      --  Long enough that a waiter that raced the lock and did not honour it
      --  would have finished, and logged a clone, by now.
      delay 0.5;
      Assert_Equal
        (Read_File (Root (F) & "/git.log"), "", "no clone while locked");

      --  The other worker finishes: the repository appears, then its lock is
      --  released, in the order the clone-then-unlock path uses.
      Make_Dir (Root (F) & "/grammars/repos/tree-sitter-ocaml");
      Delete_Tree (Root (F) & "/grammars/repos/tree-sitter-ocaml.lock");

      declare
         R : constant Result := Await (Waiter);
      begin
         Assert_Exit (R, 0, "tags");
         Assert_Contains (Both (R), "FAKE_NAME", "tagged");
         Assert_Equal
           (Read_File (Root (F) & "/git.log"), "", "no clone at all");
      end;
   end A_Waiter_Takes_Over_A_Finished_Clone;

   procedure A_Released_Lock_With_No_Repo_Means_The_Waiter_Clones
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F      : Fixture;
      Waiter : Background;
   begin
      Set_Up (F);
      Keep_A_Git_Log (F);
      Start
        (Waiter, Synapse_Fake_Bin, Args ("tags", Root (F) & "/sample.ml"),
         Repo (F));
      delay 0.5;

      --  The other worker's clone failed: the lock is released and the
      --  repository never appeared. The waiter must not conclude that
      --  someone else has it, for good.
      Delete_Tree (Root (F) & "/grammars/repos/tree-sitter-ocaml.lock");

      declare
         R : constant Result := Await (Waiter);
      begin
         Assert_Exit (R, 0, "tags");
         Assert_Contains (Both (R), "FAKE_NAME", "tagged");
         Assert_Contains
           (Read_File (Root (F) & "/git.log"), "clone", "the waiter cloned");
         Assert
           (Exists (Root (F) & "/grammars/repos/tree-sitter-ocaml"),
            "the repository exists");
      end;
   end A_Released_Lock_With_No_Repo_Means_The_Waiter_Clones;

   --  Drops the `synapse:` and `synapse-tags:` warning lines: the noise per
   --  extension mixed into a program's output.
   function Without_Warnings (Text : String) return String is
      Result : Unbounded_String;
   begin
      for Item of Lines (Text) loop
         declare
            Line : constant String := To_String (Item);
         begin
            if Line /= "" and then not Starts_With (Line, "synapse:")
              and then not Starts_With (Line, "synapse-tags:")
            then
               Append (Result, Line & LF);
            end if;
         end;
      end loop;
      return To_String (Result);
   end Without_Warnings;

   procedure A_Wedged_Lock_Times_Out_And_Is_Left_Alone
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Set_Up (F);
      Set_Env (F, "SYNAPSE_GRAMMAR_LOCK_TRIES", "3");
      declare
         R : constant Result := Run_Fake (F, "tags", Root (F) & "/sample.ml");
      begin
         Assert_Exit (R, 1, "tags");
         --  Stdout is empty, which is the part callers parse; the timeout is
         --  said on stderr.
         Assert_Equal (Without_Warnings (To_String (R.Output)), "", "stdout");
         Assert_Equal (Without_Warnings (To_String (R.Errors)), "", "stderr");
      end;
      --  A waiter that timed out does not own the lock and must not delete it.
      Assert
        (Exists (Root (F) & "/grammars/repos/tree-sitter-ocaml.lock"),
         "the lock is left for its owner");
      Assert
        (not Exists (Root (F) & "/grammars/repos/tree-sitter-ocaml"),
         "nothing was cloned");
   end A_Wedged_Lock_Times_Out_And_Is_Left_Alone;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: the grammar lock");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Waiter_Takes_Over_A_Finished_Clone'Access,
         "a waiter picks up another worker's finished clone");
      Register_Routine
        (T, A_Released_Lock_With_No_Repo_Means_The_Waiter_Clones'Access,
         "a lock released with no repository means the waiter clones");
      Register_Routine
        (T, A_Wedged_Lock_Times_Out_And_Is_Left_Alone'Access,
         "a wedged lock times out and is left for its owner");
   end Register_Tests;

end Acceptance.Tags_Lock_Tests;
