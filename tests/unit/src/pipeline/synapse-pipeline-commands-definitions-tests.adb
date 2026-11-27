with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Definitions.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;

   package JSON renames Synapse.Core.JSON;

   use type JSON.Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  Two sound definitions of different kinds and two broken files.
   procedure Set_Up (F : in out Fixture) is
   begin
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_PATH", "/defs");
      F.Base.Vars.Set ("XDG_CONFIG_HOME", "/cfg");
      F.Files.Add_File
        ("/defs/Reviewer.synapse", "Agent Reviewer [Prompt => ""Review.""];");
      F.Files.Add_File
        ("/defs/Strict_Reviewer.synapse",
         "System Strict_Reviewer [Agent => Reviewer];");
      F.Files.Add_File ("/defs/Broken.synapse", "Pipeline Broken { A [");
      F.Files.Add_File
        ("/defs/Other.synapse", "Agent Wrong [Prompt => ""x""];");
   end Set_Up;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure It_Takes_Only_A_Known_Format (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("A")) = 2, "an argument");
      Assert (Run (Env (F), Args ("--format")) = 2, "a format missing");
      Assert (Run (Env (F), Args ("--format", "yaml")) = 2, "a format");
      Assert
        (Has (F.Base.Console.Err_Text,
              "usage: synapse-pipeline definitions [--format json|text]"),
         "says how");
   end It_Takes_Only_A_Known_Format;

   procedure Json_Lists_Definitions_And_The_Files_That_Did_Not_Load
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("--format", "json")) = 0, "whatever is found");
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (F.Base.Console.Out_Text);
      begin
         Assert (Parsed.Ok, "one JSON document");
         declare
            Found    : constant JSON.Value :=
              JSON.Member_Value (Parsed.Item, "definitions");
            Problems : constant JSON.Value :=
              JSON.Member_Value (Parsed.Item, "problems");
         begin
            Assert
              (JSON.As_String (JSON.Member_Value (Parsed.Item, "format")) =
               "synapse-pipeline-definitions/v1",
               "its format");
            Assert
              (JSON.Length (Found) = 2
               and then JSON.As_String
                          (JSON.Member_Value (JSON.Element (Found, 1), "name"))
                        = "Reviewer"
               and then JSON.As_String
                          (JSON.Member_Value (JSON.Element (Found, 1), "kind"))
                        = "agent"
               and then JSON.As_String
                          (JSON.Member_Value (JSON.Element (Found, 2), "kind"))
                        = "system"
               and then JSON.As_String
                          (JSON.Member_Value (JSON.Element (Found, 2), "file"))
                        = "/defs/Strict_Reviewer.synapse",
               "the two that loaded, with kind, name and file");
            Assert (JSON.Length (Problems) = 2, "the two that did not");
            Assert
              (JSON.As_String
                 (JSON.Member_Value (JSON.Element (Problems, 1), "file")) =
               "/defs/Broken.synapse"
               and then JSON.As_Integer
                          (JSON.Member_Value
                             (JSON.Element (Problems, 1), "line")) = 1
               and then JSON.As_String
                          (JSON.Member_Value
                             (JSON.Element (Problems, 1), "message")) /= "",
               "a broken file is listed with its problem");
         end;
      end;
   end Json_Lists_Definitions_And_The_Files_That_Did_Not_Load;

   procedure Text_Lists_The_Same_For_A_Person (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args) = 0, "text is the default");
      Assert
        (Has (F.Base.Console.Out_Text,
              "agent Reviewer  /defs/Reviewer.synapse")
         and then Has (F.Base.Console.Out_Text,
                       "warning: /defs/Broken.synapse:1:"),
         "a definition and a problem");
   end Text_Lists_The_Same_For_A_Person;

   procedure Nothing_Defined_Is_An_Empty_Document (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Base.Vars.Set ("XDG_CONFIG_HOME", "/cfg");
      Assert (Run (Env (F), Args ("--format", "json")) = 0, "no definitions");
      Assert
        (F.Base.Console.Out_Text =
         "{""format"":""synapse-pipeline-definitions/v1"","
         & """definitions"":[],""problems"":[]}"
         & Character'Val (10),
         "empty lists, not missing ones: " & F.Base.Console.Out_Text);
   end Nothing_Defined_Is_An_Empty_Document;

   --  The entry of the definition called Name in a JSON listing, or null.
   function Entry_Of (Listing : JSON.Value; Name : String) return JSON.Value
   is
      Found : constant JSON.Value :=
        JSON.Member_Value (Listing, "definitions");
   begin
      for I in 1 .. JSON.Length (Found) loop
         if JSON.As_String
              (JSON.Member_Value (JSON.Element (Found, I), "name")) = Name
         then
            return JSON.Element (Found, I);
         end if;
      end loop;
      return JSON.Null_Value;
   end Entry_Of;

   procedure A_Prompt_Is_Listed_With_Kind_Prompt (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
      G : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File
        ("/defs/Careful.synapse",
         "Prompt Careful [Prompt => ""Be careful.""];");
      Assert (Run (Env (F), Args ("--format", "json")) = 0, "in JSON");
      Assert
        (JSON.As_String
           (JSON.Member_Value
              (Entry_Of (JSON.Parse (F.Base.Console.Out_Text).Item, "Careful"),
               "kind")) = "prompt",
         "its kind: " & F.Base.Console.Out_Text);
      Set_Up (G);
      G.Files.Add_File
        ("/defs/Careful.synapse",
         "Prompt Careful [Prompt => ""Be careful.""];");
      Assert (Run (Env (G), Args) = 0, "in text");
      Assert
        (Has (G.Base.Console.Out_Text,
              "prompt Careful  /defs/Careful.synapse"),
         "its line: " & G.Base.Console.Out_Text);
   end A_Prompt_Is_Listed_With_Kind_Prompt;

   procedure The_Json_Gives_A_Description_Null_When_There_Is_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File
        ("/defs/Careful.synapse",
         "Prompt Careful [Description => ""Asks for care."", "
         & "Prompt => ""Be careful.""];");
      F.Files.Add_File
        ("/defs/Work.synapse",
         "Pipeline Work [Description => ""Does the work.""] "
         & "{ A [Harness => Claude, Prompt => Careful]; }");
      Assert (Run (Env (F), Args ("--format", "json")) = 0, "whatever");
      declare
         Listing : constant JSON.Value :=
           JSON.Parse (F.Base.Console.Out_Text).Item;
      begin
         Assert
           (JSON.As_String
              (JSON.Member_Value (Entry_Of (Listing, "Careful"),
               "description")) = "Asks for care."
            and then JSON.As_String
                       (JSON.Member_Value (Entry_Of (Listing, "Work"),
                        "description")) = "Does the work.",
            "a prompt's and a pipeline's description: "
            & F.Base.Console.Out_Text);
         Assert
           (JSON.Kind_Of
              (JSON.Member_Value (Entry_Of (Listing, "Reviewer"),
               "description")) = JSON.JSON_Null,
            "null for one that has none");
      end;
      declare
         G : aliased Fixture;
      begin
         Set_Up (G);
         G.Files.Add_File
           ("/defs/Careful.synapse",
            "Prompt Careful [Description => ""Asks for care."", "
            & "Prompt => ""Be careful.""];");
         Assert (Run (Env (G), Args) = 0, "in text");
         Assert
           (not Has (G.Base.Console.Out_Text, "Asks for care."),
            "the text listing is unchanged: " & G.Base.Console.Out_Text);
      end;
   end The_Json_Gives_A_Description_Null_When_There_Is_None;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Definitions");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, It_Takes_Only_A_Known_Format'Access,
         "It takes only a known format");
      Register_Routine
        (T, Json_Lists_Definitions_And_The_Files_That_Did_Not_Load'Access,
         "Json lists definitions and the files that did not load");
      Register_Routine
        (T, Text_Lists_The_Same_For_A_Person'Access,
         "Text lists the same for a person");
      Register_Routine
        (T, A_Prompt_Is_Listed_With_Kind_Prompt'Access,
         "A prompt is listed with kind prompt");
      Register_Routine
        (T, The_Json_Gives_A_Description_Null_When_There_Is_None'Access,
         "The JSON gives a definition's description, null when it has none");
      Register_Routine
        (T, Nothing_Defined_Is_An_Empty_Document'Access,
         "Nothing defined is an empty document");
   end Register_Tests;

end Synapse.Pipeline.Commands.Definitions.Tests;
