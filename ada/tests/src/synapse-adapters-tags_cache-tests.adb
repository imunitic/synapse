with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Directories;
with Ada.Numerics.Discrete_Random;
with Ada.Strings.Fixed;
with GNAT.OS_Lib;

with AUnit.Assertions;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.Graph_Model;
with Synapse.Core.Tag_Payload;
with Synapse.Core.Tags_Cache_Format;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Tags_Cache.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function Hash (Digits_Of : String) return Core.Graph_Model.Hash is
     (Core.Graph_Model.Hash_From_Hex
        (Digits_Of & Digits_Of & Digits_Of & Digits_Of & Digits_Of &
         Digits_Of & Digits_Of & Digits_Of & Digits_Of & Digits_Of &
         Digits_Of & Digits_Of & Digits_Of & Digits_Of & Digits_Of &
         Digits_Of & Digits_Of & Digits_Of & Digits_Of & Digits_Of)
        .Value);

   function Entry_Of
     (Path        : String; Hex : String; Tags : String;
      Unsupported : Boolean := False) return Update is
     (Path  => To_Unbounded_String (Path),
      Which =>
        (Hash        => Hash (Hex), Tags => To_Unbounded_String (Tags),
         Unsupported => Unsupported));

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
   No_Removals : Core.Text_Lists.Vector;

   function Removals_Of (A : String) return Core.Text_Lists.Vector is
      Result : Core.Text_Lists.Vector;
   begin
      Result.Append (To_Unbounded_String (A));
      return Result;
   end Removals_Of;

   function Removals_Of (A, B : String) return Core.Text_Lists.Vector is
      Result : Core.Text_Lists.Vector := Removals_Of (A);
   begin
      Result.Append (To_Unbounded_String (B));
      return Result;
   end Removals_Of;

   procedure Apply
     (C        : in out Cache; Updates : Update_Vectors.Vector;
      Removals :        Core.Text_Lists.Vector)
   is
      Ignored : constant Natural := Commit (C, Updates, Removals);
   begin
      null;
   end Apply;

   function Wanted (Path, Hex : String) return Path_Hash is
     (Path => To_Unbounded_String (Path), Hash => Hash (Hex));

   function Names (Needs : Path_Hash_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for N of Needs loop
         Append (Result, N.Path & ";");
      end loop;
      return To_String (Result);
   end Names;

   function Tags_Of (C : in out Cache; Path : String) return String is
      Found : constant Maybe_Value := Get (C, Path);
   begin
      return (if Found.Found then To_String (Found.Value.Tags) else "<none>");
   end Tags_Of;

   --  ------------------------------------------------------------------

   procedure An_Absent_Cache_Opens_Empty_And_Needs_Everything
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
      Req : Path_Hash_Vectors.Vector;
   begin
      Open (C, Path (Dir, "_tags_cache.bin"));
      Assert (Count (C) = 0, "empty");
      Assert (Discarded (C) = None, "and not discarded: there was no file");
      Req.Append (Wanted ("a.wdg", "11"));
      Req.Append (Wanted ("b.wdg", "22"));
      Assert (Names (Needs_Tagging (C, Req)) = "a.wdg;b.wdg;", "everything");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Absent_Cache_Opens_Empty_And_Needs_Everything;

   procedure Commit_Then_Reopen_Brings_Back_What_Went_In
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      P       : constant String  := Path (Dir, "work/_tags_cache.bin");
      C, R    : Cache;
      Dropped : Natural;
   begin
      Open (C, P);
      Dropped :=
        Commit
          (C,
           Updates_Of
             (Entry_Of ("src/A.wdg", "11", "Alpha" & HT & "def" & LF),
              Entry_Of ("src/b.bin", "22", "", True)),
           No_Removals);
      Assert (Dropped = 0, "nothing removed");
      Open (R, P);
      Assert
        (Count (R) = 2,
         "two entries, got" & Count (R)'Image & " " &
         Issue'Image (Discarded (R)));
      Assert (Tags_Of (R, "src/A.wdg") = "Alpha" & HT & "def" & LF, "tags");
      Assert (not Get (R, "src/A.wdg").Value.Unsupported, "supported");
      Assert (Get (R, "src/b.bin").Value.Unsupported, "unsupported");
      Assert (not Get (R, "src/missing.wdg").Found, "a miss");
      Assert (Get (R, "src/A.wdg").Value.Hash = Hash ("11"), "the hash");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Commit_Then_Reopen_Brings_Back_What_Went_In;

   procedure Commit_Refuses_When_The_File_Could_Not_Be_Read
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      P       : constant String  := Path (Dir, "_tags_cache.bin");
      Real, C : Cache;
      Raised  : Boolean          := False;
   begin
      Open (Real, P);
      Apply
        (Real,
         Updates_Of
           (Entry_Of ("src/A.wdg", "11", "Alpha"),
            Entry_Of ("src/B.wdg", "22", "Beta")),
         No_Removals);
      Close (Real);
      GNAT.OS_Lib.Set_Non_Readable (P);
      Open (C, P);
      if Discarded (C) = Unreadable then
         begin
            Apply
              (C, Updates_Of (Entry_Of ("src/C.wdg", "33", "Gamma")),
               No_Removals);
         exception
            when Unreadable_Cache =>
               Raised := True;
         end;
         Assert (Raised, "refused");
         GNAT.OS_Lib.Set_Readable (P);
         Open (C, P);
         Assert (Count (C) = 2, "the real data is untouched");
         Assert
           (Get (C, "src/A.wdg").Found and then Get (C, "src/B.wdg").Found,
            "both entries");
         Assert (not Get (C, "src/C.wdg").Found, "and nothing was merged");
      else
         --  A process that can read any file, as a superuser can, cannot
         --  make one unreadable.
         GNAT.OS_Lib.Set_Readable (P);
      end if;
      Remove (Dir);
   exception
      when others =>
         GNAT.OS_Lib.Set_Readable (P);
         Remove (Dir);
         raise;
   end Commit_Refuses_When_The_File_Could_Not_Be_Read;

   procedure Needs_Tagging_Is_Only_What_Is_Missing_Or_Has_Moved_On
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
      Req : Path_Hash_Vectors.Vector;
   begin
      Open (C, Path (Dir, "_tags_cache.bin"));
      Apply
        (C,
         Updates_Of
           (Entry_Of ("same.wdg", "11", ""),
            Entry_Of ("changed.wdg", "22", "")),
         No_Removals);
      Req.Append (Wanted ("same.wdg", "11"));
      Req.Append (Wanted ("changed.wdg", "99"));
      Req.Append (Wanted ("new.wdg", "33"));
      Assert
        (Names (Needs_Tagging (C, Req)) = "changed.wdg;new.wdg;",
         "the changed one and the new one, in order");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Needs_Tagging_Is_Only_What_Is_Missing_Or_Has_Moved_On;

   procedure Needs_Tagging_Deduplicates (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
      Req : Path_Hash_Vectors.Vector;
   begin
      Open (C, Path (Dir, "_tags_cache.bin"));
      Req.Append (Wanted ("a.wdg", "11"));
      Req.Append (Wanted ("a.wdg", "11"));
      Req.Append (Wanted ("b.wdg", "22"));
      Assert
        (Names (Needs_Tagging (C, Req)) = "a.wdg;b.wdg;",
         "nothing is tagged twice");
      Req.Clear;
      Req.Append (Wanted ("a.wdg", "11"));
      Req.Append (Wanted ("a.wdg", "99"));
      Assert
        (Natural (Needs_Tagging (C, Req).Length) = 1,
         "the first of two requests for a path wins");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Needs_Tagging_Deduplicates;

   procedure A_File_That_Parsed_To_Nothing_Is_Current_And_Not_Unsupported
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
      Req : Path_Hash_Vectors.Vector;
   begin
      Open (C, Path (Dir, "_tags_cache.bin"));
      Apply
        (C,
         Updates_Of
           (Entry_Of ("empty.wdg", "11", ""),
            Entry_Of ("nogrammar.bin", "22", "", True)),
         No_Removals);
      Assert (not Get (C, "empty.wdg").Value.Unsupported, "parsed");
      Assert (Get (C, "nogrammar.bin").Value.Unsupported, "no grammar");
      Req.Append (Wanted ("empty.wdg", "11"));
      Req.Append (Wanted ("nogrammar.bin", "22"));
      Assert
        (Needs_Tagging (C, Req).Is_Empty,
         "neither is tagged again at the same hash");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_File_That_Parsed_To_Nothing_Is_Current_And_Not_Unsupported;

   procedure Commit_Merges_Onto_What_Is_There (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
   begin
      Open (C, Path (Dir, "_tags_cache.bin"));
      Apply
        (C, Updates_Of (Entry_Of ("first.wdg", "11", "One" & LF)),
         No_Removals);
      Apply
        (C, Updates_Of (Entry_Of ("second.wdg", "22", "Two" & LF)),
         No_Removals);
      Assert (Count (C) = 2, "both");
      Assert (Tags_Of (C, "first.wdg") = "One" & LF, "the first survived");
      Assert (Tags_Of (C, "second.wdg") = "Two" & LF, "the second");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Commit_Merges_Onto_What_Is_There;

   procedure A_Recommit_Of_A_Path_Replaces_Its_Entry
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
   begin
      Open (C, Path (Dir, "_tags_cache.bin"));
      Apply
        (C, Updates_Of (Entry_Of ("a.wdg", "11", "Old" & LF)), No_Removals);
      Apply
        (C, Updates_Of (Entry_Of ("a.wdg", "22", "New" & LF)), No_Removals);
      Assert (Count (C) = 1, "one entry");
      Assert (Tags_Of (C, "a.wdg") = "New" & LF, "the new tags");
      Assert (Get (C, "a.wdg").Value.Hash = Hash ("22"), "the new hash");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Recommit_Of_A_Path_Replaces_Its_Entry;

   procedure Entries_Are_Read_By_Position_And_Counted
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      C    : Cache;
      Name : Unbounded_String;
      Item : Value;
   begin
      Open (C, Path (Dir, "_tags_cache.bin"));
      Assert (not Is_Open (C), "an absent file is not open");
      Assert (Unsupported_Count (C) = 0, "and has none");
      Apply
        (C, Updates_Of (Entry_Of ("b.wdg", "22", "Two" & LF, True)),
         No_Removals);
      Assert (Is_Open (C), "open after a commit");
      Apply
        (C, Updates_Of (Entry_Of ("a.wdg", "11", "One" & LF)), No_Removals);
      Assert (Unsupported_Count (C) = 1, "one unsupported");
      Entry_At (C, 1, Name, Item);
      Assert
        (To_String (Name) = "a.wdg" and then To_String (Item.Tags) = "One" & LF
         and then not Item.Unsupported,
         "the first path in byte order");
      Entry_At (C, 2, Name, Item);
      Assert
        (To_String (Name) = "b.wdg" and then Item.Unsupported, "the second");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Entries_Are_Read_By_Position_And_Counted;

   --  The rows a refs projection emits.
   Rows : Unbounded_String;

   procedure Collect (Row : String) is
   begin
      Append (Rows, Row);
   end Collect;

   function Refs_Of (C : in out Cache) return String is
      Count_Of : Natural;
   begin
      Rows     := Null_Unbounded_String;
      Count_Of := Write_Refs (C, Collect'Access);
      return Natural'Image (Count_Of) & ":" & To_String (Rows);
   end Refs_Of;

   function Tag
     (Name       : String; Which : Core.Graph_Model.Role; Line : Natural;
      Kind, Expr : String) return Core.Graph_Model.Tag is
     (Name  => To_Unbounded_String (Name), Kind => To_Unbounded_String (Kind),
      Which => Which, Line => Line, Expression => To_Unbounded_String (Expr));

   function Encoded (A : Core.Graph_Model.Tag) return String is
      V : Core.Tag_Payload.Tag_Vectors.Vector;
   begin
      V.Append (A);
      return Core.Tag_Payload.Encode (V);
   end Encoded;

   function Encoded (A, B : Core.Graph_Model.Tag) return String is
      V : Core.Tag_Payload.Tag_Vectors.Vector;
   begin
      V.Append (A);
      V.Append (B);
      return Core.Tag_Payload.Encode (V);
   end Encoded;

   procedure Eviction_Removes_A_Path_From_The_Cache_And_The_Refs
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      P       : constant String  := Path (Dir, "_tags_cache.bin");
      C, R    : Cache;
      Dropped : Natural;
      Alpha   : constant String  :=
        Encoded
          (Tag ("Alpha", Core.Graph_Model.Def, 14, "class", "class Alpha {"));
      Gone    : constant String  :=
        Encoded
          (Tag ("Gone", Core.Graph_Model.Def, 2, "class", "class Gone {"));
   begin
      Open (C, P);
      Apply
        (C,
         Updates_Of
           (Entry_Of ("src/alpha.wdg", "11", Alpha),
            Entry_Of ("src/gone.wdg", "22", Gone)),
         No_Removals);
      declare
         Before : constant String := Refs_Of (C);
      begin
         Assert (Before (Before'First .. Before'First + 1) = " 2", "two rows");
         Assert
           (Ada.Strings.Fixed.Index (Before, "src/gone.wdg") > 0,
            "the one to go is there");
      end;
      Dropped := Commit (C, No_Updates, Removals_Of ("src/gone.wdg"));
      Assert (Dropped = 1, "one row removed");
      Assert
        (Count (C) = 1 and then not Get (C, "src/gone.wdg").Found,
         "gone from the cache");
      declare
         After : constant String := Refs_Of (C);
      begin
         Assert (After (After'First .. After'First + 1) = " 1", "one row");
         Assert
           (Ada.Strings.Fixed.Index (After, "src/gone.wdg") = 0,
            "not in the refs");
         Assert
           (Ada.Strings.Fixed.Index (After, "src/alpha.wdg") > 0,
            "the other is");
      end;
      Open (R, P);
      Assert (Count (R) = 1, "and it stays gone across a reopen");
      Assert
        (Tags_Of (R, "src/alpha.wdg") = Alpha,
         "the entry that was kept still has its tags");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Eviction_Removes_A_Path_From_The_Cache_And_The_Refs;

   procedure Evicting_A_Path_The_Cache_Never_Held_Is_Not_Counted
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      C       : Cache;
      Dropped : Natural;
   begin
      Open (C, Path (Dir, "_tags_cache.bin"));
      Apply (C, Updates_Of (Entry_Of ("kept.wdg", "11", "")), No_Removals);
      Dropped := Commit (C, No_Updates, Removals_Of ("never.wdg", "kept.wdg"));
      Assert (Dropped = 1, "only the one that was there");
      Assert (Count (C) = 0, "and the cache is empty");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Evicting_A_Path_The_Cache_Never_Held_Is_Not_Counted;

   procedure Removing_A_Path_That_Is_Also_Updated_Removes_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      C       : Cache;
      Dropped : Natural;
   begin
      Open (C, Path (Dir, "_tags_cache.bin"));
      Dropped :=
        Commit
          (C, Updates_Of (Entry_Of ("a.wdg", "11", "X" & LF)),
           Removals_Of ("a.wdg"));
      Assert (Dropped = 1 and then Count (C) = 0, "removed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Removing_A_Path_That_Is_Also_Updated_Removes_It;

   procedure The_Refs_Projection_Is_The_Tag_Line_Rows_In_Path_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      C   : Cache;
      Zed : constant String  :=
        Encoded (Tag ("Zed", Core.Graph_Model.Def, 1, "class", "class Zed {"));
      Ay  : constant String  :=
        Encoded
          (Tag ("Ay", Core.Graph_Model.Def, 0, "class", "class Ay {"),
           Tag ("call", Core.Graph_Model.Ref, 3, "call", "call();"));
   begin
      Open (C, Path (Dir, "_tags_cache.bin"));
      Apply
        (C,
         Updates_Of
           (Entry_Of ("z.wdg", "11", Zed), Entry_Of ("a.wdg", "22", Ay),
            Entry_Of ("none.bin", "33", "", True)),
         No_Removals);
      Assert
        (Refs_Of (C) =
         " 3:Ay" & HT & "def" & HT & "class" & HT & "a.wdg:0" & HT &
         "class Ay {" & LF & "call" & HT & "ref" & HT & "call" & HT &
         "a.wdg:3" & HT & "call();" & LF & "Zed" & HT & "def" & HT & "class" &
         HT & "z.wdg:1" & HT & "class Zed {" & LF,
         "rows in path order, an unsupported entry contributing none");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Refs_Projection_Is_The_Tag_Line_Rows_In_Path_Order;

   procedure A_Cache_Of_Another_Version_Is_Discarded_And_Rebuilt
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      P       : constant String  := Path (Dir, "_tags_cache.bin");
      C       : Cache;
      Entries : Core.Tags_Cache_Format.Entry_Vectors.Vector;
   begin
      Entries.Append
        (Core.Tags_Cache_Format.Entry_Type'
           (Path => To_Unbounded_String ("a.wdg"), Hash => Hash ("11"),
            Tags => To_Unbounded_String ("X" & LF), Unsupported => False));
      declare
         Bytes : String := Core.Tags_Cache_Format.Encode (Entries);
      begin
         Bytes (9) := Character'Val (3);
         File_Bytes.Write (P, Bytes);
      end;
      Open (C, P);
      Assert (Count (C) = 0, "empty");
      Assert
        (Discarded (C) = Version_Mismatch, "and the reason is the version");
      Apply (C, Updates_Of (Entry_Of ("a.wdg", "11", "X" & LF)), No_Removals);
      Assert
        (Count (C) = 1 and then Discarded (C) = None,
         "it rebuilds over the top and does not refuse forever");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Cache_Of_Another_Version_Is_Discarded_And_Rebuilt;

   procedure The_Json_Cache_An_Earlier_Version_Left_Is_Discarded
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "_tags_cache.bin");
      C   : Cache;
   begin
      File_Bytes.Write
        (P,
         "{""src/A.wdg"": {""hash"": """ & [1 .. 40 => '1'] & """," &
         " ""tags"": ""Alpha"", ""unsupported"": false}}");
      Open (C, P);
      Assert
        (Count (C) = 0 and then Discarded (C) = Not_A_Cache, "not a cache");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Json_Cache_An_Earlier_Version_Left_Is_Discarded;

   procedure A_Commit_Is_Atomic_And_Leaves_No_Temporary_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      P   : constant String  := Path (Dir, "_tags_cache.bin");
      C   : Cache;
   begin
      Open (C, P);
      Apply (C, Updates_Of (Entry_Of ("a.wdg", "11", "")), No_Removals);
      Assert (Ada.Directories.Exists (P), "the cache is there");
      Assert
        (not Ada.Directories.Exists (P & ".tmp"),
         "and no temporary file survives");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Commit_Is_Atomic_And_Leaves_No_Temporary_File;

   procedure Large_Payloads_Are_Copied_Across_Commits_Intact
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      P     : constant String  := Path (Dir, "_tags_cache.bin");
      C     : Cache;
      Big_A : constant String  := [1 .. 150_000 => 'a'];
      Big_B : constant String  := [1 .. 70_001 => 'b'];
   begin
      Open (C, P);
      Apply
        (C,
         Updates_Of
           (Entry_Of ("a.wdg", "11", Big_A), Entry_Of ("b.wdg", "22", Big_B)),
         No_Removals);
      Apply (C, Updates_Of (Entry_Of ("0.wdg", "33", "front")), No_Removals);
      Apply (C, No_Updates, Removals_Of ("a.wdg"));
      Assert (Tags_Of (C, "b.wdg") = Big_B, "a payload past a block, kept");
      Assert (Tags_Of (C, "0.wdg") = "front", "the new one");
      Assert (not Get (C, "a.wdg").Found, "the other is gone");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Large_Payloads_Are_Copied_Across_Commits_Intact;

   package Model_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, String);

   package Draw is new Ada.Numerics.Discrete_Random (Natural);

   procedure A_Cache_Follows_A_Model_Through_Random_Commits
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      P     : constant String  := Path (Dir, "_tags_cache.bin");
      C, R  : Cache;
      Model : Model_Maps.Map;
      Gen   : Draw.Generator;

      function Pick (Limit : Positive) return Natural is
        (Draw.Random (Gen) mod Limit);

      function Name (N : Natural) return String is
         Text : constant String := Natural'Image (100 + N);
      begin
         return "f" & Text (Text'First + 1 .. Text'Last) & ".wdg";
      end Name;

      function Payload return String is
         Text : String (1 .. Pick (200));
      begin
         for Ch of Text loop
            Ch := Character'Val (Pick (256));
         end loop;
         return Text;
      end Payload;
   begin
      Draw.Reset (Gen, 17);
      Open (C, P);
      for Round in 1 .. 25 loop
         declare
            Updates          : Update_Vectors.Vector;
            Removals         : Core.Text_Lists.Vector;
            Expected_Removed : Natural        := 0;
            Staged           : Model_Maps.Map := Model;
         begin
            for I in 1 .. Pick (6) loop
               declare
                  Key       : constant String := Name (Pick (12));
                  Body_Text : constant String := Payload;
               begin
                  Updates.Append (Entry_Of (Key, "55", Body_Text));
                  Staged.Include (Key, Body_Text);
               end;
            end loop;
            for I in 1 .. Pick (3) loop
               declare
                  Key : constant String := Name (Pick (12));
               begin
                  Removals.Append (To_Unbounded_String (Key));
                  if Staged.Contains (Key) then
                     Staged.Delete (Key);
                     Expected_Removed := Expected_Removed + 1;
                  end if;
               end;
            end loop;
            Assert
              (Commit (C, Updates, Removals) = Expected_Removed,
               "removed, round" & Round'Image);
            Model := Staged;
            Assert
              (Count (C) = Natural (Model.Length),
               "count, round" & Round'Image);
         end;
         for Place in Model.Iterate loop
            Assert
              (Tags_Of (C, Model_Maps.Key (Place)) =
               Model_Maps.Element (Place),
               "payload kept");
         end loop;
      end loop;
      Open (R, P);
      Assert (Count (R) = Natural (Model.Length), "after a reopen");
      for Place in Model.Iterate loop
         Assert
           (Tags_Of (R, Model_Maps.Key (Place)) = Model_Maps.Element (Place),
            "every payload on disk");
      end loop;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Cache_Follows_A_Model_Through_Random_Commits;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Tags_Cache");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Entries_Are_Read_By_Position_And_Counted'Access,
         "Entries are read by position and counted");
      Register_Routine
        (T, An_Absent_Cache_Opens_Empty_And_Needs_Everything'Access,
         "An absent cache opens empty and needs everything");
      Register_Routine
        (T, Commit_Then_Reopen_Brings_Back_What_Went_In'Access,
         "Commit then reopen brings back what went in");
      Register_Routine
        (T, Commit_Refuses_When_The_File_Could_Not_Be_Read'Access,
         "Commit refuses when the file could not be read");
      Register_Routine
        (T, Needs_Tagging_Is_Only_What_Is_Missing_Or_Has_Moved_On'Access,
         "Needs_Tagging is only what is missing or has moved on");
      Register_Routine
        (T, Needs_Tagging_Deduplicates'Access, "Needs_Tagging deduplicates");
      Register_Routine
        (T,
         A_File_That_Parsed_To_Nothing_Is_Current_And_Not_Unsupported'Access,
         "A file that parsed to nothing is current and not unsupported");
      Register_Routine
        (T, Commit_Merges_Onto_What_Is_There'Access,
         "Commit merges onto what is there");
      Register_Routine
        (T, A_Recommit_Of_A_Path_Replaces_Its_Entry'Access,
         "A recommit of a path replaces its entry");
      Register_Routine
        (T, Eviction_Removes_A_Path_From_The_Cache_And_The_Refs'Access,
         "Eviction removes a path from the cache and the refs");
      Register_Routine
        (T, Evicting_A_Path_The_Cache_Never_Held_Is_Not_Counted'Access,
         "Evicting a path the cache never held is not counted");
      Register_Routine
        (T, Removing_A_Path_That_Is_Also_Updated_Removes_It'Access,
         "Removing a path that is also updated removes it");
      Register_Routine
        (T, The_Refs_Projection_Is_The_Tag_Line_Rows_In_Path_Order'Access,
         "The refs projection is the tag-line rows in path order");
      Register_Routine
        (T, A_Cache_Of_Another_Version_Is_Discarded_And_Rebuilt'Access,
         "A cache of another version is discarded and rebuilt");
      Register_Routine
        (T, The_Json_Cache_An_Earlier_Version_Left_Is_Discarded'Access,
         "The JSON cache an earlier version left is discarded");
      Register_Routine
        (T, A_Commit_Is_Atomic_And_Leaves_No_Temporary_File'Access,
         "A commit is atomic and leaves no temporary file");
      Register_Routine
        (T, Large_Payloads_Are_Copied_Across_Commits_Intact'Access,
         "Large payloads are copied across commits intact");
      Register_Routine
        (T, A_Cache_Follows_A_Model_Through_Random_Commits'Access,
         "A cache follows a model through random commits");
   end Register_Tests;

end Synapse.Adapters.Tags_Cache.Tests;
