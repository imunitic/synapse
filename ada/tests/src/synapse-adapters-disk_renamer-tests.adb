with Ada.Directories;

with AUnit.Assertions;
with Synapse.Adapters.Disk_Deleter;
with Synapse.Adapters.File_Bytes;
with Synapse.Ports.Store;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Disk_Renamer.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   procedure Put (Dir : Scratch; Node, Text : String) is
      Full  : constant String := Path (Dir, "vault/" & Node);
      Slash : Natural := 0;
   begin
      for I in reverse Full'Range loop
         if Full (I) = '/' then
            Slash := I;
            exit;
         end if;
      end loop;
      Ada.Directories.Create_Path (Full (Full'First .. Slash - 1));
      File_Bytes.Write (Full, Text);
   end Put;

   function Text_Of (Dir : Scratch; Node : String) return String
   is (File_Bytes.Read (Path (Dir, "vault/" & Node), 100_000));

   function Exists (Dir : Scratch; Node : String) return Boolean
   is (Ada.Directories.Exists (Path (Dir, "vault/" & Node)));

   function Mover (Dir : Scratch) return Disk_Renamer
   is (Create (Path (Dir, "vault")));

   procedure Moves_The_Note_And_Removes_The_Old_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "Old.md", "---" & LF & "title: Old" & LF & "---" & LF
           & "# Old" & LF & "body" & LF);
      declare
         R : Disk_Renamer := Mover (Dir);
      begin
         R.Rename ("Old.md", "New.md");
      end;
      Assert (not Exists (Dir, "Old.md"), "the old file is gone");
      Assert (Text_Of (Dir, "New.md")
              = "---" & LF & "title: New" & LF & "---" & LF & "# New" & LF
                & "body" & LF, "title and heading follow the name");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Moves_The_Note_And_Removes_The_Old_File;

   procedure Links_Are_Rewritten_Keeping_Their_Alias
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "Old.md", "x" & LF);
      Put (Dir, "A.md", "[[Old]] and [[old|label]] and [[Old#Part]]" & LF);
      Put (Dir, "B.md", "[[Old.md]] [[tasks/Old.md]] [[Other]]" & LF);
      Put (Dir, "C.md", "no links" & LF);
      declare
         R : Disk_Renamer := Mover (Dir);
      begin
         R.Rename ("Old.md", "New.md");
      end;
      Assert (Text_Of (Dir, "A.md")
              = "[[New]] and [[New|label]] and [[New#Part]]" & LF,
              "bare, alias and anchor");
      Assert (Text_Of (Dir, "B.md") = "[[New]] [[New]] [[Other]]" & LF,
              ".md and path spellings, others untouched");
      Assert (Text_Of (Dir, "C.md") = "no links" & LF, "an unrelated note");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Links_Are_Rewritten_Keeping_Their_Alias;

   procedure Renaming_Needs_No_Referrers_And_Keeps_Odd_Notes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "Alone.md", "just text" & LF);
      Put (Dir, "Plain.md", "# Plain" & LF & LF & "no frontmatter" & LF);
      Put (Dir, "Drift.md", "---" & LF & "title: Drift" & LF & "---" & LF
           & "# Something else" & LF);
      declare
         R : Disk_Renamer := Mover (Dir);
      begin
         R.Rename ("Alone.md", "Moved.md");
         R.Rename ("Plain.md", "Plainer.md");
         R.Rename ("Drift.md", "Drifted.md");
      end;
      Assert (Text_Of (Dir, "Moved.md") = "just text" & LF, "no referrers");
      Assert (Text_Of (Dir, "Plainer.md")
              = "# Plainer" & LF & LF & "no frontmatter" & LF,
              "no frontmatter: the heading only");
      Assert (Text_Of (Dir, "Drifted.md")
              = "---" & LF & "title: Drifted" & LF & "---" & LF
                & "# Something else" & LF, "a diverged heading is left alone");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Renaming_Needs_No_Referrers_And_Keeps_Odd_Notes;

   procedure A_Self_Link_Follows_The_Note (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "Me.md", "see [[Me]]" & LF);
      declare
         R : Disk_Renamer := Mover (Dir);
      begin
         R.Rename ("Me.md", "You.md");
      end;
      Assert (Text_Of (Dir, "You.md") = "see [[You]]" & LF,
              "not left pointing at the old title");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Self_Link_Follows_The_Note;

   procedure A_Missing_Note_Fails_And_Touches_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      Raised : Boolean := False;
   begin
      Put (Dir, "A.md", "[[Ghost]]" & LF);
      declare
         R : Disk_Renamer := Mover (Dir);
      begin
         begin
            R.Rename ("Ghost.md", "Spirit.md");
         exception
            when Ports.Store.Node_Not_Found =>
               Raised := True;
         end;
      end;
      Assert (Raised, "Node_Not_Found");
      Assert (Text_Of (Dir, "A.md") = "[[Ghost]]" & LF,
              "a referrer untouched");
      Assert (not Exists (Dir, "Spirit.md"), "nothing created");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Missing_Note_Fails_And_Touches_Nothing;

   procedure A_Note_Moves_Into_A_New_Directory_Or_Over_Another
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "A.md", "from a" & LF);
      Put (Dir, "B.md", "from b" & LF);
      Put (Dir, "L.md", "[[A]]" & LF);
      declare
         R : Disk_Renamer := Mover (Dir);
      begin
         R.Rename ("A.md", "deep/er/A2.md");
         R.Rename ("B.md", "deep/er/A2.md");
      end;
      Assert (Text_Of (Dir, "deep/er/A2.md") = "from b" & LF,
              "a later move replaces what was there");
      Assert (Text_Of (Dir, "L.md") = "[[A2]]" & LF, "links follow");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Note_Moves_Into_A_New_Directory_Or_Over_Another;

   procedure A_Case_Only_Rename_Keeps_The_Note (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "Foo.md", "---" & LF & "title: Foo" & LF & "---" & LF
           & "# Foo" & LF);
      Put (Dir, "L.md", "[[Foo]]" & LF);
      declare
         R : Disk_Renamer := Mover (Dir);
      begin
         R.Rename ("Foo.md", "foo.md");
      end;
      Assert (Exists (Dir, "foo.md"), "the note exists under its new name");
      Assert (Text_Of (Dir, "foo.md")
              = "---" & LF & "title: foo" & LF & "---" & LF & "# foo" & LF,
              "with its content: a file system that does not tell cases "
              & "apart must not lose it");
      Assert (Text_Of (Dir, "L.md") = "[[foo]]" & LF, "links follow");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Case_Only_Rename_Keeps_The_Note;

   procedure Repeating_A_Rename_Finishes_It (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "Old.md", "x" & LF);
      Put (Dir, "A.md", "[[Old]]" & LF);
      Put (Dir, "B.md", "[[Old]]" & LF);
      declare
         R : Disk_Renamer := Mover (Dir);
      begin
         R.Rename ("Old.md", "New.md");
         --  Put one referrer back as if the call had stopped before it.
         Put (Dir, "Old.md", "x" & LF);
         Put (Dir, "B.md", "[[Old]]" & LF);
         R.Rename ("Old.md", "New.md");
      end;
      Assert (Text_Of (Dir, "B.md") = "[[New]]" & LF, "the straggler");
      Assert (not Exists (Dir, "Old.md"), "and the old file is gone");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Repeating_A_Rename_Finishes_It;

   procedure An_Unsafe_Path_Is_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      Raised : Boolean := False;
   begin
      Put (Dir, "A.md", "x" & LF);
      declare
         R : Disk_Renamer := Mover (Dir);
      begin
         begin
            R.Rename ("A.md", "../escape.md");
         exception
            when Ports.Store.Unsafe_Node =>
               Raised := True;
         end;
      end;
      Assert (Raised, "Unsafe_Node");
      Assert (Exists (Dir, "A.md"), "the note is still there");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Unsafe_Path_Is_Refused;

   procedure Delete_Unlinks_Every_Referrer (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "Gone.md", "x" & LF);
      Put (Dir, "A.md", "see [[Gone]] and [[gone|label]] and [[Gone#Part]]"
           & LF);
      Put (Dir, "B.md", "[[tasks/Gone.md]] [[Other]]" & LF);
      declare
         D : Disk_Deleter.Disk_Deleter :=
           Disk_Deleter.Create (Path (Dir, "vault"));
      begin
         D.Delete ("Gone.md");
      end;
      Assert (not Exists (Dir, "Gone.md"), "the note is gone");
      Assert (Text_Of (Dir, "A.md") = "see Gone and label and Gone" & LF,
              "plain text, the alias kept, the anchor dropped");
      Assert (Text_Of (Dir, "B.md") = "Gone [[Other]]" & LF, "others kept");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Delete_Unlinks_Every_Referrer;

   procedure Delete_Without_Referrers_Just_Removes_The_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      Raised : Boolean := False;
   begin
      Put (Dir, "Alone.md", "x" & LF);
      Put (Dir, "Self.md", "[[Self]]" & LF);
      declare
         D : Disk_Deleter.Disk_Deleter :=
           Disk_Deleter.Create (Path (Dir, "vault"));
      begin
         D.Delete ("Alone.md");
         D.Delete ("Self.md");
         begin
            D.Delete ("Missing.md");
         exception
            when Ports.Store.Node_Not_Found =>
               Raised := True;
         end;
         Assert (Raised, "a missing note fails clearly");
         Raised := False;
         begin
            D.Delete ("../x.md");
         exception
            when Ports.Store.Unsafe_Node =>
               Raised := True;
         end;
         Assert (Raised, "an unsafe path is refused");
      end;
      Assert (not Exists (Dir, "Alone.md")
              and then not Exists (Dir, "Self.md"), "both removed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Delete_Without_Referrers_Just_Removes_The_File;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Disk_Renamer and Disk_Deleter");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Moves_The_Note_And_Removes_The_Old_File'Access,
         "Moves the note and removes the old file");
      Register_Routine
        (T, Links_Are_Rewritten_Keeping_Their_Alias'Access,
         "Links are rewritten keeping their alias");
      Register_Routine
        (T, Renaming_Needs_No_Referrers_And_Keeps_Odd_Notes'Access,
         "Renaming needs no referrers and keeps odd notes");
      Register_Routine
        (T, A_Self_Link_Follows_The_Note'Access,
         "A self-link follows the note");
      Register_Routine
        (T, A_Missing_Note_Fails_And_Touches_Nothing'Access,
         "A missing note fails and touches nothing");
      Register_Routine
        (T, A_Note_Moves_Into_A_New_Directory_Or_Over_Another'Access,
         "A note moves into a new directory or over another");
      Register_Routine
        (T, A_Case_Only_Rename_Keeps_The_Note'Access,
         "A case-only rename keeps the note");
      Register_Routine
        (T, Repeating_A_Rename_Finishes_It'Access,
         "Repeating a rename finishes it");
      Register_Routine
        (T, An_Unsafe_Path_Is_Refused'Access, "An unsafe path is refused");
      Register_Routine
        (T, Delete_Unlinks_Every_Referrer'Access,
         "Delete unlinks every referrer");
      Register_Routine
        (T, Delete_Without_Referrers_Just_Removes_The_File'Access,
         "Delete without referrers just removes the file");
   end Register_Tests;

end Synapse.Adapters.Disk_Renamer.Tests;
