with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Interfaces;

with Synapse.Core.UTF8;

package body Synapse.Core.Wikilinks.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   type Scalars is array (Positive range <>) of UTF8.Scalar_Value;

   function U (Items : Scalars) return String is
      Result : Unbounded_String;
   begin
      for CP of Items loop
         Append (Result, UTF8.Encode (CP));
      end loop;
      return To_String (Result);
   end U;

   function Found (Body_Text : String) return String is
      Text : Unbounded_String;
   begin
      for T of Extract (Body_Text) loop
         if Text /= Null_Unbounded_String then
            Append (Text, "|");
         end if;
         Append (Text, T);
      end loop;
      return To_String (Text);
   end Found;

   procedure Extract_Reads_Targets (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Found ("see [[Some Note]] for details") = "Some Note", "bare");
      Assert (Found ("see [[Some Note|a nicer label]] for details")
              = "Some Note", "aliased");
      Assert (Found ("[[  Some Note  ]]") = "Some Note", "trimmed");
      Assert (Found ("[[A]] and [[B|display]] and [[C]]") = "A|B|C",
              "every occurrence, in order");
      Assert (Found ("[[A]] then a broken [[B with no close") = "A",
              "an unterminated link is skipped");
      Assert (Found ("[[]] and [[A]]") = "A", "an empty target");
      Assert (Found ("[[ | alias]] and [[A]]") = "A",
              "an empty target with an alias");
      Assert (Found ("see [[Some Note#A Heading]] for details")
              = "Some Note#A Heading", "the anchor stays");
      Assert (Found ("plain prose, nothing bracketed") = "", "none");
      Assert (Found ("") = "", "empty");
      Assert (Found ("[[") = "", "just an opening pair");
      Assert (Found ("[[A]]") = "A", "only a link");
      Assert (Found ("[[A]][[B]]") = "A|B", "adjacent");
      Assert (Found ("[[a" & LF & "b]]") = "a" & LF & "b", "a line break");
      Assert (Found ("[[ " & LF & "A" & Character'Val (13) & "]]") = "A",
              "line breaks trimmed");
      Assert (Found ("[[A]]]") = "A", "an extra bracket after");
      Assert (Found ("[[[A]]") = "[A", "an extra bracket before");
   end Extract_Reads_Targets;

   procedure Targets_Normalize_To_Titles (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Normalize_Target ("Foo#Heading") = "Foo", "anchor");
      Assert (Normalize_Target ("some/dir/Foo.md#Heading") = "Foo",
              "path, extension and anchor");
      Assert (Normalize_Target ("Foo.md") = "Foo", "extension");
      Assert (Normalize_Target ("some/dir/Foo") = "Foo", "path");
      Assert (Normalize_Target ("some/dir/Foo.md") = "Foo", "both");
      Assert (Normalize_Target ("Foo") = "Foo", "a bare title");
      Assert (Normalize_Target ("") = "", "empty");
      Assert (Normalize_Target (".md") = "", "only an extension");
      Assert (Normalize_Target ("a/") = "", "a trailing slash");
      Assert (Normalize_Target ("Foo.markdown") = "Foo.markdown",
              "not the extension");
      Assert (Normalize_Target ("a#b/c") = "c", "a slash after the anchor");
   end Targets_Normalize_To_Titles;

   procedure Rename (Text, Old_T, New_T, Want, Name : String) is
      Got : constant String := Rename_Target (Text, Old_T, New_T);
   begin
      Assert (Got = Want, Name & ": '" & Got & "'");
   end Rename;

   procedure Renaming_Rewrites_Matching_Links (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Moscow_Upper : constant String :=
        U ([16#41C#, 16#41E#, 16#421#, 16#41A#, 16#412#, 16#410#]);
      Moscow       : constant String :=
        U ([16#41C#, 16#43E#, 16#441#, 16#43A#, 16#432#, 16#430#]);
      Piter        : constant String :=
        U ([16#421#, 16#430#, 16#43D#, 16#43A#, 16#442#, 16#2D#, 16#41F#]);
      Decomposed   : constant String := U ([16#304B#, 16#3099#]);
      Composed     : constant String := U ([16#304C#]);
   begin
      Rename ("see [[Old Name]] here", "Old Name", "New Name",
              "see [[New Name]] here", "bare");
      Rename ("see [[Old Name|a nicer label]] here", "Old Name", "New Name",
              "see [[New Name|a nicer label]] here", "alias");
      Rename ("[[old name]]", "Old Name", "New Name", "[[New Name]]",
              "case-insensitive");
      Rename ("see [[Old Name#Some Heading]] here", "Old Name", "New Name",
              "see [[New Name#Some Heading]] here", "anchor");
      Rename ("[[Old Name#Some Heading|a nicer label]]", "Old Name",
              "New Name", "[[New Name#Some Heading|a nicer label]]",
              "anchor and alias");
      Rename ("[[Something Else]]", "Old Name", "New Name",
              "[[Something Else]]", "not matching");
      Rename ("[[Old Name]] and [[Other]] and [[Old Name|again]]", "Old Name",
              "New Name", "[[New Name]] and [[Other]] and [[New Name|again]]",
              "every occurrence");
      Rename ("[[Old Name]] then [[broken with no close", "Old Name",
              "New Name", "[[New Name]] then [[broken with no close",
              "unterminated");
      Rename ("see [[" & Moscow_Upper & "]] here", Moscow, Piter,
              "see [[" & Piter & "]] here", "non-Latin, any case");
      Rename ("see [[" & Decomposed & "]] here", Composed, "New Name",
              "see [[New Name]] here", "NFC composition");
      Rename ("[[Old Name.md]]", "Old Name", "New Name", "[[New Name]]",
              ".md suffix");
      Rename ("[[tasks/synapse/Old Name.md]]", "Old Name", "New Name",
              "[[New Name]]", "path-qualified");
      Rename ("[[Old Name]]", "tasks/Old Name.md", "New Name",
              "[[New Name]]", "an old target given as a path");
      Rename ("no links at all", "Old Name", "New Name", "no links at all",
              "no links");
      Rename ("", "Old Name", "New Name", "", "empty");
      Rename ("[[]]", "", "New", "[[]]", "an empty target never matches");
      Rename ("[[ Old Name ]]", "Old Name", "N", "[[N]]", "blanks");
   end Renaming_Rewrites_Matching_Links;

   procedure Unlink (Text, Old_T, Want, Name : String) is
      Got : constant String := Unlink_Target (Text, Old_T);
   begin
      Assert (Got = Want, Name & ": '" & Got & "'");
   end Unlink;

   procedure Unlinking_Leaves_Readable_Text (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Unlink ("see [[Old Name]] here", "Old Name", "see Old Name here",
              "the bare title");
      Unlink ("see [[Old Name|a nicer label]] here", "Old Name",
              "see a nicer label here", "the alias");
      Unlink ("[[old name]]", "Old Name", "old name",
              "the case as typed");
      Unlink ("see [[Old Name#Some Heading]] here", "Old Name",
              "see Old Name here", "the anchor is dropped");
      Unlink ("[[Old Name#Some Heading|a nicer label]]", "Old Name",
              "a nicer label", "an anchor and an alias");
      Unlink ("[[Something Else]]", "Old Name", "[[Something Else]]",
              "not matching");
      Unlink ("[[Old Name]] and [[Other]] and [[Old Name|again]]", "Old Name",
              "Old Name and [[Other]] and again", "every occurrence");
      Unlink ("[[Old Name]] then [[broken with no close", "Old Name",
              "Old Name then [[broken with no close", "unterminated");
      Unlink ("[[Old Name.md]]", "Old Name", "Old Name", ".md");
      Unlink ("[[tasks/synapse/Old Name.md]]", "Old Name", "Old Name",
              "path-qualified");
      Unlink ("[[Old Name|  spaced  ]]", "Old Name", "spaced",
              "the alias is trimmed");
   end Unlinking_Leaves_Readable_Text;

   procedure Titles_Come_From_Paths (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Title_Of ("tasks/synapse/Foo.md") = "Foo", "nested");
      Assert (Title_Of ("Foo.md") = "Foo", "bare");
      Assert (Title_Of ("Foo") = "Foo", "no extension");
      Assert (Title_Of ("a/b/Foo.txt") = "Foo.txt", "another extension");
      Assert (Title_Of ("a.b.md") = "a.b", "inner dot");
      Assert (Title_Of ("") = "", "empty");
   end Titles_Come_From_Paths;

   procedure A_Moved_Notes_Title_And_Heading_Follow_Its_Name
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Note : constant String :=
        "---" & LF & "title: Old" & LF & "tags: []" & LF & "---" & LF & "# Old"
        & LF & LF & "text" & LF;
   begin
      Assert (Sync_Title_And_Heading (Note, "Old", "New")
              = "---" & LF & "title: New" & LF & "tags: []" & LF & "---" & LF
                & "# New" & LF & LF & "text" & LF, "both follow");
      Assert (Sync_Title_And_Heading
                ("# Old" & LF & "text" & LF, "Old", "New")
              = "# New" & LF & "text" & LF,
              "no frontmatter: only the heading");
      Assert (Sync_Title_And_Heading
                ("---" & LF & "title: Old" & LF & "---" & LF & "# Diverged"
                 & LF, "Old", "New")
              = "---" & LF & "title: New" & LF & "---" & LF & "# Diverged"
                & LF, "a diverged heading is left alone");
      Assert (Sync_Title_And_Heading
                ("---" & LF & "title: Old" & LF & "---" & LF & "text" & LF,
                 "Old", "New")
              = "---" & LF & "title: New" & LF & "---" & LF & "text" & LF,
              "no heading");
      Assert (Sync_Title_And_Heading
                ("# Old" & LF & "## Old" & LF & "# Old" & LF, "Old", "New")
              = "# New" & LF & "## Old" & LF & "# Old" & LF,
              "only the first H1");
      Assert (Sync_Title_And_Heading
                ("---" & LF & "title: Old" & LF & "---" & LF, "Old", "A: b")
              = "---" & LF & "title: ""A: b""" & LF & "---" & LF,
              "a title that needs quotes");
      Assert (Sync_Title_And_Heading ("# Old", "Old", "New") = "# New",
              "no final line break");
      Assert (Sync_Title_And_Heading ("", "Old", "New") = "", "empty");
      Assert (Sync_Title_And_Heading
                ("# Old" & Character'Val (13) & LF, "Old", "New")
              = "# Old" & Character'Val (13) & LF,
              "a carriage return makes it another heading");
   end A_Moved_Notes_Title_And_Heading_Follow_Its_Name;

   procedure Random_Text_Never_Raises (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      State : Interfaces.Unsigned_64 := 16#2B99_2DDF_A232_9781#;

      function Next (Bound : Positive) return Natural is
      begin
         State :=
           State * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
         return
           Natural ((State / 65_536) mod Interfaces.Unsigned_64 (Bound));
      end Next;

      function Piece (N : Natural) return String
      is (case N is
            when 0 => "[[",
            when 1 => "]]",
            when 2 => "|",
            when 3 => "#",
            when 4 => "Old",
            when 5 => "New Name",
            when 6 => ".md",
            when 7 => "/",
            when 8 => " ",
            when 9 => LF & "",
            when 10 => "[",
            when others => "]");
   begin
      for Round in 1 .. 4_000 loop
         declare
            Text : Unbounded_String;
         begin
            for K in 1 .. Next (14) loop
               Append (Text, Piece (Next (12)));
            end loop;
            declare
               Source  : constant String := To_String (Text);
               Targets : constant Text_Lists.Vector := Extract (Source);
               Renamed : constant String := Rename_Target (Source, "Old", "N");
               Gone    : constant String := Unlink_Target (Source, "Old");
               pragma Unreferenced (Targets, Renamed, Gone);
            begin
               null;
            end;
         exception
            when others =>
               Assert (False, "raised on round" & Round'Image);
         end;
      end loop;
   end Random_Text_Never_Raises;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Wikilinks");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Extract_Reads_Targets'Access, "Extract reads targets");
      Register_Routine
        (T, Targets_Normalize_To_Titles'Access,
         "Targets normalize to titles");
      Register_Routine
        (T, Renaming_Rewrites_Matching_Links'Access,
         "Renaming rewrites matching links");
      Register_Routine
        (T, Unlinking_Leaves_Readable_Text'Access,
         "Unlinking leaves readable text");
      Register_Routine
        (T, Titles_Come_From_Paths'Access, "Titles come from paths");
      Register_Routine
        (T, A_Moved_Notes_Title_And_Heading_Follow_Its_Name'Access,
         "A moved note's title and heading follow its name");
      Register_Routine
        (T, Random_Text_Never_Raises'Access, "Random text never raises");
   end Register_Tests;

end Synapse.Core.Wikilinks.Tests;
