with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with Synapse.Adapters.Fake_Variables;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.JSON;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Schema_Loader.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

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

   Tags_Schema : constant String :=
     "schema: synapse-note-schema/v1" & LF & "id: a/v1" & LF & "frontmatter:" &
     LF & "  fields:" & LF & "    tags:" & LF & "      type: list" & LF &
     "      required: true" & LF & "    title:" & LF & "      type: string" &
     LF & "body:" & LF & "  h1:" & LF & "    required: false" & LF &
     "checks: []" & LF;

   function Fault (Result : Load_Result) return String is
     (if Load_Results.Is_Success (Result) then "<loaded>"
      else To_String (Load_Results.Error (Result)));

   function Has_Tags (Result : Load_Result) return Boolean is
     (Load_Results.Is_Success (Result)
      and then Core.JSON.Has_Member
        (Core.JSON.Member_Value
           (Core.JSON.Member_Value
              (Load_Results.Value (Result), "frontmatter"),
            "fields"),
         "tags"));

   procedure Faults_Are_Named (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      Assert
        (Fault (Load_Schema (V, "a/v1")) = "ContentRootMissing",
         "no content root");
      V.Set ("SYNAPSE_CONTENT_ROOT", "");
      Assert
        (Fault (Load_Schema (V, "a/v1")) = "ContentRootMissing",
         "an empty one");
      V.Set ("SYNAPSE_CONTENT_ROOT", Path (Dir));
      Assert (Fault (Load_Schema (V, "a/v1")) = "FileNotFound", "no file");
      Put (Path (Dir, "schema/a/v1.yaml"), "");
      Assert
        (Fault (Load_Schema (V, "a/v1")) = "EmptyDocument",
         "a fault of the YAML reader");
      Put
        (Path (Dir, "schema/a/v1.yaml"),
         "a:" & LF & Character'Val (9) & "b: 1" & LF);
      Assert
        (Fault (Load_Schema (V, "a/v1")) = "TabIndent",
         "named TabIndent");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Faults_Are_Named;

   procedure A_Schema_Loads_And_An_Override_Is_Merged_Over_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      V.Set ("SYNAPSE_CONTENT_ROOT", Path (Dir));
      V.Set ("XDG_CONFIG_HOME", Path (Dir));
      Put (Path (Dir, "schema/a/v1.yaml"), Tags_Schema);
      Put (Path (Dir, "schema/b/v1.yaml"), Tags_Schema);
      Assert (Has_Tags (Load_Schema (V, "a/v1")), "as shipped");

      Put
        (Path (Dir, "synapse/schema-overrides/a/v1.yaml"),
         "frontmatter:" & LF & "  fields:" & LF & "    tags: null" & LF);
      Assert (not Has_Tags (Load_Schema (V, "a/v1")), "tags removed");
      Assert
        (Has_Tags (Load_Schema (V, "b/v1")),
         "an override for one id never affects another");

      Put
        (Path (Dir, "synapse/schema-overrides/b/v1.yaml"),
         "frontmatter:" & LF);
      Assert
        (Fault (Load_Schema (V, "b/v1")) /= "<loaded>",
         "a broken override is a fault");

      Put
        (Path (Dir, "synapse/schema-overrides/b/v1.yaml"),
         "lints:" & LF & "  - match:" & LF & "      nothing: 1" & LF &
         "    severity: error" & LF);
      Assert
        (Fault (Load_Schema (V, "b/v1")) /= "<loaded>",
         "a patch that matches nothing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Schema_Loads_And_An_Override_Is_Merged_Over_It;

   procedure Vocabularies_Are_Found_Through_The_Tiers
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      V.Set ("HOME", Path (Dir));
      Assert
        (not Load_Vocabulary (V, "synapse-tag-vocabulary.conf").Found, "none");
      Put
        (Path (Dir, ".claude/synapse-tag-vocabulary.conf"),
         "a" & LF & "b" & LF);
      declare
         Found : constant Maybe_Text :=
           Load_Vocabulary (V, "synapse-tag-vocabulary.conf");
      begin
         Assert
           (Found.Found and then To_String (Found.Value) = "a" & LF & "b" & LF,
            "read");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Vocabularies_Are_Found_Through_The_Tiers;

   procedure Schema_Ids_Must_Be_Kind_Slash_Version
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      procedure Safe (Id : String) is
      begin
         Assert (Is_Safe_Schema_Id (Id), "safe: " & Id);
      end Safe;

      procedure Unsafe (Id : String) is
      begin
         Assert (not Is_Safe_Schema_Id (Id), "unsafe: '" & Id & "'");
      end Unsafe;
   begin
      Safe ("vault-note/v1");
      Safe ("vault_task_note/v1");
      Safe ("a/b/c");
      Safe ("A1/B2");
      Unsafe ("");
      Unsafe ("vault-note");
      Unsafe ("../secret");
      Unsafe ("a/../b");
      Unsafe ("/a/b");
      Unsafe ("a//b");
      Unsafe ("a/b/");
      Unsafe ("a/./b");
      Unsafe ("a\b");
      Unsafe ("a/b.yaml");
      Unsafe ("a/b c");
      Unsafe ("a/b:c");
      Unsafe ("/");
   end Schema_Ids_Must_Be_Kind_Slash_Version;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Schema_Loader");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, Faults_Are_Named'Access, "Faults are named");
      Register_Routine
        (T, A_Schema_Loads_And_An_Override_Is_Merged_Over_It'Access,
         "A schema loads and an override is merged over it");
      Register_Routine
        (T, Vocabularies_Are_Found_Through_The_Tiers'Access,
         "Vocabularies are found through the tiers");
      Register_Routine
        (T, Schema_Ids_Must_Be_Kind_Slash_Version'Access,
         "Schema ids must be kind/version");
   end Register_Tests;

end Synapse.Adapters.Schema_Loader.Tests;
