with Synapse.Commands.Vault_Usage;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Vault_Links.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   --  a links b, a gap, and a name two notes share; b links back; a lone
   --  note; a note with no links.
   procedure Fill (Dir : Scratch) is
   begin
      Put
        (Dir, "a.md", "See [[b]] and [[gap]] and [[dup]], [[b]] again." & LF);
      Put (Dir, "b.md", "back to [[a]]" & LF);
      Put (Dir, "x/dup.md", "one" & LF);
      Put (Dir, "y/dup.md", "two" & LF);
      Put (Dir, "lone.md", "no links" & LF);
   end Fill;

   procedure Backlinks_Counts_The_Links_Of_Each_Linking_Note
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run_Backlinks (Env (F), Args ("b.md")) = 0, "success");
      Assert
        (F.Console.Out_Text = "a.md" & HT & "2" & LF,
         "one row, two links: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Backlinks_Counts_The_Links_Of_Each_Linking_Note;

   procedure Backlinks_Of_An_Unlinked_Note_Print_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run_Backlinks (Env (F), Args ("lone.md")) = 0, "success");
      Assert (F.Console.Out_Text = "", "nothing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Backlinks_Of_An_Unlinked_Note_Print_Nothing;

   procedure Links_Lists_Each_Target_Once (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run_Links (Env (F), Args ("a.md")) = 0, "success");
      Assert
        (F.Console.Out_Text = "b.md" & LF & "x/dup.md" & LF & "y/dup.md" & LF,
         "the notes it reaches: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Links_Lists_Each_Target_Once;

   procedure Unresolved_Prints_A_Row_For_Each_Source_And_Target
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run_Unresolved (Env (F), Args) = 0, "success");
      Assert
        (F.Console.Out_Text = "a.md" & HT & "gap" & HT & "1" & LF,
         "the broken link: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Unresolved_Prints_A_Row_For_Each_Source_And_Target;

   procedure Orphans_And_Dead_Ends_List_The_Notes (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run_Orphans (Env (F), Args) = 0, "orphans succeed");
      Assert
        (F.Console.Out_Text = "lone.md" & LF,
         "nothing links to the lone note: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert (Run_Deadends (Env (F), Args) = 0, "dead ends succeed");
      Assert
        (F.Console.Out_Text =
         "lone.md" & LF & "x/dup.md" & LF & "y/dup.md" & LF,
         "no link leads anywhere: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Orphans_And_Dead_Ends_List_The_Notes;

   procedure Ambiguous_Prints_A_Row_For_Each_Source_And_Candidate
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Fill (Dir);
      Assert (Run_Ambiguous (Env (F), Args) = 0, "success");
      Assert
        (F.Console.Out_Text =
         "a.md" & HT & "dup" & HT & "x/dup.md" & HT & "1" & LF & "a.md" & HT &
         "dup" & HT & "y/dup.md" & HT & "1" & LF,
         "both candidates: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Ambiguous_Prints_A_Row_For_Each_Source_And_Candidate;

   procedure A_Command_That_Names_A_Note_Needs_Exactly_One_Path
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Backlinks (Env (F), Args) = 2, "backlinks, none");
      Assert (Run_Links (Env (F), Args ("a", "b")) = 2, "links, two");
      Assert
        (F.Console.Err_Text = Vault_Usage.Backlinks & Vault_Usage.Links,
         "each prints its own usage");
      F.Console.Clear;
      Assert (Run_Backlinks (Env (F), Args ("--help")) = 0, "help");
      Assert (F.Console.Err_Text = Vault_Usage.Backlinks, "its usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Command_That_Names_A_Note_Needs_Exactly_One_Path;

   procedure A_Command_That_Names_No_Note_Takes_No_Arguments
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Unresolved (Env (F), Args ("x")) = 2, "unresolved");
      Assert (Run_Orphans (Env (F), Args ("x")) = 2, "orphans");
      Assert (Run_Deadends (Env (F), Args ("x")) = 2, "dead ends");
      Assert (Run_Ambiguous (Env (F), Args ("x")) = 2, "ambiguous");
      Assert
        (F.Console.Err_Text =
         Vault_Usage.Unresolved & Vault_Usage.Orphans & Vault_Usage.Deadends &
         Vault_Usage.Ambiguous,
         "each prints its own usage");
      F.Console.Clear;
      Assert (Run_Ambiguous (Env (F), Args ("-h")) = 0, "help");
      Assert (F.Console.Err_Text = Vault_Usage.Ambiguous, "its usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Command_That_Names_No_Note_Takes_No_Arguments;

   procedure Every_Link_Command_Needs_A_Vault (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Assert (Run_Backlinks (Env (F), Args ("a")) = 1, "backlinks");
      Assert (Run_Links (Env (F), Args ("a")) = 1, "links");
      Assert (Run_Unresolved (Env (F), Args) = 1, "unresolved");
      Assert (Run_Orphans (Env (F), Args) = 1, "orphans");
      Assert (Run_Deadends (Env (F), Args) = 1, "dead ends");
      Assert (Run_Ambiguous (Env (F), Args) = 1, "ambiguous");
      Assert (F.Console.Out_Text = "", "nothing printed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Every_Link_Command_Needs_A_Vault;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Vault_Links");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Backlinks_Counts_The_Links_Of_Each_Linking_Note'Access,
         "Backlinks counts the links of each linking note");
      Register_Routine
        (T, Backlinks_Of_An_Unlinked_Note_Print_Nothing'Access,
         "Backlinks of an unlinked note print nothing");
      Register_Routine
        (T, Links_Lists_Each_Target_Once'Access,
         "Links lists each target once");
      Register_Routine
        (T, Unresolved_Prints_A_Row_For_Each_Source_And_Target'Access,
         "Unresolved prints a row for each source and target");
      Register_Routine
        (T, Orphans_And_Dead_Ends_List_The_Notes'Access,
         "Orphans and dead ends list the notes");
      Register_Routine
        (T, Ambiguous_Prints_A_Row_For_Each_Source_And_Candidate'Access,
         "Ambiguous prints a row for each source and candidate");
      Register_Routine
        (T, A_Command_That_Names_A_Note_Needs_Exactly_One_Path'Access,
         "A command that names a note needs exactly one path");
      Register_Routine
        (T, A_Command_That_Names_No_Note_Takes_No_Arguments'Access,
         "A command that names no note takes no arguments");
      Register_Routine
        (T, Every_Link_Command_Needs_A_Vault'Access,
         "Every link command needs a vault");
   end Register_Tests;

end Synapse.Commands.Vault_Links.Tests;
