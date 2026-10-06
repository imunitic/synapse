with Ada.Characters.Latin_1;
with Ada.Directories;
with Ada.Streams.Stream_IO;

with AUnit.Assertions;

with Synapse.Core.Note_Operators;
with Synapse.Core.Schema_Rules;
with Synapse.Core.Schema_YAML;

package body Synapse.Core.Note_Schema.Tests is

   use AUnit.Assertions;
   use JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Ada.Characters.Latin_1.LF;

   Schema_Dir : constant String := "../../packages/synapse/schema";

   Operators : Note_Operators.Note_Operators renames Note_Operators.Operators;

   Head      : constant String :=
     "schema: synapse-note-schema/v1" & LF & "id: t/v1" & LF;
   Fm_Ok     : constant String :=
     "frontmatter:" & LF & "  fields:" & LF & "    title:" & LF
     & "      type: string" & LF;
   Body_Ok   : constant String :=
     "body:" & LF & "  h1:" & LF & "    required: false" & LF;
   Checks_Ok : constant String := "checks: []" & LF;

   function Message_Of
     (Source : String; Ops : JSON_Logic.Operator_Set'Class := Operators)
      return String
   is
      Parsed : constant Schema_YAML.Parse_Result := Schema_YAML.Parse (Source);
   begin
      Assert (Parsed.Ok, "the schema YAML parses: " & Source);
      declare
         Result : constant Check_Result :=
           Validate_Schema (Parsed.Root, "t/v1", Ops);
      begin
         return (if Result.Valid
                 then "<valid>"
                 else Ada.Strings.Unbounded.To_String (Result.Message));
      end;
   end Message_Of;

   procedure Rejects (Source, Want : String) is
      Got : constant String := Message_Of (Source);
   begin
      Assert (Got = Want, "got '" & Got & "', wanted '" & Want & "'");
   end Rejects;

   procedure Accepts (Source : String) is
   begin
      Assert (Message_Of (Source) = "<valid>",
              "should be valid, got: " & Message_Of (Source));
   end Accepts;

   --  A schema around one part under test.
   function With_Field (Lines : String) return String
   is (Head & "frontmatter:" & LF & "  fields:" & LF & "    title:" & LF
       & Lines & Body_Ok & Checks_Ok);

   function With_Frontmatter (Lines : String) return String
   is (Head & "frontmatter:" & LF & Lines & Body_Ok & Checks_Ok);

   function With_Body (Lines : String) return String
   is (Head & Fm_Ok & "body:" & LF & Lines & Checks_Ok);

   function With_Checks (Lines : String) return String
   is (Head & Fm_Ok & Body_Ok & Lines);

   function With_Lints (Lines : String) return String
   is (Head & Fm_Ok & Body_Ok & Checks_Ok & "lints:" & LF & Lines);

   H1_Ok : constant String := "  h1:" & LF & "    required: false" & LF;

   ---------------------------------------------------------------------------
   --  Header and root
   ---------------------------------------------------------------------------

   procedure A_Well_Formed_Schema_Is_Accepted (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Accepts (Head & Fm_Ok & Body_Ok & Checks_Ok);
      Accepts
        (Head & "frontmatter:" & LF & "  field_order: relative" & LF
         & "  fields:" & LF & "    tags:" & LF & "      type: list" & LF
         & "      items: string" & LF & "      required: true" & LF
         & "    when:" & LF & "      type: timestamp" & LF
         & "      mutable: false"
         & LF & "    kind:" & LF & "      type: string" & LF
         & "      enum: [a, b]" & LF & "      pattern: '^[a-z]+$'" & LF
         & "      min_length: 3" & LF & Body_Ok & Checks_Ok);
   end A_Well_Formed_Schema_Is_Accepted;

   procedure The_Header_Is_Checked_First (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Rejects ("- a" & LF, "schema: document root must be a mapping");
      Rejects ("id: t/v1" & LF & Fm_Ok & Body_Ok & Checks_Ok,
               "schema.schema: required string is missing");
      Rejects ("schema: 5" & LF & "id: t/v1" & LF,
               "schema.schema: required string is missing");
      Rejects ("schema: other/v9" & LF & "id: t/v1" & LF,
               "schema.schema: unsupported language 'other/v9'");
      Rejects ("schema: synapse-note-schema/v1" & LF,
               "schema.id: required string is missing");
      Rejects ("schema: synapse-note-schema/v1" & LF & "id: x/v1" & LF,
               "schema.id: expected 't/v1', found 'x/v1'");
   end The_Header_Is_Checked_First;

   ---------------------------------------------------------------------------
   --  Frontmatter
   ---------------------------------------------------------------------------

   procedure Frontmatter_Structure_Is_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Rejects (Head & Body_Ok & Checks_Ok,
               "schema.frontmatter: required mapping is missing");
      Rejects (Head & "frontmatter: none" & LF & Body_Ok & Checks_Ok,
               "schema.frontmatter: required mapping is missing");
      Rejects (With_Frontmatter ("  extra: 1" & LF
                                 & "  fields:" & LF & "    t:" & LF
                                 & "      type: string" & LF),
               "schema.frontmatter.extra: unsupported v1 key");
      Rejects (With_Frontmatter ("  field_order: 5" & LF & "  fields:" & LF
                                 & "    t:" & LF & "      type: string" & LF),
               "schema.frontmatter.field_order: must be string");
      Rejects (With_Frontmatter ("  field_order: absolute" & LF & "  fields:"
        & LF
                                 & "    t:" & LF & "      type: string" & LF),
               "schema.frontmatter.field_order: unsupported value 'absolute'");
      Rejects (With_Frontmatter ("  field_order: relative" & LF),
               "schema.frontmatter.fields: required mapping is missing");
      Rejects (With_Frontmatter ("  fields: none" & LF),
               "schema.frontmatter.fields: required mapping is missing");
   end Frontmatter_Structure_Is_Checked;

   procedure Field_Rules_Are_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Prefix : constant String := "schema.frontmatter.fields.title";
   begin
      Rejects (With_Frontmatter ("  fields:" & LF & "    title: string" & LF),
               Prefix & ": must be a mapping");
      Rejects (With_Field ("      type: string" & LF & "      color: red"
        & LF),
               Prefix & ".color: unsupported v1 key");
      Rejects (With_Field ("      required: true" & LF),
               Prefix & ".type: required string is missing");
      Rejects (With_Field ("      type: 5" & LF),
               Prefix & ".type: required string is missing");
      Rejects (With_Field ("      type: float" & LF),
               Prefix & ".type: unsupported type 'float'");
      Rejects (With_Field ("      type: string" & LF
        & "      required: yes_please"
                           & LF & "      mutable: x" & LF),
               Prefix & ".required: must be boolean");
      Rejects (With_Field ("      type: string" & LF & "      required: true"
        & LF
                           & "      mutable: ""no""" & LF),
               Prefix & ".mutable: must be boolean");
      Rejects (With_Field ("      type: string" & LF & "      min_length: x"
        & LF),
               Prefix & ".min_length: must be integer");
      Rejects (With_Field ("      type: string" & LF & "      min_length: 0"
        & LF),
               Prefix & ".min_length: must be at least 1");
      Rejects (With_Field ("      type: string" & LF & "      min_length: -1"
        & LF),
               Prefix & ".min_length: must be at least 1");
      Rejects (With_Field ("      type: string" & LF & "      pattern: 5"
        & LF),
               Prefix & ".pattern: must be string");
      Rejects (With_Field ("      type: string" & LF & "      enum: x" & LF),
               Prefix & ".enum: must be a string list");
      Rejects (With_Field ("      type: string" & LF & "      enum: [a, 5]"
        & LF),
               Prefix & ".enum: must be a string list");
      Rejects (With_Field ("      type: list" & LF),
               Prefix & ".items: required string is missing");
      Rejects (With_Field ("      type: list" & LF & "      items: integer"
        & LF),
               Prefix & ".items: only string is supported in v1");
   end Field_Rules_Are_Checked;

   procedure Pattern_Faults_Are_Named_As_Zig_Names_Them
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      procedure Check (Pattern, Fault : String) is
      begin
         Rejects
           (With_Field ("      type: string" & LF & "      pattern: '"
             & Pattern
                        & "'" & LF),
            "schema.frontmatter.fields.title.pattern: " & Fault);
      end Check;
   begin
      Check ("\d", "InvalidEscape");
      Check ("[a", "UnterminatedClass");
      Check ("[]", "EmptyClass");
      Check ("a{", "InvalidQuantifier");
      Check ("*a", "InvalidQuantifier");
      Check ("(a)", "UnsupportedConstruct");
      Check ("a|b", "UnsupportedConstruct");
      Accepts (With_Field ("      type: string" & LF
        & "      pattern: '^[a-z]+-[0-9]{3,}$'"
                           & LF));
   end Pattern_Faults_Are_Named_As_Zig_Names_Them;

   ---------------------------------------------------------------------------
   --  Body
   ---------------------------------------------------------------------------

   procedure Body_Structure_Is_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Rejects (Head & Fm_Ok
        & Checks_Ok, "schema.body: required mapping is missing");
      Rejects (With_Body ("  extra: 1" & LF & H1_Ok),
               "schema.body.extra: unsupported v1 key");
      Rejects (With_Body ("  sections: []" & LF),
               "schema.body.h1: required mapping is missing");
      Rejects (With_Body ("  h1:" & LF & "    extra: 1" & LF),
               "schema.body.h1.extra: unsupported v1 key");
      Rejects (With_Body ("  h1:" & LF & "    count: 0" & LF),
               "schema.body.h1.count: must be at least 1");
      Rejects (With_Body ("  h1:" & LF & "    count: -1" & LF),
               "schema.body.h1.count: must be at least 1");
      Rejects (With_Body ("  h1:" & LF & "    count: many" & LF),
               "schema.body.h1.count: must be integer");
      Accepts (With_Body ("  h1:" & LF & "    required: true" & LF
                          & "    count: 1" & LF
                          & "    equals: frontmatter.title" & LF
                          & "  section_order: relative" & LF));
   end Body_Structure_Is_Checked;

   procedure Section_Rules_Are_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Sections (Lines : String) return String
      is (With_Body (H1_Ok & "  sections:" & LF & Lines));
   begin
      Rejects (With_Body (H1_Ok & "  sections: one" & LF),
               "schema.body.sections: must be a list");
      Rejects (Sections ("    - plain" & LF),
               "schema.body.sections[0].<non-mapping>: unsupported v1 key");
      Rejects (Sections ("    - title: A" & LF & "      color: red" & LF),
               "schema.body.sections[0].color: unsupported v1 key");
      Rejects (Sections ("    - title: A" & LF & "    - level: 2" & LF),
               "schema.body.sections[1]: title or title_pattern is required");
      Rejects (Sections ("    - title: A" & LF & "      level: 0" & LF),
               "schema.body.sections[0].level: must be at least 1");
      Rejects (Sections ("    - title: A" & LF & "      level: two" & LF),
               "schema.body.sections[0].level: must be integer");
      Rejects (Sections ("    - title: A" & LF & "      max_occurs: 0" & LF),
               "schema.body.sections[0].max_occurs: must be at least 1");
      Rejects (Sections ("    - title: A" & LF & "      required: ""true"""
        & LF),
               "schema.body.sections[0].required: must be boolean");
      Rejects (Sections ("    - title: A" & LF & "      non_empty: 1" & LF),
               "schema.body.sections[0].non_empty: must be boolean");
      Rejects (Sections ("    - title: A" & LF & "      repeatable: ""yes"""
        & LF),
               "schema.body.sections[0].repeatable: must be boolean");
      Rejects (Sections ("    - title_pattern: 5" & LF),
               "schema.body.sections[0].title_pattern: must be string");
      Rejects (Sections ("    - title_pattern: '[x'" & LF),
               "schema.body.sections[0].title_pattern: UnterminatedClass");
      Rejects (Sections ("    - title: A" & LF & "      content:" & LF
                         & "        extra: 1" & LF),
               "schema.body.sections[0].content.extra: unsupported v1 key");
      Rejects (Sections ("    - title: A" & LF & "      content:" & LF
                         & "        enum: x" & LF),
               "schema.body.sections[0].content.enum: must be a string list");
      Rejects (Sections ("    - title: A" & LF & "      children: x" & LF),
               "schema.body.sections[0].children: must be a list");
      Accepts (Sections ("    - title: A" & LF & "      level: 2" & LF
                         & "      required: true" & LF
                         & "      non_empty: true" & LF
                         & "      max_occurs: 3" & LF & "      content:" & LF
                         & "        type: string" & LF
                         & "        enum: [x, y]" & LF
                         & "      children:" & LF
                         & "        - title_pattern: '^X'"
                         & LF));
   end Section_Rules_Are_Checked;

   procedure A_Childs_Diagnostic_Carries_Its_Own_Index
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Rejects (With_Body (H1_Ok & "  sections:" & LF & "    - title: A" & LF
                          & "    - title: B" & LF & "      children:" & LF
                          & "        - title: C" & LF & "        - title: D"
                          & LF
                          & "          level: 0" & LF),
               "schema.body.sections[1].level: must be at least 1");
   end A_Childs_Diagnostic_Carries_Its_Own_Index;

   procedure Preamble_Lead_And_Checklist_Are_Checked
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Rejects (With_Body (H1_Ok & "  preamble: x" & LF),
               "schema.body.preamble: must be a list of mappings");
      Rejects (With_Body (H1_Ok & "  preamble:" & LF & "    - plain" & LF),
               "schema.body.preamble: must be a list of mappings");
      Rejects (With_Body (H1_Ok & "  preamble:" & LF & "    - type: blockquote"
                          & LF & "    - extra: 1" & LF),
               "schema.body.preamble[1].extra: unsupported v1 key");
      Rejects (With_Body (H1_Ok & "  preamble:" & LF & "    - pattern: 'a{'"
        & LF),
               "schema.body.preamble[0].pattern: InvalidQuantifier");
      Accepts (With_Body (H1_Ok & "  preamble:" & LF
        & "    - type: blockquote" & LF
                          & "      required: false" & LF
                          & "      position: immediately_after_h1" & LF
                          & "      marker: '> Compiled task:'" & LF
                          & "      pattern: '^> Compiled task: "
                          & "\[\[[^\]]+\]\]$'" & LF));
      Rejects (With_Body (H1_Ok & "  lead:" & LF & "    extra: 1" & LF),
               "schema.body.lead.extra: unsupported v1 key");
      Rejects (With_Body (H1_Ok & "  lead:" & LF & "    required: ""true"""
        & LF),
               "schema.body.lead.required: must be boolean");
      Rejects (With_Body (H1_Ok & "  lead: x" & LF),
               "schema.body.lead.<non-mapping>: unsupported v1 key");
      Rejects (With_Body (H1_Ok & "  checklist:" & LF & "    extra: 1" & LF),
               "schema.body.checklist.extra: unsupported v1 key");
      Rejects (With_Body (H1_Ok & "  checklist:" & LF & "    required: 1"
        & LF),
               "schema.body.checklist.required: must be boolean");
      Rejects (With_Body (H1_Ok & "  checklist:" & LF & "    min_items: x"
        & LF),
               "schema.body.checklist.min_items: must be integer");
      Rejects (With_Body (H1_Ok & "  checklist:" & LF & "    min_items: -1"
        & LF),
               "schema.body.checklist.min_items: must not be negative");
      Rejects (With_Body (H1_Ok & "  checklist:" & LF
        & "    allowed_children: x" & LF),
               "schema.body.checklist.allowed_children:"
               & " must be a string list");
      Accepts (With_Body (H1_Ok & "  checklist:" & LF & "    required: true"
        & LF
                          & "    min_items: 0" & LF
                          & "    position: after_lead" & LF
                          & "    nested_items: forbidden" & LF
                          & "    allowed_children: [description]" & LF));
   end Preamble_Lead_And_Checklist_Are_Checked;

   ---------------------------------------------------------------------------
   --  checks and lints
   ---------------------------------------------------------------------------

   procedure Checks_Are_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Rejects (Head & Fm_Ok
        & Body_Ok, "schema.checks: required list is missing");
      Rejects (With_Checks ("checks: scalar"
        & LF), "schema.checks: must be a list");
      Rejects (With_Checks ("checks:" & LF & "  - message: hi" & LF),
               "schema.checks[0]: exactly one rule operator is required");
      Rejects (With_Checks ("checks:" & LF & "  - eq: [1, 1]" & LF
                            & "  - eq: [1, 1]" & LF & "    and: [true]" & LF),
               "schema.checks[1]: exactly one rule operator is required");
      Rejects (With_Checks ("checks:" & LF & "  - plain" & LF),
               "schema.checks[0]: exactly one rule operator is required");
      Rejects (With_Checks ("checks:" & LF & "  - eq: [1, 1]" & LF
                            & "    message: 5" & LF),
               "schema.checks[0].message: must be string");
      Rejects (With_Checks ("checks:" & LF & "  - eq: null" & LF),
               "schema.checks[0].eq: a bare null is not valid here");
      Rejects (With_Checks ("checks:" & LF & "  - bogus: 1" & LF),
               "schema.checks[0]: unknown operator 'bogus'");
      Rejects (With_Checks ("checks:" & LF & "  - and:" & LF
                            & "      - eq: [1, 1]" & LF & "      - bogus: 1"
                            & LF),
               "schema.checks[0]: unknown operator 'bogus'");
      Accepts (With_Checks ("checks:" & LF & "  - eq:" & LF
                            & "      - var: filename.stem" & LF
                            & "      - var: frontmatter.title" & LF
                            & "    message: the title is the file name" & LF
                            & "  - on_create:" & LF
                            & "      var: id_is_unique" & LF
                            & "  - not:" & LF & "      starts_with:" & LF
                            & "        - var: a" & LF & "        - var: b" & LF
                            & "  - all:" & LF
                            & "      - var: frontmatter.tags" & LF
                            & "      - in:" & LF & "          - var: ''" & LF
                            & "          - var: vocabularies.tags" & LF));
   end Checks_Are_Checked;

   procedure Lints_Are_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Accepts (Head & Fm_Ok & Body_Ok & Checks_Ok);
      Rejects (Head & Fm_Ok & Body_Ok & Checks_Ok & "lints: x" & LF,
               "schema.lints: must be a list");
      Rejects (With_Lints ("  - severity: warn" & LF),
               "schema.lints[0]: exactly one rule operator is required");
      Rejects (With_Lints ("  - no_hard_wrap:" & LF & "      var: body.prose"
        & LF
                           & "    severity: warn" & LF & "    extra: 1" & LF),
               "schema.lints[0]: exactly one rule operator is required");
      Rejects (With_Lints ("  - no_hard_wrap:" & LF & "      var: body.prose"
        & LF
                           & "    message: 5" & LF & "    severity: warn"
                           & LF),
               "schema.lints[0].message: must be string");
      Rejects (With_Lints ("  - no_hard_wrap:" & LF & "      var: body.prose"
        & LF),
               "schema.lints[0].severity: required string is missing");
      Rejects (With_Lints ("  - no_hard_wrap:" & LF & "      var: body.prose"
        & LF
                           & "    severity: critical" & LF),
               "schema.lints[0].severity: unsupported value 'critical'");
      Rejects (With_Lints ("  - not_a_real_operator:" & LF
        & "      var: body.prose"
                           & LF & "    severity: warn" & LF),
               "schema.lints[0]: unknown operator 'not_a_real_operator'");
      Rejects (With_Lints ("  - eq: null" & LF & "    severity: warn" & LF),
               "schema.lints[0].eq: a bare null is not valid here");
      Accepts (With_Lints ("  - no_hard_wrap:" & LF & "      var: body.prose"
        & LF
                           & "    severity: ignore" & LF));
      Accepts (With_Lints ("  - no_hard_wrap:" & LF & "      var: body.prose"
        & LF
                           & "    severity: warn" & LF));
      Accepts (With_Lints ("  - no_hard_wrap:" & LF & "      var: body.prose"
        & LF
                           & "    severity: error" & LF));
   end Lints_Are_Checked;

   procedure Severities_Parse (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Parse_Severity ("ignore").Found
              and then Parse_Severity ("ignore").Level = Ignore, "ignore");
      Assert (Parse_Severity ("warn").Level = Warn, "warn");
      Assert (Parse_Severity ("error").Level = Error_Level, "error");
      Assert (not Parse_Severity ("critical").Found, "anything else");
      Assert (not Parse_Severity ("").Found, "empty");
      Assert (not Parse_Severity ("Warn").Found, "case matters");
   end Severities_Parse;

   procedure The_Operators_Come_From_The_Set (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Source : constant String :=
        With_Lints ("  - no_hard_wrap:" & LF & "      var: body.prose" & LF
                    & "    severity: warn" & LF);
   begin
      Assert (Message_Of (Source, JSON_Logic.No_Operators)
              = "schema.lints[0]: unknown operator 'no_hard_wrap'",
              "unknown without the set");
      Assert (Message_Of (Source, Operators) = "<valid>", "known with it");
   end The_Operators_Come_From_The_Set;

   ---------------------------------------------------------------------------
   --  The shipped schemas
   ---------------------------------------------------------------------------

   procedure The_Shipped_Schemas_Are_Valid (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      procedure Check (Name : String) is
         Path : constant String := Schema_Dir & "/" & Name & "/v1.yaml";
         File : Ada.Streams.Stream_IO.File_Type;
      begin
         Assert (Ada.Directories.Exists (Path), Path & " exists");
         Ada.Streams.Stream_IO.Open
           (File, Ada.Streams.Stream_IO.In_File, Path);
         declare
            Size : constant Natural :=
              Natural (Ada.Streams.Stream_IO.Size (File));
            Text : String (1 .. Size);
         begin
            String'Read (Ada.Streams.Stream_IO.Stream (File), Text);
            Ada.Streams.Stream_IO.Close (File);
            declare
               Parsed : constant Schema_YAML.Parse_Result :=
                 Schema_YAML.Parse (Text);
            begin
               Assert (Parsed.Ok, Name & " parses");
               declare
                  Id     : constant String :=
                    As_String (Member_Value (Parsed.Root, "id"));
                  Result : constant Check_Result :=
                    Validate_Schema (Parsed.Root, Id, Operators);
               begin
                  Assert (Result.Valid,
                          Name & " validates: "
                          & (if Result.Valid then ""
                             else Ada.Strings.Unbounded.To_String
                                    (Result.Message)));
                  Assert
                    (not Validate_Schema
                           (Parsed.Root, "other/v1", Operators).Valid,
                     Name & " is bound to its own id");
                  if Name = "vault-note" then
                     declare
                        Stems : constant Schema_Rules.String_Array :=
                          Schema_Rules.Needed_Vocabulary_Stems (Parsed.Root);
                     begin
                        Assert
                          (Stems'Length = 1
                           and then Ada.Strings.Unbounded.To_String (Stems (1))
                                    = "synapse-tag-vocabulary",
                           "vault-note reads the tag vocabulary");
                        Assert (Schema_Rules.Needs_Identity_Scan (Parsed.Root),
                                "vault-note checks identity");
                     end;
                  elsif Name = "graph-node" then
                     Assert
                       (not Schema_Rules.Needs_Identity_Scan (Parsed.Root),
                             "graph-node has no identity check");
                  end if;
               end;
            end;
         end;
      end Check;
   begin
      Check ("vault-note");
      Check ("vault-task-note");
      Check ("vault-design-note");
      Check ("graph-node");
   end The_Shipped_Schemas_Are_Valid;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Note_Schema");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Well_Formed_Schema_Is_Accepted'Access,
         "A well-formed schema is accepted");
      Register_Routine
        (T, The_Header_Is_Checked_First'Access, "The header is checked first");
      Register_Routine
        (T, Frontmatter_Structure_Is_Checked'Access,
         "Frontmatter structure is checked");
      Register_Routine
        (T, Field_Rules_Are_Checked'Access, "Field rules are checked");
      Register_Routine
        (T, Pattern_Faults_Are_Named_As_Zig_Names_Them'Access,
         "Pattern faults are named as Zig names them");
      Register_Routine
        (T, Body_Structure_Is_Checked'Access, "Body structure is checked");
      Register_Routine
        (T, Section_Rules_Are_Checked'Access, "Section rules are checked");
      Register_Routine
        (T, A_Childs_Diagnostic_Carries_Its_Own_Index'Access,
         "A child's diagnostic carries its own index");
      Register_Routine
        (T, Preamble_Lead_And_Checklist_Are_Checked'Access,
         "Preamble, lead and checklist are checked");
      Register_Routine (T, Checks_Are_Checked'Access, "Checks are checked");
      Register_Routine (T, Lints_Are_Checked'Access, "Lints are checked");
      Register_Routine (T, Severities_Parse'Access, "Severities parse");
      Register_Routine
        (T, The_Operators_Come_From_The_Set'Access,
         "The operators come from the set");
      Register_Routine
        (T, The_Shipped_Schemas_Are_Valid'Access,
         "The shipped schemas are valid");
   end Register_Tests;

end Synapse.Core.Note_Schema.Tests;
