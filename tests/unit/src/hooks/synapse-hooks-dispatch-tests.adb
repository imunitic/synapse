with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with Synapse.Commands;
with AUnit.Assertions;

package body Synapse.Hooks.Dispatch.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Remote : constant String := "https://example.com/o/widget.git";

   Engine_Source : constant String :=
     "pub fn start() void {}" & LF & "pub fn stop() void {}" & LF &
     "const x = 1;" & LF;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure Work (Dir : Scratch; Name, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path (Dir, "work/" & Name)));
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "work/" & Name), Text);
   end Work;

   function Node (Dir : Scratch; File : String) return String is
     (Synapse.Adapters.File_Bytes.Read
        (Path (Dir, "vault/synapse/widget@main/" & File), 1_000_000));

   --  The context pinned to a checkout on `main`; no graph yet.
   procedure Pin (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Vault (F, Dir);
      F.Clock.Now := To_Unbounded_String ("2026-09-07T14:32:05+02:00");
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      Put_File (Dir, "src/engine.ext", Engine_Source);
      Put_File (Dir, "src/render.ext", "paint" & LF);
      Put_File (Dir, "README.md", "hello" & LF);
      Commit_All (Dir);
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", Repo (Dir));
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", Remote);
   end Pin;

   procedure Feed (F : aliased in out Fixture; Text : String) is
   begin
      F.Console.Set_Stdin (Text);
   end Feed;

   function Quote (Text : String) return String is ("""" & Text & """");

   procedure An_Unknown_Hook_Is_A_Usage_Error_And_Nothing_Else_Is
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("wat")) = 2, "unknown");
      Assert
        (Has
           (F.Console.Err_Text,
            "synapse-hook: unknown hook 'wat'" & LF &
            "usage: synapse-hook <hook>"),
         "named: " & F.Console.Err_Text);
      F.Console.Clear;
      Assert (Run (Env (F), Args) = 2, "none");
      Assert (Has (F.Console.Err_Text, "usage: synapse-hook <hook>"), "usage");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (Has (F.Console.Err_Text, "staleness        PostToolUse"),
         "lists them");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Unknown_Hook_Is_A_Usage_Error_And_Nothing_Else_Is;

   procedure A_Hook_Always_Exits_Zero (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "nowhere"));
      Assert (Run (Env (F), Args ("staleness")) = 0, "staleness");
      Assert (Run (Env (F), Args ("prompt-context")) = 0, "prompt-context");
      Assert (Run (Env (F), Args ("session-start")) = 0, "session-start");
      Assert (Run (Env (F), Args ("stop-nudge")) = 0, "stop-nudge");
      Assert (Run (Env (F), Args ("vault-pull")) = 0, "vault-pull");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Hook_Always_Exits_Zero;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Hooks.Dispatch");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, An_Unknown_Hook_Is_A_Usage_Error_And_Nothing_Else_Is'Access,
         "An unknown hook is a usage error and nothing else is");
      Register_Routine
        (T, A_Hook_Always_Exits_Zero'Access, "A hook always exits zero");
   end Register_Tests;

end Synapse.Hooks.Dispatch.Tests;
