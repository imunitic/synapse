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

package body Synapse.Commands.Comments_Sweep.Tests is

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

   procedure Sweep_Checks_Every_File_And_Reports_The_Changed_Ones
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Setup (F, Dir);
      Assert
        (Sweep (Env (F), Repo (Dir), False) = 0,
         "success: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text,
            "-- src/a.ext --" & LF & "Docstring staleness") >
         0,
         "the changed file: " & F.Console.Out_Text);
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "-- src/b.ext --") = 0,
         "not the quiet one");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text,
            "comments-sweep: 3 files checked, 1 changed, 0 evicted" & LF) >
         0,
         "the totals: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Sweep_Checks_Every_File_And_Reports_The_Changed_Ones;

   procedure Sweep_Counts_A_Vanished_Docstring_As_Evicted
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Setup (F, Dir);
      Assert (Sweep (Env (F), Repo (Dir), False) = 0, "first");
      F.Extractors.Pairs.Include (Source_Text, Found_None);
      F.Console.Clear;
      Assert (Sweep (Env (F), Repo (Dir), False) = 0, "second");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text,
            "comments-sweep: 3 files checked, 0 changed, 1 evicted" & LF) >
         0,
         "the totals: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Sweep_Counts_A_Vanished_Docstring_As_Evicted;

   procedure Sweep_When_Off_Still_Counts_The_Files
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "");
      Assert (Sweep (Env (F), Repo (Dir), False) = 0, "success");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text,
            "comments-sweep: 3 files checked, 0 changed, 0 evicted" & LF) >
         0,
         "the totals: " & F.Console.Out_Text);
      Assert (F.Extractors.Asked = 0, "nothing parsed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Sweep_When_Off_Still_Counts_The_Files;

   procedure Sweep_Outside_A_Repository_Fails (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      Away : constant Scratch := Make_Outside_Git;
      F    : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Ada.Directories.Create_Path (Path (Away, "plain"));
      Assert
        (Sweep (Env (F), Path (Away, "plain"), False) = 1, "no repository");
      Assert
        (F.Console.Err_Text =
         "synapse-comments-sweep: not inside a git repo" & LF,
         "says so: " & F.Console.Err_Text);
      Remove (Away);
   end Sweep_Outside_A_Repository_Fails;

   procedure Sweep_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
      G   : Guard;
   begin
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("-h")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text,
            "usage: synapse comments-sweep [--reenumerate]") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Sweep_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Comments_Sweep");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Sweep_Checks_Every_File_And_Reports_The_Changed_Ones'Access,
         "Sweep checks every file and reports the changed ones");
      Register_Routine
        (T, Sweep_Counts_A_Vanished_Docstring_As_Evicted'Access,
         "Sweep counts a vanished docstring as evicted");
      Register_Routine
        (T, Sweep_When_Off_Still_Counts_The_Files'Access,
         "Sweep when off still counts the files");
      Register_Routine
        (T, Sweep_Outside_A_Repository_Fails'Access,
         "Sweep outside a repository fails");
      Register_Routine (T, Sweep_Arguments'Access, "Sweep arguments");
   end Register_Tests;

end Synapse.Commands.Comments_Sweep.Tests;
