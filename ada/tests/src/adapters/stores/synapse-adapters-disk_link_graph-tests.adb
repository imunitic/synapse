with Ada.Containers;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.UTF8;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Disk_Link_Graph.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;
   use type Ada.Containers.Count_Type;

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

   function Joined (List : Core.Text_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Item of List loop
         if Text /= Null_Unbounded_String then
            Append (Text, "|");
         end if;
         Append (Text, Item);
      end loop;
      return To_String (Text);
   end Joined;

   function Shown (List : Port.Backlink_Vectors.Vector) return String is
      Text : Unbounded_String;
   begin
      for B of List loop
         if Text /= Null_Unbounded_String then
            Append (Text, "|");
         end if;
         Append (Text, B.Node & ":" & Ada.Strings.Fixed.Trim
                                        (B.Count'Image, Ada.Strings.Left));
      end loop;
      return To_String (Text);
   end Shown;

   function Graph (Dir : Scratch) return Disk_Link_Graph
   is (Create (Path (Dir, "vault")));

   procedure A_Bare_Link_Resolves_To_The_Real_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "A.md", "see [[B]]" & LF);
      Put (Dir, "dir/B.md", "target" & LF);
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (Joined (G.Links ("A.md")) = "dir/B.md", "A links to B");
         Assert (Shown (G.Backlinks ("dir/B.md")) = "A.md:1", "and back");
         Assert (G.Backlinks ("A.md").Is_Empty, "nothing links to A");
         Assert (G.Links ("dir/B.md").Is_Empty, "B links nowhere");
         Assert (G.Links ("Missing.md").Is_Empty, "an unknown note");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Bare_Link_Resolves_To_The_Real_File;

   procedure Backlinks_Count_Every_Link (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "A.md", "[[T]] and [[T|again]] and [[t#heading]]" & LF);
      Put (Dir, "B.md", "[[T]]" & LF);
      Put (Dir, "T.md", "x" & LF);
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (Shown (G.Backlinks ("T.md")) = "A.md:3|B.md:1",
                 "counted, by name: " & Shown (G.Backlinks ("T.md")));
         Assert (Joined (G.Links ("A.md")) = "T.md", "listed once");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Backlinks_Count_Every_Link;

   procedure Resolution_Ignores_Case_Path_And_Suffix
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "A.md", "[[b]] [[dir/B.md]] [[B.md]]" & LF);
      Put (Dir, "B.md", "x" & LF);
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (Shown (G.Backlinks ("B.md")) = "A.md:3", "three spellings");
         Assert (G.Unresolved_Links.Is_Empty, "none unresolved");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Resolution_Ignores_Case_Path_And_Suffix;

   procedure Titles_Match_Through_Unicode_Normalization
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir        : constant Scratch := Make;
      Composed   : constant String := Core.UTF8.Encode (16#304C#);
      Decomposed : constant String :=
        Core.UTF8.Encode (16#304B#) & Core.UTF8.Encode (16#3099#);
      Upper      : constant String :=
        Core.UTF8.Encode (16#41C#) & Core.UTF8.Encode (16#41E#);
      Lower      : constant String :=
        Core.UTF8.Encode (16#43C#) & Core.UTF8.Encode (16#43E#);
   begin
      Put (Dir, "A.md", "[[" & Decomposed & "]] and [[" & Upper & "]]" & LF);
      Put (Dir, Composed & ".md", "x" & LF);
      Put (Dir, Lower & ".md", "x" & LF);
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (G.Unresolved_Links.Is_Empty
                 and then G.Ambiguous_Links.Is_Empty, "both resolve");
         Assert (Natural (G.Links ("A.md").Length) = 2, "to two notes");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Titles_Match_Through_Unicode_Normalization;

   procedure An_Unresolved_Link_Is_Reported_Not_Dropped
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "A.md", "[[Ghost]] and [[Ghost]] and [[Other ghost]]" & LF);
      Put (Dir, "B.md", "[[Ghost]]" & LF);
      declare
         G    : Disk_Link_Graph := Graph (Dir);
         Rows : constant Port.Unresolved_Vectors.Vector := G.Unresolved_Links;
      begin
         Assert (Rows.Length = 2, "two targets");
         Assert (To_String (Rows (1).Target) = "Ghost"
                 and then Rows (1).Count = 3
                 and then Joined (Rows (1).Sources) = "A.md|B.md",
                 "counted, with each source once");
         Assert (To_String (Rows (2).Target) = "Other ghost"
                 and then Rows (2).Count = 1, "the other");
         Assert (G.Links ("A.md").Is_Empty, "an unresolved link is no edge");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Unresolved_Link_Is_Reported_Not_Dropped;

   procedure A_Link_Matching_Two_Files_Is_Ambiguous
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "A.md", "[[Dup]]" & LF);
      Put (Dir, "x/Dup.md", "one" & LF);
      Put (Dir, "y/Dup.md", "two" & LF);
      declare
         G    : Disk_Link_Graph := Graph (Dir);
         Rows : constant Port.Ambiguous_Vectors.Vector := G.Ambiguous_Links;
      begin
         Assert (Rows.Length = 1, "reported");
         Assert (Joined (Rows (1).Candidates) = "x/Dup.md|y/Dup.md"
                 and then Rows (1).Count = 1
                 and then Joined (Rows (1).Sources) = "A.md", "its details");
         Assert (Shown (G.Backlinks ("x/Dup.md")) = "A.md:1"
                 and then Shown (G.Backlinks ("y/Dup.md")) = "A.md:1",
                 "both count as linked to");
         Assert (G.Unresolved_Links.Is_Empty, "and it is not unresolved");
         Assert (G.Orphans.Length = 1 and then Joined (G.Orphans) = "A.md",
                 "neither is an orphan");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Link_Matching_Two_Files_Is_Ambiguous;

   procedure Ids_Resolve_Straight_To_The_File (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "A.md", "[[sb-081]] [[sb-9]] [[Real title]]" & LF);
      Put (Dir, "one.md", "---" & LF & "note_id: sb-081" & LF & "---" & LF);
      Put (Dir, "two.md", "---" & LF & "task_id: ""sb-9""" & LF & "---" & LF);
      Put (Dir, "Real title.md", "x" & LF);
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (Joined (G.Links ("A.md")) = "one.md|two.md|Real title.md",
                 "note_id, task_id and a title: " & Joined (G.Links ("A.md")));
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Ids_Resolve_Straight_To_The_File;

   procedure An_Id_Match_Beats_A_Title_Match (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "A.md", "[[sb-1|sb-2]]" & LF);
      Put (Dir, "sb-2.md", "a note whose name looks like an id" & LF);
      Put (Dir, "holder.md", "---" & LF & "note_id: sb-1" & LF & "---" & LF);
      Put (Dir, "B.md", "[[sb-2]]" & LF);
      Put (Dir, "other.md", "---" & LF & "note_id: sb-2" & LF & "---" & LF);
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (Joined (G.Links ("A.md")) = "holder.md",
                 "the id, not the alias text");
         Assert (Joined (G.Links ("B.md")) = "other.md",
                 "an id beats a file called the same");
         Assert (G.Ambiguous_Links.Is_Empty, "so it is not ambiguous");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Id_Match_Beats_A_Title_Match;

   procedure A_Repeated_Id_Goes_To_The_First_Note (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "A.md", "[[sb-1]]" & LF);
      Put (Dir, "b.md", "---" & LF & "note_id: sb-1" & LF & "---" & LF);
      Put (Dir, "c.md", "---" & LF & "note_id: sb-1" & LF & "---" & LF);
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (Joined (G.Links ("A.md")) = "b.md", "by path order");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Repeated_Id_Goes_To_The_First_Note;

   procedure Orphans_And_Dead_Ends_Are_Found (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "Hub.md", "[[Leaf]] [[Nowhere]]" & LF);
      Put (Dir, "Leaf.md", "no links" & LF);
      Put (Dir, "Lonely.md", "no links, nothing links here" & LF);
      Put (Dir, "OnlyBroken.md", "[[Nowhere]]" & LF);
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (Joined (G.Orphans) = "Hub.md|Lonely.md|OnlyBroken.md",
                 "nothing links to these: " & Joined (G.Orphans));
         Assert (Joined (G.Dead_Ends) = "Leaf.md|Lonely.md|OnlyBroken.md",
                 "no link leads anywhere from these: " & Joined (G.Dead_Ends));
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Orphans_And_Dead_Ends_Are_Found;

   procedure The_Code_Graph_Is_Left_Out (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "A.md", "[[Node]] [[A]]" & LF);
      Put (Dir, "synapse/repo@main/Node.md", "[[A]] [[Gone]]" & LF);
      Put (Dir, "synapse/other.md", "x" & LF);
      Put (Dir, "synapsey/B.md", "x" & LF);
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (G.Links ("A.md").Length = 1
                 and then Joined (G.Links ("A.md")) = "A.md",
                 "no candidate under synapse/");
         Assert (Joined (G.Orphans) = "synapsey/B.md",
                 "not indexed as a note: " & Joined (G.Orphans));
         Assert (Shown (G.Backlinks ("synapse/repo@main/Node.md")) = "",
                 "never a target");
         declare
            Rows : constant Port.Unresolved_Vectors.Vector :=
              G.Unresolved_Links;
         begin
            Assert (Rows.Length = 1
                    and then To_String (Rows (1).Target) = "Node",
                    "a link to it is unresolved, its own links unread");
         end;
         Assert (Joined (G.Dead_Ends) = "synapsey/B.md",
                 "dead ends skip it too");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Code_Graph_Is_Left_Out;

   procedure Empty_And_Self_Linking_Vaults_Work
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Ada.Directories.Create_Path (Path (Dir, "vault"));
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (G.Orphans.Is_Empty and then G.Dead_Ends.Is_Empty
                 and then G.Unresolved_Links.Is_Empty
                 and then G.Ambiguous_Links.Is_Empty, "an empty vault");
      end;
      Put (Dir, "Self.md", "[[Self]]" & LF);
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (Shown (G.Backlinks ("Self.md")) = "Self.md:1", "a self-link");
         Assert (G.Orphans.Is_Empty, "counts as linked to");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Empty_And_Self_Linking_Vaults_Work;

   procedure A_Large_Vault_Resolves_In_One_Pass
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      Count : constant := 300;

      function Name (N : Positive) return String
      is ("n" & Ada.Strings.Fixed.Trim (N'Image, Ada.Strings.Left));
   begin
      for I in 1 .. Count loop
         Put (Dir, Name (I) & ".md",
              "[[" & Name (I mod Count + 1) & "]]" & LF);
      end loop;
      declare
         G : Disk_Link_Graph := Graph (Dir);
      begin
         Assert (G.Orphans.Is_Empty and then G.Dead_Ends.Is_Empty,
                 "a ring: everyone is linked and links");
         Assert (Shown (G.Backlinks ("n1.md")) = "n300.md:1", "its backlink");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Large_Vault_Resolves_In_One_Pass;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Disk_Link_Graph");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Bare_Link_Resolves_To_The_Real_File'Access,
         "A bare link resolves to the real file");
      Register_Routine
        (T, Backlinks_Count_Every_Link'Access, "Backlinks count every link");
      Register_Routine
        (T, Resolution_Ignores_Case_Path_And_Suffix'Access,
         "Resolution ignores case, path and suffix");
      Register_Routine
        (T, Titles_Match_Through_Unicode_Normalization'Access,
         "Titles match through Unicode normalization");
      Register_Routine
        (T, An_Unresolved_Link_Is_Reported_Not_Dropped'Access,
         "An unresolved link is reported, not dropped");
      Register_Routine
        (T, A_Link_Matching_Two_Files_Is_Ambiguous'Access,
         "A link matching two files is ambiguous");
      Register_Routine
        (T, Ids_Resolve_Straight_To_The_File'Access,
         "Ids resolve straight to the file");
      Register_Routine
        (T, An_Id_Match_Beats_A_Title_Match'Access,
         "An id match beats a title match");
      Register_Routine
        (T, A_Repeated_Id_Goes_To_The_First_Note'Access,
         "A repeated id goes to the first note");
      Register_Routine
        (T, Orphans_And_Dead_Ends_Are_Found'Access,
         "Orphans and dead ends are found");
      Register_Routine
        (T, The_Code_Graph_Is_Left_Out'Access, "The code graph is left out");
      Register_Routine
        (T, Empty_And_Self_Linking_Vaults_Work'Access,
         "Empty and self-linking vaults work");
      Register_Routine
        (T, A_Large_Vault_Resolves_In_One_Pass'Access,
         "A large vault resolves in one pass");
   end Register_Tests;

end Synapse.Adapters.Disk_Link_Graph.Tests;
