with Ada.Calendar;
with Ada.Containers;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;
with Synapse.Adapters.Store_Contract;
with Synapse.Core.JSON;

package body Synapse.Adapters.Disk_Store.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Counter : Natural := 0;

   --  A fresh directory, removed when the test is done.
   type Scratch is limited record
      Path : Unbounded_String;
   end record;

   function Make return Scratch is
      Seconds : constant Natural :=
        Natural (Ada.Calendar.Seconds (Ada.Calendar.Clock) * 1_000.0);
   begin
      Counter := Counter + 1;
      return Result : Scratch do
         Result.Path :=
           To_Unbounded_String
             (Ada.Directories.Current_Directory & "/obj/store-test-" &
              Ada.Strings.Fixed.Trim
                (Natural'Image (Seconds), Ada.Strings.Left) &
              "-" &
              Ada.Strings.Fixed.Trim
                (Natural'Image (Counter), Ada.Strings.Left));
         Ada.Directories.Create_Path (To_String (Result.Path));
      end return;
   end Make;

   procedure Remove (S : Scratch) is
   begin
      Ada.Directories.Delete_Tree (To_String (S.Path));
   exception
      when others =>
         null;
   end Remove;

   function Vault (S : Scratch) return String is
     (To_String (S.Path) & "/vault");

   function File_Text (Path : String) return String is
      use Ada.Streams.Stream_IO;
      File : File_Type;
   begin
      Open (File, In_File, Path);
      declare
         Text : String (1 .. Natural (Size (File)));
      begin
         String'Read (Stream (File), Text);
         Close (File);
         return Text;
      end;
   end File_Text;

   procedure Put (S : in out Disk_Store; Node, Text : String) is
   begin
      Assert (S.Write (Node, Text).Accepted, "write " & Node);
   end Put;

   function Joined (S : in out Disk_Store) return String is
      Result : Unbounded_String;
   begin
      for Name of S.List loop
         if Result /= Null_Unbounded_String then
            Append (Result, "|");
         end if;
         Append (Result, Name);
      end loop;
      return To_String (Result);
   end Joined;

   function Raises_Unsafe (S : in out Disk_Store; Node : String) return Boolean
   is
      Read_Raised, Write_Raised : Boolean := False;
   begin
      begin
         declare
            Ignore : constant Port.Maybe_Text := S.Read (Node);
         begin
            null;
         end;
      exception
         when Port.Unsafe_Node =>
            Read_Raised := True;
      end;
      begin
         declare
            Ignore : constant Port.Write_Result := S.Write (Node, "x");
         begin
            null;
         end;
      exception
         when Port.Unsafe_Node =>
            Write_Raised := True;
      end;
      return Read_Raised and then Write_Raised;
   end Raises_Unsafe;

   ---------------------------------------------------------------------------

   procedure Meets_The_Store_Contract (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "synapse/repo@main");
   begin
      Store_Contract.Check (S);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Meets_The_Store_Contract;

   procedure A_Node_Lives_Under_The_Namespace (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      S    : Disk_Store       := Create (Vault (Dir), "synapse/repo@main");
      Note : constant String  :=
        "---" & LF & "title: Foo" & LF & "---" & LF & "body" & LF;
   begin
      Put (S, "Foo.md", Note);
      Assert
        (File_Text (Vault (Dir) & "/synapse/repo@main/Foo.md") = Note,
         "on disk, under the namespace");
      Assert (To_String (S.Read ("Foo.md").Value) = Note, "and back");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Node_Lives_Under_The_Namespace;

   procedure An_Empty_Namespace_Addresses_The_Vault_Itself
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "");
   begin
      Put (S, "tasks/synapse/x.md", "x");
      Assert
        (File_Text (Vault (Dir) & "/tasks/synapse/x.md") = "x", "unprefixed");
      Assert (Joined (S) = "tasks/synapse/x.md", "listed by full path");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Empty_Namespace_Addresses_The_Vault_Itself;

   procedure A_Write_Is_Atomic (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      S    : Disk_Store       := Create (Vault (Dir), "ns");
      Path : constant String  := Vault (Dir) & "/ns/Foo.md";
   begin
      Put (S, "Foo.md", "first");
      Put (S, "Foo.md", "second");
      Assert
        (not Ada.Directories.Exists (Path & ".tmp"),
         "no temporary file survives");
      Assert (File_Text (Path) = "second", "the overwrite replaced it");
      Assert (Joined (S) = "Foo.md", "and it is listed once");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Write_Is_Atomic;

   procedure Unsafe_Names_Are_Refused (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "ns");
   begin
      Assert (Raises_Unsafe (S, "../../../../etc/passwd"), "leading ..");
      Assert (Raises_Unsafe (S, "a/../../b.md"), "buried ..");
      Assert (Raises_Unsafe (S, "/etc/passwd"), "absolute");
      Assert (Raises_Unsafe (S, "..\x"), "backslash");
      Assert
        (not Ada.Directories.Exists (Vault (Dir) & "/ns"),
         "nothing was created");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Unsafe_Names_Are_Refused;

   procedure A_Missing_Node_Or_Namespace_Is_Empty_Not_An_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "never/written");
   begin
      Assert (not S.Read ("Nope.md").Found, "missing node");
      Assert (S.List.Is_Empty, "a namespace never written to");
      Assert (S.Search ("anything").Is_Empty, "nothing to search");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Missing_Node_Or_Namespace_Is_Empty_Not_An_Error;

   procedure Listing_Walks_Subdirectories_And_Skips_Hidden_And_Other_Files
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      S    : Disk_Store       := Create (Vault (Dir), "ns");
      Base : constant String  := Vault (Dir) & "/ns";
   begin
      Put (S, "b.md", "b");
      Put (S, "a/deep/c.md", "c");
      Put (S, "a/a.md", "a");
      Put (S, ".git/config.md", "hidden dir");
      Put (S, ".hidden.md", "hidden file");
      Put (S, "a/.obsidian/x.md", "nested hidden dir");
      Put (S, "notes.txt", "not markdown");
      Put (S, "x.markdown", "not .md");
      Put (S, "Z.md", "upper");
      Put (S, "spaced name.md", "spaces");
      Ada.Directories.Create_Path (Base & "/empty-dir");
      Assert
        (Joined (S) = "Z.md|a/a.md|a/deep/c.md|b.md|spaced name.md",
         "sorted markdown outside hidden names: " & Joined (S));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Listing_Walks_Subdirectories_And_Skips_Hidden_And_Other_Files;

   procedure Every_Byte_Value_Round_Trips (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      S    : Disk_Store       := Create (Vault (Dir), "");
      Text : String (1 .. 1_024);
   begin
      for I in Text'Range loop
         Text (I) := Character'Val ((I - 1) mod 256);
      end loop;
      Put (S, "bytes.md", Text);
      Assert (To_String (S.Read ("bytes.md").Value) = Text, "binary safe");
      Put (S, "empty.md", "");
      Assert (S.Read ("empty.md").Found, "an empty note exists");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Every_Byte_Value_Round_Trips;

   procedure Names_With_Spaces_And_Unicode_Work (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      S    : Disk_Store       := Create (Vault (Dir), "");
      Name : constant String  :=
        "Caf" & Character'Val (16#C3#) & Character'Val (16#A9#) &
        " au lait.md";
   begin
      Put (S, Name, "x");
      Assert (S.Read (Name).Found, "read back");
      Assert (Joined (S) = Name, "listed under the same name");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Names_With_Spaces_And_Unicode_Work;

   procedure A_Failed_Write_Raises_And_Leaves_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir    : constant Scratch := Make;
      S      : Disk_Store       := Create (Vault (Dir), "ns");
      Raised : Boolean          := False;
   begin
      --  A file where a directory is needed.
      Put (S, "blocker", "i am a file");
      begin
         declare
            Ignore : constant Port.Write_Result :=
              S.Write ("blocker/x.md", "x");
         begin
            null;
         end;
      exception
         when Port.Store_Failure =>
            Raised := True;
      end;
      Assert (Raised, "Store_Failure");
      Assert
        (not Ada.Directories.Exists (Vault (Dir) & "/ns/blocker/x.md.tmp"),
         "no temporary file");

      --  A directory where a file is expected.
      Ada.Directories.Create_Path (Vault (Dir) & "/ns/folder.md");
      Raised := False;
      begin
         declare
            Ignore : constant Port.Maybe_Text := S.Read ("folder.md");
         begin
            null;
         end;
      exception
         when Port.Store_Failure =>
            Raised := True;
      end;
      Assert (Raised, "reading a directory fails");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Failed_Write_Raises_And_Leaves_Nothing;

   procedure Search_Finds_Text_Ignoring_Case_And_Frontmatter
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "");
   begin
      Put
        (S, "one.md",
         "---" & LF & "title: only in meta widget" & LF & "---" & LF &
         "plain body" & LF);
      Put
        (S, "two.md",
         "---" & LF & "title: Two" & LF & "---" & LF & "first" & LF &
         "A Widget here" & LF & "another WIDGET" & LF);
      Put (S, "three.md", "a widget" & LF);
      declare
         Hits : constant Port.Hit_Vectors.Vector := S.Search ("widget");
      begin
         Assert
           (Hits.Length = 2,
            "frontmatter is not searched:" & Hits.Length'Image);
         Assert
           (To_String (Hits (1).Node) = "two.md"
            and then Hits (1).Score > Hits (2).Score,
            "the most occurrences first");
         Assert
           (To_String (Hits (1).Context) = "A Widget here",
            "the first matching line");
         Assert (To_String (Hits (2).Node) = "three.md", "then the rest");
      end;
      Assert (S.Search ("gadget").Is_Empty, "no match is an empty result");
      Assert (S.Search ("").Is_Empty, "an empty query matches nothing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Search_Finds_Text_Ignoring_Case_And_Frontmatter;

   procedure Equal_Scores_Are_Ordered_By_Name (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "");
   begin
      Put (S, "b.md", "needle");
      Put (S, "a.md", "needle");
      Put (S, "c.md", "needle");
      declare
         Hits : constant Port.Hit_Vectors.Vector := S.Search ("needle");
      begin
         Assert
           (To_String (Hits (1).Node) = "a.md"
            and then To_String (Hits (2).Node) = "b.md"
            and then To_String (Hits (3).Node) = "c.md",
            "by name");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Equal_Scores_Are_Ordered_By_Name;

   ---------------------------------------------------------------------------
   --  Ranked and filtered search
   ---------------------------------------------------------------------------

   function Rule (Text : String) return Filtered.Path_Filter is
      Quoted : String := Text;
   begin
      for C of Quoted loop
         if C = ''' then
            C := '"';
         end if;
      end loop;
      declare
         Parsed : constant Synapse.Core.JSON.Parse_Result :=
           Synapse.Core.JSON.Parse (Quoted);
      begin
         Assert (Parsed.Ok, "the filter parses");
         return (Found => True, Value => Parsed.Item);
      end;
   end Rule;

   function Nodes (Hits : Port.Hit_Vectors.Vector) return String is
      Result : Unbounded_String;
   begin
      for H of Hits loop
         if Result /= Null_Unbounded_String then
            Append (Result, "|");
         end if;
         Append (Result, H.Node);
      end loop;
      return To_String (Result);
   end Nodes;

   procedure A_Rare_Word_Outranks_A_Common_One (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "");
   begin
      --  "widget" is in one note and "common" in all four: a query with both
      --  ranks the widget note first though neither repeats a word.
      Put (S, "rare.md", "common widget" & LF);
      Put (S, "other1.md", "common" & LF);
      Put (S, "other2.md", "common" & LF);
      Put (S, "other3.md", "common" & LF);
      declare
         Hits : constant Port.Hit_Vectors.Vector := S.Search ("widget common");
      begin
         Assert (Hits.Length >= 2, "something is found");
         Assert (To_String (Hits (1).Node) = "rare.md", "the rare one first");
         Assert (Hits (1).Score > Hits (2).Score, "by a real margin");
         Assert
           (Nodes (Hits) = "rare.md|other1.md|other2.md|other3.md",
            "then the ties by name: " & Nodes (Hits));
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Rare_Word_Outranks_A_Common_One;

   procedure A_Path_Filter_Scopes_The_Candidates (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch              := Make;
      S       : Disk_Store                    := Create (Vault (Dir), "");
      Designs : constant Filtered.Path_Filter :=
        Rule ("{'glob': ['designs/*', {'var': 'path'}]}");
   begin
      Put (S, "designs/x.md", "widget prose here" & LF);
      Put (S, "tasks/y.md", "widget prose here too" & LF);
      Assert
        (Nodes (S.Search_Filtered ("widget", Designs)) = "designs/x.md",
         "only the designs");
      Assert
        (Nodes (S.Search_Filtered ("widget", Filtered.No_Filter)) =
         "designs/x.md|tasks/y.md",
         "no filter is every node");
      Assert
        (Nodes (S.Search ("widget")) =
         Nodes (S.Search_Filtered ("widget", Filtered.No_Filter)),
         "and it is plain search");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Path_Filter_Scopes_The_Candidates;

   procedure A_Filter_That_Cannot_Be_Judged_Excludes_Everything
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "");
   begin
      Put (S, "a.md", "widget" & LF);
      Assert
        (S.Search_Filtered ("widget", Rule ("{'no_such_operator': 1}"))
           .Is_Empty,
         "an unknown operator");
      Assert (S.Search_Filtered ("widget", Rule ("false")).Is_Empty, "false");
      Assert (S.Search_Filtered ("widget", Rule ("null")).Is_Empty, "null");
      Assert
        (Nodes (S.Search_Filtered ("widget", Rule ("true"))) = "a.md",
         "true keeps it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Filter_That_Cannot_Be_Judged_Excludes_Everything;

   procedure Rarity_Is_Judged_Inside_The_Filtered_Set
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch              := Make;
      S    : Disk_Store                    := Create (Vault (Dir), "");
      Keep : constant Filtered.Path_Filter :=
        Rule ("{'glob': ['k/*', {'var': 'path'}]}");

      function Top_Score (Filter : Filtered.Path_Filter) return Float is
        (S.Search_Filtered ("gadget", Filter) (1).Score);
   begin
      Put (S, "k/one.md", "gadget" & LF);
      for I in 1 .. 20 loop
         Put
           (S,
            "o/" &
            Ada.Strings.Fixed.Trim (Integer'Image (I), Ada.Strings.Left) &
            ".md",
            "gadget" & LF);
      end loop;
      --  The word is in every note either way, but D grows with the corpus.
      Assert
        (Top_Score (Keep) /= Top_Score (Filtered.No_Filter),
         "the corpus is the filtered set");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Rarity_Is_Judged_Inside_The_Filtered_Set;

   procedure Short_Or_Numeric_Queries_Fall_Back_To_A_Substring
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "");
   begin
      Put (S, "a.md", "the id 42 record" & LF);
      Put (S, "b.md", "id and 42 apart" & LF);
      --  No word of the query is long enough, so the whole query is matched
      --  as a literal.
      Assert (Nodes (S.Search ("id 42")) = "a.md", "contiguous only");
      Put
        (S, "c.md",
         "---" & LF & "sources:" & LF & "  - hash: 42424242" & LF & "---" &
         LF & "no digits here" & LF);
      Assert
        (S.Search ("42424242").Is_Empty,
         "the fallback ignores frontmatter too");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Short_Or_Numeric_Queries_Fall_Back_To_A_Substring;

   procedure Identifiers_And_Prose_Find_Each_Other
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "");
   begin
      Put (S, "a.md", "the disk store handles this" & LF);
      Assert
        (Nodes (S.Search ("DiskStore")) = "a.md",
         "identifier query, prose text");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Identifiers_And_Prose_Find_Each_Other;

   procedure Stopwords_Remove_A_Term (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      S     : Disk_Store       := Create (Vault (Dir), "");
      Words : Core.Text_Lists.Set;
   begin
      Put (S, "a.md", "plain notes about handling" & LF);
      Put (S, "b.md", "about nothing at all" & LF);
      Assert
        (Nodes (S.Search ("about handling")) = "a.md|b.md",
         "'about' counts at first");
      Words.Insert ("about");
      S.Set_Stopwords (Words);
      Assert
        (Nodes (S.Search ("about handling")) = "a.md",
         "then only 'handling' does");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Stopwords_Remove_A_Term;

   procedure Context_Is_The_First_Line_With_Any_Term
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      S   : Disk_Store       := Create (Vault (Dir), "");
   begin
      Put
        (S, "a.md",
         "---" & LF & "title: widget in meta" & LF & "---" & LF & "intro" &
         LF & "a Gadget line" & LF & "a widget line" & LF);
      declare
         Hits : constant Port.Hit_Vectors.Vector := S.Search ("widget gadget");
      begin
         Assert (Hits.Length = 1, "one hit");
         Assert
           (To_String (Hits (1).Context) = "a Gadget line",
            "the first line with any term");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Context_Is_The_First_Line_With_Any_Term;

   ---------------------------------------------------------------------------

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Disk_Store");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Meets_The_Store_Contract'Access, "Meets the store contract");
      Register_Routine
        (T, A_Node_Lives_Under_The_Namespace'Access,
         "A node lives under the namespace");
      Register_Routine
        (T, An_Empty_Namespace_Addresses_The_Vault_Itself'Access,
         "An empty namespace addresses the vault itself");
      Register_Routine (T, A_Write_Is_Atomic'Access, "A write is atomic");
      Register_Routine
        (T, Unsafe_Names_Are_Refused'Access, "Unsafe names are refused");
      Register_Routine
        (T, A_Missing_Node_Or_Namespace_Is_Empty_Not_An_Error'Access,
         "A missing node or namespace is empty, not an error");
      Register_Routine
        (T,
         Listing_Walks_Subdirectories_And_Skips_Hidden_And_Other_Files'Access,
         "Listing walks subdirectories and skips hidden and other files");
      Register_Routine
        (T, Every_Byte_Value_Round_Trips'Access,
         "Every byte value round-trips");
      Register_Routine
        (T, Names_With_Spaces_And_Unicode_Work'Access,
         "Names with spaces and Unicode work");
      Register_Routine
        (T, A_Failed_Write_Raises_And_Leaves_Nothing'Access,
         "A failed write raises and leaves nothing");
      Register_Routine
        (T, Search_Finds_Text_Ignoring_Case_And_Frontmatter'Access,
         "Search finds text, ignoring case and frontmatter");
      Register_Routine
        (T, Equal_Scores_Are_Ordered_By_Name'Access,
         "Equal scores are ordered by name");
      Register_Routine
        (T, A_Rare_Word_Outranks_A_Common_One'Access,
         "A rare word outranks a common one");
      Register_Routine
        (T, A_Path_Filter_Scopes_The_Candidates'Access,
         "A path filter scopes the candidates");
      Register_Routine
        (T, A_Filter_That_Cannot_Be_Judged_Excludes_Everything'Access,
         "A filter that cannot be judged excludes everything");
      Register_Routine
        (T, Rarity_Is_Judged_Inside_The_Filtered_Set'Access,
         "Rarity is judged inside the filtered set");
      Register_Routine
        (T, Short_Or_Numeric_Queries_Fall_Back_To_A_Substring'Access,
         "Short or numeric queries fall back to a substring");
      Register_Routine
        (T, Identifiers_And_Prose_Find_Each_Other'Access,
         "Identifiers and prose find each other");
      Register_Routine
        (T, Stopwords_Remove_A_Term'Access, "Stopwords remove a term");
      Register_Routine
        (T, Context_Is_The_First_Line_With_Any_Term'Access,
         "Context is the first line with any term");
   end Register_Tests;

end Synapse.Adapters.Disk_Store.Tests;
