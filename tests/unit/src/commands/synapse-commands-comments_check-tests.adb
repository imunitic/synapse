with Ada.Finalization;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Ports.Docstring_Pairs;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with AUnit.Assertions;

package body Synapse.Commands.Comments_Check.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;

   package Pairs renames Synapse.Ports.Docstring_Pairs;

   LF : constant Character := Character'Val (10);

   Source_Text : constant String := "// Starts it." & LF & "fn start()" & LF;

   function Pair
     (Name, Doc : String; First : Positive := 1) return Pairs.Pair is
     (Kind               => To_Unbounded_String ("function"),
      Name               => To_Unbounded_String (Name),
      Docstring_Text     => To_Unbounded_String (Doc),
      Decl_Text => To_Unbounded_String (Name), Docstring_Start_Line => First,
      Docstring_End_Line => First, Decl_Start_Line => First + 1,
      Decl_End_Line      => First + 1);

   function Found (Item : Pairs.Pair) return Pairs.Finding is
      Items : Pairs.Pair_Vectors.Vector;
   begin
      Items.Append (Item);
      return (Kind => Pairs.Found, Pairs => Items);
   end Found;

   function Found_None return Pairs.Finding is
     (Kind => Pairs.Found, Pairs => Pairs.Pair_Vectors.Empty_Vector);

   procedure Setup (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Work (F, Dir);
      F.Vars.Set ("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "1");
      Put_File (Dir, "src/a.ext", Source_Text);
      Put_File (Dir, "src/b.ext", "plain" & LF);
      Put_File (Dir, "notes.md", "text" & LF);
      Commit_All (Dir);
      F.Extractors.Pairs.Include
        (Source_Text, Found (Pair ("fn start()", "Starts it.")));
   end Setup;

   function Within (Dir : Scratch) return Boolean is
   begin
      Ada.Directories.Set_Directory (Repo (Dir));
      return True;
   end Within;

   Home : constant String := Ada.Directories.Current_Directory;

   --  Puts the working directory back however a test ends.
   type Guard is
   limited new Ada.Finalization.Limited_Controlled with null record;

   overriding procedure Finalize (G : in out Guard) is
      pragma Unreferenced (G);
   begin
      Ada.Directories.Set_Directory (Home);
   end Finalize;

   procedure Check_Reports_A_New_Docstring_Once (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Setup (F, Dir);
      if Within (Dir) then
         Assert
           (Run (Env (F), Args ("src/a.ext")) = 0,
            "success: " & F.Console.Err_Text);
         Assert
           (F.Console.Out_Text =
            "Docstring staleness (Tier 2): the following changed since last checked:" &
            LF &
            "- `fn start()` (function): new or changed since last checked" &
            LF,
            "the report: " & F.Console.Out_Text);
         F.Console.Clear;
         Assert (Run (Env (F), Args ("src/a.ext")) = 0, "again");
         Assert (F.Console.Out_Text = "", "nothing is new the second time");
      end if;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Reports_A_New_Docstring_Once;

   procedure Check_Reports_A_Changed_Docstring_And_Its_Tell
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Setup (F, Dir);
      if Within (Dir) then
         Assert (Run (Env (F), Args ("src/a.ext")) = 0, "first");
         F.Extractors.Pairs.Include
           (Source_Text,
            Found (Pair ("fn start()", "Starts it, as it used to.")));
         F.Console.Clear;
         Assert (Run (Env (F), Args ("src/a.ext")) = 0, "second");
         Assert
           (F.Console.Out_Text =
            "Docstring staleness (Tier 2): the following changed since last checked:" &
            LF &
            "- `fn start()` (function): new or changed since last checked" &
            LF & "  historian-plague tell: ""used to""" & LF,
            "the report: " & F.Console.Out_Text);
      end if;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Reports_A_Changed_Docstring_And_Its_Tell;

   procedure Check_Appends_The_Style_Rubric (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Setup (F, Dir);
      F.Vars.Set ("XDG_CONFIG_HOME", Path (Dir, "cfg"));
      Ada.Directories.Create_Path (Path (Dir, "cfg/synapse"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "cfg/synapse/synapse-comment-style-rules.conf"),
         "Be kind." & LF);
      if Within (Dir) then
         Assert (Run (Env (F), Args ("src/a.ext")) = 0, "success");
         Assert
           (Ada.Strings.Fixed.Index
              (F.Console.Out_Text,
               LF &
               "Style rubric to judge the affected docstring(s) against:" &
               LF & "Be kind." & LF) >
            0,
            "the rubric follows: " & F.Console.Out_Text);
      end if;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Appends_The_Style_Rubric;

   procedure Check_Is_Silent_When_There_Is_Nothing_To_Check
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Setup (F, Dir);
      if Within (Dir) then
         Assert
           (Run (Env (F), Args ("src/b.ext")) = 0, "no grammar for the text");
         Assert
           (Run (Env (F), Args ("notes.md")) = 0,
            "no grammar for the extension");
         Assert
           (Run (Env (F), Args ("src/gone.ext")) = 0,
            "a file that is not there");
         Assert
           (F.Console.Out_Text = "" and then F.Console.Err_Text = "",
            "nothing said");
         F.Vars.Set ("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "");
         Assert (Run (Env (F), Args ("src/a.ext")) = 0, "off");
         Assert (F.Console.Out_Text = "", "nothing said when it is off");
      end if;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Is_Silent_When_There_Is_Nothing_To_Check;

   procedure Check_Asks_Nothing_Of_The_Grammar_When_It_Is_Off
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "");
      if Within (Dir) then
         Assert (Run (Env (F), Args ("src/a.ext")) = 0, "off");
         Assert (F.Extractors.Asked = 0, "the file was not parsed");
         F.Vars.Set ("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "1");
         Assert (Run (Env (F), Args ("src/a.ext")) = 0, "on");
         Assert (F.Extractors.Asked = 1, "now it was");
      end if;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Asks_Nothing_Of_The_Grammar_When_It_Is_Off;

   procedure Check_Fails_On_A_File_The_Grammar_Cannot_Parse
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Setup (F, Dir);
      F.Extractors.Pairs.Include (Source_Text, (Kind => Pairs.Failed));
      if Within (Dir) then
         Assert (Run (Env (F), Args ("src/a.ext")) = 1, "fails");
         Assert
           (F.Console.Err_Text =
            "synapse-comments-check: could not parse src/a.ext" & LF,
            "says so: " & F.Console.Err_Text);
      end if;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Fails_On_A_File_The_Grammar_Cannot_Parse;

   procedure Check_Wants_A_Path_Inside_The_Repository
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Setup (F, Dir);
      if Within (Dir) then
         Assert (Run (Env (F), Args ("../elsewhere.ext")) = 1, "outside");
         Assert
           (Ada.Strings.Fixed.Index
              (F.Console.Err_Text,
               "synapse-comments-check: ../elsewhere.ext is not inside ") =
            1,
            "says so: " & F.Console.Err_Text);
      end if;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Wants_A_Path_Inside_The_Repository;

   procedure Check_Outside_A_Repository_Fails (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      Away : constant Scratch := Make_Outside_Git;
      F    : aliased Fixture;
      G    : Guard;
   begin
      Use_Work (F, Dir);
      Ada.Directories.Create_Path (Path (Away, "plain"));
      Ada.Directories.Set_Directory (Path (Away, "plain"));
      Assert (Run (Env (F), Args ("a.ext")) = 1, "no repository");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text,
            "synapse-comments-check: not inside a git repo") =
         1,
         "says so: " & F.Console.Err_Text);
      Remove (Away);
   end Check_Outside_A_Repository_Fails;

   procedure Check_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Assert (Run (Env (F), Args) = 2, "a path is needed");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse comments-check <path>") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Check_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Comments_Check");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Check_Reports_A_New_Docstring_Once'Access,
         "Check reports a new docstring once");
      Register_Routine
        (T, Check_Reports_A_Changed_Docstring_And_Its_Tell'Access,
         "Check reports a changed docstring and its tell");
      Register_Routine
        (T, Check_Appends_The_Style_Rubric'Access,
         "Check appends the style rubric");
      Register_Routine
        (T, Check_Is_Silent_When_There_Is_Nothing_To_Check'Access,
         "Check is silent when there is nothing to check");
      Register_Routine
        (T, Check_Asks_Nothing_Of_The_Grammar_When_It_Is_Off'Access,
         "Check asks nothing of the grammar when it is off");
      Register_Routine
        (T, Check_Fails_On_A_File_The_Grammar_Cannot_Parse'Access,
         "Check fails on a file the grammar cannot parse");
      Register_Routine
        (T, Check_Wants_A_Path_Inside_The_Repository'Access,
         "Check wants a path inside the repository");
      Register_Routine
        (T, Check_Outside_A_Repository_Fails'Access,
         "Check outside a repository fails");
      Register_Routine (T, Check_Arguments'Access, "Check arguments");
   end Register_Tests;

end Synapse.Commands.Comments_Check.Tests;
