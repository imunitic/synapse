with Ada.Characters.Latin_1;
with Ada.Containers;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings;
with Ada.Strings.Fixed;
with Interfaces;

with AUnit.Assertions;
with Synapse.Core.Note_Operators;
with Synapse.Core.Schema_YAML;

package body Synapse.Core.Note_Check.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Note_Model;
   use type Ada.Containers.Count_Type;
   use type Interfaces.Unsigned_64;
   use type Note_Schema.Severity;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Ada.Characters.Latin_1.LF;
   CR : constant Character := Ada.Characters.Latin_1.CR;

   Schema_Dir : constant String := "../../packages/synapse/schema";

   --  UTF-8 text spelled out in bytes.
   Dash : constant String :=
     Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   Five_E_Acute : constant String :=
     [for I in 1 .. 10
      => Character'Val (if I mod 2 = 1 then 16#C3# else 16#A9#)];

   ---------------------------------------------------------------------------
   --  Schemas
   ---------------------------------------------------------------------------

   Head : constant String :=
     "schema: synapse-note-schema/v1" & LF & "id: t/v1" & LF;

   Title_Field : constant String :=
     "frontmatter:" & LF & "  fields:" & LF & "    title:" & LF
     & "      type: string" & LF & "      required: true" & LF;

   H1_Body : constant String :=
     "body:" & LF & "  h1:" & LF & "    required: true" & LF;

   --  A schema with a title field and a body of Body_Part.
   function Schema
     (Body_Part    : String := H1_Body;
      Checks       : String := "checks: []" & LF;
      Extra_Fields : String := "") return String
   is (Head & Title_Field & Extra_Fields & Body_Part & Checks);

   Bare_Schema : constant String :=
     Head & "frontmatter:" & LF & "  fields:" & LF
     & "    schema:" & LF & "      type: string" & LF & "      required: true"
     & LF & "      const: vault-note/v1" & LF
     & "    title:" & LF & "      type: string" & LF & "      required: true"
     & LF & "      min_length: 1" & LF
     & "    note_id:" & LF & "      type: string" & LF & "      required: true"
     & LF & "      pattern: '^[a-z][a-z0-9-]*-[0-9]{3,}$'" & LF
     & "      mutable: false" & LF
     & "    created:" & LF & "      type: timestamp" & LF
     & "      required: true" & LF & "      mutable: false" & LF
     & "    updated:" & LF & "      type: timestamp" & LF
     & "      required: true" & LF
     & "    tags:" & LF & "      type: list" & LF & "      required: true" & LF
     & "      items: string" & LF
     & "body:" & LF & "  h1:" & LF & "    required: true" & LF
     & "    count: 1" & LF & "    equals: frontmatter.title" & LF
     & "  sections:" & LF & "    - title: Summary" & LF & "      level: 2" & LF
     & "      required: true" & LF & "  section_order: relative" & LF
     & "checks:" & LF
     & "  - eq:" & LF & "      - var: filename.stem" & LF
     & "      - var: frontmatter.title" & LF
     & "  - on_create:" & LF & "      var: id_is_unique" & LF
     & "  - all:" & LF & "      - var: frontmatter.tags" & LF
     & "      - in:" & LF & "          - var: ''" & LF
     & "          - var: vocabularies.synapse-tag-vocabulary" & LF
     & "  - lte:" & LF & "      - var: created_epoch" & LF
     & "      - var: updated_epoch" & LF
     & "  - on_create:" & LF & "      eq:" & LF
     & "        - var: created_epoch" & LF & "        - var: updated_epoch"
     & LF;

   function Parsed (Source : String) return JSON.Value is
      Result : constant Schema_YAML.Parse_Result := Schema_YAML.Parse (Source);
   begin
      Assert (Schema_YAML.Parse_Results.Is_Success (Result), "the schema parses");
      declare
         Valid : constant Note_Schema.Check_Result :=
           Note_Schema.Validate_Schema
             (Schema_YAML.Parse_Results.Value (Result), "t/v1", Note_Operators.Operators);
         Bare  : constant Note_Schema.Check_Result :=
           Note_Schema.Validate_Schema
             (Schema_YAML.Parse_Results.Value (Result), "vault-note/v1", Note_Operators.Operators);
      begin
         Assert (Note_Schema.Check_Results.Is_Success (Valid) or else Note_Schema.Check_Results.Is_Success (Bare),
                 "the schema is valid: "
                 & (if Note_Schema.Check_Results.Is_Success (Valid) then "" else To_String (Note_Schema.Check_Results.Error (Valid))));
      end;
      return Schema_YAML.Parse_Results.Value (Result);
   end Parsed;

   ---------------------------------------------------------------------------
   --  Notes
   ---------------------------------------------------------------------------

   function Note (Fields : String; Body_Text : String := "# Example" & LF)
      return String
   is ("---" & LF & Fields & "---" & LF & Body_Text);

   function Example (Body_Text : String := "# Example" & LF) return String
   is (Note ("title: Example" & LF, Body_Text));

   Create_Ctx : constant Context := (Mode => Create, others => <>);

   function Message_Of
     (Source, Text : String; Ctx : Context := Create_Ctx;
      Path : String := "x.md") return String
   is
      Result : constant Note_Schema.Check_Result :=
        Validate_Note (Parsed (Source), Text, Path, Ctx);
   begin
      return (if Note_Schema.Check_Results.Is_Success (Result) then "<valid>" else To_String (Note_Schema.Check_Results.Error (Result)));
   end Message_Of;

   procedure Rejects
     (Source, Text, Want : String; Ctx : Context := Create_Ctx;
      Path : String := "x.md")
   is
      Got : constant String := Message_Of (Source, Text, Ctx, Path);
   begin
      Assert (Got = Want, "got '" & Got & "', wanted '" & Want & "'");
   end Rejects;

   procedure Accepts
     (Source, Text : String; Ctx : Context := Create_Ctx;
      Path : String := "x.md")
   is
      Got : constant String := Message_Of (Source, Text, Ctx, Path);
   begin
      Assert (Got = "<valid>", "should be valid, got: " & Got);
   end Accepts;

   function Vocab (Stem, Content : String) return Context is
      Ctx : Context := Create_Ctx;
   begin
      Ctx.Vocabularies.Append
        (Vocabulary_Source'
           (Stem    => To_Unbounded_String (Stem),
            Content => To_Unbounded_String (Content)));
      return Ctx;
   end Vocab;

   ---------------------------------------------------------------------------
   --  The bare-note schema
   ---------------------------------------------------------------------------

   Stamp : constant String := "'2026-08-30T10:00:00+02:00'";

   Bare_Note : constant String :=
     "---" & LF & "schema: vault-note/v1" & LF & "title: Example" & LF
     & "note_id: sb-081" & LF & "created: " & Stamp & LF
     & "updated: " & Stamp & LF & "tags: [synapse, architecture]" & LF
     & "extra: preserved" & LF & "---" & LF & LF & "# Example" & LF & LF
     & "## Summary" & LF & "Useful." & LF;

   procedure A_Conforming_Note_Is_Valid (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Accepts
        (Bare_Schema, Bare_Note,
         Vocab ("synapse-tag-vocabulary",
                "synapse" & LF & "architecture" & LF),
         "research/Example.md");
   end A_Conforming_Note_Is_Valid;

   procedure Immutable_Fields_Cannot_Change (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Existing : constant String :=
        "---" & LF & "schema: vault-note/v1" & LF & "title: Example" & LF
        & "note_id: sb-081" & LF & "created: " & Stamp & LF
        & "updated: " & Stamp & LF & "tags: []" & LF & "---" & LF
        & "# Example" & LF & "## Summary" & LF & "Old" & LF;
      Changed  : constant String :=
        "---" & LF & "schema: vault-note/v1" & LF & "title: Example" & LF
        & "note_id: sb-999" & LF & "created: " & Stamp & LF
        & "updated: '2026-08-30T11:00:00+02:00'" & LF & "tags: []" & LF
        & "---" & LF & "# Example" & LF & "## Summary" & LF & "New" & LF;
      Update   : constant Context :=
        (Mode => Note_Model.Update, Has_Existing => True,
         Existing => To_Unbounded_String (Existing), others => <>);
   begin
      Rejects (Bare_Schema, Changed, "frontmatter.note_id: field is immutable",
               Update, "research/Example.md");

      --  A migration cannot introduce an immutable field either.
      Rejects
        (Bare_Schema, Bare_Note, "frontmatter.note_id: field is immutable",
         (Mode => Migration, Has_Existing => True,
          Existing => To_Unbounded_String
                        ("---" & LF & "title: Example" & LF & "---" & LF
                         & "# Example" & LF & "## Summary" & LF & "Old" & LF),
          others => <>),
         "research/Example.md");

      --  On create there is nothing to compare with.
      Assert (Message_Of (Bare_Schema, Changed,
                          (Mode => Create, Has_Existing => True,
                           Existing => To_Unbounded_String (Existing),
                           others => <>), "research/Example.md")
              /= "frontmatter.note_id: field is immutable",
              "create does not compare");

      --  An update that leaves an immutable field alone passes that check.
      Assert (Message_Of (Bare_Schema, Existing,
                          (Mode => Note_Model.Update, Has_Existing => True,
                           Existing => To_Unbounded_String (Existing),
                           others => <>), "research/Example.md")
              /= "frontmatter.note_id: field is immutable",
              "unchanged");
   end Immutable_Fields_Cannot_Change;

   ---------------------------------------------------------------------------
   --  Field rules
   ---------------------------------------------------------------------------

   function Field_Schema (Rules : String) return String
   is (Head & "frontmatter:" & LF & "  fields:" & LF & "    title:" & LF
       & "      type: string" & LF & "      required: true" & LF
       & "    f:" & LF & Rules & H1_Body & "checks: []" & LF);

   function With_F (Value : String) return String
   is (Note ("title: Example" & LF & "f: " & Value & LF));

   procedure Field_Diagnostics_Name_The_Field (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Typed : constant String :=
        Field_Schema ("      type: string" & LF & "      required: true" & LF);
   begin
      Rejects (Typed, Note ("title: Example" & LF & "f: a" & LF & "f: b" & LF),
               "frontmatter.f: field occurs more than once");
      Rejects (Typed, Example, "frontmatter.f: required field is missing");
      Accepts (Field_Schema ("      type: string" & LF), Example);
      Rejects (Typed, With_F ("[a]"), "frontmatter.f: expected string");
      Rejects (Typed, With_F ("5"), "frontmatter.f: expected string");
      Rejects (Typed, With_F ("true"), "frontmatter.f: expected string");
      Rejects (Field_Schema ("      type: list" & LF & "      items: string"
                             & LF), With_F ("x"),
                              "frontmatter.f: expected list");
      Rejects (Field_Schema ("      type: integer" & LF), With_F ("x"),
               "frontmatter.f: expected integer");
      Accepts (Field_Schema ("      type: integer" & LF), With_F ("12"));
      Rejects (Field_Schema ("      type: boolean" & LF), With_F ("yes"),
               "frontmatter.f: expected boolean");
      Accepts (Field_Schema ("      type: boolean" & LF), With_F ("false"));
      Rejects (Field_Schema ("      type: string" & LF
                             & "      const: A" & LF),
               With_F ("B"), "frontmatter.f: expected 'A'");
      Accepts (Field_Schema ("      type: string" & LF
                             & "      const: A" & LF),
               With_F ("A"));
      Rejects (Field_Schema ("      type: string" & LF
                             & "      pattern: '^[a-z]+$'" & LF),
               With_F ("A1"),
               "frontmatter.f: does not match required pattern");
      Accepts (Field_Schema ("      type: string" & LF
                             & "      pattern: '^[a-z]+$'" & LF),
               With_F ("abc"));
      Rejects (Field_Schema ("      type: string" & LF
                             & "      enum: [a, b]" & LF),
               With_F ("c"), "frontmatter.f: value 'c' is not allowed");
      Accepts (Field_Schema ("      type: string" & LF
                             & "      enum: [a, b]" & LF), With_F ("b"));
      Rejects (Field_Schema ("      type: timestamp" & LF),
               With_F ("2026-09-06"),
               "frontmatter.f: expected RFC3339, YYYY-MM-DDTHH:MM:SS then Z or"
               & " a colon-separated numeric offset");
      Accepts (Field_Schema ("      type: timestamp" & LF),
               With_F ("'2026-09-06T21:29:16Z'"));
   end Field_Diagnostics_Name_The_Field;

   procedure Min_Length_Counts_Characters (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Source : constant String :=
        Head & "frontmatter:" & LF & "  fields:" & LF & "    title:" & LF
        & "      type: string" & LF & "      required: true" & LF
        & "      min_length: 5" & LF & H1_Body & "checks: []" & LF;
   begin
      Rejects (Source, Note ("title: Hi" & LF, "# Hi" & LF),
               "frontmatter.title: must be at least 5 characters");
      Accepts (Source, Note ("title: Hello" & LF, "# Hello" & LF));
      --  Five characters, ten bytes.
      Accepts (Source,
               Note ("title: """ & Five_E_Acute & """" & LF,
                     "# " & Five_E_Acute & LF));
   end Min_Length_Counts_Characters;

   procedure Field_Order_Is_Relative_When_Asked
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Source : constant String :=
        Head & "frontmatter:" & LF & "  field_order: relative" & LF
        & "  fields:" & LF & "    title:" & LF & "      type: string" & LF
        & "      required: true" & LF & "    sources:" & LF
        & "      type: string" & LF & "      required: false" & LF
        & H1_Body & "checks: []" & LF;
      Free : constant String := Schema (Extra_Fields => "    sources:" & LF
                                        & "      type: string" & LF
                                        & "      required: false" & LF);
   begin
      Rejects (Source,
               Note ("sources: x" & LF & "title: Example" & LF,
                     "# Example" & LF),
               "frontmatter.sources: declared fields are out of relative"
               & " order");
      Accepts (Source, Note ("title: Example" & LF & "sources: x" & LF));
      Accepts (Source, Example);  --  a missing optional field is skipped
      Accepts (Free, Note ("sources: x" & LF & "title: Example" & LF));
   end Field_Order_Is_Relative_When_Asked;

   procedure Any_Accepts_A_List_Of_Mappings (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Source : constant String :=
        Schema (Extra_Fields => "    sources:" & LF & "      type: any" & LF
                & "      required: true" & LF);
   begin
      Accepts (Source,
               Note ("title: Example" & LF & "sources:" & LF
                     & "  - path: a.zig" & LF & "    hash: aa" & LF
                     & "  - path: b.zig" & LF & "    hash: bb" & LF));
      Rejects
        (Source, Example, "frontmatter.sources: required field is missing");
   end Any_Accepts_A_List_Of_Mappings;

   procedure A_Note_Needs_Frontmatter (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Delimiters : constant String :=
        "frontmatter: opening and closing delimiters are required";
   begin
      Rejects (Schema, "# Example" & LF, Delimiters);
      Rejects (Schema, "---" & LF & "title: Example" & LF & "# Example" & LF,
               Delimiters);
      Rejects (Schema, "", Delimiters);
      Accepts (Schema, "---" & CR & LF & "title: Example" & CR & LF & "---"
               & CR & LF & "# Example" & CR & LF);
   end A_Note_Needs_Frontmatter;

   ---------------------------------------------------------------------------
   --  Body
   ---------------------------------------------------------------------------

   function Section_Schema (Sections : String) return String
   is (Schema (Body_Part => H1_Body & "  sections:" & LF & Sections));

   procedure The_H1_Is_Counted_And_Matched (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Rejects (Schema, Note ("title: Example" & LF, "no heading" & LF),
               "body.h1: expected 1, found 0");
      Rejects (Schema, Note ("title: Example" & LF,
                             "# Example" & LF & "# Again" & LF),
               "body.h1: expected 1, found 2");
      Rejects (Schema, Note ("title: Example" & LF, "# Other" & LF),
               "body.h1: must equal frontmatter.title");
      Rejects (Schema, Note ("title: Example" & LF,
                             "```" & LF & "# code" & LF & "```" & LF),
               "body.h1: expected 1, found 0");
      Accepts (Schema, Note ("title: Example" & LF,
                             "```" & LF & "# code" & LF & "```" & LF
                             & "# Example" & LF));
      Accepts (Schema (Body_Part => "body:" & LF & "  h1:" & LF
                       & "    count: 2" & LF),
               Note ("title: Example" & LF,
                     "# Example" & LF & "# Example" & LF));
   end The_H1_Is_Counted_And_Matched;

   procedure Declared_Sections_Are_Checked (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Req : constant String :=
        Section_Schema ("    - title: A" & LF & "      required: true" & LF);
   begin
      Rejects (Req, Example, "body.section.A: required heading is missing");
      Accepts (Req, Example ("# Example" & LF & "## A" & LF & "x" & LF));
      Accepts (Section_Schema ("    - title: A" & LF), Example);
      Rejects (Req, Example ("# Example" & LF & "## A" & LF & "## A" & LF),
               "body.section.A: occurs 2 times; maximum is 1");
      Accepts (Section_Schema ("    - title: A" & LF & "      max_occurs: 2"
                               & LF),
               Example ("# Example" & LF & "## A" & LF & "## A" & LF));
      Rejects (Section_Schema ("    - title: A" & LF & "      level: 3" & LF
                               & "      required: true" & LF),
               Example ("# Example" & LF & "## A" & LF),
               "body.section.A: required heading is missing");
      Rejects (Section_Schema ("    - title: A" & LF & "      non_empty: true"
                               & LF),
               Example ("# Example" & LF & "## A" & LF & LF & "## B" & LF),
               "body.section.A: must not be empty");
      Accepts (Section_Schema ("    - title: A" & LF & "      non_empty: true"
                               & LF),
               Example ("# Example" & LF & "## A" & LF & "text" & LF));
      Rejects (Section_Schema ("    - title: Status" & LF & "      content:"
                               & LF & "        enum: [Ready, Done]" & LF),
               Example ("# Example" & LF & "## Status" & LF & "Maybe" & LF),
               "body.section.Status: content 'Maybe' is not allowed");
      Accepts (Section_Schema ("    - title: Status" & LF & "      content:"
                               & LF & "        enum: [Ready, Done]" & LF),
               Example ("# Example" & LF & "## Status" & LF & "Ready" & LF));
      --  A section with only a title pattern is not looked up.
      Accepts (Section_Schema ("    - title_pattern: '^X'" & LF
                               & "      required: true" & LF), Example);
   end Declared_Sections_Are_Checked;

   procedure Declared_Sections_Keep_Their_Relative_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Source : constant String :=
        Section_Schema ("    - title: Z" & LF & "      level: 2" & LF
                        & "      required: false" & LF & "    - title: A" & LF
                        & "      level: 2" & LF & "      required: false"
                        & LF);
   begin
      Rejects (Source,
               Example ("# Example" & LF & LF & "## A" & LF & "content" & LF
                        & LF & "## Z" & LF & "content" & LF),
               "body.section.A: declared sections are out of relative order");
      Accepts (Source,
               Example ("# Example" & LF & LF & "## Z" & LF & "content" & LF
                        & LF & "## A" & LF & "content" & LF));
   end Declared_Sections_Keep_Their_Relative_Order;

   procedure Child_Headings_Follow_Their_Rules (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Children (Rules : String) return String
      is (Section_Schema ("    - title: Notes" & LF & "      level: 2" & LF
                          & "      required: false" & LF & "      children:"
                          & LF & Rules));

      Dated : constant String :=
        Children ("        - level: 3" & LF & "          required: false" & LF
                  & "          title_pattern: '^[0-9]{4}-[0-9]{2}-[0-9]{2} "
                  & Dash & " .+$'"
                  & LF);
   begin
      Rejects (Dated,
               Example ("# Example" & LF & LF & "## Notes" & LF & LF
                        & "### Not dated" & LF & LF & "content" & LF),
               "body.section.Notes: child heading 'Not dated' has an invalid"
               & " title");
      Accepts (Dated,
               Example ("# Example" & LF & LF & "## Notes" & LF & LF
                        & "### 2026-08-30 " & Dash & " entry" & LF & LF
                        & "content"
                        & LF));
      Accepts (Children ("        - title: Wanted" & LF & "          level: 3"
                         & LF & "          required: false" & LF),
               Example ("# Example" & LF & LF & "## Notes" & LF & LF
                        & "### Unrelated" & LF & LF & "content" & LF));
      Rejects (Children ("        - title: Wanted" & LF
                         & "          required: true" & LF),
               Example ("# Example" & LF & "## Notes" & LF),
               "body.section.Notes: required child heading is missing");
      Rejects (Children ("        - title: Wanted" & LF),
               Example ("# Example" & LF & "## Notes" & LF & "### Wanted" & LF
                        & "### Wanted" & LF),
               "body.section.Notes: child heading occurs more than once");
      Accepts (Children ("        - title: Wanted" & LF
                         & "          repeatable: true" & LF),
               Example ("# Example" & LF & "## Notes" & LF & "### Wanted" & LF
                        & "### Wanted" & LF));
      Rejects (Children ("        - title: Wanted" & LF
                         & "          non_empty: true" & LF),
               Example ("# Example" & LF & "## Notes" & LF & "### Wanted" & LF
                        & LF & "## Other" & LF),
               "body.section.Notes.Wanted: must not be empty");
      --  A heading outside the parent's content is not its child.
      Rejects (Children ("        - title: Wanted" & LF
                         & "          required: true" & LF),
               Example ("# Example" & LF & "## Notes" & LF & "## Other" & LF
                        & "### Wanted" & LF),
               "body.section.Notes: required child heading is missing");
   end Child_Headings_Follow_Their_Rules;

   procedure A_Backlink_Must_Follow_The_H1 (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Source : constant String :=
        Schema (Body_Part => H1_Body & "  preamble:" & LF
                & "    - type: blockquote" & LF & "      required: false" & LF
                & "      position: immediately_after_h1" & LF
                & "      marker: '> Compiled task:'" & LF
                & "      pattern: '^> Compiled task: \[\[[^\]]+\]\]$'" & LF);
   begin
      Rejects (Source,
               Example ("# Example" & LF & LF & "lead paragraph" & LF & LF
                        & "> Compiled task: [[Task title]]" & LF),
               "body.preamble: '> Compiled task:' annotation must immediately"
               & " follow H1");
      Accepts (Source,
               Example ("# Example" & LF & LF
                        & "> Compiled task: [[Task title]]" & LF & LF
                        & "## Summary" & LF & "rest" & LF));
      Rejects (Source,
               Example ("# Example" & LF & LF
                        & "> Compiled task: Task title (no wikilink)" & LF
                        & LF & "## Summary" & LF & "rest" & LF),
               "body.preamble: '> Compiled task:' annotation is malformed");
      Accepts (Source, Example ("# Example" & LF & LF & "no backlink" & LF));
      Rejects (Source,
               Example ("# Example" & LF & LF & "> Compiled task: [[A]]" & LF
                        & "## S" & LF & "> Compiled task: [[B]]" & LF),
               "body.preamble: '> Compiled task:' annotation must immediately"
               & " follow H1");
      --  Without a marker, or without a pattern, nothing is checked.
      Accepts (Schema (Body_Part => H1_Body & "  preamble:" & LF
                       & "    - type: blockquote" & LF
                       & "      pattern: '^> Compiled task: \[\[[^\]]+\]\]$'"
                       & LF),
               Example ("# Example" & LF & LF & "lead paragraph" & LF & LF
                        & "> Compiled task: [[Task title]]" & LF));
      Accepts (Schema (Body_Part => H1_Body & "  preamble:" & LF
                       & "    - type: blockquote" & LF
                       & "      marker: '> Compiled task:'" & LF),
               Example ("# Example" & LF & LF & "lead paragraph" & LF & LF
                        & "> Compiled task: anything" & LF));
   end A_Backlink_Must_Follow_The_H1;

   Checklist_Sections : constant String :=
     "  sections:" & LF & "    - title: Checklist" & LF & "      level: 2" & LF
     & "      required: true" & LF & "    - title: Notes" & LF
     & "      level: 2" & LF & "      required: false" & LF;

   function Task_Schema (Checklist : String) return String
   is (Schema (Body_Part => H1_Body & "  lead:" & LF & "    required: true"
               & LF & "  checklist:" & LF & Checklist & Checklist_Sections));

   procedure Checklists_Are_Counted_Under_Their_Heading
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Two : constant String :=
        Task_Schema ("    required: true" & LF & "    min_items: 2" & LF);
      One : constant String :=
        Task_Schema ("    required: true" & LF & "    min_items: 1" & LF);
   begin
      Rejects (Two,
               Example ("# Example" & LF & LF & "lead" & LF & LF
                        & "## Checklist" & LF & LF & "- [ ] one" & LF & LF
                        & "## Notes" & LF & "rest" & LF),
               "body.checklist: expected at least 2 flat item(s), found 1");
      Accepts (Two,
               Example ("# Example" & LF & LF & "lead" & LF & LF
                        & "## Checklist" & LF & LF & "- [ ] one" & LF
                        & "- [x] two" & LF & LF & "## Notes" & LF & "rest"
                        & LF));
      --  Only the Checklist heading's own content counts.
      Rejects (One,
               Example ("# Example" & LF & LF & "lead" & LF & LF
                        & "## Checklist" & LF & LF & "## Notes" & LF & LF
                        & "- [ ] not a checklist item" & LF),
               "body.checklist: expected at least 1 flat item(s), found 0");
      Accepts (One,
               Example ("# Example" & LF & LF & "lead" & LF & LF
                        & "## Checklist" & LF & LF & "- [ ] one" & LF & LF
                        & "## Notes" & LF & LF & "- [ ] not counted" & LF));
      Rejects (One,
               Example ("# Example" & LF & LF & "lead" & LF & LF
                        & "## Checklist" & LF & LF & "- [ ] one" & LF
                        & "  - [ ] sub" & LF),
               "body.checklist: nested checklist items are not allowed");
      Accepts (One,
               Example ("# Example" & LF & LF & "lead" & LF & LF
                        & "## Checklist" & LF & LF & "- [X] one" & LF));
      --  Fenced text is not an item, nested or not.
      Accepts (One,
               Example ("# Example" & LF & LF & "lead" & LF & LF
                        & "## Checklist" & LF & LF & "- [ ] one" & LF
                        & "```" & LF & "  - [ ] sample" & LF & "```" & LF));
      Rejects (One,
               Example ("# Example" & LF & LF & "lead" & LF & LF
                        & "## Checklist" & LF & LF & "text only" & LF),
               "body.checklist: expected at least 1 flat item(s), found 0");
      Accepts (Task_Schema ("    required: false" & LF),
               Example ("# Example" & LF & LF & "lead" & LF & LF
                        & "## Checklist" & LF));
   end Checklists_Are_Counted_Under_Their_Heading;

   procedure Lead_Prose_Comes_Before_The_Checklist
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Source : constant String := Task_Schema ("    required: true" & LF);
   begin
      Rejects (Source,
               Example ("# Example" & LF & LF & "## Checklist" & LF & LF
                        & "- [ ] one" & LF),
               "body.lead: prose before the checklist is required");
      Accepts (Source,
               Example ("# Example" & LF & LF & "lead prose" & LF & LF
                        & "## Checklist" & LF & LF & "- [ ] one" & LF));
      Rejects (Source,
               Example ("# Example" & LF & LF & "> a quote only" & LF & LF
                        & "## Checklist" & LF & LF & "- [ ] one" & LF),
               "body.lead: prose before the checklist is required");
      Accepts (Source,
               Example ("# Example" & CR & LF & CR & LF & "lead" & CR & LF
                        & CR & LF & "## Checklist" & CR & LF & CR & LF
                        & "- [ ] one" & CR & LF));
   end Lead_Prose_Comes_Before_The_Checklist;

   ---------------------------------------------------------------------------
   --  Rules
   ---------------------------------------------------------------------------

   function Checks_Schema (Rules : String) return String
   is (Schema (Checks => "checks:" & LF & Rules));

   Precedes : constant String :=
     "frontmatter.updated: must not precede frontmatter.created";

   Updated_Not_Before_Created : constant String :=
     Checks_Schema ("  - lte:" & LF & "      - var: created_epoch" & LF
                    & "      - var: updated_epoch" & LF
                    & "    message: '" & Precedes & "'" & LF);

   procedure Timestamps_Compare_As_Instants (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Pair (Created, Updated : String) return String
      is (Note ("title: Example" & LF & "updated: '" & Updated & "'" & LF
                & "created: '" & Created & "'" & LF));
   begin
      Rejects (Updated_Not_Before_Created, Example, Precedes);  --  missing
      Rejects (Updated_Not_Before_Created,
               Pair ("2026-08-30T02:00:00+02:00", "2026-08-30T01:00:00+02:00"),
               Precedes);
      Accepts (Updated_Not_Before_Created,
               Pair ("2026-08-30T01:00:00+02:00",
                     "2026-08-30T02:00:00+02:00"));
      --  The same wall-clock time an hour apart across the clocks going back.
      Accepts (Updated_Not_Before_Created,
               Pair ("2026-10-25T02:30:00+02:00",
                     "2026-10-25T02:30:00+01:00"));
      Rejects (Updated_Not_Before_Created,
               Pair ("2026-10-25T02:30:00+01:00", "2026-10-25T02:30:00+02:00"),
               Precedes);
   end Timestamps_Compare_As_Instants;

   procedure Equality_Of_Two_Missing_Fields_Holds (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Source : constant String :=
        Schema (Extra_Fields =>
                  "    a:" & LF & "      type: string" & LF
                  & "      required: false" & LF
                  & "    b:" & LF & "      type: string" & LF
                  & "      required: false" & LF,
                Checks => "checks:" & LF & "  - eq:" & LF
                & "      - var: frontmatter.a" & LF
                & "      - var: frontmatter.b" & LF
                & "    message: 'frontmatter.a: must equal frontmatter.b'"
                & LF);
   begin
      Accepts (Source, Example);
      Accepts
        (Source, Note ("title: Example" & LF & "a: x" & LF & "b: x" & LF));
      Rejects (Source, Note ("title: Example" & LF & "a: x" & LF),
               "frontmatter.a: must equal frontmatter.b");
   end Equality_Of_Two_Missing_Fields_Holds;

   procedure Creation_Only_Rules_Skip_Updates (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Source : constant String :=
        Checks_Schema ("  - on_create:" & LF & "      eq:" & LF
                       & "        - var: frontmatter.status" & LF
                       & "        - TODO" & LF
                       & "    message: ""frontmatter.status: must equal 'TODO'"
                       & " on creation""" & LF);
      Done : constant String :=
        Note ("title: Example" & LF & "status: DONE" & LF);
   begin
      Rejects (Source, Done,
               "frontmatter.status: must equal 'TODO' on creation");
      Accepts (Source, Done,
               (Mode => Note_Model.Update, Has_Existing => True,
                Existing => To_Unbounded_String (Example), others => <>));
      Rejects (Source, Done,
               "frontmatter.status: must equal 'TODO' on creation",
               (Mode => Migration, others => <>));
   end Creation_Only_Rules_Skip_Updates;

   procedure Vocabularies_Limit_A_Field (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Source : constant String :=
        Schema (Extra_Fields =>
                  "    tags:" & LF & "      type: list" & LF
                  & "      required: true" & LF & "      items: string" & LF,
                Checks => "checks:" & LF & "  - all:" & LF
                & "      - var: frontmatter.tags" & LF & "      - in:" & LF
                & "          - var: ''" & LF
                & "          - var: vocabularies.synapse-tag-vocabulary" & LF
                & "    message: ""frontmatter.tags: not in"
                & " synapse-tag-vocabulary.conf""" & LF);
      Ctx : constant Context :=
        Vocab ("synapse-tag-vocabulary", "synapse" & LF & "architecture" & LF);
   begin
      Rejects (Source,
               Note ("title: Example" & LF & "tags: [synapse, nope]" & LF),
               "frontmatter.tags: not in synapse-tag-vocabulary.conf", Ctx);
      Accepts (Source, Note ("title: Example" & LF & "tags: [synapse]" & LF),
               Ctx);
   end Vocabularies_Limit_A_Field;

   procedure A_Failing_Rule_Without_A_Message_Prints_Itself
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Rejects (Checks_Schema ("  - eq:" & LF & "      - var: frontmatter.title"
                              & LF & "      - Other" & LF),
               Example,
               "rule failed: {""=="":[{""var"":""frontmatter.title""},"
               & """Other""]}");
      Rejects (Checks_Schema ("  - not:" & LF & "      var: frontmatter.title"
                              & LF),
               Example,
               "rule failed: {""!"":{""var"":""frontmatter.title""}}");

      --  A long rule is cut at 512 bytes.
      declare
         Words : Unbounded_String;
      begin
         for I in 1 .. 200 loop
            Append (Words, (if I > 1 then ", " else "") & "word"
                    & Ada.Strings.Fixed.Trim (Integer'Image (I),
                                              Ada.Strings.Left));
         end loop;
         declare
            Got : constant String :=
              Message_Of (Checks_Schema ("  - in:" & LF & "      - nothing"
                                         & LF & "      - [" & To_String (Words)
                                         & "]" & LF), Example);
         begin
            Assert (Got'Length = 13 + 512,
                    "cut at 512 bytes after the prefix:" & Got'Length'Image);
            Assert (Got (Got'First .. Got'First + 12) = "rule failed: ",
                    "prefix");
         end;
      end;
   end A_Failing_Rule_Without_A_Message_Prints_Itself;

   procedure The_First_Failing_Rule_Is_Reported
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Rejects (Checks_Schema ("  - eq: [1, 1]" & LF & "  - eq: [1, 2]" & LF
                              & "    message: second" & LF & "  - eq: [1, 3]"
                              & LF & "    message: third" & LF),
               Example, "second");
      Accepts (Checks_Schema ("  - eq: [1, 1]" & LF & "  - ne: [1, 2]" & LF),
               Example);
   end The_First_Failing_Rule_Is_Reported;

   procedure Frontmatter_Problems_Come_Before_Body_And_Rules
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Source : constant String :=
        Schema (Checks => "checks:" & LF & "  - eq: [1, 2]" & LF
                & "    message: rule" & LF);
   begin
      Rejects (Source,
               "---" & LF & "other: x" & LF & "---" & LF & "no h1" & LF,
               "frontmatter.title: required field is missing");
      Rejects (Source, Note ("title: Example" & LF, "no h1" & LF),
               "body.h1: expected 1, found 0");
      Rejects (Source, Example, "rule");
   end Frontmatter_Problems_Come_Before_Body_And_Rules;

   ---------------------------------------------------------------------------
   --  Lints
   ---------------------------------------------------------------------------

   Lint_Fields : constant String :=
     "    task_id:" & LF & "      type: string" & LF;

   function Lint_Schema (Lints : String) return String
   is (Schema (Extra_Fields => Lint_Fields) & "lints:" & LF & Lints);

   Wrapped : constant String :=
     "# Example" & LF & LF & "## Summary" & LF & "This is a sentence that got"
     & LF & "hard-wrapped across two lines." & LF;

   Joined : constant String :=
     "# Example" & LF & LF & "## Summary" & LF
     & "This is one continuous line, exactly as the convention wants." & LF;

   function No_Wrap (Severity : String) return String
   is (Lint_Schema ("  - no_hard_wrap:" & LF & "      var: body.prose" & LF
                    & "    severity: " & Severity & LF));

   function Lints_Of (Source, Text : String) return Finding_Vectors.Vector
   is (Lint_Note (Parsed (Source), Text, "x.md"));

   procedure A_Schema_Without_Lints_Lints_Nothing (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Lints_Of (Schema, Example (Wrapped)).Is_Empty, "no lints key");
   end A_Schema_Without_Lints_Lints_Nothing;

   procedure A_Wrapped_Paragraph_Is_A_Finding (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Found : constant Finding_Vectors.Vector :=
        Lints_Of (No_Wrap ("warn"), Example (Wrapped));
   begin
      Assert (Found.Length = 1, "one finding");
      Assert (Found (1).Level = Note_Schema.Warn, "its severity");
      Assert (Ada.Strings.Unbounded.Index (Found (1).Message, "no_hard_wrap")
              > 0, "the rule is named: " & To_String (Found (1).Message));
      Assert (Lints_Of (No_Wrap ("warn"), Example (Joined)).Is_Empty,
              "a clean note");
   end A_Wrapped_Paragraph_Is_A_Finding;

   procedure Severity_Is_Carried_Or_Skips_The_Rule
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Lints_Of (No_Wrap ("ignore"), Example (Wrapped)).Is_Empty,
              "ignore skips the rule");
      Assert (Lints_Of (No_Wrap ("error"), Example (Wrapped)) (1).Level
              = Note_Schema.Error_Level, "error");

      --  An ignored rule is not evaluated at all: a zero width would raise.
      declare
         Source : constant String :=
           Lint_Schema ("  - hard_wrap:" & LF & "      - var: body.prose" & LF
                        & "      - 0" & LF & "    severity: ignore" & LF);
      begin
         Assert (Lints_Of (Source, Example).Is_Empty, "not evaluated");
      end;
   end Severity_Is_Carried_Or_Skips_The_Rule;

   procedure Every_Failing_Lint_Is_Collected (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Source : constant String :=
        Lint_Schema ("  - no_hard_wrap:" & LF & "      var: body.prose" & LF
                     & "    severity: warn" & LF
                     & "  - eq: [1, 2]" & LF & "    message: always"
                     & LF & "    severity: error" & LF
                     & "  - eq: [1, 1]" & LF & "    severity: warn" & LF
                     & "  - not:" & LF & "      starts_with:" & LF
                     & "        - var: frontmatter.title" & LF
                     & "        - var: frontmatter.task_id" & LF
                     & "    severity: warn" & LF);
      Found : constant Finding_Vectors.Vector :=
        Lints_Of (Source, Note ("title: sb-1 x" & LF & "task_id: sb-1" & LF,
                                Wrapped));
   begin
      Assert (Found.Length = 3, "three findings:" & Found.Length'Image);
      Assert (Found (2).Level = Note_Schema.Error_Level
              and then To_String (Found (2).Message) = "always",
              "its message");
      Assert (Found (1).Level = Note_Schema.Warn
              and then Found (3).Level = Note_Schema.Warn, "in order");
   end Every_Failing_Lint_Is_Collected;

   procedure Prose_That_Is_Not_Wrapped_Passes_The_Lint
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Lints_Of
                (No_Wrap ("warn"),
                 Example ("# Example" & LF & LF & "## Summary" & LF
                          & "| a | b |" & LF & "| c | d |" & LF & LF
                          & "- item one" & LF & "  a continuation" & LF
                          & "  and another line" & LF & LF & "```" & LF
                          & "code line one" & LF & "code line two" & LF
                          & "```" & LF)).Is_Empty, "excluded shapes");
   end Prose_That_Is_Not_Wrapped_Passes_The_Lint;

   procedure A_Title_Starting_With_Its_Id_Fires
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Source : constant String :=
        Lint_Schema ("  - not:" & LF & "      starts_with:" & LF
                     & "        - var: frontmatter.title" & LF
                     & "        - var: frontmatter.task_id" & LF
                     & "    severity: warn" & LF);
      Found : constant Finding_Vectors.Vector :=
        Lints_Of (Source,
                  Note ("title: ""sb-102 " & Dash & " Something""" & LF
                        & "task_id: sb-102" & LF));
   begin
      Assert (Found.Length = 1, "prefixed");
      Assert (Ada.Strings.Unbounded.Index (Found (1).Message, "starts_with")
              > 0, "named: " & To_String (Found (1).Message));
      Assert (Lints_Of (Source, Note ("title: Something" & LF
                                      & "task_id: sb-102" & LF)).Is_Empty,
              "clean");
      Assert (Lints_Of (Source, Example).Is_Empty, "no id to start with");
   end A_Title_Starting_With_Its_Id_Fires;

   ---------------------------------------------------------------------------
   --  Schema ids
   ---------------------------------------------------------------------------

   function Id_Of (Fields : String) return String is
      Found : constant Maybe_Text := Schema_Id (Note (Fields));
   begin
      return
        (if Found.Found then "<" & To_String (Found.Value) & ">" else "none");
   end Id_Of;

   procedure Schema_Ids_Are_Read_Quoted_Or_Not (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Id_Of ("schema: vault-note/v1" & LF) = "<vault-note/v1>", "plain");
      Assert (Id_Of ("schema: ""vault-note/v1""" & LF) = "<vault-note/v1>",
              "double quoted");
      Assert (Id_Of ("schema: 'vault-note/v1'" & LF) = "<vault-note/v1>",
              "single quoted");
      Assert (Id_Of ("schema:   x   # why" & LF) = "<x>", "comment");
      Assert
        (Id_Of ("title: a" & LF & "schema: x" & LF) = "<x>", "later line");
      Assert (Id_Of ("schema: [a, b]" & LF) = "none", "a list");
      Assert (Id_Of ("schema: {a: b}" & LF) = "none", "a mapping");
      Assert (Id_Of ("schema:" & LF) = "none", "empty");
      Assert (Id_Of ("title: a" & LF) = "none", "absent");
      Assert (Id_Of ("  schema: x" & LF) = "none", "indented");
      Assert (Id_Of ("# schema: x" & LF) = "none", "comment line");
      Assert (Id_Of ("subschema: x" & LF) = "none", "a different key");
      Assert (Id_Of ("schema: 5" & LF) = "<5>", "digits are text");
      Assert
        (Id_Of ("schema: x" & LF & "schema: y" & LF) = "<x>", "the first");
      Assert (not Schema_Id ("schema: x" & LF).Found, "no frontmatter");
      Assert (Schema_Id (Note ("schema: x" & CR & LF)).Found, "CRLF");
   end Schema_Ids_Are_Read_Quoted_Or_Not;

   ---------------------------------------------------------------------------
   --  Shipped schemas
   ---------------------------------------------------------------------------

   function Read_File (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Assert (Ada.Directories.Exists (Path), Path & " exists");
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      declare
         Text : String (1 .. Natural (Ada.Streams.Stream_IO.Size (File)));
      begin
         String'Read (Ada.Streams.Stream_IO.Stream (File), Text);
         Ada.Streams.Stream_IO.Close (File);
         return Text;
      end;
   end Read_File;

   function Shipped (Name : String) return JSON.Value is
      Result : constant Schema_YAML.Parse_Result :=
        Schema_YAML.Parse (Read_File (Schema_Dir & "/" & Name & "/v1.yaml"));
   begin
      Assert (Schema_YAML.Parse_Results.Is_Success (Result), Name & " parses");
      return Schema_YAML.Parse_Results.Value (Result);
   end Shipped;

   procedure Shipped_Schemas_Accept_Conforming_Notes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      Projects : constant String := "synapse=sb" & LF;
      Tags     : constant String := "synapse" & LF & "ada" & LF;

      function Ctx_For (Mode : Note_Model.Mode) return Context is
         Ctx : Context := (Mode => Mode, others => <>);
      begin
         Ctx.Vocabularies.Append
           (Vocabulary_Source'
              (Stem    => To_Unbounded_String ("synapse-projects"),
               Content => To_Unbounded_String (Projects)));
         Ctx.Vocabularies.Append
           (Vocabulary_Source'
              (Stem    => To_Unbounded_String ("synapse-tag-vocabulary"),
               Content => To_Unbounded_String (Tags)));
         return Ctx;
      end Ctx_For;

      Task_Note : constant String :=
        "---" & LF & "schema: vault-task-note/v1" & LF & "title: Example" & LF
        & "project: ""sb""" & LF & "task_id: ""sb-001""" & LF
        & "created: """ & "2026-10-06T10:00:00+02:00""" & LF
        & "updated: ""2026-10-06T10:00:00+02:00""" & LF
        & "tags: [synapse, ada]" & LF & "status: TODO" & LF & "---" & LF
        & "# Example" & LF & LF & "> Design note: [[A design]]" & LF & LF
        & "Lead prose." & LF & LF & "## Checklist" & LF & LF
        & "- [ ] first" & LF & LF & "## Notes" & LF & LF
        & "### 2026-10-06 " & Dash & " Summary" & LF & "- done" & LF;

      Vault_Note : constant String :=
        "---" & LF & "schema: vault-note/v1" & LF & "title: Example" & LF
        & "note_id: sb-081" & LF & "created: " & Stamp & LF
        & "updated: " & Stamp & LF & "tags: [synapse, ada]" & LF
        & "---" & LF & LF & "# Example" & LF & LF & "## Summary" & LF
        & "Useful." & LF;
   begin
      declare
         Got : constant Note_Schema.Check_Result :=
           Validate_Note (Shipped ("vault-task-note"), Task_Note,
                          "tasks/s/Example.md",
                          Ctx_For (Create));
      begin
         Assert (Note_Schema.Check_Results.Is_Success (Got), "a task note: "
                 & (if Note_Schema.Check_Results.Is_Success (Got) then "" else To_String (Note_Schema.Check_Results.Error (Got))));
      end;
      declare
         Got : constant Note_Schema.Check_Result :=
           Validate_Note (Shipped ("vault-note"), Vault_Note, "r/Example.md",
                          Ctx_For (Create));
      begin
         Assert (Note_Schema.Check_Results.Is_Success (Got), "a vault note: "
                 & (if Note_Schema.Check_Results.Is_Success (Got) then "" else To_String (Note_Schema.Check_Results.Error (Got))));
      end;

      --  A task note created as DONE is refused by its own rule.
      declare
         Done : String := Task_Note;
         Mark : constant Natural := Ada.Strings.Fixed.Index (Done, "TODO");
      begin
         Done (Mark .. Mark + 3) := "DONE";
         Assert
           (To_String
              (Note_Schema.Check_Results.Error
                 (Validate_Note (Shipped ("vault-task-note"), Done,
                                 "tasks/s/Example.md", Ctx_For (Create))))
            = "frontmatter.status: must equal TODO on creation",
            "creation status");
         Assert (Note_Schema.Check_Results.Is_Success
                   (Validate_Note (Shipped ("vault-task-note"), Done,
                                   "tasks/s/Example.md", Ctx_For (Update))),
                 "but an update may change it");
      end;

      --  Lints on the shipped schemas never raise and find nothing in a
      --  tidy note.
      Assert (Lint_Note (Shipped ("vault-task-note"), Task_Note,
                         "tasks/s/Example.md").Is_Empty, "no findings");
   end Shipped_Schemas_Accept_Conforming_Notes;

   procedure Random_Notes_Never_Raise (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      State : Interfaces.Unsigned_64 := 16#4F1B_BCDC_BFA5_3E0B#;

      function Next (Bound : Positive) return Natural is
      begin
         State :=
           State * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
         return
           Natural ((State / 65_536) mod Interfaces.Unsigned_64 (Bound));
      end Next;

      function Piece (N : Natural) return String
      is (case N is
            when 0 => "---" & LF,
            when 1 => "title: X" & LF,
            when 2 => "tags: [a, b]" & LF,
            when 3 => "status: TODO" & LF,
            when 4 => "created: '2026-10-06T10:00:00Z'" & LF,
            when 5 => "# X" & LF,
            when 6 => "## Checklist" & LF,
            when 7 => "- [ ] item" & LF,
            when 8 => "  - [x] nested" & LF,
            when 9 => "## Notes" & LF,
            when 10 => "### 2026-10-06 - day" & LF,
            when 11 => "> Design note: [[X]]" & LF,
            when 12 => "text words here" & LF,
            when 13 => CR & LF,
            when 14 => "```" & LF,
            when 15 => "tags:" & LF & "  - a" & LF,
            when 16 => "task_id: sb-001" & LF,
            when 17 => "note_id: sb-002" & LF,
            when 18 => "schema: vault-note/v1" & LF,
            when 19 => "[" & LF,
            when others => "x: ""open" & LF);

      function Name_At (N : Positive) return String
      is (case N is
            when 1 => "vault-note",
            when 2 => "vault-task-note",
            when others => "vault-design-note");
   begin
      for N in 1 .. 3 loop
         declare
            Name         : constant String := Name_At (N);
            Schema_Value : constant JSON.Value := Shipped (Name);
         begin
            for Round in 1 .. 800 loop
               declare
                  Text : Unbounded_String;
               begin
                  for K in 1 .. Next (25) loop
                     Append (Text, Piece (Next (21)));
                  end loop;
                  declare
                     Note : constant String := To_String (Text);
                     Mode : constant Note_Model.Mode :=
                       Note_Model.Mode'Val (Next (3));
                     Result : constant Note_Schema.Check_Result :=
                       Validate_Note
                         (Schema_Value, Note, "x.md",
                          (Mode => Mode, Has_Existing => Next (2) = 0,
                           Existing => To_Unbounded_String (Note),
                           others => <>));
                     Lints  : constant Finding_Vectors.Vector :=
                       Lint_Note (Schema_Value, Note, "x.md");
                     Id     : constant Maybe_Text := Schema_Id (Note);
                     pragma Unreferenced (Result, Lints, Id);
                  begin
                     null;
                  end;
               exception
                  when others =>
                     Assert (False, Name & " raised on round"
                             & Round'Image);
               end;
            end loop;
         end;
      end loop;
   end Random_Notes_Never_Raise;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Note_Check");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Conforming_Note_Is_Valid'Access, "A conforming note is valid");
      Register_Routine
        (T, Immutable_Fields_Cannot_Change'Access,
         "Immutable fields cannot change");
      Register_Routine
        (T, Field_Diagnostics_Name_The_Field'Access,
         "Field diagnostics name the field");
      Register_Routine
        (T, Min_Length_Counts_Characters'Access,
         "min_length counts characters");
      Register_Routine
        (T, Field_Order_Is_Relative_When_Asked'Access,
         "Field order is relative when asked");
      Register_Routine
        (T, Any_Accepts_A_List_Of_Mappings'Access,
         "any accepts a list of mappings");
      Register_Routine
        (T, A_Note_Needs_Frontmatter'Access, "A note needs frontmatter");
      Register_Routine
        (T, The_H1_Is_Counted_And_Matched'Access,
         "The H1 is counted and matched");
      Register_Routine
        (T, Declared_Sections_Are_Checked'Access,
         "Declared sections are checked");
      Register_Routine
        (T, Declared_Sections_Keep_Their_Relative_Order'Access,
         "Declared sections keep their relative order");
      Register_Routine
        (T, Child_Headings_Follow_Their_Rules'Access,
         "Child headings follow their rules");
      Register_Routine
        (T, A_Backlink_Must_Follow_The_H1'Access,
         "A backlink must follow the H1");
      Register_Routine
        (T, Checklists_Are_Counted_Under_Their_Heading'Access,
         "Checklists are counted under their heading");
      Register_Routine
        (T, Lead_Prose_Comes_Before_The_Checklist'Access,
         "Lead prose comes before the checklist");
      Register_Routine
        (T, Timestamps_Compare_As_Instants'Access,
         "Timestamps compare as instants");
      Register_Routine
        (T, Equality_Of_Two_Missing_Fields_Holds'Access,
         "Equality of two missing fields holds");
      Register_Routine
        (T, Creation_Only_Rules_Skip_Updates'Access,
         "Creation-only rules skip updates");
      Register_Routine
        (T, Vocabularies_Limit_A_Field'Access,
         "Vocabularies limit a field");
      Register_Routine
        (T, A_Failing_Rule_Without_A_Message_Prints_Itself'Access,
         "A failing rule without a message prints itself");
      Register_Routine
        (T, The_First_Failing_Rule_Is_Reported'Access,
         "The first failing rule is reported");
      Register_Routine
        (T, Frontmatter_Problems_Come_Before_Body_And_Rules'Access,
         "Frontmatter problems come before body and rules");
      Register_Routine
        (T, A_Schema_Without_Lints_Lints_Nothing'Access,
         "A schema without lints lints nothing");
      Register_Routine
        (T, A_Wrapped_Paragraph_Is_A_Finding'Access,
         "A wrapped paragraph is a finding");
      Register_Routine
        (T, Severity_Is_Carried_Or_Skips_The_Rule'Access,
         "Severity is carried or skips the rule");
      Register_Routine
        (T, Every_Failing_Lint_Is_Collected'Access,
         "Every failing lint is collected");
      Register_Routine
        (T, Prose_That_Is_Not_Wrapped_Passes_The_Lint'Access,
         "Prose that is not wrapped passes the lint");
      Register_Routine
        (T, A_Title_Starting_With_Its_Id_Fires'Access,
         "A title starting with its id fires");
      Register_Routine
        (T, Schema_Ids_Are_Read_Quoted_Or_Not'Access,
         "Schema ids are read quoted or not");
      Register_Routine
        (T, Shipped_Schemas_Accept_Conforming_Notes'Access,
         "Shipped schemas accept conforming notes");
      Register_Routine
        (T, Random_Notes_Never_Raise'Access, "Random notes never raise");
   end Register_Tests;

end Synapse.Core.Note_Check.Tests;
