with Ada.Strings.Fixed;

with Synapse.Commands.Vault_Usage;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Vault_Search.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   function Note (Title, Tags, Text : String) return String is
     ("---" & LF & "title: " & Title & LF & "tags: " & Tags & LF & "---" & LF &
      Text & LF);

   procedure Fill (Dir : Scratch) is
   begin
      Put (Dir, "a.md", Note ("A", "[x, y]", "alpha beta" & LF & "gamma"));
      Put (Dir, "b.md", Note ("B", "[z]", "beta only"));
      Put (Dir, "c.md", "no frontmatter alpha" & LF);
   end Fill;

   Rule_Tagged_X : constant String := "{""in"": [""x"", {""var"": ""tags""}]}";

   procedure Search_Prints_The_Path_And_Each_Asked_For_Field
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      F.Console.Set_Stdin (Rule_Tagged_X);
      Assert
        (Run_Search
           (Env (F), Args ("--fields", "frontmatter.title,tags,missing")) =
         0,
         "success");
      Assert
        (F.Console.Out_Text =
         "a.md" & HT & "A" & HT & "[""x"",""y""]" & HT & "null" & LF,
         "a string bare, a list and a missing field as JSON: " &
         F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Prints_The_Path_And_Each_Asked_For_Field;

   procedure Search_Without_Fields_Prints_Bare_Paths
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      F.Console.Set_Stdin ("true");
      Assert (Run_Search (Env (F), Args) = 0, "success");
      Assert
        (F.Console.Out_Text = "a.md" & LF & "b.md" & LF & "c.md" & LF,
         "every note: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Without_Fields_Prints_Bare_Paths;

   procedure Search_Trims_The_Fields_And_Skips_Empty_Ones
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      F.Console.Set_Stdin (Rule_Tagged_X);
      Assert
        (Run_Search (Env (F), Args ("--fields", " frontmatter.title ,, ")) = 0,
         "ok");
      Assert
        (F.Console.Out_Text = "a.md" & HT & "A" & LF,
         "only title: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Trims_The_Fields_And_Skips_Empty_Ones;

   procedure Search_Fields_May_Be_Given_Twice (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      F.Console.Set_Stdin (Rule_Tagged_X);
      Assert
        (Run_Search
           (Env (F),
            Args ("--fields", "frontmatter.title", "--fields", "tags")) =
         0,
         "ok");
      Assert
        (F.Console.Out_Text = "a.md" & HT & "A" & HT & "[""x"",""y""]" & LF,
         "both: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Fields_May_Be_Given_Twice;

   procedure Search_Stdin_That_Is_Not_JSON_Fails (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      F.Console.Set_Stdin ("not json");
      Assert (Run_Search (Env (F), Args) = 1, "code 1");
      Assert
        (F.Console.Err_Text = "synapse-vault: stdin is not valid JSON" & LF,
         "the message");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Stdin_That_Is_Not_JSON_Fails;

   procedure Search_Arguments_It_Does_Not_Know_Are_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Search (Env (F), Args ("--fields")) = 2, "dangling");
      Assert (Run_Search (Env (F), Args ("extra")) = 2, "stray");
      Assert
        (F.Console.Err_Text = Vault_Usage.Search & Vault_Usage.Search,
         "the usage");
      F.Console.Clear;
      Assert (Run_Search (Env (F), Args ("--fields", "a", "-h")) = 0, "help");
      Assert (F.Console.Err_Text = Vault_Usage.Search, "help prints it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Arguments_It_Does_Not_Know_Are_A_Usage_Error;

   procedure Search_Text_Prints_Node_Score_And_Line_Ranges
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run_Search_Text (Env (F), Args ("alpha")) = 0, "success");
      Assert
        (F.Console.Out_Text =
         "a.md" & HT & "0.5" & HT & "5" & LF & "c.md" & HT & "0.5" & HT & "1" &
         LF,
         "the matching lines, frontmatter counted: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Text_Prints_Node_Score_And_Line_Ranges;

   procedure Search_Text_Merges_Adjacent_Lines_And_Finds_Any_Word
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run_Search_Text (Env (F), Args ("alpha gamma")) = 0, "success");
      Assert
        (F.Console.Out_Text
           (F.Console.Out_Text'First .. F.Console.Out_Text'First + 4) =
         "a.md" & HT,
         "the best note first");
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, HT & "5-6" & LF) > 0,
         "lines 5 and 6 as one range: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Text_Merges_Adjacent_Lines_And_Finds_Any_Word;

   procedure Search_Text_Prints_At_Most_Ten_Notes (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      for I in 1 .. 12 loop
         Put
           (Dir,
            "n" &
            Ada.Strings.Fixed.Trim (Integer'Image (I), Ada.Strings.Both) &
            ".md",
            "common word" & LF);
      end loop;
      Assert (Run_Search_Text (Env (F), Args ("common")) = 0, "success");
      Assert
        (Ada.Strings.Fixed.Count (F.Console.Out_Text, "" & LF) = 10,
         "ten rows: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Text_Prints_At_Most_Ten_Notes;

   procedure Search_Text_With_Nothing_Found_Prints_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run_Search_Text (Env (F), Args ("zzzzqq")) = 0, "success");
      Assert (F.Console.Out_Text = "", "nothing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Text_With_Nothing_Found_Prints_Nothing;

   procedure Search_Text_Scopes_By_A_Path_Filter_On_Stdin
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      F.Console.Set_Stdin ("{""glob"": [""a*"", {""var"": ""path""}]}");
      Assert
        (Run_Search_Text (Env (F), Args ("alpha", "--path-filter")) = 0, "ok");
      Assert
        (F.Console.Out_Text = "a.md" & HT & "0.6666667" & HT & "5" & LF,
         "only a.md: " & F.Console.Out_Text);
      F.Console.Clear;
      F.Console.Set_Stdin ("oops");
      Assert
        (Run_Search_Text (Env (F), Args ("alpha", "--path-filter")) = 1,
         "a filter that is not JSON");
      Assert
        (F.Console.Err_Text = "synapse-vault: stdin is not valid JSON" & LF,
         "the message");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Text_Scopes_By_A_Path_Filter_On_Stdin;

   procedure Search_Text_Scopes_By_A_Namespace (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "branch: main" & LF & "remote: r" & LF & "---" & LF &
         "alpha" & LF);
      Put (Dir, "synapse/widget@main/n.md", "alpha node" & LF);
      F.Vars.Set ("SYNAPSE_REPO_ROOT", "/w");
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", "r");
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      Assert
        (Run_Search_Text
           (Env (F), Args ("alpha", "--namespace", "widget@main")) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "a.md") = 0
         and then
           Ada.Strings.Fixed.Index
             (F.Console.Out_Text, "synapse/widget@main/n.md") >
           0,
         "only that graph: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Text_Scopes_By_A_Namespace;

   procedure Search_Text_Ands_The_Namespace_With_A_Path_Filter
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "branch: main" & LF & "remote: r" & LF & "---" & LF &
         "alpha" & LF);
      Put (Dir, "synapse/widget@main/n.md", "alpha node" & LF);
      Put (Dir, "synapse/widget@main/m.md", "alpha other" & LF);
      F.Vars.Set ("SYNAPSE_REPO_ROOT", "/w");
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", "r");
      F.Console.Set_Stdin ("{""glob"": [""*/n.md"", {""var"": ""path""}]}");
      Assert
        (Run_Search_Text
           (Env (F),
            Args ("alpha", "--namespace", "widget@main", "--path-filter")) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text, "synapse/widget@main/n.md") >
         0
         and then Ada.Strings.Fixed.Index (F.Console.Out_Text, "m.md") = 0,
         "both limits apply: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Text_Ands_The_Namespace_With_A_Path_Filter;

   procedure Search_Text_Refuses_A_Namespace_That_Has_No_Graph
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert
        (Run_Search_Text
           (Env (F), Args ("alpha", "--namespace", "gadget@main")) =
         1,
         "code 1");
      Assert (F.Console.Out_Text = "", "nothing printed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Text_Refuses_A_Namespace_That_Has_No_Graph;

   procedure Search_Text_Refuses_A_Namespace_That_Is_Not_Plain
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Put
        (Dir, "synapse/wi""dget@main/Index.md",
         "---" & LF & "branch: main" & LF & "remote: r" & LF & "---" & LF);
      F.Vars.Set ("SYNAPSE_REPO_ROOT", "/w");
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", "r");
      Assert
        (Run_Search_Text
           (Env (F), Args ("alpha", "--namespace", "wi""dget@main")) =
         2,
         "code 2: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "--namespace expects <repo>@<branch>") >
         0,
         "the message: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Text_Refuses_A_Namespace_That_Is_Not_Plain;

   procedure Search_Text_Arguments_It_Does_Not_Know_Are_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Search_Text (Env (F), Args) = 2, "no query");
      Assert
        (Run_Search_Text
           (Env (F), Args ("q", "--path-filter", "--path-filter")) =
         2,
         "a flag twice");
      Assert
        (Run_Search_Text (Env (F), Args ("q", "--namespace")) = 2, "dangling");
      Assert
        (Run_Search_Text
           (Env (F), Args ("q", "--namespace", "a@b", "--namespace", "c@d")) =
         2,
         "a namespace twice");
      Assert (Run_Search_Text (Env (F), Args ("q", "extra")) = 2, "stray");
      F.Console.Clear;
      Assert (Run_Search_Text (Env (F), Args ("--help")) = 0, "help");
      Assert (F.Console.Err_Text = Vault_Usage.Search_Text, "its usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Text_Arguments_It_Does_Not_Know_Are_A_Usage_Error;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Vault_Search");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Search_Prints_The_Path_And_Each_Asked_For_Field'Access,
         "Search prints the path and each asked for field");
      Register_Routine
        (T, Search_Without_Fields_Prints_Bare_Paths'Access,
         "Search without fields prints bare paths");
      Register_Routine
        (T, Search_Trims_The_Fields_And_Skips_Empty_Ones'Access,
         "Search trims the fields and skips empty ones");
      Register_Routine
        (T, Search_Fields_May_Be_Given_Twice'Access,
         "Search fields may be given twice");
      Register_Routine
        (T, Search_Stdin_That_Is_Not_JSON_Fails'Access,
         "Search stdin that is not JSON fails");
      Register_Routine
        (T, Search_Arguments_It_Does_Not_Know_Are_A_Usage_Error'Access,
         "Search arguments it does not know are a usage error");
      Register_Routine
        (T, Search_Text_Prints_Node_Score_And_Line_Ranges'Access,
         "Search text prints node score and line ranges");
      Register_Routine
        (T, Search_Text_Merges_Adjacent_Lines_And_Finds_Any_Word'Access,
         "Search text merges adjacent lines and finds any word");
      Register_Routine
        (T, Search_Text_Prints_At_Most_Ten_Notes'Access,
         "Search text prints at most ten notes");
      Register_Routine
        (T, Search_Text_With_Nothing_Found_Prints_Nothing'Access,
         "Search text with nothing found prints nothing");
      Register_Routine
        (T, Search_Text_Scopes_By_A_Path_Filter_On_Stdin'Access,
         "Search text scopes by a path filter on stdin");
      Register_Routine
        (T, Search_Text_Scopes_By_A_Namespace'Access,
         "Search text scopes by a namespace");
      Register_Routine
        (T, Search_Text_Ands_The_Namespace_With_A_Path_Filter'Access,
         "Search text ands the namespace with a path filter");
      Register_Routine
        (T, Search_Text_Refuses_A_Namespace_That_Has_No_Graph'Access,
         "Search text refuses a namespace that has no graph");
      Register_Routine
        (T, Search_Text_Refuses_A_Namespace_That_Is_Not_Plain'Access,
         "Search text refuses a namespace that is not plain");
      Register_Routine
        (T, Search_Text_Arguments_It_Does_Not_Know_Are_A_Usage_Error'Access,
         "Search text arguments it does not know are a usage error");
   end Register_Tests;

end Synapse.Commands.Vault_Search.Tests;
