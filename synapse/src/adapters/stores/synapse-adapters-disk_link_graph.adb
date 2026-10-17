with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Vectors;

with Synapse.Adapters.Disk_Store;
with Synapse.Core.Frontmatter;
with Synapse.Core.Unicode.Transforms;
with Synapse.Core.Wikilinks;
with Synapse.Ports.Store;

package body Synapse.Adapters.Disk_Link_Graph is

   use Ada.Strings.Unbounded;
   use type Ada.Containers.Count_Type;

   function Create (Vault : String) return Disk_Link_Graph is
     (Port.Link_Graph with Vault => To_Unbounded_String (Vault));

   --  One link of one note, and the notes it can mean.
   type Edge is record
      Source     : Unbounded_String;
      Target     : Unbounded_String;  --  as written
      Candidates : Core.Text_Lists.Vector;
   end record;

   package Edge_Vectors is new Ada.Containers.Vectors (Positive, Edge);

   package Path_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Core.Text_Lists.Vector, "<", Core.Text_Lists.Vectors."=");

   package Id_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, String);

   function In_Code_Graph (Path : String) return Boolean is
   begin
      for I in Path'Range loop
         if Path (I) = '/' then
            return Path (Path'First .. I - 1) = "synapse";
         end if;
      end loop;
      return Path = "synapse";
   end In_Code_Graph;

   function Contains
     (List : Core.Text_Lists.Vector; Item : String) return Boolean is
     (List.Contains (To_Unbounded_String (Item)));

   --  The value of the field Key, or "" when there is none.
   function Field (Text, Key : String) return String is
      Found : constant Core.Frontmatter.Maybe_Span :=
        Core.Frontmatter.Find_Field (Text, Key);
   begin
      if Found.Found then
         return
           Text
             (Text'First + Found.Value.First ..
                  Text'First + Found.Value.Stop - 1);
      end if;
      return "";
   end Field;

   function Has_Field (Text, Key : String) return Boolean is
     (Core.Frontmatter.Find_Field (Text, Key).Found);

   --  The note's identity: its `note_id`, else its `task_id`, or "".
   function Identity (Text : String) return String is
     (if Has_Field (Text, "note_id") then Field (Text, "note_id")
      else Field (Text, "task_id"));

   --  Every edge of the vault, in the order of the notes and of the links in
   --  them, and every note path.
   procedure Build
     (Vault :     String; Paths : out Core.Text_Lists.Vector;
      Edges : out Edge_Vectors.Vector)
   is
      Disk   : Disk_Store.Disk_Store := Disk_Store.Create (Vault, "");
      Ids    : Id_Maps.Map;
      Titles : Path_Maps.Map;

      type Pending is record
         Source, Target : Unbounded_String;
      end record;
      package Pending_Vectors is new Ada.Containers.Vectors
        (Positive, Pending);
      Links : Pending_Vectors.Vector;
   begin
      for Name of Disk.List loop
         if not In_Code_Graph (To_String (Name)) then
            Paths.Append (Name);
         end if;
      end loop;

      for Path of Paths loop
         declare
            Title : constant String :=
              Core.Unicode.Transforms.Normalize_Key
                (Core.Wikilinks.Title_Of (To_String (Path)));
         begin
            if not Titles.Contains (Title) then
               Titles.Insert (Title, Core.Text_Lists.Vectors.Empty_Vector);
            end if;
            Titles.Reference (Title).Append (Path);
         end;
      end loop;

      for Path of Paths loop
         declare
            Found : constant Ports.Store.Maybe_Text :=
              Disk.Read (To_String (Path));
         begin
            if Found.Found then
               declare
                  Text : constant String := To_String (Found.Value);
                  Id   : constant String := Identity (Text);
               begin
                  if Id /= "" and then not Ids.Contains (Id) then
                     Ids.Insert (Id, To_String (Path));
                  end if;
                  for Target of Core.Wikilinks.Extract (Text) loop
                     Links.Append (Pending'(Source => Path, Target => Target));
                  end loop;
               end;
            end if;
         end;
      end loop;

      for Item of Links loop
         declare
            Normalized : constant String :=
              Core.Wikilinks.Normalize_Target (To_String (Item.Target));
            Candidates : Core.Text_Lists.Vector;
         begin
            if Ids.Contains (Normalized) then
               Candidates.Append
                 (To_Unbounded_String (Ids.Element (Normalized)));
            else
               declare
                  Key : constant String :=
                    Core.Unicode.Transforms.Normalize_Key (Normalized);
               begin
                  if Titles.Contains (Key) then
                     Candidates := Titles.Element (Key);
                  end if;
               end;
            end if;
            Edges.Append
              (Edge'
                 (Source     => Item.Source, Target => Item.Target,
                  Candidates => Candidates));
         end;
      end loop;
   end Build;

   overriding function Backlinks
     (G : in out Disk_Link_Graph; Node : String)
      return Port.Backlink_Vectors.Vector
   is
      Paths  : Core.Text_Lists.Vector;
      Edges  : Edge_Vectors.Vector;
      Counts : Id_Maps.Map;  --  source -> count as text
      Result : Port.Backlink_Vectors.Vector;
   begin
      Build (To_String (G.Vault), Paths, Edges);
      for E of Edges loop
         if Contains (E.Candidates, Node) then
            declare
               Source : constant String := To_String (E.Source);
            begin
               if Counts.Contains (Source) then
                  Counts.Replace
                    (Source,
                     Natural'Image
                       (Natural'Value (Counts.Element (Source)) + 1));
               else
                  Counts.Insert (Source, " 1");
               end if;
            end;
         end if;
      end loop;
      for C in Counts.Iterate loop
         Result.Append
           (Port.Backlink'
              (Node  => To_Unbounded_String (Id_Maps.Key (C)),
               Count => Natural'Value (Id_Maps.Element (C))));
      end loop;
      return Result;
   end Backlinks;

   overriding function Links
     (G : in out Disk_Link_Graph; Node : String) return Core.Text_Lists.Vector
   is
      Paths  : Core.Text_Lists.Vector;
      Edges  : Edge_Vectors.Vector;
      Result : Core.Text_Lists.Vector;
   begin
      Build (To_String (G.Vault), Paths, Edges);
      for E of Edges loop
         if To_String (E.Source) = Node then
            for Candidate of E.Candidates loop
               if not Result.Contains (Candidate) then
                  Result.Append (Candidate);
               end if;
            end loop;
         end if;
      end loop;
      return Result;
   end Links;

   --  Appends Item to List unless it is there.
   procedure Add_Once
     (List : in out Core.Text_Lists.Vector; Item : Unbounded_String)
   is
   begin
      if not List.Contains (Item) then
         List.Append (Item);
      end if;
   end Add_Once;

   overriding function Unresolved_Links
     (G : in out Disk_Link_Graph) return Port.Unresolved_Vectors.Vector
   is
      Paths  : Core.Text_Lists.Vector;
      Edges  : Edge_Vectors.Vector;
      Result : Port.Unresolved_Vectors.Vector;
      Index  : Id_Maps.Map;  --  target -> position in Result as text
   begin
      Build (To_String (G.Vault), Paths, Edges);
      for E of Edges loop
         if E.Candidates.Is_Empty then
            declare
               Target : constant String := To_String (E.Target);
            begin
               if not Index.Contains (Target) then
                  Result.Append
                    (Port.Unresolved'
                       (Target  => E.Target, Count => 0,
                        Sources => Core.Text_Lists.Vectors.Empty_Vector));
                  Index.Insert
                    (Target, Natural'Image (Natural (Result.Length)));
               end if;
               declare
                  Position : constant Positive :=
                    Positive'Value (Index.Element (Target));
               begin
                  Result.Reference (Position).Count :=
                    Result (Position).Count + 1;
                  Add_Once (Result.Reference (Position).Sources, E.Source);
               end;
            end;
         end if;
      end loop;

      declare
         function Before (A, B : Port.Unresolved) return Boolean is
           (A.Target < B.Target);
         package Order is new Port.Unresolved_Vectors.Generic_Sorting (Before);
      begin
         Order.Sort (Result);
      end;
      return Result;
   end Unresolved_Links;

   overriding function Ambiguous_Links
     (G : in out Disk_Link_Graph) return Port.Ambiguous_Vectors.Vector
   is
      Paths  : Core.Text_Lists.Vector;
      Edges  : Edge_Vectors.Vector;
      Result : Port.Ambiguous_Vectors.Vector;
      Index  : Id_Maps.Map;
   begin
      Build (To_String (G.Vault), Paths, Edges);
      for E of Edges loop
         if E.Candidates.Length > 1 then
            declare
               Target : constant String := To_String (E.Target);
            begin
               if not Index.Contains (Target) then
                  Result.Append
                    (Port.Ambiguous'
                       (Target  => E.Target, Candidates => E.Candidates,
                        Count   => 0,
                        Sources => Core.Text_Lists.Vectors.Empty_Vector));
                  Index.Insert
                    (Target, Natural'Image (Natural (Result.Length)));
               end if;
               declare
                  Position : constant Positive :=
                    Positive'Value (Index.Element (Target));
               begin
                  Result.Reference (Position).Count :=
                    Result (Position).Count + 1;
                  Add_Once (Result.Reference (Position).Sources, E.Source);
               end;
            end;
         end if;
      end loop;

      declare
         function Before (A, B : Port.Ambiguous) return Boolean is
           (A.Target < B.Target);
         package Order is new Port.Ambiguous_Vectors.Generic_Sorting (Before);
      begin
         Order.Sort (Result);
      end;
      return Result;
   end Ambiguous_Links;

   overriding function Orphans
     (G : in out Disk_Link_Graph) return Core.Text_Lists.Vector
   is
      Paths  : Core.Text_Lists.Vector;
      Edges  : Edge_Vectors.Vector;
      Linked : Core.Text_Lists.Vector;
      Result : Core.Text_Lists.Vector;
   begin
      Build (To_String (G.Vault), Paths, Edges);
      for E of Edges loop
         for Candidate of E.Candidates loop
            Add_Once (Linked, Candidate);
         end loop;
      end loop;
      for Path of Paths loop
         if not Linked.Contains (Path) then
            Result.Append (Path);
         end if;
      end loop;
      return Result;
   end Orphans;

   overriding function Dead_Ends
     (G : in out Disk_Link_Graph) return Core.Text_Lists.Vector
   is
      Paths   : Core.Text_Lists.Vector;
      Edges   : Edge_Vectors.Vector;
      Leading : Core.Text_Lists.Vector;
      Result  : Core.Text_Lists.Vector;
   begin
      Build (To_String (G.Vault), Paths, Edges);
      for E of Edges loop
         if not E.Candidates.Is_Empty then
            Add_Once (Leading, E.Source);
         end if;
      end loop;
      for Path of Paths loop
         if not Leading.Contains (Path) then
            Result.Append (Path);
         end if;
      end loop;
      return Result;
   end Dead_Ends;

end Synapse.Adapters.Disk_Link_Graph;
