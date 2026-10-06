with Ada.Characters.Latin_1;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Interfaces;

package body Synapse.Core.Schema_YAML.Tests is

   use AUnit.Assertions;
   use JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Ada.Characters.Latin_1.LF;
   CR : constant Character := Ada.Characters.Latin_1.CR;
   HT : constant Character := Ada.Characters.Latin_1.HT;

   --  Where the shipped schema documents are, from the test run's directory.
   Schema_Dir : constant String := "../../packages/synapse/schema";

   function Doc (Source : String) return Value is
      R : constant Parse_Result := Parse (Source);
   begin
      if not R.Ok then
         Assert (False, "should parse: " & R.Error'Image & " at line"
                 & R.Line'Image & " in " & Source);
      end if;
      return R.Root;
   end Doc;

   procedure Expect_Fault
     (Source : String; Want : Parse_Fault; Line : Natural := 0)
   is
      R : constant Parse_Result := Parse (Source);
   begin
      if R.Ok then
         Assert (False, "should fail with " & Want'Image & ": " & Source);
      else
         Assert (R.Error = Want,
                 "got " & R.Error'Image & " for " & Source);
         if Line /= 0 then
            Assert (R.Line = Line,
                    Want'Image & " at line" & R.Line'Image
                    & ", wanted" & Line'Image & " in " & Source);
         end if;
      end if;
   end Expect_Fault;

   function Get (V : Value; Path : String) return Value is
      Current : Value := V;
      First   : Positive := Path'First;
   begin
      loop
         declare
            Stop : Natural := First;
         begin
            while Stop <= Path'Last and then Path (Stop) /= '.' loop
               Stop := Stop + 1;
            end loop;
            declare
               Key : constant String := Path (First .. Stop - 1);
            begin
               Assert (Kind_Of (Current) = JSON_Object
                       and then Has_Member (Current, Key),
                       "path " & Path & " breaks at " & Key);
               Current := Member_Value (Current, Key);
            end;
            exit when Stop > Path'Last;
            First := Stop + 1;
         end;
      end loop;
      return Current;
   end Get;

   function Str (V : Value; Path : String) return String
   is (As_String (Get (V, Path)));

   function Merged (Base, Override : Value) return Value is
      R : constant Merge_Result := Merge (Base, Override);
   begin
      if not R.Ok then
         Assert (False, "merge should succeed, got " & R.Error'Image);
      end if;
      return R.Root;
   end Merged;

   procedure Expect_Merge_Fault
     (Base, Override : String; Want : Merge_Fault)
   is
      R : constant Merge_Result := Merge (Doc (Base), Doc (Override));
   begin
      if R.Ok then
         Assert (False, "merge should fail with " & Want'Image);
      else
         Assert (R.Error = Want, "merge gave " & R.Error'Image
                 & ", wanted " & Want'Image);
      end if;
   end Expect_Merge_Fault;

   ---------------------------------------------------------------------------
   --  Parsing: what Zig's tests cover
   ---------------------------------------------------------------------------

   procedure Parses_The_Schema_DSL_Shapes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Root : constant Value :=
        Doc ("schema: synapse-note-schema/v1" & LF
             & "id: vault-note/v1" & LF
             & "frontmatter:" & LF
             & "  fields:" & LF
             & "    title:" & LF
             & "      type: string" & LF
             & "      required: true" & LF
             & "body:" & LF
             & "  sections:" & LF
             & "    - title: Summary" & LF
             & "      level: 2" & LF
             & "checks:" & LF
             & "  - equals: [filename.stem, frontmatter.title] # same title"
             & LF);
      Sections : constant Value := Get (Root, "body.sections");
   begin
      Assert (Str (Root, "schema") = "synapse-note-schema/v1", "a scalar");
      Assert (As_Boolean (Get (Root, "frontmatter.fields.title.required")),
              "a boolean");
      Assert (Kind_Of (Sections) = JSON_Array and then Length (Sections) = 1,
              "a list of one mapping");
      Assert (Str (Element (Sections, 1), "title") = "Summary", "its title");
      Assert (As_Integer (Get (Element (Sections, 1), "level")) = 2,
              "its integer");
      Assert (Length (Get (Root, "checks")) = 1, "checks");
      Assert (Length (Get (Element (Get (Root, "checks"), 1), "equals")) = 2,
              "a flow list, with its comment cut");
   end Parses_The_Schema_DSL_Shapes;

   procedure Refuses_YAML_Outside_The_Subset (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect_Fault ("x: &anchor value" & LF, Anchor_Or_Alias, 1);
      Expect_Fault ("x: !thing value" & LF, Custom_Tag, 1);
      Expect_Fault ("x: |" & LF & "  value: here" & LF, Block_Scalar, 1);
      Expect_Fault ("x: {a: b}" & LF, Flow_Map, 1);
      Expect_Fault ("x: y" & LF & "---" & LF & "z: q" & LF,
                    Multiple_Documents, 2);
      Expect_Fault ("x: yes" & LF, Implicit_Type, 1);
      Expect_Fault ("x:" & LF & HT & "y: z" & LF, Tab_Indent, 2);
   end Refuses_YAML_Outside_The_Subset;

   procedure Duplicate_Keys_Fail_Closed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect_Fault ("x: one" & LF & "x: two" & LF, Duplicate_Key, 2);
      Expect_Fault ("- a: 1" & LF & "  a: 2" & LF, Duplicate_Key);
      Expect_Fault ("m:" & LF & "  k: 1" & LF & "  k: 2" & LF,
                    Duplicate_Key, 3);
   end Duplicate_Keys_Fail_Closed;

   procedure A_Literal_Null_Is_A_Tombstone (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Kind_Of (Get (Doc ("x: null" & LF), "x")) = JSON_Null,
              "null reads as a null value");
      Expect_Fault ("x: Null" & LF, Implicit_Type, 1);
      Expect_Fault ("x: NULL" & LF, Implicit_Type, 1);
      Expect_Fault ("x: ~" & LF, Implicit_Type, 1);
   end A_Literal_Null_Is_A_Tombstone;

   ---------------------------------------------------------------------------
   --  Parsing: faults, scalars, quoting
   ---------------------------------------------------------------------------

   procedure Every_Fault_Names_Its_Line (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Expect_Fault ("", Empty_Document);
      Expect_Fault ("# only a comment" & LF & LF, Empty_Document);
      Expect_Fault (" a: 1" & LF, Invalid_Indent, 1);
      Expect_Fault ("  a: 1" & LF, Unexpected_Indent, 1);
      Expect_Fault ("a: 1" & LF & "    b: 2" & LF, Unexpected_Indent, 2);
      Expect_Fault ("a:" & LF & "b: 1" & LF, Empty_Value, 1);
      Expect_Fault ("a:" & LF, Empty_Value, 1);
      Expect_Fault ("- a" & LF & "b: 1" & LF, Mixed_Collection, 2);
      Expect_Fault ("a: 1" & LF & "- b" & LF, Mixed_Collection, 2);
      Expect_Fault ("a b" & LF, Malformed_Mapping, 1);
      Expect_Fault ("1a: x" & LF, Malformed_Mapping, 1);
      Expect_Fault ("'a': x" & LF, Malformed_Mapping, 1);
      Expect_Fault ("a: *.md" & LF, Anchor_Or_Alias, 1);
      Expect_Fault ("a: x&y" & LF, Anchor_Or_Alias, 1);
      Expect_Fault ("a: [1, 2" & LF, Invalid_Flow_List, 1);
      Expect_Fault ("a: [[1]]" & LF, Invalid_Flow_List, 1);
      Expect_Fault ("a: [1,,2]" & LF, Invalid_Flow_List, 1);
      Expect_Fault ("a: 'x" & LF, Unterminated_String, 1);
      Expect_Fault ("a: ""x" & LF, Unterminated_String, 1);
      Expect_Fault ("a: 'it''s'" & LF, Invalid_Escape, 1);
      Expect_Fault ("a: ""\q""" & LF, Invalid_Escape, 1);
      Expect_Fault ("a: 99999999999999999999" & LF, Invalid_Integer, 1);
      Expect_Fault ("a: 007" & LF, Implicit_Type, 1);
      Expect_Fault ("a: -012" & LF, Implicit_Type, 1);
      Expect_Fault ("x:" & LF & "  - " & LF, Empty_Value);
      Expect_Fault ("a:" & LF & "  b: 1" & LF & "c:" & LF & "d: 2" & LF,
                    Empty_Value, 3);
   end Every_Fault_Names_Its_Line;

   procedure Reads_Scalars (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Root : constant Value :=
        Doc ("t: true" & LF & "f: false" & LF & "n: 0" & LF & "neg: -5" & LF
             & "minus_zero: -0" & LF & "big: 9223372036854775807" & LF
             & "low: -9223372036854775808" & LF & "dash: -" & LF
             & "dec: 1.5" & LF & "word: hello world" & LF
             & "url: http://example.org/x" & LF & "path: designs/a" & LF);
   begin
      Assert
        (As_Boolean (Get (Root, "t"))
         and then not As_Boolean (Get (Root, "f")),
              "booleans");
      Assert (As_Integer (Get (Root, "n")) = 0, "zero");
      Assert (As_Integer (Get (Root, "neg")) = -5, "negative");
      Assert (As_Integer (Get (Root, "minus_zero")) = 0, "-0");
      Assert (As_Integer (Get (Root, "big")) = Long_Long_Integer'Last,
              "the largest integer");
      Assert (As_Integer (Get (Root, "low")) = Long_Long_Integer'First,
              "the smallest");
      Assert (Str (Root, "dash") = "-", "a lone minus is text");
      Assert (Str (Root, "dec") = "1.5", "a decimal is text");
      Assert (Str (Root, "word") = "hello world", "a plain string");
      Assert (Str (Root, "url") = "http://example.org/x",
              "a value may hold colons");
      Assert (Str (Root, "path") = "designs/a", "a slash");
   end Reads_Scalars;

   procedure Reads_Quoted_Strings (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Root : constant Value :=
        Doc ("s: 'single ""quoted"" # not a comment'" & LF
             & "d: ""double " & '\' & """q" & '\' & """ "
             & '\' & "n" & '\' & "t"
             & '\' & '\' & "end""" & LF
             & "glob: ""designs/*""" & LF
             & "empty: ''" & LF
             & "colon: 'a: b'" & LF
             & "bare: a#b" & LF
             & "cut: a #cut" & LF);
   begin
      Assert (Str (Root, "s") = "single ""quoted"" # not a comment",
              "single quotes keep everything, a hash included");
      Assert (Str (Root, "d")
              = "double ""q"" " & LF & HT & '\' & "end",
              "double-quoted escapes");
      Assert (Str (Root, "glob") = "designs/*", "a quoted glob");
      Assert (Str (Root, "empty") = "", "an empty string");
      Assert (Str (Root, "colon") = "a: b", "a quoted colon");
      Assert (Str (Root, "bare") = "a#b", "a hash inside a word");
      Assert (Str (Root, "cut") = "a", "a comment after whitespace");
   end Reads_Quoted_Strings;

   procedure Reads_Flow_Lists (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Root : constant Value :=
        Doc ("a: [x, y, 3, true]" & LF & "b: []" & LF & "c: [ ]" & LF
             & "d: [""a, b"", 'c, d']" & LF & "e: [  spaced ,  out  ]" & LF);
   begin
      Assert (Length (Get (Root, "a")) = 4, "four items");
      Assert (As_String (Element (Get (Root, "a"), 1)) = "x", "a string");
      Assert (As_Integer (Element (Get (Root, "a"), 3)) = 3, "an integer");
      Assert (As_Boolean (Element (Get (Root, "a"), 4)), "a boolean");
      Assert (Length (Get (Root, "b")) = 0, "empty");
      Assert (Length (Get (Root, "c")) = 0, "blank");
      Assert (As_String (Element (Get (Root, "d"), 1)) = "a, b",
              "a comma inside quotes stays");
      Assert (As_String (Element (Get (Root, "e"), 2)) = "out", "trimmed");
   end Reads_Flow_Lists;

   procedure Reads_Lists_And_List_Items (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Root : constant Value :=
        Doc ("items:" & LF
             & "  - plain" & LF
             & "  - name: one" & LF
             & "    level: 2" & LF
             & "  - nested:" & LF
             & "      deep: 1" & LF
             & "    after: 2" & LF
             & "  - http://example.org" & LF
             & "  - ""quoted: text""" & LF
             & "  - [a, b]" & LF
             & "top: 1" & LF);
      Items : constant Value := Get (Root, "items");
   begin
      Assert (Length (Items) = 6, "six items");
      Assert (As_String (Element (Items, 1)) = "plain", "a scalar item");
      Assert (Str (Element (Items, 2), "name") = "one"
              and then As_Integer (Get (Element (Items, 2), "level")) = 2,
              "a mapping item with a second field");
      Assert (As_Integer (Get (Element (Items, 3), "nested.deep")) = 1
              and then As_Integer (Get (Element (Items, 3), "after")) = 2,
              "a nested block under the first key, then another field");
      Assert (Kind_Of (Element (Items, 4)) = JSON_Object
              and then Str (Element (Items, 4), "http") = "//example.org",
              "an unquoted item with a colon reads as a mapping");
      Assert (As_String (Element (Items, 5)) = "quoted: text",
              "a quoted item stays text");
      Assert (Kind_Of (Element (Items, 6)) = JSON_Array, "a flow list item");
      Assert (As_Integer (Get (Root, "top")) = 1, "and the map continues");
   end Reads_Lists_And_List_Items;

   procedure Handles_Layout_And_Line_Endings (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Source : constant String :=
        "# header" & LF & LF & "a: 1  # trailing" & LF
        & "   " & LF & "b:" & LF & "  c: two" & LF & "  # inner" & LF
        & "  d: 3" & LF;
      Crlf   : constant String :=
        "# header" & CR & LF & CR & LF & "a: 1  # trailing" & CR & LF
        & "b:" & CR & LF & "  c: two" & CR & LF & "  d: 3" & CR & LF;
   begin
      Assert (As_Integer (Get (Doc (Source), "a")) = 1, "a comment is cut");
      Assert (Str (Doc (Source), "b.c") = "two"
              and then As_Integer (Get (Doc (Source), "b.d")) = 3,
              "blank and comment lines are skipped");
      Assert (Doc (Crlf) = Doc (Source), "CRLF reads the same as LF");
      Assert (As_Integer (Get (Doc ("a: 1"), "a")) = 1,
              "no final line feed");
   end Handles_Layout_And_Line_Endings;

   procedure Refuses_Bad_Text_And_Deep_Nesting (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      function Nested (Depth : Natural) return String is
         use Ada.Strings.Unbounded;
         Result : Unbounded_String;
      begin
         for I in 0 .. Depth - 1 loop
            Append (Result, String'(1 .. 2 * I => ' ') & "k:" & LF);
         end loop;
         Append (Result, String'(1 .. 2 * Depth => ' ') & "v: 1" & LF);
         return To_String (Result);
      end Nested;
   begin
      Expect_Fault ("a: " & Character'Val (16#FF#) & LF, Invalid_UTF8, 1);
      Expect_Fault ("a: ""x" & Character'Val (16#C3#) & """" & LF,
                    Invalid_UTF8, 1);
      Assert (Schema_YAML.Parse (Nested (Max_Depth - 4)).Ok,
              "deep, but within the limit");
      Expect_Fault (Nested (Max_Depth + 20), Too_Deep);
   end Refuses_Bad_Text_And_Deep_Nesting;

   procedure The_Shipped_Schemas_Parse (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);

      procedure Check (Name : String) is
         Path : constant String := Schema_Dir & "/" & Name & "/v1.yaml";
         File : Ada.Streams.Stream_IO.File_Type;
      begin
         if not Ada.Directories.Exists (Path) then
            Assert (False, Path & " is missing");
            return;
         end if;
         Ada.Streams.Stream_IO.Open
           (File, Ada.Streams.Stream_IO.In_File, Path);
         declare
            Size   : constant Natural :=
              Natural (Ada.Streams.Stream_IO.Size (File));
            Text   : String (1 .. Size);
         begin
            String'Read (Ada.Streams.Stream_IO.Stream (File), Text);
            Ada.Streams.Stream_IO.Close (File);
            declare
               Root : constant Value := Doc (Text);
            begin
               Assert
                 (Has_Member (Root, "schema"),
                  Name & " names its schema");
               Assert (Has_Member (Root, "id"), Name & " has an id");
               Assert
                 (Merged (Root, Root) = Root,
                  Name & " merged with itself");
            end;
         end;
      end Check;
   begin
      Check ("vault-note");
      Check ("vault-task-note");
      Check ("vault-design-note");
      Check ("graph-node");
   end The_Shipped_Schemas_Parse;

   ---------------------------------------------------------------------------
   --  Merge: what Zig's tests cover
   ---------------------------------------------------------------------------

   procedure Merge_Replaces_Adds_And_Keeps (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Result : constant Value :=
        Merged (Doc ("a: one" & LF & "b: two" & LF), Doc ("a: ONE" & LF));
      Added  : constant Value :=
        Merged (Doc ("a: one" & LF), Doc ("b: two" & LF));
   begin
      Assert (Str (Result, "a") = "ONE", "an override's scalar wins");
      Assert (Str (Result, "b") = "two", "an unmentioned key is untouched");
      Assert (Str (Added, "a") = "one" and then Str (Added, "b") = "two",
              "a key only the override declares is added");
   end Merge_Replaces_Adds_And_Keeps;

   procedure A_Null_Deletes_The_Key (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Result : constant Value :=
        Merged (Doc ("a: one" & LF & "b: two" & LF), Doc ("a: null" & LF));
      Absent : constant Value :=
        Merged (Doc ("a: one" & LF), Doc ("z: null" & LF));
   begin
      Assert (not Has_Member (Result, "a"), "the key is gone");
      Assert (Str (Result, "b") = "two", "the other stays");
      Assert (not Has_Member (Absent, "z"),
              "a null for an absent key adds nothing");
   end A_Null_Deletes_The_Key;

   procedure Nested_Maps_Merge_Recursively (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Result : constant Value :=
        Merged
          (Doc ("fields:" & LF & "  title:" & LF & "    type: string" & LF
                & "    required: true" & LF & "  tags:" & LF
                & "    type: list" & LF),
           Doc ("fields:" & LF & "  title:" & LF & "    required: false" & LF
                & "  note_id:" & LF & "    type: string" & LF));
   begin
      Assert (Str (Result, "fields.title.type") = "string",
              "the base's type is kept");
      Assert (not As_Boolean (Get (Result, "fields.title.required")),
              "the override's flag wins");
      Assert
        (Str (Result, "fields.tags.type") = "list",
         "a sibling is untouched");
      Assert (Str (Result, "fields.note_id.type") = "string",
              "a new field is added whole");
   end Nested_Maps_Merge_Recursively;

   procedure A_List_Is_Replaced_Wholesale (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Result : constant Value :=
        Merged (Doc ("lints:" & LF & "  - a: one" & LF & "  - a: two" & LF),
                Doc ("lints:" & LF & "  - a: two" & LF & "  - a: three" & LF));
      Lints  : constant Value := Get (Result, "lints");
   begin
      Assert (Length (Lints) = 2, "two entries");
      Assert (Str (Element (Lints, 1), "a") = "two"
              and then Str (Element (Lints, 2), "a") = "three",
              "omission removes, inclusion adds");
   end A_List_Is_Replaced_Wholesale;

   Patch_Base : constant String :=
     "lints:" & LF
     & "  - no_hard_wrap:" & LF & "      var: body.prose" & LF
     & "    severity: warn" & LF
     & "  - not:" & LF & "      starts_with:" & LF
     & "        - var: frontmatter.title" & LF
     & "        - var: frontmatter.note_id" & LF
     & "    severity: warn" & LF;

   procedure A_Patch_Edits_The_Matched_Entry (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Result : constant Value :=
        Merged
          (Doc (Patch_Base),
           Doc ("lints:" & LF & "  - match:" & LF & "      no_hard_wrap:" & LF
                 & "        var: body.prose" & LF
                 & "    severity: error" & LF));
      Lints  : constant Value := Get (Result, "lints");
   begin
      Assert (Length (Lints) = 2, "still two");
      Assert (Str (Element (Lints, 1), "severity") = "error",
              "the matched entry changed, in place");
      Assert (Str (Element (Lints, 2), "severity") = "warn",
              "its sibling did not");
      Assert (Has_Member (Element (Lints, 1), "no_hard_wrap"),
              "the entry kept its other fields");
   end A_Patch_Edits_The_Matched_Entry;

   procedure A_Patch_Applies_To_Every_Match (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Result : constant Value :=
        Merged
          (Doc ("lints:" & LF & "  - a: one" & LF & "    severity: warn" & LF
                & "  - a: two" & LF & "    severity: warn" & LF
                & "  - a: three" & LF & "    severity: ignore" & LF),
           Doc ("lints:" & LF & "  - match:" & LF & "      severity: warn" & LF
                & "    severity: error" & LF));
      Lints  : constant Value := Get (Result, "lints");
   begin
      Assert (Length (Lints) = 3, "three entries");
      Assert (Str (Element (Lints, 1), "severity") = "error"
              and then Str (Element (Lints, 2), "severity") = "error",
              "both matches changed");
      Assert (Str (Element (Lints, 3), "severity") = "ignore",
              "the non-match did not");
   end A_Patch_Applies_To_Every_Match;

   procedure A_Patch_With_No_Delta_Removes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Result : constant Value :=
        Merged
          (Doc ("lints:" & LF & "  - a: one" & LF & "    severity: warn" & LF),
           Doc ("lints:" & LF & "  - match:" & LF & "      a: one" & LF));
   begin
      Assert (Length (Get (Result, "lints")) = 0, "an empty list is left");
   end A_Patch_With_No_Delta_Removes;

   procedure Patches_Apply_In_Order (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Result : constant Value :=
        Merged
          (Doc ("l:" & LF & "  - a: one" & LF & "    s: warn" & LF
                & "  - a: two" & LF & "    s: warn" & LF),
           Doc ("l:" & LF & "  - match:" & LF & "      a: one" & LF
                & "    s: error" & LF & "  - match:" & LF & "      s: error"
                & LF & "    extra: yes_it_did" & LF));
   begin
      Assert (Str (Element (Get (Result, "l"), 1), "extra") = "yes_it_did",
              "the second patch sees the first one's change");
      Assert (not Has_Member (Element (Get (Result, "l"), 2), "extra"),
              "and only that entry");
   end Patches_Apply_In_Order;

   procedure Patch_Faults_Are_Reported (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      One : constant String :=
        "lints:" & LF & "  - a: one" & LF & "    severity: warn" & LF;
   begin
      Expect_Merge_Fault
        (One,
         "lints:" & LF & "  - match:" & LF & "      a: nope" & LF
         & "    severity: error" & LF,
         Patch_Match_Not_Found);
      Expect_Merge_Fault
        (One,
         "lints:" & LF & "  - match:" & LF & "      a: one" & LF
         & "    severity: error" & LF & "  - a: two" & LF
         & "    severity: warn" & LF,
         Mixed_Patch_List);
      Expect_Merge_Fault
        ("checks: []" & LF,
         "lints:" & LF & "  - match:" & LF & "      a: one" & LF
         & "    severity: error" & LF,
         Patch_On_Non_List);
      Expect_Merge_Fault
        ("lints: scalar" & LF,
         "lints:" & LF & "  - match:" & LF & "      a: one" & LF
         & "    severity: error" & LF,
         Patch_On_Non_List);
      Expect_Merge_Fault
        (One,
         "lints:" & LF & "  - match: not-a-map" & LF & "    severity: error"
         & LF,
         Patch_Match_Not_Map);
   end Patch_Faults_Are_Reported;

   procedure The_Result_Does_Not_Depend_On_Its_Inputs
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Result : Value;
   begin
      declare
         Base     : constant Value :=
           Doc ("a: one" & LF & "b:" & LF & "  c: two" & LF);
         Override : constant Value := Doc ("b:" & LF & "  d: three" & LF);
      begin
         Result := Merged (Base, Override);
      end;
      Assert (Str (Result, "a") = "one", "a base value");
      Assert (Str (Result, "b.c") = "two", "a nested base value");
      Assert (Str (Result, "b.d") = "three", "an override value");
   end The_Result_Does_Not_Depend_On_Its_Inputs;

   ---------------------------------------------------------------------------
   --  Properties
   ---------------------------------------------------------------------------

   Seed : Interfaces.Unsigned_64 := 20_261_012;

   function Next (Limit : Positive) return Natural is
      use type Interfaces.Unsigned_64;
   begin
      Seed := Seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Natural ((Seed / 2**20) mod Interfaces.Unsigned_64 (Limit));
   end Next;

   --  A map of up to four keys; values are scalars, lists without `match`
   --  entries, or further maps. No nulls.
   function Random_Map (Depth : Natural) return Value is
      Fields : Member_Array (1 .. Next (4));
   begin
      for I in Fields'Range loop
         Fields (I).Key :=
           Ada.Strings.Unbounded.To_Unbounded_String
             ("k" & Natural'Image (Next (5)) (2 .. 2));
         case Next (if Depth >= 2 then 4 else 6) is
            when 0 =>
               Fields (I).Item := Make_Integer (Long_Long_Integer (Next (9)));

            when 1 =>
               Fields (I).Item :=
                 Make_String ("s" & Natural'Image (Next (9)) (2 .. 2));

            when 2 =>
               Fields (I).Item := Make_Boolean (Next (2) = 0);

            when 3 =>
               Fields (I).Item :=
                 Make_Array ([Make_Integer (Long_Long_Integer (Next (9))),
                              Make_String ("x")]);

            when others =>
               Fields (I).Item := Random_Map (Depth + 1);
         end case;
      end loop;
      return Make_Object (Fields);
   end Random_Map;

   procedure Merge_Laws_Hold (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Empty : constant Value := Make_Object ([]);
   begin
      for I in 1 .. 2_000 loop
         declare
            Base     : constant Value := Random_Map (0);
            Override : constant Value := Random_Map (0);
            Once     : constant Value := Merged (Base, Override);
         begin
            if Merged (Base, Empty) /= Base then
               Assert
                 (False,
                  "case" & I'Image & ": an empty override changed it");
            end if;
            if Merged (Base, Base) /= Base then
               Assert
                 (False,
                  "case" & I'Image & ": merging with itself changed it");
            end if;
            if Merged (Once, Override) /= Once then
               Assert (False, "case" & I'Image & ": merging twice differs");
            end if;
            for K in 1 .. Length (Base) loop
               declare
                  Key : constant String := Member_Key (Base, K);
               begin
                  if not Has_Member (Once, Key) then
                     Assert (False, "case" & I'Image & ": lost key " & Key);
                  elsif not Has_Member (Override, Key)
                    and then Member_Value (Once, Key) /= Member_At (Base, K)
                  then
                     Assert (False, "case" & I'Image & ": changed key " & Key);
                  end if;
               end;
            end loop;
            for K in 1 .. Length (Override) loop
               declare
                  Key : constant String := Member_Key (Override, K);
                  Mine : constant Value := Member_At (Override, K);
               begin
                  if Kind_Of (Mine) /= JSON_Object
                    and then Member_Value (Once, Key) /= Mine
                  then
                     Assert (False, "case" & I'Image & ": the override lost "
                             & Key);
                  end if;
               end;
            end loop;
         end;
      end loop;
   end Merge_Laws_Hold;

   procedure Random_Text_Never_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Alphabet : constant String :=
        "ab:-[],'#&*!|>{}""\ " & LF & CR & HT & "01 ";
   begin
      for I in 1 .. 20_000 loop
         declare
            Text : String (1 .. Next (50));
         begin
            for C of Text loop
               C := Alphabet (Alphabet'First + Next (Alphabet'Length));
            end loop;
            declare
               R : constant Parse_Result := Parse (Text);
            begin
               if R.Ok then
                  declare
                     M : constant Merge_Result := Merge (R.Root, R.Root);
                     pragma Unreferenced (M);
                  begin
                     null;
                  end;
               end if;
            end;
         exception
            when E : others =>
               Assert (False, "raised " & Ada.Exceptions.Exception_Name (E));
         end;
      end loop;
   end Random_Text_Never_Raises;

   ---------------------------------------------------------------------------

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Schema_YAML");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Parses_The_Schema_DSL_Shapes'Access,
         "Parses the schema DSL shapes");
      Register_Routine
        (T, Refuses_YAML_Outside_The_Subset'Access,
         "Refuses YAML outside the subset");
      Register_Routine
        (T, Duplicate_Keys_Fail_Closed'Access, "Duplicate keys fail closed");
      Register_Routine
        (T, A_Literal_Null_Is_A_Tombstone'Access,
         "A literal null is a tombstone");
      Register_Routine
        (T, Every_Fault_Names_Its_Line'Access, "Every fault names its line");
      Register_Routine (T, Reads_Scalars'Access, "Reads scalars");
      Register_Routine
        (T, Reads_Quoted_Strings'Access, "Reads quoted strings");
      Register_Routine (T, Reads_Flow_Lists'Access, "Reads flow lists");
      Register_Routine
        (T, Reads_Lists_And_List_Items'Access, "Reads lists and list items");
      Register_Routine
        (T, Handles_Layout_And_Line_Endings'Access,
         "Handles layout and line endings");
      Register_Routine
        (T, Refuses_Bad_Text_And_Deep_Nesting'Access,
         "Refuses bad text and deep nesting");
      Register_Routine
        (T, The_Shipped_Schemas_Parse'Access, "The shipped schemas parse");
      Register_Routine
        (T, Merge_Replaces_Adds_And_Keeps'Access,
         "Merge replaces, adds and keeps");
      Register_Routine
        (T, A_Null_Deletes_The_Key'Access, "A null deletes the key");
      Register_Routine
        (T, Nested_Maps_Merge_Recursively'Access,
         "Nested maps merge recursively");
      Register_Routine
        (T, A_List_Is_Replaced_Wholesale'Access,
         "A list is replaced wholesale");
      Register_Routine
        (T, A_Patch_Edits_The_Matched_Entry'Access,
         "A patch edits the matched entry");
      Register_Routine
        (T, A_Patch_Applies_To_Every_Match'Access,
         "A patch applies to every match");
      Register_Routine
        (T, A_Patch_With_No_Delta_Removes'Access,
         "A patch with no delta removes");
      Register_Routine
        (T, Patches_Apply_In_Order'Access, "Patches apply in order");
      Register_Routine
        (T, Patch_Faults_Are_Reported'Access, "Patch faults are reported");
      Register_Routine
        (T, The_Result_Does_Not_Depend_On_Its_Inputs'Access,
         "The result does not depend on its inputs");
      Register_Routine (T, Merge_Laws_Hold'Access, "Merge laws hold");
      Register_Routine
        (T, Random_Text_Never_Raises'Access, "Random text never raises");
   end Register_Tests;

end Synapse.Core.Schema_YAML.Tests;
