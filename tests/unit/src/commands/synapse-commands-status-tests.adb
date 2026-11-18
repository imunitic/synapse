with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;

package body Synapse.Commands.Status.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure Fill (Dir : Scratch) is
   begin
      Put
        (Dir, "designs/p/Talk.md",
         "---" & LF & "title: Talk" & LF & "note_id: p-1" & LF & "---" & LF
         & "## Status" & LF & "Discussing" & LF);
      Put
        (Dir, "tasks/p/Work.md",
         "---" & LF & "title: Work" & LF & "task_id: p-2" & LF
         & "status: IN-PROGRESS" & LF & "---" & LF & "- [ ] a" & LF);
   end Fill;

   procedure Text_Is_The_Default_And_Reads_The_Vault
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run (Env (F), Args) = 0, "it succeeds");
      Assert
        (F.Console.Out_Text =
         "## Discussing" & LF & "- [p-1] Talk" & LF & LF
         & "## In progress (unchecked items)" & LF
         & "- [p-2] Work (1 unchecked)" & LF,
         "the sections that have items: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Text_Is_The_Default_And_Reads_The_Vault;

   procedure Json_Says_The_Format_And_Every_Path (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run (Env (F), Args ("--format", "json")) = 0, "it succeeds");
      declare
         Text : constant String := F.Console.Out_Text;
      begin
         Assert
           (Synapse.Core.JSON.Parse (Text).Ok
            and then Has (Text, """format"":""synapse-status/v1""")
            and then Has (Text, """path"":""designs/p/Talk.md""")
            and then Has (Text, """unchecked"":1"),
            "it is the JSON of synapse-status/v1: " & Text);
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Json_Says_The_Format_And_Every_Path;

   procedure A_Vault_Of_Nothing_Is_Clear (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "plain.md", "just a note" & LF);
      Assert
        (Run (Env (F), Args ("--format", "text")) = 0
         and then F.Console.Out_Text =
                  "Vault is clear -- nothing outstanding." & LF,
         "it says so");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Vault_Of_Nothing_Is_Clear;

   procedure Without_A_Vault_It_Fails_And_A_Bad_Argument_Is_Usage
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
      G : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 1, "no vault is configured");
      Assert
        (Has (F.Console.Err_Text, "synapse-status"),
         "it says whose complaint it is");
      Assert (Run (Env (G), Args ("--format", "xml")) = 2, "a format it lacks");
      Assert (Run (Env (G), Args ("--format")) = 2, "a format without a value");
      Assert (Run (Env (G), Args ("extra")) = 2, "an argument it lacks");
      Assert
        (Run (Env (G), Args ("--help")) = 0
         and then Has (G.Console.Out_Text, "usage: synapse status"),
         "help");
   end Without_A_Vault_It_Fails_And_A_Bad_Argument_Is_Usage;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Status");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Text_Is_The_Default_And_Reads_The_Vault'Access,
         "Text is the default and reads the vault");
      Register_Routine
        (T, Json_Says_The_Format_And_Every_Path'Access,
         "JSON says the format and every path");
      Register_Routine
        (T, A_Vault_Of_Nothing_Is_Clear'Access, "A vault of nothing is clear");
      Register_Routine
        (T, Without_A_Vault_It_Fails_And_A_Bad_Argument_Is_Usage'Access,
         "Without a vault it fails and a bad argument is usage");
   end Register_Tests;

end Synapse.Commands.Status.Tests;
