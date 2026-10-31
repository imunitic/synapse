with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Syntax;

package body Synapse.Pipeline.Definitions.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Syntax.Definition_Kind;
   use type Source_Errors.Source_Error;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   Reviewer_Agent  : constant String := "Agent Reviewer [Prompt => ""x""];";
   Strict_System   : constant String :=
     "System Strict_Reviewer [Agent => Reviewer];";
   Develop_Feature : constant String :=
     "Pipeline Develop_Feature { A [Agent => Reviewer]; }";

   function Root (Path : String; Required : Boolean := True)
      return Search_Paths.Root
   is
     (Path => To_Unbounded_String (Path), Required => Required);

   function Roots_Of (A : String; B : String := ""; C : String := "")
      return Search_Paths.Root_Vectors.Vector
   is
      Result : Search_Paths.Root_Vectors.Vector;
   begin
      Result.Append (Root (A));
      if B /= "" then
         Result.Append (Root (B));
      end if;
      if C /= "" then
         Result.Append (Root (C));
      end if;
      return Result;
   end Roots_Of;

   --  Whether Problem is in File at Line and Column and says Message.
   procedure Assert_Problem
     (Problem : Source_Errors.Source_Error;
      File    : String; Line, Column : Positive; Message : String;
      Label   : String)
   is
   begin
      Assert
        (To_String (Problem.File) = File,
         Label & ": in " & File & ", is " & Source_Errors.Image (Problem));
      Assert
        (Problem.Line = Line and then Problem.Column = Column,
         Label & ": at " & Source_Errors.Image (Problem));
      Assert
        (Ada.Strings.Fixed.Index (To_String (Problem.Message), Message) > 0,
         Label & ": says '" & Message & "', says "
         & Source_Errors.Image (Problem));
   end Assert_Problem;

   procedure Every_Root_Joins_One_Namespace (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/a/Strict_Reviewer.synapse", Strict_System);
      F.Add_File ("/a/Reviewer.synapse", Reviewer_Agent);
      F.Add_File ("/b/Develop_Feature.synapse", Develop_Feature);
      declare
         R : constant Load_Report := Load (F, Roots_Of ("/a", "/b"));
         N : Namespaces.Namespace renames R.Definitions;
      begin
         Assert (R.Problems.Is_Empty, "nothing wrong");
         Assert (Namespaces.Count (N) = 3, "three definitions");
         Assert
           (To_String (Namespaces.Names (N) (1)) = "Develop_Feature"
            and then To_String (Namespaces.Names (N) (3)) = "Strict_Reviewer",
            "named alphabetically");
         Assert
           (Namespaces.Element (N, "Reviewer").Item.Kind =
              Syntax.Agent_Definition
            and then Namespaces.Element (N, "Strict_Reviewer").Item.Kind =
              Syntax.System_Definition
            and then Namespaces.Element (N, "Develop_Feature").Item.Kind =
              Syntax.Pipeline_Definition,
            "of all three kinds, in one namespace");
         Assert
           (To_String (Namespaces.Element (N, "Develop_Feature").Path) =
            "/b/Develop_Feature.synapse",
            "each remembers its file");
      end;
   end Every_Root_Joins_One_Namespace;

   procedure Only_Definition_Files_Directly_In_A_Root_Are_Read
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/a/Reviewer.synapse", Reviewer_Agent);
      F.Add_File ("/a/notes.md", "not a definition");
      F.Add_File ("/a/Reviewer.synapse.bak", "not a definition either");
      F.Add_File ("/a/sub/Other.synapse", "Agent Other [];");
      declare
         R : constant Load_Report := Load (F, Roots_Of ("/a"));
      begin
         Assert
           (R.Problems.Is_Empty
            and then Namespaces.Count (R.Definitions) = 1
            and then Namespaces.Contains (R.Definitions, "Reviewer"),
            "only Reviewer.synapse");
      end;
   end Only_Definition_Files_Directly_In_A_Root_Are_Read;

   procedure A_Missing_Root_Is_Skipped_Or_A_Problem
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F     : Fake_Files.Fake_Files;
      Roots : Search_Paths.Root_Vectors.Vector;
   begin
      F.Add_File ("/a/Reviewer.synapse", Reviewer_Agent);
      Roots.Append (Root ("/not/there", Required => False));
      Roots.Append (Root ("/a"));
      Assert (Load (F, Roots).Problems.Is_Empty, "skipped, not a problem");
      Roots.Append (Root ("/also/not/there", Required => True));
      declare
         R : constant Load_Report := Load (F, Roots);
      begin
         Assert (Natural (R.Problems.Length) = 1, "one problem");
         Assert_Problem
           (R.Problems (1), "/also/not/there", 1, 1, "does not exist",
            "a required root");
         Assert
           (Namespaces.Contains (R.Definitions, "Reviewer"),
            "the other roots still load");
      end;
      Assert
        (Namespaces.Count
           (Load (F, Search_Paths.Root_Vectors.Empty_Vector).Definitions) = 0,
         "no roots, no definitions");
   end A_Missing_Root_Is_Skipped_Or_A_Problem;

   procedure A_Bad_File_Does_Not_Stop_The_Others (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/a/Bad.synapse", "System Bad [A => ];");
      F.Add_File ("/a/Reviewer.synapse", Reviewer_Agent);
      declare
         R : constant Load_Report := Load (F, Roots_Of ("/a"));
         N : Namespaces.Namespace renames R.Definitions;
      begin
         Assert (Namespaces.Contains (N, "Reviewer"), "the good file loads");
         Assert
           (Namespaces.Has_Failed (N, "Bad")
            and then not Namespaces.Contains (N, "Bad"),
            "the bad one is a failed name, not a definition");
         Assert (Natural (R.Problems.Length) = 1, "one problem");
         Assert_Problem
           (R.Problems (1), "/a/Bad.synapse", 1, 18, "expected a value",
            "a syntax error");
         Assert
           (Namespaces.Failure (N, "Bad") = R.Problems (1),
            "the name remembers it");
         Assert
           (Warning (R.Problems (1)) =
            "warning: /a/Bad.synapse:1:18: expected a value after '=>', "
            & "found ']'",
            "as a warning");
      end;
   end A_Bad_File_Does_Not_Stop_The_Others;

   procedure An_Unreadable_File_Is_A_Failed_Name (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/a/Reviewer.synapse", Reviewer_Agent);
      F.Unreadable.Include ("/a/Reviewer.synapse");
      declare
         R : constant Load_Report := Load (F, Roots_Of ("/a"));
      begin
         Assert (Namespaces.Has_Failed (R.Definitions, "Reviewer"), "failed");
         Assert_Problem
           (R.Problems (1), "/a/Reviewer.synapse", 1, 1, "cannot be read",
            "an unreadable file");
      end;
   end An_Unreadable_File_Is_A_Failed_Name;

   procedure A_File_Is_Named_After_What_It_Declares
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/a/Reviewer.synapse", "Agent Review [];");
      declare
         R : constant Load_Report := Load (F, Roots_Of ("/a"));
      begin
         Assert
           (Namespaces.Has_Failed (R.Definitions, "Reviewer")
            and then not Namespaces.Contains (R.Definitions, "Review"),
            "the name the file stands for failed");
         Assert_Problem
           (R.Problems (1), "/a/Reviewer.synapse", 1, 7,
            "'Reviewer' declares 'Review'", "a name that differs");
      end;
   end A_File_Is_Named_After_What_It_Declares;

   procedure A_Name_Claimed_Twice_Belongs_To_Neither
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/a/Reviewer.synapse", Reviewer_Agent);
      F.Add_File ("/b/Reviewer.synapse", "System Reviewer [];");
      declare
         R : constant Load_Report := Load (F, Roots_Of ("/a", "/b"));
      begin
         Assert
           (Namespaces.Has_Failed (R.Definitions, "Reviewer")
            and then not Namespaces.Contains (R.Definitions, "Reviewer"),
            "neither the agent nor the system can be used");
         Assert (Natural (R.Problems.Length) = 1, "one problem");
         Assert_Problem
           (R.Problems (1), "/b/Reviewer.synapse", 1, 8,
            "'Reviewer' is defined in both /a/Reviewer.synapse and "
            & "/b/Reviewer.synapse",
            "an agent and a system of one name");
      end;
      F.Add_File ("/c/Reviewer.synapse", "Agent Reviewer [];");
      declare
         R : constant Load_Report := Load (F, Roots_Of ("/a", "/b", "/c"));
      begin
         Assert
           (Natural (R.Problems.Length) = 2
            and then not Namespaces.Contains (R.Definitions, "Reviewer"),
            "a third claim is another problem and changes nothing");
      end;
   end A_Name_Claimed_Twice_Belongs_To_Neither;

   procedure A_Good_File_After_A_Failed_Name_Conflicts
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/a/Reviewer.synapse", "Agent Reviewer [");
      F.Add_File ("/b/Reviewer.synapse", Reviewer_Agent);
      declare
         R : constant Load_Report := Load (F, Roots_Of ("/a", "/b"));
      begin
         Assert
           (Namespaces.Has_Failed (R.Definitions, "Reviewer")
            and then not Namespaces.Contains (R.Definitions, "Reviewer"),
            "the name stays failed");
         Assert (Natural (R.Problems.Length) = 2, "both are reported");
         Assert_Problem
           (R.Problems (2), "/b/Reviewer.synapse", 1, 1,
            "also the name of a file that failed", "the good file");
      end;
   end A_Good_File_After_A_Failed_Name_Conflicts;

   procedure The_Same_File_Reached_Twice_Counts_Once
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      F.Add_File ("/a/Reviewer.synapse", Reviewer_Agent);
      declare
         Twice : constant Load_Report := Load (F, Roots_Of ("/a", "/a"));
         Slash : constant Load_Report := Load (F, Roots_Of ("/a", "/a/"));
      begin
         Assert
           (Twice.Problems.Is_Empty
            and then Namespaces.Count (Twice.Definitions) = 1,
            "a root listed twice");
         Assert
           (Slash.Problems.Is_Empty
            and then Namespaces.Count (Slash.Definitions) = 1,
            "and with a trailing slash");
      end;
   end The_Same_File_Reached_Twice_Counts_Once;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Definitions");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Every_Root_Joins_One_Namespace'Access,
         "Every root joins one namespace");
      Register_Routine
        (T, Only_Definition_Files_Directly_In_A_Root_Are_Read'Access,
         "Only definition files directly in a root are read");
      Register_Routine
        (T, A_Missing_Root_Is_Skipped_Or_A_Problem'Access,
         "A missing root is skipped or a problem");
      Register_Routine
        (T, A_Bad_File_Does_Not_Stop_The_Others'Access,
         "A bad file does not stop the others");
      Register_Routine
        (T, An_Unreadable_File_Is_A_Failed_Name'Access,
         "An unreadable file is a failed name");
      Register_Routine
        (T, A_File_Is_Named_After_What_It_Declares'Access,
         "A file is named after what it declares");
      Register_Routine
        (T, A_Name_Claimed_Twice_Belongs_To_Neither'Access,
         "A name claimed twice belongs to neither");
      Register_Routine
        (T, A_Good_File_After_A_Failed_Name_Conflicts'Access,
         "A good file after a failed one of the same name is a conflict");
      Register_Routine
        (T, The_Same_File_Reached_Twice_Counts_Once'Access,
         "The same file reached twice counts once");
   end Register_Tests;

end Synapse.Pipeline.Definitions.Tests;
