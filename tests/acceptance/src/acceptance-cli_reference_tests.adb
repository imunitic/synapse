with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Acceptance.Fixtures;
with Synapse.Core.Text_Lists;

package body Acceptance.Cli_Reference_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Generator : constant String :=
     Checkout & "/docs/synapse/generate-cli-reference.sh";

   Cli_Md : constant String := Checkout & "/docs/synapse/cli.md";

   function Run_Generator
     (F : Fixture; Cwd : String; Script : String; Flag : String := "")
      return Result is
     (Run (F, "bash", Args (Script, Flag), Cwd));

   procedure The_Committed_Reference_Is_Up_To_Date
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      --  The generator defaults to `bin/synapse`; pointing it at the programs
      --  this suite tests leaves nothing implicit.
      Set_Env (F, "SYNAPSE_BIN", Synapse_Bin);
      Set_Env (F, "SYNAPSE_HOOK_BIN", Hook_Bin);
      declare
         R : constant Result :=
           Run_Generator (F, Checkout, Generator, "--check");
      begin
         Assert_Exit (R, 0, "generate-cli-reference --check");
         Assert_Contains (Both (R), "up to date", "says so");
      end;
   end The_Committed_Reference_Is_Up_To_Date;

   --  Simulated by editing the committed document and not the program: a
   --  program with a different help would need a rebuild inside a test.
   procedure Check_Fails_When_The_Document_Has_Moved_On
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F      : Fixture;
      Docs   : constant String := Root (F) & "/docs";
      Script : constant String := Docs & "/generate-cli-reference.sh";
   begin
      Set_Env (F, "SYNAPSE_BIN", Synapse_Fake_Bin);
      Set_Env (F, "SYNAPSE_HOOK_BIN", Hook_Bin);
      Write_File (Docs & "/cli.md", Read_File (Cli_Md));
      Write_File (Script, Read_File (Generator));
      Make_Executable (Script);

      Assert_Exit
        (Run_Generator (F, Docs, "./generate-cli-reference.sh", "--check"), 0,
         "as copied");

      Write_File
        (Docs & "/cli.md",
         Read_File (Docs & "/cli.md") & "a line the programs never print" &
         LF);
      declare
         R : constant Result :=
           Run_Generator (F, Docs, "./generate-cli-reference.sh", "--check");
      begin
         Assert_Exit (R, 1, "after the edit");
         Assert_Contains (Both (R), "out of date", "says so");
      end;
   end Check_Fails_When_The_Document_Has_Moved_On;

   function Is_Lower (C : Character) return Boolean is (C in 'a' .. 'z');

   procedure Every_Subcommand_Has_A_Section_And_No_Block_Is_Empty
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F    : Fixture;
      Doc  : constant String := Read_File (Cli_Md);
      Help : constant Result := Run_Fake (F, "--help");
      Seen : Synapse.Core.Text_Lists.Set;
   begin
      for Item of Lines
        (To_String (Help.Output) & LF & To_String (Help.Errors))
      loop
         declare
            Line : constant String := To_String (Item);
         begin
            if Starts_With (Line, "  ") and then Line'Length > 2
              and then Is_Lower (Line (Line'First + 2))
            then
               declare
                  Rest : constant String := Line (Line'First + 2 .. Line'Last);
                  Stop : Natural         := Rest'First + 1;
               begin
                  while Stop <= Rest'Last
                    and then (Is_Lower (Rest (Stop)) or else Rest (Stop) = '-')
                  loop
                     Stop := Stop + 1;
                  end loop;
                  if Stop <= Rest'Last and then Rest (Stop) = ' '
                    and then not Seen.Contains (Rest (Rest'First .. Stop - 1))
                  then
                     Seen.Include (Rest (Rest'First .. Stop - 1));
                     Assert
                       (Has_Line
                          (Doc,
                           "### synapse " & Rest (Rest'First .. Stop - 1)),
                        "cli.md has no section for " &
                        Rest (Rest'First .. Stop - 1));
                  end if;
               end;
            end if;
         end;
      end loop;
      Assert (not Seen.Is_Empty, "the help lists subcommands");
      Assert (Has_Line (Doc, "## synapse-hook"), "cli.md covers the hook");

      --  An opening fence followed at once by its closing fence is an empty
      --  block.
      declare
         Previous : Unbounded_String;
      begin
         for Item of Lines (Doc) loop
            Assert
              (not
               (To_String (Item) = "```"
                and then To_String (Previous) = "```"),
               "an empty fenced block");
            Previous := Item;
         end loop;
      end;
   end Every_Subcommand_Has_A_Section_And_No_Block_Is_Empty;

   procedure The_Generated_Help_Is_What_The_Program_Prints
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F    : Fixture;
      R    : constant Result := Run_Fake (F, "query", "--help");
      Last : Unbounded_String;
   begin
      for Item of Lines (To_String (R.Output) & LF & To_String (R.Errors)) loop
         if Trim (To_String (Item)) /= "" then
            Last := Item;
         end if;
      end loop;
      Assert (Length (Last) > 0, "query --help printed something");
      Assert_Contains (Read_File (Cli_Md), To_String (Last), "cli.md");
   end The_Generated_Help_Is_What_The_Program_Prints;

   procedure A_Help_That_Needs_An_Environment_Fails_The_Generator
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F     : Fixture;
      Needy : constant String := Root (F) & "/needy";
   begin
      Write_File
        (Needy,
         "#!/bin/bash" & LF & "[ -n ""${SOME_REQUIRED_VAR:-}"" ] || exit 1" &
         LF & "echo ""usage: needy""" & LF);
      Make_Executable (Needy);
      Set_Env (F, "SYNAPSE_BIN", Needy);
      Set_Env (F, "SYNAPSE_HOOK_BIN", Needy);
      declare
         R : constant Result := Run_Generator (F, Root (F), Generator);
      begin
         Assert_Exit (R, 1, "generator");
         Assert_Contains (Both (R), "without an environment", "says why");
      end;
   end A_Help_That_Needs_An_Environment_Fails_The_Generator;

   procedure A_Bad_Flag_Exits_2_With_Usage (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
      R : constant Result :=
        Run_Generator (F, Checkout, Generator, "--nonsense");
   begin
      Assert_Exit (R, 2, "generator --nonsense");
      Assert_Contains (Both (R), "Usage:", "usage");
   end A_Bad_Flag_Exits_2_With_Usage;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: the generated CLI reference");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Committed_Reference_Is_Up_To_Date'Access,
         "the committed docs/synapse/cli.md is up to date");
      Register_Routine
        (T, Check_Fails_When_The_Document_Has_Moved_On'Access,
         "--check fails when the document has moved on");
      Register_Routine
        (T, Every_Subcommand_Has_A_Section_And_No_Block_Is_Empty'Access,
         "every subcommand has a section, and no fenced block is empty");
      Register_Routine
        (T, The_Generated_Help_Is_What_The_Program_Prints'Access,
         "the generated help is what the program prints");
      Register_Routine
        (T, A_Help_That_Needs_An_Environment_Fails_The_Generator'Access,
         "a --help that needs an environment fails the generator");
      Register_Routine
        (T, A_Bad_Flag_Exits_2_With_Usage'Access,
         "a bad flag exits 2 with usage");
   end Register_Tests;

end Acceptance.Cli_Reference_Tests;
