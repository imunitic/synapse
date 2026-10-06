with AUnit.Assertions;

with Synapse.Adapters.Fake_Repo_Reader;

package body Synapse.Core.Namespace.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package Fake renames Adapters.Fake_Repo_Reader;

   LF : constant Character := Character'Val (10);

   function Term (Text : String) return Maybe_Text is
     (Found => True, Text => To_Unbounded_String (Text));

   No_Term : constant Maybe_Text := (Found => False);

   function Shown (Value : Maybe_Text) return String is
     (if Value.Found then "<" & To_String (Value.Text) & ">" else "none");

   function Field
     (Content, Prefix : String; Terminator : Maybe_Text := No_Term)
      return String is
     (Shown (Extract_Field (Content, Prefix, Terminator)));

   procedure Extract_Field_Takes_A_Prefix_To_A_Terminator
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Field ("package com.example.billing;" & LF, "package ", Term (";")) =
         "<com.example.billing>",
         "prefix to terminator, trimmed");
      Assert
        (Field
           ("module github.com/acme/widget" & LF & LF & "go 1.22" & LF,
            "module ") =
         "<github.com/acme/widget>",
         "no terminator means to the end of the line");
      Assert
        (Field ("  (name widget)" & LF, "(name ", Term (")")) = "<widget>",
         "leading blanks before the prefix are skipped");
      Assert
        (Field
           ("package first;" & LF & "// package second;" & LF, "package ",
            Term (";")) =
         "<first>",
         "the first qualifying line, not a later one");
      Assert
        (Field ("class Foo {}" & LF, "package ", Term (";")) = "none",
         "a prefix that never appears");
      Assert
        (Field
           ("package com.example" & LF & "package real;" & LF, "package ",
            Term (";")) =
         "<real>",
         "an unterminated line is skipped, not truncated");
      Assert
        (Field ("package ;" & LF, "package ", Term (";")) = "none",
         "a blank value is none, not empty");
      Assert
        (Field ("name widget" & Character'Val (13) & LF, "name ") = "<widget>",
         "a carriage return is not part of the value");
      Assert (Field ("", "name ") = "none", "empty content");
      Assert
        (Field ("tab" & Character'Val (9) & "x" & LF, "tab") = "<x>",
         "tabs trim like blanks");
   end Extract_Field_Takes_A_Prefix_To_A_Terminator;

   procedure A_Block_Comment_Does_Not_Smuggle_In_A_Declaration
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Field
           ("/*" & LF & "package com.example.old;" & LF & "*/" & LF &
            "package real;" & LF,
            "package ", Term (";")) =
         "<real>",
         "a multi-line block comment");
      Assert
        (Field
           ("/* package com.example.old; */" & LF & "package real;" & LF,
            "package ", Term (";")) =
         "<real>",
         "a single-line one");
      Assert
        (Field
           ("/*" & LF & "package com.example.old;" & LF & "*/" & LF &
            "class Foo {}" & LF,
            "package ", Term (";")) =
         "none",
         "nothing real after the comment");
      Assert
        (Field
           ("/*" & LF & "filler" & LF & "package hidden;" & LF & "*/" & LF &
            "package real;" & LF,
            "package ", Term (";")) =
         "<real>",
         "a declaration deep inside a multi-line comment");
      Assert
        (Field
           ("code /* open" & LF & "package hidden;" & LF & "close */" & LF &
            "package real;" & LF,
            "package ", Term (";")) =
         "<real>",
         "a comment that starts after code on its line");
   end A_Block_Comment_Does_Not_Smuggle_In_A_Declaration;

   procedure Dir_Of_And_Base_Of_Split_On_The_Last_Slash
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Dir_Of ("src/core/vocab.wdg") = "src/core", "directory");
      Assert (Base_Of ("src/core/vocab.wdg") = "vocab.wdg", "file");
      Assert
        (Dir_Of ("README.md") = ""
         and then Base_Of ("README.md") = "README.md",
         "at the root");
      Assert (Dir_Of ("a\b/c") = "a\b", "only a slash splits");
      Assert
        (Base_Of ("dir/") = "" and then Dir_Of ("dir/") = "dir",
         "a trailing slash");
   end Dir_Of_And_Base_Of_Split_On_The_Last_Slash;

   procedure Nearest_Namespace_Walks_Up_To_The_Closest_Ancestor
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      By_Dir : Dir_Maps.Map;
   begin
      By_Dir.Include ("", "root_lib");
      By_Dir.Include ("widget/src", "widget");
      Assert
        (Shown (Nearest_Namespace (By_Dir, "widget/src")) = "<widget>",
         "an exact match wins over a farther ancestor");
      Assert
        (Shown (Nearest_Namespace (By_Dir, "widget/src/nested/deep")) =
         "<widget>",
         "walks up past directories with no build file");
      Assert
        (Shown (Nearest_Namespace (By_Dir, "other")) = "<root_lib>",
         "up to the root");
      By_Dir.Delete ("");
      Assert
        (Shown (Nearest_Namespace (By_Dir, "other/crate")) = "none",
         "no ancestor recorded anything");
   end Nearest_Namespace_Walks_Up_To_The_Closest_Ancestor;

   function Reg (Text : String) return Registry is (Parse (Text));

   procedure An_Empty_Registry_Has_No_Rule (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Empty : constant Registry := Parse ("{}");
   begin
      Assert (Is_Empty (Empty), "empty");
      Assert (not Rule_For_Path (Empty, "a/b.xx").Found, "no rule");
      Assert (Is_Empty (Parse ("[]")), "an array is an empty registry");
   end An_Empty_Registry_Has_No_Rule;

   procedure An_In_File_Rule_Round_Trips_Every_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R     : constant Registry   :=
        Reg
          ("{""xx"": {""kind"": ""in-file"", ""prefix"": ""package ""," &
           " ""terminator"": "";""}}");
      Found : constant Maybe_Rule := Rule_For_Path (R, "src/a.xx");
   begin
      Assert (Found.Found and then Found.Value.Which = In_File, "in file");
      Assert (To_String (Found.Value.Prefix) = "package ", "prefix");
      Assert (Shown (Found.Value.Terminator) = "<;>", "terminator");
      Assert (not Found.Value.File.Found, "no file");
   end An_In_File_Rule_Round_Trips_Every_Field;

   procedure A_Build_File_Rule_Needs_Its_File (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R     : constant Registry   :=
        Reg
          ("{""yy"": {""kind"": ""build-file"", ""file"": ""manifest.yy""," &
           " ""prefix"": ""module ""}," &
           " ""zz"": {""kind"": ""build-file"", ""prefix"": ""module ""}}");
      Found : constant Maybe_Rule := Rule_For_Path (R, "a.yy");
   begin
      Assert
        (Found.Found and then Found.Value.Which = Build_File, "build file");
      Assert (Shown (Found.Value.File) = "<manifest.yy>", "its file");
      Assert (not Found.Value.Terminator.Found, "to the end of the line");
      Assert
        (not Rule_For_Path (R, "a.zz").Found,
         "a build-file rule with no file is not a rule");
   end A_Build_File_Rule_Needs_Its_File;

   procedure What_Is_Not_A_Rule_Is_Left_Out_And_The_Rest_Apply
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : constant Registry :=
        Reg
          ("{""a"": {""kind"": ""other"", ""prefix"": ""x""}," &
           " ""b"": {""kind"": ""in-file"", ""prefix"": """"}," &
           " ""c"": {""kind"": ""in-file""}," & " ""d"": ""text""," &
           " ""e"": {""kind"": 3, ""prefix"": ""x""}," &
           " ""f"": {""kind"": ""in-file"", ""prefix"": ""p""," &
           " ""terminator"": """"}}");
   begin
      Assert (Natural (R.Rules.Length) = 1, "only the last is a rule");
      Assert
        (not Rule_For_Path (R, "x.f").Value.Terminator.Found,
         "an empty terminator means none");
   end What_Is_Not_A_Rule_Is_Left_Out_And_The_Rest_Apply;

   procedure A_Dependency_Rule_Takes_The_Whole_Span
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R     : constant Registry   :=
        Reg
          ("{""xx"": {""kind"": ""build-file"", ""file"": ""build.deps""," &
           " ""prefix"": ""depends "", ""terminator"": "")""}}");
      Found : constant Maybe_Rule := Rule_For_Path (R, "a.xx");
   begin
      Assert
        (Field
           ("depends widget str)" & LF, To_String (Found.Value.Prefix),
            Found.Value.Terminator) =
         "<widget str>",
         "a list is one span, split by the caller");
   end A_Dependency_Rule_Takes_The_Whole_Span;

   procedure Lookup_Is_By_The_Last_Extension_And_Hidden_Files_Have_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : constant Registry :=
        Reg ("{""xx"": {""kind"": ""in-file"", ""prefix"": ""p""}}");
   begin
      Assert (Rule_For_Path (R, "src/a.xx").Found, "an extension");
      Assert (Rule_For_Path (R, "src/a.b.xx").Found, "the last one");
      Assert (not Rule_For_Path (R, "src/a.xx.yy").Found, "not the first");
      Assert (not Rule_For_Path (R, "src/.xx").Found, "a hidden file");
      Assert (not Rule_For_Path (R, "src/a").Found, "no extension");
      Assert
        (not Rule_For_Path (R, "dir.xx/a").Found, "a dot in a directory name");
      Assert (not Rule_For_Path (R, "zz").Found, "an unregistered one");
      Assert (not Is_Empty (R), "and the registry is not empty because of it");
   end Lookup_Is_By_The_Last_Extension_And_Hidden_Files_Have_None;

   procedure Aliases_Are_Parsed_And_Skipped_When_Empty
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R     : constant Registry   :=
        Reg
          ("{""xx"": {""kind"": ""in-file"", ""prefix"": ""name ""," &
           " ""aliases"": [{""prefix"": ""public ""}, {""prefix"": """"}," &
           " ""text"", {""terminator"": "";""}," &
           " {""prefix"": ""x "", ""terminator"": "";""}]}}");
      Found : constant Maybe_Rule := Rule_For_Path (R, "a.xx");
   begin
      Assert (Natural (Found.Value.Aliases.Length) = 2, "two good aliases");
      Assert
        (To_String (Found.Value.Aliases (1).Prefix) = "public "
         and then not Found.Value.Aliases (1).Terminator.Found,
         "the first");
      Assert
        (Shown (Found.Value.Aliases (2).Terminator) = "<;>", "the second");
   end Aliases_Are_Parsed_And_Skipped_When_Empty;

   procedure A_Registry_That_Is_Not_Json_Is_Malformed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      begin
         declare
            Ignore : constant Registry := Parse ("not json");
         begin
            null;
         end;
      exception
         when Malformed =>
            Raised := True;
      end;
      Assert (Raised, "a load error");
   end A_Registry_That_Is_Not_Json_Is_Malformed;

   function Kept_Of (A, B, C : String := "") return Text_Lists.Vector is
      Result : Text_Lists.Vector;

      procedure Add (Path : String) is
      begin
         if Path /= "" then
            Result.Append (To_Unbounded_String (Path));
         end if;
      end Add;
   begin
      Add (A);
      Add (B);
      Add (C);
      return Result;
   end Kept_Of;

   function Rows (V : Row_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for Item of V loop
         Append (Result, Item.Path & "=" & Item.Namespace & ";");
      end loop;
      return To_String (Result);
   end Rows;

   procedure A_Build_File_Rule_Resolves_Files_To_The_Nearest_Ancestors_Value
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
   begin
      Disk.Put ("widget/src/build.deps", "name widget" & LF);
      Disk.Put ("widget/src/main.xx", "run" & LF);
      Assert
        (Rows
           (Compute_Per_File
              (Disk, Kept_Of ("widget/src/build.deps", "widget/src/main.xx"),
               Reg
                 ("{""xx"": {""kind"": ""build-file""," &
                  " ""file"": ""build.deps""," &
                  " ""prefix"": ""name ""}}"))) =
         "widget/src/main.xx=widget;",
         "the nearest build file's value");
   end A_Build_File_Rule_Resolves_Files_To_The_Nearest_Ancestors_Value;

   procedure Two_Rules_Sharing_A_Build_File_Extract_Independently
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
   begin
      Disk.Put
        ("widget/src/build.deps", "name widget" & LF & "other gadget" & LF);
      Disk.Put ("widget/src/main.xx", "run" & LF);
      Disk.Put ("widget/src/main.yy", "run" & LF);
      Assert
        (Rows
           (Compute_Per_File
              (Disk,
               Kept_Of
                 ("widget/src/build.deps", "widget/src/main.xx",
                  "widget/src/main.yy"),
               Reg
                 ("{""xx"": {""kind"": ""build-file""," &
                  " ""file"": ""build.deps""," & " ""prefix"": ""name ""}," &
                  " ""yy"": {""kind"": ""build-file""," &
                  " ""file"": ""build.deps""," &
                  " ""prefix"": ""other ""}}"))) =
         "widget/src/main.xx=widget;widget/src/main.yy=gadget;",
         "each reads its own prefix, not the first one's memoized map");
   end Two_Rules_Sharing_A_Build_File_Extract_Independently;

   procedure An_Empty_Registry_Reads_No_File (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
   begin
      Assert
        (Compute_Per_File (Disk, Kept_Of ("widget/src/main.xx"), Parse ("{}"))
           .Is_Empty,
         "no rows");
      Assert (Disk.Reads = 0, "and no file was touched");
   end An_Empty_Registry_Reads_No_File;

   procedure An_In_File_Rule_Reads_The_File_Itself
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
   begin
      Disk.Put ("pkg/main.yy", "package pkg.widget" & LF);
      Assert
        (Rows
           (Compute_Per_File
              (Disk, Kept_Of ("pkg/main.yy"),
               Reg
                 ("{""yy"": {""kind"": ""in-file""," &
                  " ""prefix"": ""package ""}}"))) =
         "pkg/main.yy=pkg.widget;",
         "no ancestor search");
      Assert
        (Compute_Per_File
           (Disk, Kept_Of ("pkg/missing.yy"),
            Reg
              ("{""yy"": {""kind"": ""in-file""," &
               " ""prefix"": ""package ""}}"))
           .Is_Empty,
         "a file that cannot be read has no row");
   end An_In_File_Rule_Reads_The_File_Itself;

   procedure Aliases_Add_Identities_From_The_Same_Build_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Disk  : Fake.Reader;
      Rules : constant Registry :=
        Reg
          ("{""xx"": {""kind"": ""build-file"", ""file"": ""build.deps""," &
           " ""prefix"": ""name ""," &
           " ""aliases"": [{""prefix"": ""public ""}]}}");
   begin
      Disk.Put
        ("widget/src/build.deps",
         "name widget" & LF & "public widget-pub" & LF);
      Disk.Put ("widget/src/main.xx", "run" & LF);
      Assert
        (Rows
           (Compute_Per_File
              (Disk, Kept_Of ("widget/src/build.deps", "widget/src/main.xx"),
               Rules)) =
         "widget/src/main.xx=widget;widget/src/main.xx=widget-pub;",
         "ascending within a path");
      Disk.Put ("widget/src/build.deps", "name widget" & LF);
      Assert
        (Rows
           (Compute_Per_File
              (Disk, Kept_Of ("widget/src/build.deps", "widget/src/main.xx"),
               Rules)) =
         "widget/src/main.xx=widget;",
         "an alias with no match contributes nothing");
   end Aliases_Add_Identities_From_The_Same_Build_File;

   procedure Rows_Are_Sorted_By_Path_Then_Namespace
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
   begin
      Disk.Put ("b/main.yy", "package zeta" & LF);
      Disk.Put ("a/main.yy", "package alpha" & LF);
      Assert
        (Rows
           (Compute_Per_File
              (Disk, Kept_Of ("b/main.yy", "a/main.yy"),
               Reg
                 ("{""yy"": {""kind"": ""in-file""," &
                  " ""prefix"": ""package ""}}"))) =
         "a/main.yy=alpha;b/main.yy=zeta;",
         "path ascending");
   end Rows_Are_Sorted_By_Path_Then_Namespace;

   procedure A_Build_File_Is_Read_Once_For_Many_Files
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Disk : Fake.Reader;
      Kept : Text_Lists.Vector := Kept_Of ("lib/build.deps");
   begin
      Disk.Put ("lib/build.deps", "name lib" & LF);
      for I in 1 .. 20 loop
         declare
            Image : constant String := Integer'Image (I);
            Path  : constant String :=
              "lib/f" & Image (Image'First + 1 .. Image'Last) & ".xx";
         begin
            Disk.Put (Path, "x");
            Kept.Append (To_Unbounded_String (Path));
         end;
      end loop;
      Assert
        (Natural
           (Compute_Per_File
              (Disk, Kept,
               Reg
                 ("{""xx"": {""kind"": ""build-file""," &
                  " ""file"": ""build.deps""," & " ""prefix"": ""name ""}}"))
              .Length) =
         20,
         "all twenty files resolve");
      Assert (Disk.Reads = 1, "from one read of the build file");
   end A_Build_File_Is_Read_Once_For_Many_Files;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Namespace");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Extract_Field_Takes_A_Prefix_To_A_Terminator'Access,
         "Extract_Field takes a prefix to a terminator");
      Register_Routine
        (T, A_Block_Comment_Does_Not_Smuggle_In_A_Declaration'Access,
         "A block comment does not smuggle in a declaration");
      Register_Routine
        (T, Dir_Of_And_Base_Of_Split_On_The_Last_Slash'Access,
         "Dir_Of and Base_Of split on the last slash");
      Register_Routine
        (T, Nearest_Namespace_Walks_Up_To_The_Closest_Ancestor'Access,
         "Nearest_Namespace walks up to the closest ancestor");
      Register_Routine
        (T, An_Empty_Registry_Has_No_Rule'Access,
         "An empty registry has no rule");
      Register_Routine
        (T, An_In_File_Rule_Round_Trips_Every_Field'Access,
         "An in-file rule round-trips every field");
      Register_Routine
        (T, A_Build_File_Rule_Needs_Its_File'Access,
         "A build-file rule needs its file");
      Register_Routine
        (T, What_Is_Not_A_Rule_Is_Left_Out_And_The_Rest_Apply'Access,
         "What is not a rule is left out and the rest apply");
      Register_Routine
        (T, A_Dependency_Rule_Takes_The_Whole_Span'Access,
         "A dependency rule takes the whole span");
      Register_Routine
        (T, Lookup_Is_By_The_Last_Extension_And_Hidden_Files_Have_None'Access,
         "Lookup is by the last extension and hidden files have none");
      Register_Routine
        (T, Aliases_Are_Parsed_And_Skipped_When_Empty'Access,
         "Aliases are parsed and skipped when empty");
      Register_Routine
        (T, A_Registry_That_Is_Not_Json_Is_Malformed'Access,
         "A registry that is not JSON is malformed");
      Register_Routine
        (T,
         A_Build_File_Rule_Resolves_Files_To_The_Nearest_Ancestors_Value'
           Access,
         "A build-file rule resolves files to the nearest ancestor's value");
      Register_Routine
        (T, Two_Rules_Sharing_A_Build_File_Extract_Independently'Access,
         "Two rules sharing a build file extract independently");
      Register_Routine
        (T, An_Empty_Registry_Reads_No_File'Access,
         "An empty registry reads no file");
      Register_Routine
        (T, An_In_File_Rule_Reads_The_File_Itself'Access,
         "An in-file rule reads the file itself");
      Register_Routine
        (T, Aliases_Add_Identities_From_The_Same_Build_File'Access,
         "Aliases add identities from the same build file");
      Register_Routine
        (T, Rows_Are_Sorted_By_Path_Then_Namespace'Access,
         "Rows are sorted by path then namespace");
      Register_Routine
        (T, A_Build_File_Is_Read_Once_For_Many_Files'Access,
         "A build file is read once for many files");
   end Register_Tests;

end Synapse.Core.Namespace.Tests;
