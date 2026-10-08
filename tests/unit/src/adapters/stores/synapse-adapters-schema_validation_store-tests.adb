with Ada.Containers;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.Fake_Clock;
with Synapse.Adapters.Fake_Store;
with Synapse.Adapters.Fake_Variables;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Schema_Validation_Store.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Test_Schema : constant String :=
     "schema: synapse-note-schema/v1" & LF & "id: vault-note/v1" & LF
     & "frontmatter:" & LF & "  fields:" & LF
     & "    schema:" & LF & "      type: string" & LF & "      required: true"
     & LF & "      const: vault-note/v1" & LF
     & "    title:" & LF & "      type: string" & LF & "      required: true"
     & LF
     & "    note_id:" & LF & "      type: string" & LF & "      required: true"
     & LF & "      mutable: false" & LF
     & "    created:" & LF & "      type: timestamp" & LF
     & "      required: true" & LF & "      mutable: false" & LF
     & "    updated:" & LF & "      type: timestamp" & LF
     & "      required: true" & LF
     & "    tags:" & LF & "      type: list" & LF & "      required: true" & LF
     & "      items: string" & LF
     & "body:" & LF & "  h1:" & LF & "    required: true" & LF
     & "    count: 1" & LF & "    equals: frontmatter.title" & LF
     & "  sections:" & LF & "    - title: Summary" & LF & "      level: 2" & LF
     & "      required: true" & LF
     & "checks:" & LF
     & "  - eq:" & LF & "      - var: filename.stem" & LF
     & "      - var: frontmatter.title" & LF
     & "  - on_create:" & LF & "      var: id_is_unique" & LF
     & "  - lte:" & LF & "      - var: created_epoch" & LF
     & "      - var: updated_epoch" & LF
     & "lints:" & LF & "  - no_hard_wrap:" & LF & "      var: body.prose" & LF
     & "    severity: warn" & LF
     & "    message: 'body: no_hard_wrap paragraph is wrapped'" & LF;

   Stamp : constant String := "'2026-08-30T01:00:00+02:00'";

   function Note
     (Title : String := "Example"; Summary : String := "Old.";
      Id    : String := "sb-081";
      Tags  : String := "tags: []" & LF) return String
   is ("---" & LF & "schema: vault-note/v1" & LF & "title: " & Title & LF
       & "note_id: " & Id & LF & "created: " & Stamp & LF
       & "updated: " & Stamp & LF & Tags & "---" & LF & LF & "# " & Title & LF
       & LF & "## Summary" & LF & Summary & LF);

   Wrapped : constant String :=
     Note (Summary => "This sentence got" & LF & "hard-wrapped across two"
           & " lines.");

   procedure Put (Path, Text : String) is
      Slash : Natural := 0;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            Slash := I;
            exit;
         end if;
      end loop;
      Ada.Directories.Create_Path (Path (Path'First .. Slash - 1));
      File_Bytes.Write (Path, Text);
   end Put;

   --  A content root holding the test schema, and everything a store needs.
   type Fixture is limited record
      Dir   : Scratch := Make;
      Fake  : aliased Fake_Store.Fake_Store;
      Vars  : aliased Fake_Variables.Fake_Variables;
      Clock : aliased Fake_Clock.Fake_Clock;
   end record;

   procedure Prepare (F : in out Fixture; Schema : String := Test_Schema) is
   begin
      Put (Path (F.Dir, "schema/vault-note/v1.yaml"), Schema);
      F.Vars.Set ("SYNAPSE_CONTENT_ROOT", Path (F.Dir));
      F.Clock.Now := To_Unbounded_String ("2026-08-30T02:00:00+02:00");
   end Prepare;

   function Store_Of (F : in out Fixture) return Validation_Store
   is (Create (F.Fake'Access, F.Vars'Access, F.Clock'Access));

   procedure Seed (F : in out Fixture; Node, Text : String) is
   begin
      Assert (F.Fake.Write (Node, Text).Accepted, "seed " & Node);
      F.Fake.Reads := 0;
      F.Fake.Lists := 0;
      F.Fake.Writes := 0;
   end Seed;

   procedure Unsafe_Identifiers_Fail_Before_The_Store_Is_Touched
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      declare
         S      : Validation_Store := Store_Of (F);
         Result : constant Port.Write_Result :=
           S.Write ("x.md",
                    "---" & LF & "schema: ../secret" & LF & "---" & LF);
      begin
         Assert (not Result.Accepted and then Result.Status = 422, "refused");
         Assert (To_String (Result.Body_Text)
                 = "frontmatter.schema: unsafe identifier '../secret'",
                 "its message");
         Assert (F.Fake.Writes = 0, "nothing written");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end Unsafe_Identifiers_Fail_Before_The_Store_Is_Touched;

   procedure Legacy_Notes_Pass_Through (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      declare
         S : Validation_Store := Store_Of (F);
      begin
         Assert (S.Write ("legacy.md",
                          "---" & LF & "title: Legacy" & LF & "---" & LF)
                   .Accepted, "no schema, no checks");
         Assert (F.Fake.Writes = 1, "written");
         Assert (S.Write ("plain.md", "no frontmatter").Accepted,
                 "plain text");
         Assert (S.Read ("legacy.md").Found, "reads pass through");
         Assert (S.List.Length = 2, "and lists");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end Legacy_Notes_Pass_Through;

   procedure A_Schema_Cannot_Be_Dropped (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Prepare (F);
      Seed (F, "Example.md", Note);
      declare
         S      : Validation_Store := Store_Of (F);
         Result : constant Port.Write_Result :=
           S.Write ("Example.md", "---" & LF & "title: Example" & LF & "---"
                    & LF);
      begin
         Assert (not Result.Accepted
                 and then To_String (Result.Body_Text)
                          = "frontmatter.schema: cannot be removed from a "
                            & "schema-declaring note", "refused");
         Assert (F.Fake.Writes = 0, "nothing written");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end A_Schema_Cannot_Be_Dropped;

   procedure An_Update_Reads_The_Note_But_Never_Lists_The_Vault
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Prepare (F);
      Seed (F, "Example.md", Note);
      declare
         S : Validation_Store := Store_Of (F);
      begin
         Assert (S.Write ("Example.md", Note (Summary => "Updated.")).Accepted,
                 "accepted");
         Assert (F.Fake.Reads = 1, "one read of the persisted note");
         Assert (F.Fake.Lists = 0, "no scan");
         Assert (F.Fake.Writes = 1, "one write");
         --  `updated` was stamped by the store.
         Assert (Ada.Strings.Fixed.Index
                   (F.Fake.Nodes.Element ("Example.md"),
                    "updated: 2026-08-30T02:00:00+02:00") > 0,
                 "stamped with the clock");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end An_Update_Reads_The_Note_But_Never_Lists_The_Vault;

   procedure Creation_Scans_The_Vault_Once (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Prepare (F);
      declare
         S : Validation_Store := Store_Of (F);
      begin
         Assert (S.Write ("Example.md", Note).Accepted, "accepted");
         Assert (F.Fake.Lists = 1, "one scan");
         Assert (F.Fake.Writes = 1, "one write");
         --  A create keeps the caller's own `updated`.
         Assert (Ada.Strings.Fixed.Index
                   (F.Fake.Nodes.Element ("Example.md"),
                    "updated: " & Stamp) > 0, "not stamped");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end Creation_Scans_The_Vault_Once;

   procedure A_Duplicate_Identity_Is_Refused_On_Create
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Prepare (F);
      Seed (F, "Other.md", Note (Title => "Other", Id => "sb-081"));
      declare
         S      : Validation_Store := Store_Of (F);
         Result : constant Port.Write_Result := S.Write ("Example.md", Note);
      begin
         Assert (not Result.Accepted and then Result.Status = 422,
                 "refused: " & To_String (Result.Body_Text));
         Assert (F.Fake.Writes = 0, "nothing written");
         Assert (S.Write ("Example.md", Note (Id => "sb-082")).Accepted,
                 "a different identity is fine");
         Assert (S.Write ("Example.md", Note (Id => "sb-082")).Accepted,
                 "an update is never scanned");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end A_Duplicate_Identity_Is_Refused_On_Create;

   procedure A_Rejection_Never_Calls_The_Inner_Write
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Prepare (F);
      declare
         S      : Validation_Store := Store_Of (F);
         Result : constant Port.Write_Result :=
           S.Write ("Example.md", Note (Title => "Wrong"));
      begin
         Assert (not Result.Accepted and then Result.Status = 422, "refused");
         Assert (Length (Result.Body_Text) > 0, "with a reason");
         Assert (F.Fake.Writes = 0, "never written");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end A_Rejection_Never_Calls_The_Inner_Write;

   procedure A_Warning_Is_Advisory (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Prepare (F);
      declare
         S      : Validation_Store := Store_Of (F);
         Result : constant Port.Write_Result :=
           S.Write ("Example.md", Wrapped);
      begin
         Assert (Result.Accepted, "accepted");
         Assert (Result.Status = 0 and then Length (Result.Body_Text) = 0,
                 "and the result is unaffected");
         Assert (F.Fake.Writes = 1, "written");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end A_Warning_Is_Advisory;

   function Severity_Error return String is
      Text  : constant String := Test_Schema;
      Start : constant Natural :=
        Ada.Strings.Fixed.Index (Text, "severity: warn");
   begin
      return Text (Text'First .. Start - 1) & "severity: error"
        & Text (Start + 14 .. Text'Last);
   end Severity_Error;

   procedure An_Error_Finding_Blocks_The_Write (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Prepare (F, Severity_Error);
      declare
         S      : Validation_Store := Store_Of (F);
         Result : constant Port.Write_Result :=
           S.Write ("Example.md", Wrapped);
      begin
         Assert (not Result.Accepted and then Result.Status = 422, "refused");
         Assert (To_String (Result.Body_Text)
                 = "body: no_hard_wrap paragraph is wrapped",
                 "by the rule's message");
         Assert (F.Fake.Writes = 0, "never written");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end An_Error_Finding_Blocks_The_Write;

   procedure An_Override_Can_Raise_A_Severity (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Prepare (F);
      F.Vars.Set ("XDG_CONFIG_HOME", Path (F.Dir));
      Put (Path (F.Dir, "synapse/schema-overrides/vault-note/v1.yaml"),
           "lints:" & LF & "  - no_hard_wrap:" & LF & "      var: body.prose"
           & LF & "    severity: error" & LF);
      declare
         S : Validation_Store := Store_Of (F);
      begin
         Assert (not S.Write ("Example.md", Wrapped).Accepted,
                 "a replaced lint list blocks");
      end;

      Put (Path (F.Dir, "synapse/schema-overrides/vault-note/v1.yaml"),
           "lints:" & LF & "  - match:" & LF & "      no_hard_wrap:" & LF
           & "        var: body.prose" & LF & "    severity: error" & LF);
      declare
         S : Validation_Store := Store_Of (F);
      begin
         Assert (not S.Write ("Example.md", Wrapped).Accepted,
                 "a match bumps one lint without restating the list");
         Assert (F.Fake.Writes = 0, "never written");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end An_Override_Can_Raise_A_Severity;

   procedure An_Override_Can_Remove_A_Required_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
      No_Tags : constant String := Note (Tags => "");
   begin
      Prepare (F);
      F.Vars.Set ("XDG_CONFIG_HOME", Path (F.Dir));
      declare
         S : Validation_Store := Store_Of (F);
      begin
         Assert (not S.Write ("Example.md", No_Tags).Accepted,
                 "the base schema requires tags");
         Put (Path (F.Dir, "synapse/schema-overrides/vault-note/v1.yaml"),
              "frontmatter:" & LF & "  fields:" & LF & "    tags: null" & LF);
         Assert (S.Write ("Example.md", No_Tags).Accepted,
                 "the override removes the rule");
         Assert (F.Fake.Writes = 1, "written once");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end An_Override_Can_Remove_A_Required_Field;

   procedure A_Schema_That_Does_Not_Load_Refuses_The_Write
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Prepare (F);
      declare
         S      : Validation_Store := Store_Of (F);
         Result : constant Port.Write_Result :=
           S.Write ("x.md", "---" & LF & "schema: nothing/v1" & LF & "---"
                    & LF);
      begin
         Assert (To_String (Result.Body_Text) = "schema: FileNotFound",
                 "no such schema: " & To_String (Result.Body_Text));
      end;
      F.Vars.Table.Delete ("SYNAPSE_CONTENT_ROOT");
      declare
         S      : Validation_Store := Store_Of (F);
         Result : constant Port.Write_Result := S.Write ("Example.md", Note);
      begin
         Assert (To_String (Result.Body_Text) = "schema: ContentRootMissing",
                 "no content root");
      end;
      Put (Path (F.Dir, "schema/bad/v1.yaml"), "id: bad/v1" & LF);
      F.Vars.Set ("SYNAPSE_CONTENT_ROOT", Path (F.Dir));
      declare
         S      : Validation_Store := Store_Of (F);
         Result : constant Port.Write_Result :=
           S.Write ("x.md", "---" & LF & "schema: bad/v1" & LF & "---" & LF);
      begin
         Assert (not Result.Accepted
                 and then Ada.Strings.Fixed.Index
                            (To_String (Result.Body_Text), "schema.") > 0,
                 "an invalid schema document: "
                 & To_String (Result.Body_Text));
         Assert (F.Fake.Writes = 0, "nothing written");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end A_Schema_That_Does_Not_Load_Refuses_The_Write;

   procedure A_Rule_That_Raises_Refuses_The_Write (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F      : Fixture;
      Broken : constant String :=
        "schema: synapse-note-schema/v1" & LF & "id: vault-note/v1" & LF
        & "frontmatter:" & LF & "  fields:" & LF & "    title:" & LF
        & "      type: string" & LF & "body:" & LF & "  h1:" & LF
        & "    required: false" & LF & "checks:" & LF & "  - hard_wrap:" & LF
        & "      - var: body.prose" & LF & "      - 0" & LF;
   begin
      Prepare (F, Broken);
      declare
         S      : Validation_Store := Store_Of (F);
         Result : constant Port.Write_Result :=
           S.Write ("x.md", "---" & LF & "schema: vault-note/v1" & LF
                    & "title: X" & LF & "---" & LF & "# X" & LF);
      begin
         Assert (To_String (Result.Body_Text) = "checks: InvalidArguments",
                 "named: " & To_String (Result.Body_Text));
         Assert (F.Fake.Writes = 0, "never written");
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end A_Rule_That_Raises_Refuses_The_Write;

   procedure A_Missing_Vocabulary_Skips_The_File (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F      : Fixture;
      Vocab  : constant String :=
        "schema: synapse-note-schema/v1" & LF & "id: vault-note/v1" & LF
        & "frontmatter:" & LF & "  fields:" & LF & "    tags:" & LF
        & "      type: list" & LF & "      items: string" & LF & "body:" & LF
        & "  h1:" & LF
        & "    required: false" & LF & "checks:" & LF & "  - all:" & LF
        & "      - var: frontmatter.tags" & LF & "      - in:" & LF
        & "          - var: ''" & LF
        & "          - var: vocabularies.synapse-tag-vocabulary" & LF
        & "    message: not in the vocabulary" & LF;
      With_Tag : constant String :=
        "---" & LF & "schema: vault-note/v1" & LF & "title: T" & LF
        & "tags: [a]" & LF & "---" & LF & "# T" & LF;
   begin
      Prepare (F, Vocab);
      F.Vars.Set ("HOME", Path (F.Dir, "home"));
      declare
         S : Validation_Store := Store_Of (F);
      begin
         Assert (not S.Write ("x.md", With_Tag).Accepted,
                 "with no vocabulary file nothing is in it");
         Put (Path (F.Dir, "home/.claude/synapse-tag-vocabulary.conf"),
              "a" & LF & "b" & LF);
         declare
            Result : constant Port.Write_Result := S.Write ("x.md", With_Tag);
         begin
            Assert (Result.Accepted,
                    "found and used: " & To_String (Result.Body_Text));
         end;
      end;
      Remove (F.Dir);
   exception
      when others =>
         Remove (F.Dir);
         raise;
   end A_Missing_Vocabulary_Skips_The_File;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Schema_Validation_Store");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Unsafe_Identifiers_Fail_Before_The_Store_Is_Touched'Access,
         "Unsafe identifiers fail before the store is touched");
      Register_Routine
        (T, Legacy_Notes_Pass_Through'Access, "Legacy notes pass through");
      Register_Routine
        (T, A_Schema_Cannot_Be_Dropped'Access, "A schema cannot be dropped");
      Register_Routine
        (T, An_Update_Reads_The_Note_But_Never_Lists_The_Vault'Access,
         "An update reads the note but never lists the vault");
      Register_Routine
        (T, Creation_Scans_The_Vault_Once'Access,
         "Creation scans the vault once");
      Register_Routine
        (T, A_Duplicate_Identity_Is_Refused_On_Create'Access,
         "A duplicate identity is refused on create");
      Register_Routine
        (T, A_Rejection_Never_Calls_The_Inner_Write'Access,
         "A rejection never calls the inner write");
      Register_Routine
        (T, A_Warning_Is_Advisory'Access, "A warning is advisory");
      Register_Routine
        (T, An_Error_Finding_Blocks_The_Write'Access,
         "An error finding blocks the write");
      Register_Routine
        (T, An_Override_Can_Raise_A_Severity'Access,
         "An override can raise a severity");
      Register_Routine
        (T, An_Override_Can_Remove_A_Required_Field'Access,
         "An override can remove a required field");
      Register_Routine
        (T, A_Schema_That_Does_Not_Load_Refuses_The_Write'Access,
         "A schema that does not load refuses the write");
      Register_Routine
        (T, A_Rule_That_Raises_Refuses_The_Write'Access,
         "A rule that raises refuses the write");
      Register_Routine
        (T, A_Missing_Vocabulary_Skips_The_File'Access,
         "A missing vocabulary skips the file");
   end Register_Tests;

end Synapse.Adapters.Schema_Validation_Store.Tests;
