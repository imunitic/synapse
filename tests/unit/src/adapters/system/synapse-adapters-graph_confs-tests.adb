with Ada.Directories;

with AUnit.Assertions;

with Synapse.Adapters.Fake_Variables;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Graph_Confs.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;
   use type Core.Grammar_Registry.Readiness_Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

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

   procedure No_File_Means_Empty_Lists (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      V.Set ("HOME", Path (Dir));
      Assert
        (Core.Kind_Synonyms.Is_Empty (Load_Kind_Synonyms (V)),
         "no kind synonyms");
      Assert (Load_Fence_Languages (V).Entries.Is_Empty, "no fence languages");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end No_File_Means_Empty_Lists;

   procedure A_File_In_The_Tiers_Is_Read (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      V.Set ("HOME", Path (Dir));
      Put
        (Path (Dir, ".claude/synapse-kind-synonyms.conf"),
         "[{""match"": ""widget"", ""kind"": ""gadget""}]");
      Put
        (Path (Dir, ".config/synapse/synapse-fence-languages.conf"),
         "{"".wdg"": ""widget""}");
      Assert
        (Core.Kind_Synonyms.Kind_For (Load_Kind_Synonyms (V), "widget", "s")
           .Found,
         "the kind synonyms");
      Assert
        (Core.Fence_Languages.Language_For
           (Load_Fence_Languages (V), "a.wdg") =
         "widget",
         "the fence languages, from another tier");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_File_In_The_Tiers_Is_Read;

   procedure A_File_That_Is_Not_Json_Is_A_Load_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      V      : Fake_Variables.Fake_Variables;
      Raised : Boolean          := False;
   begin
      V.Set ("HOME", Path (Dir));
      Put (Path (Dir, ".claude/synapse-fence-languages.conf"), "not json");
      begin
         declare
            Ignore : constant Core.Fence_Languages.Registry :=
              Load_Fence_Languages (V);
         begin
            null;
         end;
      exception
         when Core.Fence_Languages.Malformed =>
            Raised := True;
      end;
      Assert (Raised, "malformed, and not a silent fallback");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_File_That_Is_Not_Json_Is_A_Load_Error;

   procedure Rule_Files_Are_Read_From_The_Tiers_And_Absent_Is_Empty
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      V.Set ("HOME", Path (Dir));
      Assert
        (Core.Namespace.Is_Empty (Load_Namespace_Rules (V))
         and then Core.Namespace.Is_Empty (Load_Dependency_Rules (V)),
         "no files, no rules");
      Put
        (Path (Dir, ".claude/synapse-namespace-rules.conf"),
         "{""xx"": {""kind"": ""in-file"", ""prefix"": ""package ""}}");
      Put
        (Path (Dir, ".config/synapse/synapse-dependency-rules.conf"),
         "{""yy"": {""kind"": ""in-file"", ""prefix"": ""uses ""}}");
      Assert
        (Core.Namespace.Rule_For_Path (Load_Namespace_Rules (V), "a.xx").Found
         and then not Core.Namespace.Rule_For_Path
           (Load_Namespace_Rules (V), "a.yy")
           .Found,
         "the namespace rules");
      Assert
        (Core.Namespace.Rule_For_Path (Load_Dependency_Rules (V), "a.yy").Found
         and then not Core.Namespace.Rule_For_Path
           (Load_Dependency_Rules (V), "a.xx")
           .Found,
         "the dependency rules, a separate file");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rule_Files_Are_Read_From_The_Tiers_And_Absent_Is_Empty;

   procedure The_Grammar_Registry_Is_Read_From_The_Tiers
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      V.Set ("HOME", Path (Dir));
      Assert
        (Core.Grammar_Registry.Lookup (Load_Grammar_Registry (V), "wdg").Kind =
         Core.Grammar_Registry.No_Entry,
         "no file, no entry");
      Put
        (Path (Dir, ".config/synapse/synapse-grammars.conf"),
         "{""wdg"":{""repo"":""https://host/tree-sitter-wdg""," &
         """scope"":""source.wdg""}}");
      Assert
        (Core.Grammar_Registry.Lookup (Load_Grammar_Registry (V), "wdg").Kind =
         Core.Grammar_Registry.Ready,
         "the entry in the file");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Grammar_Registry_Is_Read_From_The_Tiers;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Graph_Confs");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, No_File_Means_Empty_Lists'Access, "No file means empty lists");
      Register_Routine
        (T, A_File_In_The_Tiers_Is_Read'Access, "A file in the tiers is read");
      Register_Routine
        (T, Rule_Files_Are_Read_From_The_Tiers_And_Absent_Is_Empty'Access,
         "Rule files are read from the tiers and absent is empty");
      Register_Routine
        (T, The_Grammar_Registry_Is_Read_From_The_Tiers'Access,
         "The grammar registry is read from the tiers");
      Register_Routine
        (T, A_File_That_Is_Not_Json_Is_A_Load_Error'Access,
         "A file that is not JSON is a load error");
   end Register_Tests;

end Synapse.Adapters.Graph_Confs.Tests;
