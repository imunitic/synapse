with Ada.Directories;
with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.JSON;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;

package body Synapse.Commands.Projects.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   function Conf_Path (Dir : Scratch) return String is
     (Path (Dir, ".claude/synapse-projects.conf"));

   procedure Put (File, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (File));
      Synapse.Adapters.File_Bytes.Write (File, Text);
   end Put;

   function Read (File : String) return String is
     (Synapse.Adapters.File_Bytes.Read (File, 1_000_000));

   procedure List_Gives_The_Pairs_As_Text_And_As_Json
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir));
      Put
        (Conf_Path (Dir),
         "# mine" & LF & "widget=wd" & LF & "gadget=gd" & LF);
      Assert (Run (Env (F), Args) = 0, "no arguments lists");
      Assert
        (F.Console.Out_Text = "widget=wd" & LF & "gadget=gd" & LF,
         "the pairs, no comments: " & F.Console.Out_Text);
      G.Vars.Set ("HOME", Path (Dir));
      Assert
        (Run (Env (G), Args ("list", "--format", "json")) = 0, "json");
      declare
         Text : constant String := G.Console.Out_Text;
      begin
         Assert (Synapse.Core.JSON.Parse (Text).Ok, "it is JSON: " & Text);
         Assert (Has (Text, """format"":""synapse-projects/v1"""), "format");
         Assert (Has (Text, """name"":""widget"""), "a name: " & Text);
         Assert (Has (Text, """prefix"":""gd"""), "a prefix");
         Assert (Has (Text, Conf_Path (Dir)), "the file it read");
      end;
      Remove (Dir);
   end List_Gives_The_Pairs_As_Text_And_As_Json;

   procedure List_Of_No_File_Is_Empty (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir));
      Assert (Run (Env (F), Args ("list")) = 0, "success");
      Assert (F.Console.Out_Text = "", "nothing");
      Assert
        (not Ada.Directories.Exists (Conf_Path (Dir)),
         "a listing makes no file");
      Remove (Dir);
   end List_Of_No_File_Is_Empty;

   procedure Add_Writes_A_Last_Line_And_Names_The_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir));
      Put (Conf_Path (Dir), "# mine" & LF & "widget=wd");
      Assert (Run (Env (F), Args ("add", "gadget", "gd")) = 0, "added");
      Assert
        (F.Console.Out_Text = Conf_Path (Dir) & LF,
         "the file is named: " & F.Console.Out_Text);
      Assert
        (Read (Conf_Path (Dir)) = "# mine" & LF & "widget=wd" & LF &
         "gadget=gd" & LF,
         "a line is added, the rest is as it was");
      Remove (Dir);
   end Add_Writes_A_Last_Line_And_Names_The_File;

   procedure Add_Makes_The_File_When_There_Is_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir));
      Assert (Run (Env (F), Args ("add", "widget", "wd")) = 0, "added");
      Assert
        (Read (Conf_Path (Dir)) = "widget=wd" & LF, "a file with the line");
      Remove (Dir);
   end Add_Makes_The_File_When_There_Is_None;

   procedure Add_Refuses_What_The_Rules_Refuse (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir));
      Put (Conf_Path (Dir), "widget=wd" & LF);
      Assert
        (Run (Env (F), Args ("add", "widget", "xx")) = 1, "a name in use");
      Assert (Has (F.Console.Err_Text, "already a project"), "and says why");
      Assert (Run (Env (F), Args ("add", "Bad", "bd")) = 1, "a bad name");
      Assert
        (Read (Conf_Path (Dir)) = "widget=wd" & LF,
         "a refusal leaves the file as it was");
      Remove (Dir);
   end Add_Refuses_What_The_Rules_Refuse;

   procedure Add_Without_A_Home_Says_So (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("add", "widget", "wd")) = 1, "refused");
      Assert (Has (F.Console.Err_Text, "no home directory"), "and says why");
   end Add_Without_A_Home_Says_So;

   procedure Wrong_Arguments_Are_A_Usage_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert
        (Run (Env (F), Args ("add", "widget")) = 2, "a prefix is missing");
      Assert (Run (Env (F), Args ("remove", "widget")) = 2, "no such action");
      Assert
        (Run (Env (F), Args ("list", "--format", "yaml")) = 2,
         "no such format");
      Assert (Has (F.Console.Err_Text, "usage: synapse projects"), "usage");
   end Wrong_Arguments_Are_A_Usage_Error;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Projects");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, List_Gives_The_Pairs_As_Text_And_As_Json'Access,
         "List gives the pairs as text and as json");
      Register_Routine
        (T, List_Of_No_File_Is_Empty'Access, "List of no file is empty");
      Register_Routine
        (T, Add_Writes_A_Last_Line_And_Names_The_File'Access,
         "Add writes a last line and names the file");
      Register_Routine
        (T, Add_Makes_The_File_When_There_Is_None'Access,
         "Add makes the file when there is none");
      Register_Routine
        (T, Add_Refuses_What_The_Rules_Refuse'Access,
         "Add refuses what the rules refuse");
      Register_Routine
        (T, Add_Without_A_Home_Says_So'Access,
         "Add without a home says so");
      Register_Routine
        (T, Wrong_Arguments_Are_A_Usage_Error'Access,
         "Wrong arguments are a usage error");
   end Register_Tests;

end Synapse.Commands.Projects.Tests;
