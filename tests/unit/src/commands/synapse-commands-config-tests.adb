with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.JSON;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;

package body Synapse.Commands.Config.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  `set Key Value`, with a Value that may be empty, which Args drops.
   function Set_Args (Key, Value : String) return Lists.Vector is
      Result : Lists.Vector;
   begin
      Result.Append (Ada.Strings.Unbounded.To_Unbounded_String ("set"));
      Result.Append (Ada.Strings.Unbounded.To_Unbounded_String (Key));
      Result.Append (Ada.Strings.Unbounded.To_Unbounded_String (Value));
      return Result;
   end Set_Args;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Conf_Path (Dir : Scratch) return String is
     (Path (Dir, ".claude/synapse.conf"));

   procedure Put (File, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (File));
      Synapse.Adapters.File_Bytes.Write (File, Text);
   end Put;

   function Read (File : String) return String is
     (Synapse.Adapters.File_Bytes.Read (File, 1_000_000));

   --  Runs Body_Test with a home directory that holds Conf_Text as its
   --  synapse.conf, or no file when Conf_Text is `-`.
   procedure Home
     (F : aliased in out Fixture; Dir : Scratch; Conf_Text : String := "-")
   is
   begin
      F.Vars.Set ("HOME", Path (Dir));
      if Conf_Text /= "-" then
         Put (Conf_Path (Dir), Conf_Text);
      end if;
   end Home;

   procedure List_Gives_Every_Setting_As_Json (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Home
        (F, Dir,
         "SYNAPSE_VAULT_DIR=/my/vault" & LF & "SYNAPSE_VAULT_PUSH_EVERY=7" &
         LF);
      F.Vars.Set ("SYNAPSE_VAULT_PUSH_EVERY", "2");
      Assert
        (Run (Env (F), Args ("list", "--format", "json")) = 0, "success");
      declare
         Out_Text : constant String := F.Console.Out_Text;
      begin
         Assert
           (Synapse.Core.JSON.Parse (Out_Text).Ok, "it is JSON: " & Out_Text);
         Assert
           (Has (Out_Text, """format"":""synapse-config/v1"""), "format");
         Assert
           (Has (Out_Text, """key"":""SYNAPSE_VAULT_DIR"""), "the vault");
         Assert
           (Has (Out_Text, """value"":""/my/vault"",""source"":""file"""),
            "its value comes from the file");
         Assert
           (Has
              (Out_Text,
               """value"":""2"",""source"":""environment"",""file"":" &
               """" & Conf_Path (Dir) &
               """,""file_value"":""7"",""shadowed"":true"),
            "a variable wins over the file and says so");
         Assert
           (Has (Out_Text, """default"":""300"""), "a default is reported");
         Assert
           (Has
              (Out_Text,
               """key"":""SYNAPSE_AUTHOR_POOL"",""kind"":""number"""),
            "kinds are named");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end List_Gives_Every_Setting_As_Json;

   procedure List_Says_What_Is_Unset_And_What_Is_Default
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Home (F, Dir);
      Assert (Run (Env (F), Args ("list")) = 0, "success");
      Assert
        (Has (F.Console.Out_Text, "SYNAPSE_VAULT_DIR = (none)  [unset]"),
         "a setting with no value");
      Assert
        (Has
           (F.Console.Out_Text,
            "SYNAPSE_VAULT_PUSH_EVERY = 5  [default]"),
         "a setting at its default");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end List_Says_What_Is_Unset_And_What_Is_Default;

   procedure A_Variable_That_A_Setting_Ignores_Is_Not_A_Source
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Home (F, Dir, "SYNAPSE_AUTHOR_POOL=3" & LF);
      F.Vars.Set ("SYNAPSE_AUTHOR_POOL", "9");
      Assert (Run (Env (F), Args ("list")) = 0, "success");
      Assert
        (Has (F.Console.Out_Text, "SYNAPSE_AUTHOR_POOL = 3  [file in "),
         "only the file carries this one");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Variable_That_A_Setting_Ignores_Is_Not_A_Source;

   procedure Set_Changes_The_File_That_Holds_The_Key
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Home
        (F, Dir,
         "# mine" & LF & "SYNAPSE_VAULT_DIR=/old # keep" & LF &
         "SYNAPSE_VAULT_PUSH_EVERY=9" & LF);
      Assert
        (Run (Env (F), Args ("set", "SYNAPSE_VAULT_DIR", "/new vault")) = 0,
         "success");
      Assert
        (Read (Conf_Path (Dir)) =
         "# mine" & LF & "SYNAPSE_VAULT_DIR=""/new vault"" # keep" & LF &
         "SYNAPSE_VAULT_PUSH_EVERY=9" & LF,
         "only that line changed: " & Read (Conf_Path (Dir)));
      Assert
        (F.Console.Out_Text = Conf_Path (Dir) & LF, "it says which file");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Set_Changes_The_File_That_Holds_The_Key;

   procedure Set_Makes_The_File_When_There_Is_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Home (F, Dir);
      Assert
        (Run (Env (F), Args ("set", "SYNAPSE_VAULT_PUSH_EVERY", "3")) = 0,
         "success");
      Assert
        (Read (Conf_Path (Dir)) = "SYNAPSE_VAULT_PUSH_EVERY=3" & LF,
         "a new file with the one line");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Set_Makes_The_File_When_There_Is_None;

   procedure A_Value_That_Does_Not_Fit_Is_Refused_And_Nothing_Is_Written
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;

      procedure Refused (Key, Value, Part : String) is
         Code : constant Exit_Code := Run (Env (F), Set_Args (Key, Value));
      begin
         Assert (Code = 1, Key & " = " & Value & " is refused");
         Assert (Has (F.Console.Err_Text, Part), "the reason: " & Part);
      end Refused;
   begin
      Home (F, Dir);
      Refused ("SYNAPSE_VAULT_PUSH_EVERY", "many", "a whole number");
      Refused ("SYNAPSE_VAULT_INTEGRATIONS", "disk", "disk");
      Refused ("SYNAPSE_VAULT_INTEGRATIONS", "git,git", "more than once");
      Refused ("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "", "takes a value");
      Refused ("SYNAPSE_VAULT_DIR", "", "takes a path");
      Refused ("SYNAPSE_VAULT_DIR", "two" & LF & "lines", "one line");
      Refused ("NOT_A_SETTING", "1", "unknown setting");
      Assert
        (not Ada.Directories.Exists (Conf_Path (Dir)), "no file was made");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Value_That_Does_Not_Fit_Is_Refused_And_Nothing_Is_Written;

   procedure Set_Says_When_A_Variable_Wins (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Home (F, Dir);
      F.Vars.Set ("SYNAPSE_VAULT_PUSH_EVERY", "2");
      Assert
        (Run (Env (F), Args ("set", "SYNAPSE_VAULT_PUSH_EVERY", "3")) = 0,
         "it is written all the same");
      Assert
        (Has (F.Console.Err_Text, "SYNAPSE_VAULT_PUSH_EVERY is set and wins"),
         "with a note");
      Assert (Has (Read (Conf_Path (Dir)), "=3"), "the file has the value");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Set_Says_When_A_Variable_Wins;

   procedure The_Shipped_Template_Is_Never_Written
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir      : constant Scratch := Make;
      F        : aliased Fixture;
      Template : constant String := Path (Dir, "pkg/synapse.conf.template");
   begin
      Home (F, Dir);
      Put (Template, "SYNAPSE_VAULT_DIR=/from/template" & LF);
      F.Vars.Set ("SYNAPSE_CONTENT_ROOT", Path (Dir, "pkg"));
      Assert
        (Run (Env (F), Args ("set", "SYNAPSE_VAULT_DIR", "/mine")) = 0,
         "success");
      Assert
        (Read (Template) = "SYNAPSE_VAULT_DIR=/from/template" & LF,
         "the template is as it was");
      Assert
        (Read (Conf_Path (Dir)) = "SYNAPSE_VAULT_DIR=/mine" & LF,
         "the value goes in the user's own file");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Shipped_Template_Is_Never_Written;

   procedure Unset_Removes_The_Setting_And_Is_Idempotent
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Home
        (F, Dir,
         "# mine" & LF & "SYNAPSE_VAULT_PUSH_EVERY=9" & LF &
         "SYNAPSE_VAULT_DIR=/v" & LF);
      Assert
        (Run (Env (F), Args ("unset", "SYNAPSE_VAULT_PUSH_EVERY")) = 0,
         "success");
      Assert
        (Read (Conf_Path (Dir)) =
         "# mine" & LF & "SYNAPSE_VAULT_DIR=/v" & LF,
         "the line is gone and the rest is as it was");
      Assert
        (Run (Env (F), Args ("unset", "SYNAPSE_VAULT_PUSH_EVERY")) = 0,
         "again: nothing to do, not an error");
      Assert
        (Run (Env (F), Args ("unset", "NOT_A_SETTING")) = 1, "unknown key");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Unset_Removes_The_Setting_And_Is_Idempotent;

   procedure Wrong_Arguments_Are_A_Usage_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "nothing");
      Assert (Run (Env (F), Args ("frob")) = 2, "unknown subcommand");
      Assert (Run (Env (F), Args ("set", "ONLY_KEY")) = 2, "set needs two");
      Assert (Run (Env (F), Args ("unset")) = 2, "unset needs one");
      Assert (Run (Env (F), Args ("list", "--wat")) = 2, "unknown flag");
      Assert
        (Run (Env (F), Args ("list", "--format", "xml")) = 2,
         "unknown format");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
      Assert (Run (Env (F), Args ("--help")) = 0, "help succeeds");
   end Wrong_Arguments_Are_A_Usage_Error;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Config");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, List_Gives_Every_Setting_As_Json'Access,
         "List gives every setting as JSON");
      Register_Routine
        (T, List_Says_What_Is_Unset_And_What_Is_Default'Access,
         "List says what is unset and what is the default");
      Register_Routine
        (T, A_Variable_That_A_Setting_Ignores_Is_Not_A_Source'Access,
         "A variable that a setting ignores is not a source");
      Register_Routine
        (T, Set_Changes_The_File_That_Holds_The_Key'Access,
         "Set changes the file that holds the key");
      Register_Routine
        (T, Set_Makes_The_File_When_There_Is_None'Access,
         "Set makes the file when there is none");
      Register_Routine
        (T, A_Value_That_Does_Not_Fit_Is_Refused_And_Nothing_Is_Written'Access,
         "A value that does not fit is refused and nothing is written");
      Register_Routine
        (T, Set_Says_When_A_Variable_Wins'Access,
         "Set says when a variable wins");
      Register_Routine
        (T, The_Shipped_Template_Is_Never_Written'Access,
         "The shipped template is never written");
      Register_Routine
        (T, Unset_Removes_The_Setting_And_Is_Idempotent'Access,
         "Unset removes the setting and is idempotent");
      Register_Routine
        (T, Wrong_Arguments_Are_A_Usage_Error'Access,
         "Wrong arguments are a usage error");
   end Register_Tests;

end Synapse.Commands.Config.Tests;
