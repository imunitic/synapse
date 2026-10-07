with Ada.Directories;
with GNAT.OS_Lib;

with AUnit.Assertions;
with Synapse.Adapters.Fake_Variables;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.Hashing;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Docstring_Cache.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;
   use type Core.Hashing.Digest;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Filled (Byte : Natural) return Core.Hashing.Digest is
     ([others => Byte]);

   function Where (Path, Name, Kind : String) return Key is
     (Path => To_Unbounded_String (Path), Name => To_Unbounded_String (Name),
      Kind => To_Unbounded_String (Kind));

   function Item
     (Path, Name, Kind : String; Doc, Decl : Natural; Lines : Natural := 0)
      return Update is
     (Where => Where (Path, Name, Kind),
      Which =>
        (Docstring_Hash  => Filled (Doc), Decl_Hash => Filled (Decl),
         Docstring_Start => Lines, Docstring_End => Lines + 1,
         Decl_Start      => Lines + 2, Decl_End => Lines + 6));

   function Updates_Of (A : Update) return Update_Vectors.Vector is
      Result : Update_Vectors.Vector;
   begin
      Result.Append (A);
      return Result;
   end Updates_Of;

   function Updates_Of (A, B : Update) return Update_Vectors.Vector is
      Result : Update_Vectors.Vector := Updates_Of (A);
   begin
      Result.Append (B);
      return Result;
   end Updates_Of;

   function Updates_Of (A, B, C : Update) return Update_Vectors.Vector is
      Result : Update_Vectors.Vector := Updates_Of (A, B);
   begin
      Result.Append (C);
      return Result;
   end Updates_Of;

   No_Updates  : Update_Vectors.Vector;
   No_Removals : Key_Vectors.Vector;

   function Removals_Of (A : Key) return Key_Vectors.Vector is
      Result : Key_Vectors.Vector;
   begin
      Result.Append (A);
      return Result;
   end Removals_Of;

   procedure Apply
     (C        : in out Cache; Updates : Update_Vectors.Vector;
      Removals :        Key_Vectors.Vector := No_Removals)
   is
      Ignored : constant Natural := Commit (C, Updates, Removals);
   begin
      null;
   end Apply;

   function Names (Needs : Update_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for N of Needs loop
         Append (Result, N.Where.Name & ";");
      end loop;
      return To_String (Result);
   end Names;

   procedure An_Absent_Index_Opens_Empty_And_Needs_Everything
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
   begin
      Open (C, Path (Dir, "_docstring_index.bin"));
      Assert (Count (C) = 0 and then Discarded (C) = None, "empty");
      Assert
        (Names
           (Needs_Check (C, Updates_Of (Item ("a.wdg", "foo", "fn", 1, 2)))) =
         "foo;",
         "everything is needed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Absent_Index_Opens_Empty_And_Needs_Everything;

   procedure Commit_Then_Reopen_Brings_Back_What_Went_In
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      P    : constant String  := Path (Dir, "work/_docstring_index.bin");
      C, R : Cache;
   begin
      Open (C, P);
      Apply
        (C,
         Updates_Of
           (Item ("a.wdg", "foo", "fn", 1, 2, 3),
            Item ("a.wdg", "bar", "type", 3, 4)));
      Open (R, P);
      Assert (Count (R) = 2, "two entries");
      declare
         Got : constant Maybe_Value := Get (R, Where ("a.wdg", "foo", "fn"));
      begin
         Assert (Got.Found, "found");
         Assert
           (Got.Value.Docstring_Hash = Filled (1)
            and then Got.Value.Decl_Hash = Filled (2),
            "the hashes");
         Assert
           (Got.Value.Docstring_Start = 3 and then Got.Value.Docstring_End = 4
            and then Got.Value.Decl_Start = 5 and then Got.Value.Decl_End = 9,
            "line ranges round-trip, for a check that cannot parse");
      end;
      Assert
        (not Get (R, Where ("a.wdg", "foo", "type")).Found,
         "the kind is part of the key");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Commit_Then_Reopen_Brings_Back_What_Went_In;

   procedure Needs_Check_Is_Either_Hash_Moving_Or_A_New_Triple
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
   begin
      Open (C, Path (Dir, "_docstring_index.bin"));
      Apply
        (C,
         Updates_Of
           (Item ("a.wdg", "foo", "fn", 1, 2),
            Item ("a.wdg", "bar", "fn", 3, 4)));
      Assert
        (Names
           (Needs_Check
              (C,
               Updates_Of
                 (Item ("a.wdg", "foo", "fn", 1, 2),
                  Item ("a.wdg", "bar", "fn", 3, 99),
                  Item ("a.wdg", "baz", "fn", 5, 6)))) =
         "bar;baz;",
         "unchanged is silent; a moved declaration and a new triple hit");
      Assert
        (Names
           (Needs_Check (C, Updates_Of (Item ("a.wdg", "foo", "fn", 99, 2)))) =
         "foo;",
         "a moved docstring hits");
      Assert
        (Names
           (Needs_Check
              (C, Updates_Of (Item ("a.wdg", "foo", "type", 1, 2)))) =
         "foo;",
         "another kind is another triple");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Needs_Check_Is_Either_Hash_Moving_Or_A_New_Triple;

   procedure Needs_Check_Deduplicates (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
   begin
      Open (C, Path (Dir, "_docstring_index.bin"));
      Assert
        (Names
           (Needs_Check
              (C,
               Updates_Of
                 (Item ("a.wdg", "foo", "fn", 1, 2),
                  Item ("a.wdg", "foo", "fn", 1, 2),
                  Item ("a.wdg", "bar", "fn", 3, 4)))) =
         "foo;bar;",
         "nothing is checked twice");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Needs_Check_Deduplicates;

   function Joined (V : File_Entry_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for E of V loop
         Append (Result, E.Name & "/" & E.Kind & ";");
      end loop;
      return To_String (Result);
   end Joined;

   procedure Entries_For_Path_Scopes_To_One_File_In_Stored_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
   begin
      Open (C, Path (Dir, "_docstring_index.bin"));
      Apply
        (C,
         Updates_Of
           (Item ("b.wdg", "gamma", "fn", 3, 13),
            Item ("a.wdg", "beta", "fn", 2, 12),
            Item ("a.wdg", "alpha", "fn", 1, 11)));
      Assert
        (Joined (Entries_For_Path (C, "a.wdg")) = "alpha/fn;beta/fn;",
         "the file's entries, in stored order");
      Assert (Joined (Entries_For_Path (C, "b.wdg")) = "gamma/fn;", "another");
      Assert (Entries_For_Path (C, "c.wdg").Is_Empty, "an untracked file");
      Assert
        (Entries_For_Path (C, "a.wdg") (1).Which.Docstring_Hash = Filled (1),
         "with their values");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Entries_For_Path_Scopes_To_One_File_In_Stored_Order;

   procedure Eviction_Removes_A_Triple_And_An_Absent_One_Is_Not_Counted
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir      : constant Scratch := Make;
      C        : Cache;
      Removals : Key_Vectors.Vector;
   begin
      Open (C, Path (Dir, "_docstring_index.bin"));
      Apply
        (C,
         Updates_Of
           (Item ("a.wdg", "foo", "fn", 1, 2),
            Item ("a.wdg", "bar", "fn", 3, 4)));
      Removals.Append (Where ("a.wdg", "foo", "fn"));
      Removals.Append (Where ("a.wdg", "never", "fn"));
      Assert
        (Commit (C, No_Updates, Removals) = 1, "only the one that was there");
      Assert
        (Count (C) = 1
         and then not Get (C, Where ("a.wdg", "foo", "fn")).Found,
         "gone");
      Assert (Get (C, Where ("a.wdg", "bar", "fn")).Found, "the other stays");
      Assert
        (Commit
           (C, Updates_Of (Item ("a.wdg", "bar", "fn", 9, 9)),
            Removals_Of (Where ("a.wdg", "bar", "fn"))) =
         1,
         "removing a triple that is also updated removes it");
      Assert (Count (C) = 0, "and the index is empty");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Eviction_Removes_A_Triple_And_An_Absent_One_Is_Not_Counted;

   procedure A_Recommit_Of_A_Triple_Replaces_It_And_Others_Are_Kept
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
   begin
      Open (C, Path (Dir, "_docstring_index.bin"));
      Apply
        (C,
         Updates_Of
           (Item ("a.wdg", "foo", "fn", 1, 2),
            Item ("a.wdg", "other", "fn", 5, 6)));
      Apply (C, Updates_Of (Item ("a.wdg", "foo", "fn", 7, 8)));
      Assert (Count (C) = 2, "no second row");
      Assert
        (Get (C, Where ("a.wdg", "foo", "fn")).Value.Docstring_Hash =
         Filled (7),
         "the new pair");
      Assert
        (Get (C, Where ("a.wdg", "other", "fn")).Value.Docstring_Hash =
         Filled (5),
         "the other, merged onto and kept");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Recommit_Of_A_Triple_Replaces_It_And_Others_Are_Kept;

   procedure A_Commit_Leaves_No_Temporary_File (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "_docstring_index.bin");
      C   : Cache;
   begin
      Open (C, P);
      Apply (C, Updates_Of (Item ("a.wdg", "foo", "fn", 1, 2)));
      Assert
        (Ada.Directories.Exists (P)
         and then not Ada.Directories.Exists (P & ".tmp"),
         "the index is there and no partial file is visible");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Commit_Leaves_No_Temporary_File;

   procedure A_Damaged_Or_Other_Version_Index_Is_Discarded_And_Rebuilt
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "_docstring_index.bin");
      C   : Cache;
   begin
      File_Bytes.Write (P, "not an index at all, but longer than a header");
      Open (C, P);
      Assert (Count (C) = 0 and then Discarded (C) = Not_A_Cache, "foreign");
      Apply (C, Updates_Of (Item ("a.wdg", "foo", "fn", 1, 2)));
      Assert
        (Count (C) = 1 and then Discarded (C) = None, "rebuilt over the top");
      Close (C);
      declare
         Bytes : String := File_Bytes.Read (P, 10_000);
      begin
         Bytes (9) := Character'Val (7);
         File_Bytes.Write (P, Bytes);
      end;
      Open (C, P);
      Assert (Discarded (C) = Version_Mismatch, "another version");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Damaged_Or_Other_Version_Index_Is_Discarded_And_Rebuilt;

   procedure Commit_Refuses_When_The_File_Could_Not_Be_Read
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      P       : constant String  := Path (Dir, "_docstring_index.bin");
      Real, C : Cache;
      Raised  : Boolean          := False;
   begin
      Open (Real, P);
      Apply (Real, Updates_Of (Item ("a.wdg", "foo", "fn", 1, 2)));
      Close (Real);
      GNAT.OS_Lib.Set_Non_Readable (P);
      Open (C, P);
      if Discarded (C) = Unreadable then
         begin
            Apply (C, Updates_Of (Item ("a.wdg", "new", "fn", 3, 4)));
         exception
            when Unreadable_Cache =>
               Raised := True;
         end;
         Assert (Raised, "refused");
         GNAT.OS_Lib.Set_Readable (P);
         Open (C, P);
         Assert
           (Count (C) = 1 and then Get (C, Where ("a.wdg", "foo", "fn")).Found,
            "the real data is untouched");
      else
         GNAT.OS_Lib.Set_Readable (P);
      end if;
      Remove (Dir);
   exception
      when others =>
         GNAT.OS_Lib.Set_Readable (P);
         Remove (Dir);
         raise;
   end Commit_Refuses_When_The_File_Could_Not_Be_Read;

   procedure Enabled_Only_When_A_Non_Empty_Value_Is_Set
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      V.Set ("HOME", Path (Dir));
      Assert
        (not Enabled (V),
         "absent from the environment and the " & "configuration: disabled");
      V.Set ("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "");
      Assert (not Enabled (V), "an empty value is the same as absent");
      V.Set ("SYNAPSE_DOCSTRING_STALENESS_DETECTION", "false");
      Assert
        (Enabled (V), "any non-empty value enables it, no boolean parsing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enabled_Only_When_A_Non_Empty_Value_Is_Set;

   procedure Enabled_Can_Come_From_The_Configuration
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      V   : Fake_Variables.Fake_Variables;
   begin
      V.Set ("HOME", Path (Dir));
      Ada.Directories.Create_Path (Path (Dir, ".claude"));
      File_Bytes.Write
        (Path (Dir, ".claude/synapse.conf"),
         "SYNAPSE_DOCSTRING_STALENESS_DETECTION=1" & Character'Val (10));
      Assert (Enabled (V), "set in synapse.conf");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Enabled_Can_Come_From_The_Configuration;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Docstring_Cache");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, An_Absent_Index_Opens_Empty_And_Needs_Everything'Access,
         "An absent index opens empty and needs everything");
      Register_Routine
        (T, Commit_Then_Reopen_Brings_Back_What_Went_In'Access,
         "Commit then reopen brings back what went in");
      Register_Routine
        (T, Needs_Check_Is_Either_Hash_Moving_Or_A_New_Triple'Access,
         "Needs_Check is either hash moving or a new triple");
      Register_Routine
        (T, Needs_Check_Deduplicates'Access, "Needs_Check deduplicates");
      Register_Routine
        (T, Entries_For_Path_Scopes_To_One_File_In_Stored_Order'Access,
         "Entries_For_Path scopes to one file in stored order");
      Register_Routine
        (T, Eviction_Removes_A_Triple_And_An_Absent_One_Is_Not_Counted'Access,
         "Eviction removes a triple and an absent one is not counted");
      Register_Routine
        (T, A_Recommit_Of_A_Triple_Replaces_It_And_Others_Are_Kept'Access,
         "A recommit of a triple replaces it and others are kept");
      Register_Routine
        (T, A_Commit_Leaves_No_Temporary_File'Access,
         "A commit leaves no temporary file");
      Register_Routine
        (T, A_Damaged_Or_Other_Version_Index_Is_Discarded_And_Rebuilt'Access,
         "A damaged or other-version index is discarded and rebuilt");
      Register_Routine
        (T, Commit_Refuses_When_The_File_Could_Not_Be_Read'Access,
         "Commit refuses when the file could not be read");
      Register_Routine
        (T, Enabled_Only_When_A_Non_Empty_Value_Is_Set'Access,
         "Enabled only when a non-empty value is set");
      Register_Routine
        (T, Enabled_Can_Come_From_The_Configuration'Access,
         "Enabled can come from the configuration");
   end Register_Tests;

end Synapse.Adapters.Docstring_Cache.Tests;
