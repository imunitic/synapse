with Synapse.Commands.Vault_Usage;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Vault_Read.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);

   Note : constant String :=
     "---" & LF & "title: ""A""" & LF & "tags: [x]" & LF & "---" & LF & "# A" &
     LF & LF & "Intro ^top" & LF & LF & "## Sub" & LF & "text" & LF;

   procedure Read_Prints_The_Note_Exactly_As_Stored
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "a/b.md", Note);
      Assert (Run_Read (Env (F), Args ("a/b.md")) = 0, "success");
      Assert (F.Console.Out_Text = Note, "the whole text, nothing added");
      Assert (F.Console.Err_Text = "", "nothing on standard error");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Read_Prints_The_Note_Exactly_As_Stored;

   procedure Read_Of_A_Missing_Note_Fails_And_Names_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Read (Env (F), Args ("gone.md")) = 1, "code 1");
      Assert (F.Console.Out_Text = "", "nothing printed");
      Assert
        (F.Console.Err_Text = "synapse-vault: no such note: gone.md" & LF,
         "the message: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Read_Of_A_Missing_Note_Fails_And_Names_It;

   procedure Read_Refuses_A_Path_That_Leaves_The_Vault
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Read (Env (F), Args ("../x.md")) = 1, "code 1");
      Assert
        (F.Console.Err_Text = "synapse-vault: read failed" & LF,
         "the message: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Read_Refuses_A_Path_That_Leaves_The_Vault;

   procedure Read_With_No_Vault_Says_So (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Assert (Run_Read (Env (F), Args ("a.md")) = 1, "code 1");
      Assert
        (F.Console.Err_Text = "synapse-vault: no vault" & LF,
         "the message: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Read_With_No_Vault_Says_So;

   procedure Read_Arguments_That_Are_Not_One_Path_Are_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Read (Env (F), Args) = 2, "none");
      Assert (Run_Read (Env (F), Args ("a.md", "b.md")) = 2, "two");
      Assert
        (F.Console.Err_Text = Vault_Usage.Read & Vault_Usage.Read,
         "the usage each time");
      F.Console.Clear;
      Assert (Run_Read (Env (F), Args ("--help")) = 0, "help succeeds");
      Assert (F.Console.Err_Text = Vault_Usage.Read, "help prints the usage");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Read_Arguments_That_Are_Not_One_Path_Are_A_Usage_Error;

   procedure List_Prints_Every_Note_Path_In_Order (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "z.md", "z");
      Put (Dir, "a/b.md", "b");
      Put (Dir, "a.md", "a");
      Assert (Run_List (Env (F), Args) = 0, "success");
      Assert
        (F.Console.Out_Text = "a.md" & LF & "a/b.md" & LF & "z.md" & LF,
         "sorted, one per line: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end List_Prints_Every_Note_Path_In_Order;

   procedure List_Of_An_Empty_Vault_Prints_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_List (Env (F), Args) = 0, "success");
      Assert (F.Console.Out_Text = "", "nothing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end List_Of_An_Empty_Vault_Prints_Nothing;

   procedure List_Takes_No_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_List (Env (F), Args ("x")) = 2, "an argument");
      Assert (F.Console.Err_Text = Vault_Usage.List, "the usage");
      F.Console.Clear;
      Assert (Run_List (Env (F), Args ("-h")) = 0, "help");
      Assert (F.Console.Err_Text = Vault_Usage.List, "the usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end List_Takes_No_Arguments;

   procedure Doc_Map_Lists_Headings_Blocks_And_Keys
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "n.md", Note);
      Assert (Run_Doc_Map (Env (F), Args ("n.md")) = 0, "success");
      Assert
        (F.Console.Out_Text =
         "heading" & ASCII.HT & "A" & LF & "heading" & ASCII.HT & "A::Sub" &
         LF & "block" & ASCII.HT & "top" & LF & "frontmatter" & ASCII.HT &
         "title" & LF & "frontmatter" & ASCII.HT & "tags" & LF,
         "headings, blocks, keys: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doc_Map_Lists_Headings_Blocks_And_Keys;

   procedure Doc_Map_Of_A_Missing_Note_Fails (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Doc_Map (Env (F), Args ("gone.md")) = 1, "code 1");
      Assert
        (F.Console.Err_Text = "synapse-vault: no such note: gone.md" & LF,
         "the message");
      Assert (Run_Doc_Map (Env (F), Args) = 2, "no path is a usage error");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doc_Map_Of_A_Missing_Note_Fails;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Vault_Read");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Read_Prints_The_Note_Exactly_As_Stored'Access,
         "Read prints the note exactly as stored");
      Register_Routine
        (T, Read_Of_A_Missing_Note_Fails_And_Names_It'Access,
         "Read of a missing note fails and names it");
      Register_Routine
        (T, Read_Refuses_A_Path_That_Leaves_The_Vault'Access,
         "Read refuses a path that leaves the vault");
      Register_Routine
        (T, Read_With_No_Vault_Says_So'Access, "Read with no vault says so");
      Register_Routine
        (T, Read_Arguments_That_Are_Not_One_Path_Are_A_Usage_Error'Access,
         "Read arguments that are not one path are a usage error");
      Register_Routine
        (T, List_Prints_Every_Note_Path_In_Order'Access,
         "List prints every note path in order");
      Register_Routine
        (T, List_Of_An_Empty_Vault_Prints_Nothing'Access,
         "List of an empty vault prints nothing");
      Register_Routine
        (T, List_Takes_No_Arguments'Access, "List takes no arguments");
      Register_Routine
        (T, Doc_Map_Lists_Headings_Blocks_And_Keys'Access,
         "Doc map lists headings blocks and keys");
      Register_Routine
        (T, Doc_Map_Of_A_Missing_Note_Fails'Access,
         "Doc map of a missing note fails");
   end Register_Tests;

end Synapse.Commands.Vault_Read.Tests;
