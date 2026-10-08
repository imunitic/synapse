with Ada.Strings.Fixed;
with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with Synapse.Adapters.Fake_Variables;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Conf_Files.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  A file with its directories.
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

   function Shown (Found : Maybe_Path) return String is
     (if Found.Found then To_String (Found.Value) else "none");

   procedure Home_Vars
     (V   : in out Fake_Variables.Fake_Variables; Dir : Scratch;
      Xdg :        Boolean := False)
   is
   begin
      V.Set ("HOME", Path (Dir));
      if Xdg then
         V.Set ("XDG_CONFIG_HOME", Path (Dir, "xdg"));
      end if;
   end Home_Vars;

   procedure Tier_One_Wins_Over_Tier_Two (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      Home_Vars (V, Dir, True);
      Put (Path (Dir, "xdg/synapse/foo.conf"), "xdg");
      Put (Path (Dir, ".claude/foo.conf"), "claude");
      Assert
        (Shown (Resolve_Conf_Path (V, "foo.conf")) =
         Path (Dir, "xdg/synapse/foo.conf"),
         "XDG_CONFIG_HOME first");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Tier_One_Wins_Over_Tier_Two;

   procedure Without_Xdg_Config_Dot_Config_Comes_Before_Claude
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      Home_Vars (V, Dir);
      Put (Path (Dir, ".config/synapse/foo.conf"), "dot-config");
      Put (Path (Dir, ".claude/foo.conf"), "claude");
      Assert
        (Shown (Resolve_Conf_Path (V, "foo.conf")) =
         Path (Dir, ".config/synapse/foo.conf"),
         "~/.config/synapse");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Without_Xdg_Config_Dot_Config_Comes_Before_Claude;

   procedure Claude_Is_Found_And_Nothing_Is_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      V    : Fake_Variables.Fake_Variables;
      None : Fake_Variables.Fake_Variables;
   begin
      Home_Vars (V, Dir, True);
      Assert
        (Shown (Resolve_Conf_Path (V, "foo.conf")) = "none", "exists nowhere");
      Put (Path (Dir, ".claude/foo.conf"), "claude");
      Assert
        (Shown (Resolve_Conf_Path (V, "foo.conf")) =
         Path (Dir, ".claude/foo.conf"),
         "~/.claude as it always was");
      Assert
        (Shown (Resolve_Conf_Path (None, "foo.conf")) = "none",
         "no variables at all");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Claude_Is_Found_And_Nothing_Is_Nothing;

   procedure The_Bundled_Template_Is_Last_And_Read_Only
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      Home_Vars (V, Dir);
      Put (Path (Dir, "content/foo.conf.template"), "content");
      Assert
        (Shown (Resolve_Conf_Path (V, "foo.conf")) = "none",
         "the content root is not set");
      V.Set ("SYNAPSE_CONTENT_ROOT", Path (Dir, "content"));
      Assert
        (Shown (Resolve_Conf_Path (V, "foo.conf")) =
         Path (Dir, "content/foo.conf.template"),
         "the installed package's default");
      V.Set ("CLAUDE_PLUGIN_ROOT", Path (Dir, "plugin"));
      Put (Path (Dir, "plugin/bar.conf.template"), "plugin");
      Assert
        (Shown (Resolve_Conf_Path (V, "bar.conf")) = "none",
         "CLAUDE_PLUGIN_ROOT is not a source");
      Put (Path (Dir, ".claude/foo.conf"), "mine");
      Assert
        (Shown (Resolve_Conf_Path (V, "foo.conf")) =
         Path (Dir, ".claude/foo.conf"),
         "a user's file is never shadowed by the default");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Bundled_Template_Is_Last_And_Read_Only;

   procedure Writes_Go_Where_The_Machine_Keeps_Config
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      Home_Vars (V, Dir);
      Put (Path (Dir, "content/foo.conf.template"), "content");
      V.Set ("SYNAPSE_CONTENT_ROOT", Path (Dir, "content"));
      Assert
        (Resolve_Write_Path (V, "foo.conf") = Path (Dir, ".claude/foo.conf"),
         "never the template: nothing else exists, ~/.claude");

      Ada.Directories.Create_Path (Path (Dir, ".config"));
      Assert
        (Resolve_Write_Path (V, "foo.conf") =
         Path (Dir, ".config/synapse/foo.conf"),
         "~/.config exists, so there");

      V.Set ("XDG_CONFIG_HOME", Path (Dir, "xdg"));
      Assert
        (Resolve_Write_Path (V, "foo.conf") =
         Path (Dir, "xdg/synapse/foo.conf"),
         "XDG_CONFIG_HOME set");

      Put (Path (Dir, ".claude/foo.conf"), "old");
      Assert
        (Resolve_Write_Path (V, "foo.conf") = Path (Dir, ".claude/foo.conf"),
         "an existing file is its own write target");
      Put (Path (Dir, "xdg/synapse/foo.conf"), "new");
      Assert
        (Resolve_Write_Path (V, "foo.conf") =
         Path (Dir, "xdg/synapse/foo.conf"),
         "tier one wins");

      declare
         None   : Fake_Variables.Fake_Variables;
         Raised : Boolean := False;
      begin
         begin
            declare
               Ignore : constant String := Resolve_Write_Path (None, "x.conf");
            begin
               null;
            end;
         exception
            when No_Home =>
               Raised := True;
         end;
         Assert (Raised, "no home, no place");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Writes_Go_Where_The_Machine_Keeps_Config;

   procedure The_Vault_Is_Named_By_The_Environment_Or_A_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      Home_Vars (V, Dir);
      Assert (Shown (Vault_Dir (V)) = "none", "nothing names it");
      Put
        (Path (Dir, ".claude/second-brain.conf"),
         "SYNAPSE_VAULT_DIR=/old/vault" & LF);
      Assert
        (Shown (Vault_Dir (V)) = "/old/vault",
         "the pre-rename file is read when it is the only one");
      Put
        (Path (Dir, ".claude/synapse.conf"),
         "SYNAPSE_VAULT_DIR=""$HOME/Vault""" & LF);
      Assert
        (Shown (Vault_Dir (V)) = Path (Dir) & "/Vault",
         "synapse.conf wins, and expands");
      V.Set ("SYNAPSE_VAULT_DIR", "/pinned");
      Assert
        (Shown (Vault_Dir (V)) = "/pinned",
         "the environment wins, so a test can pin a vault");
      V.Set ("SYNAPSE_VAULT_DIR", "");
      Assert
        (Shown (Vault_Dir (V)) = Path (Dir) & "/Vault",
         "an empty variable is not a setting");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Vault_Is_Named_By_The_Environment_Or_A_File;

   procedure Any_Key_Falls_Back_To_The_File (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      Home_Vars (V, Dir);
      Put
        (Path (Dir, ".claude/synapse.conf"),
         "SYNAPSE_VAULT_INTEGRATIONS=git" & LF & "EMPTY=" & LF &
         "SYNAPSE_X=from-first" & LF);
      Put
        (Path (Dir, ".claude/second-brain.conf"),
         "EMPTY=fallback" & LF & "SYNAPSE_X=from-second" & LF);
      Assert
        (Shown (Resolve (V, "SYNAPSE_VAULT_INTEGRATIONS")) = "git",
         "a key other than the vault");
      Assert (Shown (Resolve (V, "SYNAPSE_X")) = "from-first", "first file");
      Assert
        (Shown (Resolve (V, "EMPTY")) = "fallback",
         "an empty value does not count, so the next file is tried");
      Assert (Shown (Resolve (V, "ABSENT")) = "none", "nowhere");
      V.Set ("SYNAPSE_X", "env");
      Assert (Shown (Resolve (V, "SYNAPSE_X")) = "env", "the environment");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Any_Key_Falls_Back_To_The_File;

   procedure A_File_Over_A_Megabyte_Is_Ignored (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      Home_Vars (V, Dir);
      Put
        (Path (Dir, ".claude/synapse.conf"),
         "K=small" & LF & Ada.Strings.Fixed."*" (1_024 * 1_024 + 1, 'x'));
      Assert (Shown (Resolve (V, "K")) = "none", "too large to trust");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_File_Over_A_Megabyte_Is_Ignored;

   procedure The_Push_Threshold_Defaults_To_Five (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      Home_Vars (V, Dir);
      Assert (Push_Every (V) = 5, "unset");
      V.Set ("SYNAPSE_VAULT_PUSH_EVERY", "12");
      Assert (Push_Every (V) = 12, "set");
      V.Set ("SYNAPSE_VAULT_PUSH_EVERY", "0");
      Assert (Push_Every (V) = 0, "zero means never");
      V.Set ("SYNAPSE_VAULT_PUSH_EVERY", "soon");
      Assert (Push_Every (V) = 5, "not a number");
      V.Set ("SYNAPSE_VAULT_PUSH_EVERY", "-3");
      Assert (Push_Every (V) = 5, "negative");
      V.Set ("SYNAPSE_VAULT_PUSH_EVERY", "99999999999999999999");
      Assert (Push_Every (V) = 5, "too large");
      V.Set ("SYNAPSE_VAULT_PUSH_EVERY", "");
      Put
        (Path (Dir, ".claude/synapse.conf"),
         "SYNAPSE_VAULT_PUSH_EVERY=7" & LF);
      Assert (Push_Every (V) = 7, "from the file");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Push_Threshold_Defaults_To_Five;

   procedure Stopwords_Come_From_Their_File (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      V    : Fake_Variables.Fake_Variables;
      None : Fake_Variables.Fake_Variables;
   begin
      Home_Vars (V, Dir);
      Assert (Load_Stopwords (V).Is_Empty, "no file");
      Put
        (Path (Dir, ".claude/synapse-prompt-stopwords.conf"),
         "# noise" & LF & "About" & LF & LF & "with" & LF);
      declare
         Words : constant Core.Text_Lists.Set := Load_Stopwords (V);
      begin
         Assert
           (Words.Contains ("about") and then Words.Contains ("with")
            and then Natural (Words.Length) = 2,
            "read, lowercased, comments skipped");
      end;
      Assert (Load_Stopwords (None).Is_Empty, "no home");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Stopwords_Come_From_Their_File;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Conf_Files");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Tier_One_Wins_Over_Tier_Two'Access, "Tier one wins over tier two");
      Register_Routine
        (T, Without_Xdg_Config_Dot_Config_Comes_Before_Claude'Access,
         "Without XDG, ~/.config comes before ~/.claude");
      Register_Routine
        (T, Claude_Is_Found_And_Nothing_Is_Nothing'Access,
         "~/.claude is found and nothing is nothing");
      Register_Routine
        (T, The_Bundled_Template_Is_Last_And_Read_Only'Access,
         "The bundled template is last and read-only");
      Register_Routine
        (T, Writes_Go_Where_The_Machine_Keeps_Config'Access,
         "Writes go where the machine keeps config");
      Register_Routine
        (T, The_Vault_Is_Named_By_The_Environment_Or_A_File'Access,
         "The vault is named by the environment or a file");
      Register_Routine
        (T, Any_Key_Falls_Back_To_The_File'Access,
         "Any key falls back to the file");
      Register_Routine
        (T, A_File_Over_A_Megabyte_Is_Ignored'Access,
         "A file over a megabyte is ignored");
      Register_Routine
        (T, The_Push_Threshold_Defaults_To_Five'Access,
         "The push threshold defaults to five");
      Register_Routine
        (T, Stopwords_Come_From_Their_File'Access,
         "Stopwords come from their file");
   end Register_Tests;

end Synapse.Adapters.Conf_Files.Tests;
