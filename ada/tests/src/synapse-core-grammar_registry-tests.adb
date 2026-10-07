with AUnit.Assertions;

package body Synapse.Core.Grammar_Registry.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Text_Of (M : Maybe_Text) return String is
     (if M.Found then To_String (M.Value) else "<none>");

   Sample : constant String :=
     "{""alpha"":{""repo"":""https://host/tree-sitter-alpha""," &
     """scope"":""source.alpha""}," & """beta"":{""unsupported"":true}," &
     """broken"":{""repo"":""https://host/y""}}";

   procedure Ready_Unsupported_And_Absent_Are_Three_Answers
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : constant Registry := Parse (Sample);
   begin
      Assert
        (Lookup (R, "alpha").Kind = Ready
         and then To_String (Lookup (R, "alpha").Scope) = "source.alpha",
         "ready, with its scope");
      Assert (Lookup (R, "beta").Kind = Unusable, "marked unsupported");
      Assert
        (Lookup (R, "broken").Kind = Unusable, "a repository and no scope");
      Assert (Lookup (R, "gamma").Kind = No_Entry, "not registered");
   end Ready_Unsupported_And_Absent_Are_Three_Answers;

   procedure An_Entry_That_Is_Malformed_Is_Unusable_Not_Absent
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : constant Registry :=
        Parse
          ("{""a"":5,""b"":{""repo"":""r"",""scope"":3}," &
           """c"":{""repo"":"""",""scope"":""s""}," &
           """d"":{""repo"":""r"",""scope"":""""}," &
           """e"":{""repo"":""r"",""scope"":""s"",""unsupported"":false}," &
           """f"":{""repo"":""r"",""scope"":""s"",""unsupported"":""yes""}," &
           """g"":{""repo"":5,""scope"":""s""}}");
   begin
      Assert (Lookup (R, "a").Kind = Unusable, "not an object");
      Assert (Lookup (R, "b").Kind = Unusable, "scope is not a string");
      Assert (Lookup (R, "c").Kind = Unusable, "empty repository");
      Assert (Lookup (R, "d").Kind = Unusable, "empty scope");
      Assert (Lookup (R, "e").Kind = Ready, "unsupported false is usable");
      Assert
        (Lookup (R, "f").Kind = Ready,
         "unsupported only counts when it is the boolean true");
      Assert (Lookup (R, "g").Kind = Unusable, "repository is not a string");
   end An_Entry_That_Is_Malformed_Is_Unusable_Not_Absent;

   procedure Anything_But_An_Object_Has_No_Entry (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Lookup (Parse ("[]"), "alpha").Kind = No_Entry, "an array");
      Assert (Lookup (Parse ("3"), "alpha").Kind = No_Entry, "a number");
      Assert (Lookup (Parse ("{}"), "alpha").Kind = No_Entry, "empty");
   end Anything_But_An_Object_Has_No_Entry;

   procedure Text_That_Is_Not_Json_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Raised : Boolean := False;
   begin
      declare
         Ignore : constant Registry := Parse ("{""a"":");
      begin
         null;
      end;
   exception
      when Malformed =>
         Raised := True;
         Assert (Raised, "malformed");
   end Text_That_Is_Not_Json_Is_Refused;

   procedure The_Queries_Field_Absent_Means_Tags_And_Known_Values_Parse
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : constant Registry :=
        Parse
          ("{""a"":{""repo"":""r"",""scope"":""s""}," &
           """b"":{""repo"":""r"",""scope"":""s"",""queries"":""locals""}," &
           """c"":{""repo"":""r"",""scope"":""s"",""queries"":""generated""}," &
           """d"":{""repo"":""r"",""scope"":""s"",""queries"":""typo""}," &
           """e"":{""repo"":""r"",""scope"":""s"",""queries"":42}}");
   begin
      Assert (Lookup (R, "a").Source = Tags, "absent");
      Assert (Lookup (R, "b").Source = Locals, "locals");
      Assert (Lookup (R, "c").Source = Generated, "generated");
      Assert (Lookup (R, "d").Source = Tags, "unrecognised falls back");
      Assert (Lookup (R, "e").Source = Tags, "wrong type falls back");
      Assert (Source_Of (R, "c") = Generated, "Source_Of agrees");
      Assert (Source_Of (R, "nope") = Tags, "no entry");
   end The_Queries_Field_Absent_Means_Tags_And_Known_Values_Parse;

   procedure Path_And_Symbol_Are_Optional_And_Absent_Means_Derive
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      R : constant Registry :=
        Parse
          ("{""a"":{""repo"":""https://host/tree-sitter-alpha""," &
           """scope"":""source.alpha""}," &
           """b"":{""repo"":""https://host/tree-sitter-multi""," &
           """scope"":""source.b"",""path"":""grammars/b""}," &
           """c"":{""repo"":""https://host/tree-sitter-multi""," &
           """scope"":""source.c"",""path"":""grammars/c""," &
           """symbol"":""tree_sitter_multi_c""}," &
           """empty"":{""repo"":""r"",""scope"":""s"",""path"":""""," &
           """symbol"":""""}}");
   begin
      Assert
        (not Path_For (R, "a").Found and then not Symbol_For (R, "a").Found,
         "neither");
      Assert
        (Text_Of (Path_For (R, "b")) = "grammars/b"
         and then not Symbol_For (R, "b").Found,
         "a path to a grammar");
      Assert
        (Text_Of (Path_For (R, "c")) = "grammars/c"
         and then Text_Of (Symbol_For (R, "c")) = "tree_sitter_multi_c",
         "and a symbol");
      Assert
        (not Path_For (R, "empty").Found
         and then not Symbol_For (R, "empty").Found,
         "an empty string is not a value");
      Assert (not Path_For (R, "nope").Found, "no entry");
      Assert
        (Text_Of (Repo_For (R, "b")) = "https://host/tree-sitter-multi",
         "the repository");
      Assert (not Repo_For (R, "nope").Found, "no entry, no repository");
      Assert
        (Text_Of
           (Repo_For
              (Parse ("{""e"":{""repo"":"""",""scope"":""s""}}"), "e")) =
         "",
         "an empty repository is returned as it is: Lookup refuses it");
   end Path_And_Symbol_Are_Optional_And_Absent_Means_Derive;

   procedure An_Extension_Is_Lowercased_And_A_Dotless_Name_Has_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Extension_Of ("src/Main.EXT") = "ext", "lowercased");
      Assert (Extension_Of ("Makefile") = "", "no dot");
      Assert (Extension_Of ("dir.d/README") = "", "a directory's dot");
      Assert (Extension_Of (".gitignore") = "gitignore", "a leading dot");
      Assert (Extension_Of ("weird.") = "", "a trailing dot");
      Assert (Extension_Of ("a.tar.gz") = "gz", "the last dot");
      Assert (Extension_Of ("") = "", "empty");
   end An_Extension_Is_Lowercased_And_A_Dotless_Name_Has_None;

   procedure A_Symbol_Is_Derived_From_The_Repository_Name
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Symbol_For ("tree-sitter-alpha") = "tree_sitter_alpha", "prefix");
      Assert
        (Symbol_For ("tree-sitter-embedded-thing") =
         "tree_sitter_embedded_thing",
         "dashes");
      Assert (Symbol_For ("widget") = "tree_sitter_widget", "no prefix");
      Assert (Symbol_For ("tree-sitter-") = "tree_sitter_", "nothing after");
      Assert
        (Symbol_For ("tree-sitt") = "tree_sitter_tree_sitt",
         "a prefix cut short");
   end A_Symbol_Is_Derived_From_The_Repository_Name;

   procedure A_Repository_Name_Comes_Off_A_Url (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Repo_Name_Of ("https://host/org/tree-sitter-alpha") =
         "tree-sitter-alpha",
         "plain");
      Assert
        (Repo_Name_Of ("https://host/org/tree-sitter-alpha.git") =
         "tree-sitter-alpha",
         ".git");
      Assert
        (Repo_Name_Of ("git@host:org/tree-sitter-alpha.git") =
         "tree-sitter-alpha",
         "scp style");
      Assert
        (Repo_Name_Of ("https://host/org/tree-sitter-alpha/") =
         "tree-sitter-alpha",
         "trailing slash");
      Assert (Repo_Name_Of ("name") = "name", "no slash");
      Assert (Repo_Name_Of ("") = "", "empty");
      Assert (Repo_Name_Of (".git") = "", "only the suffix");
   end A_Repository_Name_Comes_Off_A_Url;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Grammar_Registry");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Ready_Unsupported_And_Absent_Are_Three_Answers'Access,
         "Ready, unsupported and absent are three answers");
      Register_Routine
        (T, An_Entry_That_Is_Malformed_Is_Unusable_Not_Absent'Access,
         "An entry that is malformed is unusable, not absent");
      Register_Routine
        (T, Anything_But_An_Object_Has_No_Entry'Access,
         "Anything but an object has no entry");
      Register_Routine
        (T, Text_That_Is_Not_Json_Is_Refused'Access,
         "Text that is not JSON is refused");
      Register_Routine
        (T, The_Queries_Field_Absent_Means_Tags_And_Known_Values_Parse'Access,
         "The queries field: absent means tags, and known values parse");
      Register_Routine
        (T, Path_And_Symbol_Are_Optional_And_Absent_Means_Derive'Access,
         "Path and symbol are optional, and absent means derive");
      Register_Routine
        (T, An_Extension_Is_Lowercased_And_A_Dotless_Name_Has_None'Access,
         "An extension is lowercased and a dotless name has none");
      Register_Routine
        (T, A_Symbol_Is_Derived_From_The_Repository_Name'Access,
         "A symbol is derived from the repository name");
      Register_Routine
        (T, A_Repository_Name_Comes_Off_A_Url'Access,
         "A repository name comes off a URL");
   end Register_Tests;

end Synapse.Core.Grammar_Registry.Tests;
