with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Adapters.File_Bytes;
with Synapse.Commands.Vault_Usage;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Vault_Write.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);

   Note : constant String :=
     "---" & LF & "title: ""A""" & LF & "---" & LF & "# A" & LF & LF &
     "## Sub" & LF & "old" & LF & LF & "## Other ^blk" & LF & "keep" & LF;

   function Read (Dir : Scratch; Name : String) return String is
     (Adapters.File_Bytes.Read (Path (Dir, "vault/" & Name), 1_000_000));

   procedure Write_Stores_The_Note_And_Prints_Its_Path
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      F.Console.Set_Stdin (Note);
      Assert (Run_Write (Env (F), Args ("a/b.md")) = 0, "success");
      Assert (F.Console.Out_Text = "a/b.md" & LF, "the path");
      Assert (Read (Dir, "a/b.md") = Note, "the text, exactly");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Stores_The_Note_And_Prints_Its_Path;

   procedure Write_Replaces_What_Was_There (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "n.md", "old");
      F.Console.Set_Stdin ("new");
      Assert (Run_Write (Env (F), Args ("n.md")) = 0, "success");
      Assert (Read (Dir, "n.md") = "new", "replaced");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Replaces_What_Was_There;

   procedure Write_Refuses_A_Path_That_Leaves_The_Vault
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      F.Console.Set_Stdin ("x");
      Assert (Run_Write (Env (F), Args ("../out.md")) = 1, "code 1");
      Assert
        (F.Console.Err_Text = "synapse-vault: write failed" & LF,
         "the message: " & F.Console.Err_Text);
      Assert (F.Console.Out_Text = "", "nothing printed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Refuses_A_Path_That_Leaves_The_Vault;

   procedure Write_Reports_A_Note_Its_Schema_Rejects
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put_Schema
        (Dir, "t-note/v1",
         "schema: synapse-note-schema/v1" & LF & "id: t-note/v1" & LF &
         "frontmatter:" & LF & "  fields:" & LF & "    title:" & LF &
         "      type: string" & LF & "      required: true" & LF & "body:" &
         LF & "  h1:" & LF & "    required: false" & LF & "checks:" & LF &
         "  - eq:" & LF & "      - var: filename.stem" & LF &
         "      - var: filename.stem" & LF);
      F.Console.Set_Stdin
        ("---" & LF & "schema: t-note/v1" & LF & "---" & LF & "# X" & LF);
      Assert (Run_Write (Env (F), Args ("x.md")) = 1, "code 1");
      Assert
        (F.Console.Err_Text =
         "synapse-vault: write rejected (422): frontmatter.title: required " &
         "field is missing" & LF,
         "the status and reason: " & F.Console.Err_Text);
      Assert
        (not Ada.Directories.Exists (Path (Dir, "vault/x.md")),
         "nothing written");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Reports_A_Note_Its_Schema_Rejects;

   procedure Write_Arguments_That_Are_Not_One_Path_Are_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Write (Env (F), Args) = 2, "none");
      Assert (Run_Write (Env (F), Args ("a", "b")) = 2, "two");
      F.Console.Clear;
      Assert (Run_Write (Env (F), Args ("-h")) = 0, "help");
      Assert (F.Console.Err_Text = Vault_Usage.Write, "its usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_Arguments_That_Are_Not_One_Path_Are_A_Usage_Error;

   procedure Write_With_The_Git_Integration_Commits_The_Note
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      F.Vars.Set ("SYNAPSE_VAULT_INTEGRATIONS", "git");
      F.Console.Set_Stdin ("text" & LF);
      Assert (Run_Write (Env (F), Args ("n.md")) = 0, "success");
      Assert (Commit_Count (Path (Dir, "vault")) = 1, "one commit");
      Assert
        (Head_Subject (Path (Dir, "vault")) = "vault: n.md", "its subject");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Write_With_The_Git_Integration_Commits_The_Note;

   procedure Patch_Replaces_A_Heading_S_Section_And_Prints_The_Path
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "n.md", Note);
      F.Console.Set_Stdin ("new" & LF);
      Assert
        (Run_Patch (Env (F), Args ("n.md", "--heading", "A::Sub")) = 0,
         "success: " & F.Console.Err_Text);
      Assert (F.Console.Out_Text = "n.md" & LF, "the path");
      Assert
        (Ada.Strings.Fixed.Index (Read (Dir, "n.md"), "## Sub" & LF & "new") >
         0
         and then Ada.Strings.Fixed.Index (Read (Dir, "n.md"), "old") = 0,
         "replaced: " & Read (Dir, "n.md"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Patch_Replaces_A_Heading_S_Section_And_Prints_The_Path;

   procedure Patch_Appends_Prepends_And_Creates (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "n.md", Note);
      F.Console.Set_Stdin ("more" & LF);
      Assert
        (Run_Patch
           (Env (F), Args ("n.md", "--heading", "A::Sub", "--append")) =
         0,
         "append");
      Assert
        (Ada.Strings.Fixed.Index (Read (Dir, "n.md"), "old" & LF & "more") > 0,
         "after the old text");
      Assert
        (Run_Patch
           (Env (F), Args ("n.md", "--heading", "A::New", "--create")) =
         0,
         "create");
      Assert
        (Ada.Strings.Fixed.Index (Read (Dir, "n.md"), "## New") > 0,
         "the new heading");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Patch_Appends_Prepends_And_Creates;

   procedure Patch_Finds_A_Heading_Whose_Text_Has_A_Single_Colon
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "n.md", "# A" & LF & LF & "## Note: more" & LF & "old" & LF);
      F.Console.Set_Stdin ("new" & LF);
      Assert
        (Run_Patch (Env (F), Args ("n.md", "--heading", "A::Note: more")) = 0,
         "success: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index (Read (Dir, "n.md"), "old") = 0, "replaced");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Patch_Finds_A_Heading_Whose_Text_Has_A_Single_Colon;

   procedure Patch_Renames_A_Heading_And_Prints_Its_New_Path
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "n.md", Note);
      F.Console.Set_Stdin ("Renamed");
      Assert
        (Run_Patch
           (Env (F),
            Args ("n.md", "--heading", "A::Sub", "--rename-heading")) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (F.Console.Out_Text = "n.md" & LF & "A::Renamed" & LF,
         "the path and the new heading path: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Patch_Renames_A_Heading_And_Prints_Its_New_Path;

   procedure Patch_Sets_A_Block_And_A_Frontmatter_Key
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "n.md", Note);
      F.Console.Set_Stdin ("kept?" & LF);
      Assert
        (Run_Patch (Env (F), Args ("n.md", "--block", "blk")) = 0, "block");
      F.Console.Set_Stdin ("B");
      Assert
        (Run_Patch (Env (F), Args ("n.md", "--frontmatter", "title")) = 0,
         "frontmatter: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index (Read (Dir, "n.md"), "title: B") > 0,
         "the key: " & Read (Dir, "n.md"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Patch_Sets_A_Block_And_A_Frontmatter_Key;

   procedure Patch_Says_Why_It_Cannot (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "n.md", Note);
      Put (Dir, "plain.md", "no frontmatter" & LF);
      F.Console.Set_Stdin ("x");
      Assert
        (Run_Patch (Env (F), Args ("gone.md", "--heading", "A")) = 1, "a");
      Assert (Run_Patch (Env (F), Args ("n.md", "--block", "nope")) = 1, "b");
      Assert
        (Run_Patch (Env (F), Args ("plain.md", "--frontmatter", "k")) = 1,
         "c");
      Assert
        (Run_Patch
           (Env (F), Args ("n.md", "--block", "blk", "--rename-heading")) =
         1,
         "d");
      F.Console.Set_Stdin ("two" & LF & "lines");
      Assert
        (Run_Patch
           (Env (F),
            Args ("n.md", "--heading", "A::Sub", "--rename-heading")) =
         1,
         "e");
      Assert
        (F.Console.Err_Text =
         "synapse-vault: no such note: gone.md" & LF &
         "synapse-vault: target not found in n.md" & LF &
         "synapse-vault: no frontmatter in plain.md" & LF &
         "synapse-vault: --rename-heading only applies to --heading" & LF &
         "synapse-vault: a heading's new text must be a single line" & LF,
         "each message: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Patch_Says_Why_It_Cannot;

   procedure Patch_Arguments_It_Does_Not_Know_Are_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Patch (Env (F), Args) = 2, "no path");
      Assert (Run_Patch (Env (F), Args ("n.md")) = 2, "no target");
      Assert (Run_Patch (Env (F), Args ("n.md", "--heading")) = 2, "dangling");
      Assert
        (Run_Patch (Env (F), Args ("n.md", "--heading", "A", "--block", "b")) =
         2,
         "two targets");
      Assert (Run_Patch (Env (F), Args ("n.md", "--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert (Run_Patch (Env (F), Args ("--help")) = 0, "help first");
      Assert
        (Run_Patch (Env (F), Args ("n.md", "--heading", "A", "-h")) = 0,
         "help late");
      Assert
        (F.Console.Err_Text = Vault_Usage.Patch & Vault_Usage.Patch, "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Patch_Arguments_It_Does_Not_Know_Are_A_Usage_Error;

   procedure Rename_Moves_The_Note_And_Rewrites_Its_Links
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put
        (Dir, "a.md", "---" & LF & "title: a" & LF & "---" & LF & "# a" & LF);
      Put (Dir, "b.md", "see [[a]]" & LF);
      Assert (Run_Rename (Env (F), Args ("a.md", "c.md")) = 0, "success");
      Assert (F.Console.Out_Text = "c.md" & LF, "the new path");
      Assert (not Ada.Directories.Exists (Path (Dir, "vault/a.md")), "gone");
      Assert
        (Read (Dir, "b.md") = "see [[c]]" & LF,
         "the link follows: " & Read (Dir, "b.md"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rename_Moves_The_Note_And_Rewrites_Its_Links;

   procedure Rename_Of_A_Missing_Note_Fails_And_Bad_Arguments_Are_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Rename (Env (F), Args ("gone.md", "x.md")) = 1, "missing");
      Assert
        (F.Console.Err_Text = "synapse-vault: no such note: gone.md" & LF,
         "the message");
      F.Console.Clear;
      Assert (Run_Rename (Env (F), Args ("a")) = 2, "one");
      Assert (Run_Rename (Env (F), Args ("a", "b", "c")) = 2, "three");
      Assert (Run_Rename (Env (F), Args) = 2, "none");
      Assert (Run_Rename (Env (F), Args ("--help")) = 0, "help");
      Assert
        (F.Console.Err_Text =
         Vault_Usage.Rename & Vault_Usage.Rename & Vault_Usage.Rename &
         Vault_Usage.Rename,
         "usage each time");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rename_Of_A_Missing_Note_Fails_And_Bad_Arguments_Are_A_Usage_Error;

   procedure Delete_Removes_The_Note_And_Unlinks_The_Links_To_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Put (Dir, "a.md", "x" & LF);
      Put (Dir, "b.md", "see [[a]]" & LF);
      Assert (Run_Delete (Env (F), Args ("a.md")) = 0, "success");
      Assert (F.Console.Out_Text = "a.md" & LF, "the path");
      Assert (not Ada.Directories.Exists (Path (Dir, "vault/a.md")), "gone");
      Assert
        (Read (Dir, "b.md") = "see a" & LF,
         "plain text: " & Read (Dir, "b.md"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Delete_Removes_The_Note_And_Unlinks_The_Links_To_It;

   procedure Delete_Of_A_Missing_Note_Fails_And_A_Bad_Argument_Is_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Delete (Env (F), Args ("gone.md")) = 1, "missing");
      Assert
        (F.Console.Err_Text = "synapse-vault: no such note: gone.md" & LF,
         "the message");
      Assert (Run_Delete (Env (F), Args) = 2, "none");
      Assert (Run_Delete (Env (F), Args ("a", "b")) = 2, "two");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Delete_Of_A_Missing_Note_Fails_And_A_Bad_Argument_Is_A_Usage_Error;

   procedure Every_Write_Command_Needs_A_Vault (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Assert (Run_Write (Env (F), Args ("a.md")) = 1, "write");
      Assert (Run_Patch (Env (F), Args ("a.md", "--block", "b")) = 1, "patch");
      Assert (Run_Rename (Env (F), Args ("a.md", "b.md")) = 1, "rename");
      Assert (Run_Delete (Env (F), Args ("a.md")) = 1, "delete");
      Assert
        (F.Console.Err_Text =
         "synapse-vault: no vault" & LF & "synapse-vault: no vault" & LF &
         "synapse-vault: no vault" & LF & "synapse-vault: no vault" & LF,
         "each says so");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Every_Write_Command_Needs_A_Vault;

   procedure The_Pusher_With_No_Vault_Is_An_Error_And_With_One_Does_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert (Run_Git_Pusher (Env (F), Args) = 2, "no vault argument");
      Assert
        (Run_Git_Pusher (Env (F), Args (Path (Dir, "vault"))) = 0,
         "a vault that is no repository");
      Assert
        (F.Console.Out_Text = "" and then F.Console.Err_Text = "", "silent");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Pusher_With_No_Vault_Is_An_Error_And_With_One_Does_Nothing;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Vault_Write");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Write_Stores_The_Note_And_Prints_Its_Path'Access,
         "Write stores the note and prints its path");
      Register_Routine
        (T, Write_Replaces_What_Was_There'Access,
         "Write replaces what was there");
      Register_Routine
        (T, Write_Refuses_A_Path_That_Leaves_The_Vault'Access,
         "Write refuses a path that leaves the vault");
      Register_Routine
        (T, Write_Reports_A_Note_Its_Schema_Rejects'Access,
         "Write reports a note its schema rejects");
      Register_Routine
        (T, Write_Arguments_That_Are_Not_One_Path_Are_A_Usage_Error'Access,
         "Write arguments that are not one path are a usage error");
      Register_Routine
        (T, Write_With_The_Git_Integration_Commits_The_Note'Access,
         "Write with the git integration commits the note");
      Register_Routine
        (T, Patch_Replaces_A_Heading_S_Section_And_Prints_The_Path'Access,
         "Patch replaces a heading's section and prints the path");
      Register_Routine
        (T, Patch_Appends_Prepends_And_Creates'Access,
         "Patch appends prepends and creates");
      Register_Routine
        (T, Patch_Finds_A_Heading_Whose_Text_Has_A_Single_Colon'Access,
         "Patch finds a heading whose text has a single colon");
      Register_Routine
        (T, Patch_Renames_A_Heading_And_Prints_Its_New_Path'Access,
         "Patch renames a heading and prints its new path");
      Register_Routine
        (T, Patch_Sets_A_Block_And_A_Frontmatter_Key'Access,
         "Patch sets a block and a frontmatter key");
      Register_Routine
        (T, Patch_Says_Why_It_Cannot'Access, "Patch says why it cannot");
      Register_Routine
        (T, Patch_Arguments_It_Does_Not_Know_Are_A_Usage_Error'Access,
         "Patch arguments it does not know are a usage error");
      Register_Routine
        (T, Rename_Moves_The_Note_And_Rewrites_Its_Links'Access,
         "Rename moves the note and rewrites its links");
      Register_Routine
        (T,
         Rename_Of_A_Missing_Note_Fails_And_Bad_Arguments_Are_A_Usage_Error'
           Access,
         "Rename of a missing note fails and bad arguments are a usage error");
      Register_Routine
        (T, Delete_Removes_The_Note_And_Unlinks_The_Links_To_It'Access,
         "Delete removes the note and unlinks the links to it");
      Register_Routine
        (T,
         Delete_Of_A_Missing_Note_Fails_And_A_Bad_Argument_Is_A_Usage_Error'
           Access,
         "Delete of a missing note fails and a bad argument is a usage error");
      Register_Routine
        (T, Every_Write_Command_Needs_A_Vault'Access,
         "Every write command needs a vault");
      Register_Routine
        (T,
         The_Pusher_With_No_Vault_Is_An_Error_And_With_One_Does_Nothing'Access,
         "The pusher with no vault is an error and with one does nothing");
   end Register_Tests;

end Synapse.Commands.Vault_Write.Tests;
