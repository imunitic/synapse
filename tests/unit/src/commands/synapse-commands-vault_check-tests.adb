with Ada.Strings.Fixed;
with Synapse.Commands.Vault_Usage;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Vault_Check.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Schema : constant String :=
     "schema: synapse-note-schema/v1" & LF & "id: vault-note/v1" & LF &
     "frontmatter:" & LF & "  fields:" & LF & "    schema:" & LF &
     "      type: string" & LF & "      required: true" & LF &
     "      const: vault-note/v1" & LF & "    title:" & LF &
     "      type: string" & LF & "      required: true" & LF & "    note_id:" &
     LF & "      type: string" & LF & "      required: true" & LF &
     "    tags:" & LF & "      type: list" & LF & "      required: true" & LF &
     "      items: string" & LF & "body:" & LF & "  h1:" & LF &
     "    required: true" & LF & "    count: 1" & LF &
     "    equals: frontmatter.title" & LF & "checks:" & LF & "  - eq:" & LF &
     "      - var: filename.stem" & LF & "      - var: frontmatter.title" &
     LF & "  - all:" & LF & "      - var: frontmatter.tags" & LF &
     "      - in:" & LF & "          - var: ''" & LF &
     "          - var: vocabularies.synapse-tag-vocabulary" & LF &
     "    message: not in the vocabulary" & LF & "lints:" & LF &
     "  - no_hard_wrap:" & LF & "      var: body.prose" & LF &
     "    severity: warn" & LF &
     "    message: 'body: no_hard_wrap paragraph is wrapped'" & LF;

   function Note
     (Title : String; Tags : String := "[a]"; Text : String := "Short.";
      Id    : String := "note_id: sb-001" & LF) return String is
     ("---" & LF & "schema: vault-note/v1" & LF & "title: " & Title & LF & Id &
      "tags: " & Tags & LF & "---" & LF & "# " & Title & LF & LF & Text & LF);

   procedure Prepare (F : in out Fixture; Dir : Scratch) is
   begin
      Use_Vault (F, Dir);
      Put_Schema (Dir, "vault-note/v1", Schema);
      Put_Config (Dir, "synapse-tag-vocabulary.conf", "a" & LF & "b" & LF);
   end Prepare;

   procedure Check_Counts_Conforming_And_Legacy_Notes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Put (Dir, "Good.md", Note ("Good"));
      Put (Dir, "old.md", "no schema" & LF);
      Assert (Run (Env (F), Args) = 0, "success: " & F.Console.Out_Text);
      Assert
        (F.Console.Out_Text =
         "2 notes: 1 schema-declaring (1 conformant, 0 violations), 1 legacy" &
         LF,
         "the summary: " & F.Console.Out_Text);
      Assert (F.Console.Err_Text = "", "nothing on standard error");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Counts_Conforming_And_Legacy_Notes;

   procedure Check_Reports_A_Violating_Note_And_Returns_1
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Put (Dir, "Bad.md", Note ("Bad", Id => ""));
      Assert (Run (Env (F), Args) = 1, "code 1");
      Assert
        (F.Console.Out_Text =
         "Bad.md" & HT & "frontmatter.note_id: required field is missing" &
         LF &
         "1 notes: 1 schema-declaring (0 conformant, 1 violations), 0 legacy" &
         LF,
         "the row then the summary: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Reports_A_Violating_Note_And_Returns_1;

   procedure Check_Reports_A_Schema_That_Cannot_Be_Loaded
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Put (Dir, "U.md", "---" & LF & "schema: nope/v9" & LF & "---" & LF);
      Assert (Run (Env (F), Args) = 1, "code 1");
      Assert
        (F.Console.Out_Text =
         "U.md" & HT & "FileNotFound" & LF &
         "1 notes: 1 schema-declaring (0 conformant, 1 violations), 0 legacy" &
         LF,
         "named by its fault: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Reports_A_Schema_That_Cannot_Be_Loaded;

   procedure Check_Reads_Each_Vocabulary_For_Every_Note_That_Needs_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Put (Dir, "In.md", Note ("In", Tags => "[a]"));
      Put
        (Dir, "Out.md",
         Note ("Out", Tags => "[zzz]", Id => "note_id: sb-002" & LF));
      Assert (Run (Env (F), Args) = 1, "one violation");
      Assert
        (F.Console.Out_Text =
         "Out.md" & HT & "not in the vocabulary" & LF &
         "2 notes: 2 schema-declaring (1 conformant, 1 violations), 0 legacy" &
         LF,
         "only the tag outside the vocabulary: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Reads_Each_Vocabulary_For_Every_Note_That_Needs_It;

   procedure Check_Prints_Lints_As_Advice_And_Still_Succeeds
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Put (Dir, "W.md", Note ("W", Text => "wrapped" & LF & "across lines"));
      Assert (Run (Env (F), Args) = 0, "a lint is not a violation");
      Assert
        (F.Console.Out_Text =
         "1 notes: 1 schema-declaring (1 conformant, 0 violations), 0 legacy" &
         LF & LF & "Lint (advisory, 1 finding(s) across 1 note(s)):" & LF &
         "W.md" & HT & "body: no_hard_wrap paragraph is wrapped" & LF,
         "the advisory section: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Prints_Lints_As_Advice_And_Still_Succeeds;

   procedure Check_Counts_Only_The_Notes_That_Have_A_Lint
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Put (Dir, "W.md", Note ("W", Text => "wrapped" & LF & "across lines"));
      Put (Dir, "Z.md", Note ("Z", Id => "note_id: sb-002" & LF));
      Assert (Run (Env (F), Args) = 0, "success");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text, "1 finding(s) across 1 note(s)") >
         0,
         "one note of two: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Counts_Only_The_Notes_That_Have_A_Lint;

   procedure Check_Names_A_Rule_That_Fails_Instead_Of_Stopping
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put_Schema
        (Dir, "vault-note/v1",
         "schema: synapse-note-schema/v1" & LF & "id: vault-note/v1" & LF &
         "frontmatter:" & LF & "  fields:" & LF & "    title:" & LF &
         "      type: string" & LF & "body:" & LF & "  h1:" & LF &
         "    required: false" & LF & "checks:" & LF & "  - hard_wrap:" & LF &
         "      - var: body.prose" & LF & "      - 0" & LF);
      Put
        (Dir, "x.md",
         "---" & LF & "schema: vault-note/v1" & LF & "title: X" & LF & "---" &
         LF & "# X" & LF);
      Put (Dir, "y.md", "legacy" & LF);
      Assert (Run (Env (F), Args) = 1, "code 1");
      Assert
        (F.Console.Out_Text =
         "x.md" & HT & "InvalidArguments" & LF &
         "2 notes: 1 schema-declaring (0 conformant, 1 violations), 1 legacy" &
         LF,
         "the sweep went on: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Names_A_Rule_That_Fails_Instead_Of_Stopping;

   procedure Check_Takes_No_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Prepare (F, Dir);
      Assert (Run (Env (F), Args ("x")) = 2, "an argument");
      Assert (F.Console.Err_Text = Vault_Usage.Check, "the usage");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert (F.Console.Err_Text = Vault_Usage.Check, "its usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Takes_No_Arguments;

   procedure Check_Needs_A_Vault (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Assert (Run (Env (F), Args) = 1, "code 1");
      Assert
        (F.Console.Err_Text = "synapse-vault: no vault" & LF, "the message");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Needs_A_Vault;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Vault_Check");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Check_Counts_Conforming_And_Legacy_Notes'Access,
         "Check counts conforming and legacy notes");
      Register_Routine
        (T, Check_Reports_A_Violating_Note_And_Returns_1'Access,
         "Check reports a violating note and returns 1");
      Register_Routine
        (T, Check_Reports_A_Schema_That_Cannot_Be_Loaded'Access,
         "Check reports a schema that cannot be loaded");
      Register_Routine
        (T, Check_Reads_Each_Vocabulary_For_Every_Note_That_Needs_It'Access,
         "Check reads each vocabulary for every note that needs it");
      Register_Routine
        (T, Check_Prints_Lints_As_Advice_And_Still_Succeeds'Access,
         "Check prints lints as advice and still succeeds");
      Register_Routine
        (T, Check_Counts_Only_The_Notes_That_Have_A_Lint'Access,
         "Check counts only the notes that have a lint");
      Register_Routine
        (T, Check_Names_A_Rule_That_Fails_Instead_Of_Stopping'Access,
         "Check names a rule that fails instead of stopping");
      Register_Routine
        (T, Check_Takes_No_Arguments'Access, "Check takes no arguments");
      Register_Routine (T, Check_Needs_A_Vault'Access, "Check needs a vault");
   end Register_Tests;

end Synapse.Commands.Vault_Check.Tests;
