with Ada.Strings.Unbounded;
with Synapse.Core.Grammar_Registry;
with Synapse.Core.Kind_Synonyms;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with Synapse.Ports.Extractor_Factory;
with AUnit.Assertions;

package body Synapse.Commands.Tagging_Support.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   Empty_Registry : constant Core.Grammar_Registry.Registry :=
     Core.Grammar_Registry.Parse ("{}");

   Empty_Rules : constant Core.Kind_Synonyms.Rule_List :=
     Core.Kind_Synonyms.Parse ("[]");

   procedure The_Registry_Is_Found_In_The_Configuration_Or_In_The_Home
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      declare
         Registry : Core.Grammar_Registry.Registry;
         Where    : Unbounded_String;
         Status   : Load_Status;
      begin
         Load_Registry (Env (F), Registry, Where, Status);
         Assert (Status = No_Home, "no home, no registry");
         F.Vars.Set ("HOME", Path (Dir, "home"));
         Load_Registry (Env (F), Registry, Where, Status);
         Assert
           (Status = Loaded
            and then To_String (Where) =
              Path (Dir, "home/.claude/synapse-grammars.conf")
            and then Core.Grammar_Registry.Usable_Extensions (Registry)
              .Is_Empty,
            "a missing file is an empty registry, looked for in the home");
         Put_Config
           (Dir, "synapse-grammars.conf",
            "{""x"":{""repo"":""u"",""scope"":""s""}}");
         Load_Registry (Env (F), Registry, Where, Status);
         Assert
           (Natural
              (Core.Grammar_Registry.Usable_Extensions (Registry).Length) =
            1,
            "read");
         Put_Config (Dir, "synapse-grammars.conf", "{");
         Load_Registry (Env (F), Registry, Where, Status);
         Assert (Status = Unreadable, "not JSON");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Registry_Is_Found_In_The_Configuration_Or_In_The_Home;

   procedure The_Kind_Synonym_Rules_Can_Be_Named_By_A_Variable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      declare
         Rules  : Core.Kind_Synonyms.Rule_List;
         Where  : Unbounded_String;
         Status : Load_Status;
      begin
         Load_Rules (Env (F), Rules, Where, Status);
         Assert (Status = No_Home, "nowhere to look");
         F.Vars.Set ("HOME", Path (Dir, "home"));
         Load_Rules (Env (F), Rules, Where, Status);
         Assert
           (Status = Loaded and then Core.Kind_Synonyms.Is_Empty (Rules)
            and then To_String (Where) =
              Path (Dir, "home/.claude/synapse-kind-synonyms.conf"),
            "a missing file is no rules");
         Put_Config
           (Dir, "other.conf",
            "[{""match"":""function"",""kind"":""routine""}]");
         F.Vars.Set
           ("SYNAPSE_KIND_SYNONYMS_CONF",
            Path (Dir, "home/.claude/other.conf"));
         Load_Rules (Env (F), Rules, Where, Status);
         Assert
           (Status = Loaded and then not Core.Kind_Synonyms.Is_Empty (Rules)
            and then To_String (Where) = Path (Dir, "home/.claude/other.conf"),
            "the variable wins");
         Put_Config (Dir, "other.conf", "{");
         Load_Rules (Env (F), Rules, Where, Status);
         Assert (Status = Unreadable, "not JSON");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Kind_Synonym_Rules_Can_Be_Named_By_A_Variable;

   procedure The_Grammars_Directory_Is_Configured_Or_In_The_Home_Cache
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      declare
         Dir   : Unbounded_String;
         Found : Boolean;
      begin
         Grammars_Dir (Env (F), Dir, Found);
         Assert (not Found, "nothing names one");
         F.Vars.Set ("HOME", "/home/u");
         Grammars_Dir (Env (F), Dir, Found);
         Assert
           (Found and then To_String (Dir) = "/home/u/.cache/synapse/grammars",
            "the default");
         F.Vars.Set ("SYNAPSE_GRAMMARS_DIR", "/g");
         Grammars_Dir (Env (F), Dir, Found);
         Assert (Found and then To_String (Dir) = "/g", "the setting");
      end;
   end The_Grammars_Directory_Is_Configured_Or_In_The_Home_Cache;

   procedure The_Extractor_Settings_Take_The_Tries_And_The_Query_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      declare
         S : Synapse.Ports.Extractor_Factory.Settings :=
           Settings_For (Env (F), Empty_Registry, "/g", Empty_Rules);
      begin
         Assert (To_String (S.Grammars_Dir) = "/g", "the directory");
         Assert
           (S.Max_Tries = 300 and then not S.Override_Dir.Found,
            "the defaults");
         F.Vars.Set ("SYNAPSE_GRAMMAR_LOCK_TRIES", "7");
         F.Vars.Set ("SYNAPSE_GRAMMARS_QUERY_PATH", "/q");
         S := Settings_For (Env (F), Empty_Registry, "/g", Empty_Rules);
         Assert (S.Max_Tries = 7, "the tries");
         Assert
           (S.Override_Dir.Found
            and then To_String (S.Override_Dir.Value) = "/q",
            "the queries");
         F.Vars.Set ("SYNAPSE_GRAMMAR_LOCK_TRIES", "many");
         Assert
           (Settings_For (Env (F), Empty_Registry, "/g", Empty_Rules)
              .Max_Tries =
            300,
            "not a number");
         F.Vars.Set ("SYNAPSE_GRAMMAR_LOCK_TRIES", "0");
         Assert
           (Settings_For (Env (F), Empty_Registry, "/g", Empty_Rules)
              .Max_Tries =
            300,
            "zero is no wait at all");
      end;
   end The_Extractor_Settings_Take_The_Tries_And_The_Query_Directory;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Tagging_Support");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Registry_Is_Found_In_The_Configuration_Or_In_The_Home'Access,
         "The registry is found in the configuration or in the home");
      Register_Routine
        (T, The_Kind_Synonym_Rules_Can_Be_Named_By_A_Variable'Access,
         "The kind synonym rules can be named by a variable");
      Register_Routine
        (T, The_Grammars_Directory_Is_Configured_Or_In_The_Home_Cache'Access,
         "The grammars directory is configured or in the home cache");
      Register_Routine
        (T,
         The_Extractor_Settings_Take_The_Tries_And_The_Query_Directory'Access,
         "The extractor settings take the tries and the query directory");
   end Register_Tests;

end Synapse.Commands.Tagging_Support.Tests;
