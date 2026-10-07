
with Synapse.Core.Rarity;
with Synapse.Core.Refs;
with Synapse.Core.Decimal_Image;

package body Synapse.Core.Links is

   HT : constant Character := Character'Val (9);

   package Name_Lists renames Text_Lists;

   function "<" (Left, Right : Edge) return Boolean is
     (if Left.From /= Right.From then Left.From < Right.From
      elsif Left.Weight /= Right.Weight then Left.Weight > Right.Weight
      else Left.To < Right.To);

   package Edge_Sorting is new Edge_Vectors.Generic_Sorting;

   package Name_Sorting is new Text_Lists.Vectors.Generic_Sorting;

   --  The path of a refs site: before its last colon, so a drive letter stays.
   function Path_Of (Site : String) return String is
   begin
      for I in reverse Site'Range loop
         if Site (I) = ':' then
            return Site (Site'First .. I - 1);
         end if;
      end loop;
      return Site;
   end Path_Of;

   --  The nodes that own a path in the refs index, when it has any.
   function Owners_Of
     (Path_To_Nodes : Path_Nodes.Map; Site : String) return Name_Lists.Vector
   is
      Place : constant Path_Nodes.Cursor :=
        Path_To_Nodes.Find (Path_Of (Site));
   begin
      if Path_Nodes.Has_Element (Place) then
         return Path_Nodes.Element (Place);
      end if;
      return Name_Lists.Vectors.Empty_Vector;
   end Owners_Of;

   --  Drops every edge past the first Top of each From, in a vector sorted by
   --  From then descending weight.
   procedure Cap_Per_Node (Edges : in out Edge_Vectors.Vector; Top : Natural)
   is
      Kept : Edge_Vectors.Vector;
      Run  : Natural := 0;
   begin
      for E of Edges loop
         if Kept.Is_Empty or else Kept.Last_Element.From /= E.From then
            Run := 0;
         end if;
         if Run < Top then
            Kept.Append (E);
            Run := Run + 1;
         end if;
      end loop;
      Edges := Kept;
   end Cap_Per_Node;

   function Shown
     (Names : Text_Lists.Vector; Limit : Natural) return Text_Lists.Vector
   is
      Result : Text_Lists.Vector;
      Count  : constant Natural :=
        (if Limit = 0 then Natural (Names.Length)
         else Natural'Min (Limit, Natural (Names.Length)));
   begin
      for I in 1 .. Count loop
         Result.Append (Names (I));
      end loop;
      return Result;
   end Shown;

   type Definers_And_Readers is record
      Defs : Text_Lists.Set;
      Refs : Text_Lists.Set;
   end record;

   package Name_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Definers_And_Readers);

   package Inner_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Text_Lists.Vector, "<", Text_Lists.Vectors."=");

   package Outer_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Inner_Maps.Map, "<", Inner_Maps."=");

   function Compute
     (Refs          : in out Ports.Byte_Source.Source'Class;
      Path_To_Nodes :        Path_Nodes.Map; Node_Count : Natural;
      Opts          :    Options := Default_Options) return Edge_Vectors.Vector
   is
      By_Name : Name_Maps.Map;

      procedure Take (R : Core.Refs.Row) is
         Direction : constant String := To_String (R.Dir);
      begin
         if Direction /= "def" and then Direction /= "ref" then
            return;
         end if;
         declare
            Owners : constant Name_Lists.Vector :=
              Owners_Of (Path_To_Nodes, To_String (R.Site));
            Name   : constant String            := To_String (R.Name);
            Place  : Name_Maps.Cursor           := By_Name.Find (Name);
         begin
            if Owners.Is_Empty then
               return;
            end if;
            if not Name_Maps.Has_Element (Place) then
               By_Name.Insert (Name, (others => <>));
               Place := By_Name.Find (Name);
            end if;
            for Node of Owners loop
               if Direction = "def" then
                  By_Name.Reference (Place).Defs.Include (To_String (Node));
               else
                  By_Name.Reference (Place).Refs.Include (To_String (Node));
               end if;
            end loop;
         end;
      end Take;

      procedure Scan is new Core.Refs.For_Each_Row (Take);

      Rare_Max : constant Positive := Rarity.Rare_Max (Node_Count);
      Pairs    : Outer_Maps.Map;
      Result   : Edge_Vectors.Vector;
   begin
      Scan (Refs);

      for Place in By_Name.Iterate loop
         declare
            Sets :
              Definers_And_Readers renames By_Name.Constant_Reference (Place);
         begin
            --  Rarity is about who reads a symbol, not who declares it.
            if not Sets.Refs.Is_Empty
              and then Natural (Sets.Refs.Length) <= Rare_Max
              and then Natural (Sets.Defs.Length) = 1
            then
               for From_Node of Sets.Refs loop
                  for To_Node of Sets.Defs loop
                     if From_Node /= To_Node then
                        if not Pairs.Contains (From_Node) then
                           Pairs.Insert (From_Node, Inner_Maps.Empty_Map);
                        end if;
                        declare
                           Inner :
                             Inner_Maps.Map renames
                             Pairs.Reference (From_Node);
                        begin
                           if not Inner.Contains (To_Node) then
                              Inner.Insert
                                (To_Node, Text_Lists.Vectors.Empty_Vector);
                           end if;
                           Inner.Reference (To_Node).Append
                             (To_Unbounded_String (Name_Maps.Key (Place)));
                        end;
                     end if;
                  end loop;
               end loop;
            end if;
         end;
      end loop;

      for Outer in Pairs.Iterate loop
         for Inner in Outer_Maps.Element (Outer).Iterate loop
            declare
               Names : Text_Lists.Vector := Inner_Maps.Element (Inner);
            begin
               Name_Sorting.Sort (Names);
               Result.Append
                 (Edge'
                    (From    => To_Unbounded_String (Outer_Maps.Key (Outer)),
                     To      => To_Unbounded_String (Inner_Maps.Key (Inner)),
                     Weight  => Natural (Names.Length),
                     Symbols => Shown (Names, Opts.Symbols_Shown)));
            end;
         end loop;
      end loop;

      Edge_Sorting.Sort (Result);
      if Opts.Top /= 0 then
         Cap_Per_Node (Result, Opts.Top);
      end if;
      return Result;
   end Compute;

   type Occurrence is record
      Path : Unbounded_String;
      Node : Unbounded_String;
   end record;

   package Occurrence_Vectors is new Ada.Containers.Vectors
     (Positive, Occurrence);

   type Occurrences is record
      Defs : Occurrence_Vectors.Vector;
      Refs : Occurrence_Vectors.Vector;
   end record;

   package Occurrence_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Occurrences);

   package Set_Inner_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Text_Lists.Set, "<", Text_Lists.Sets."=");

   package Set_Outer_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (String, Set_Inner_Maps.Map, "<", Set_Inner_Maps."=");

   function Resolve_Ambiguous
     (Refs          : in out Ports.Byte_Source.Source'Class;
      Path_To_Nodes :        Path_Nodes.Map; Path_To_Namespace : Path_Sets.Map;
      Path_To_Deps  :        Path_Sets.Map; Opts : Options := Default_Options)
      return Edge_Vectors.Vector
   is
      By_Name : Occurrence_Maps.Map;

      procedure Take (R : Core.Refs.Row) is
         Direction : constant String := To_String (R.Dir);
      begin
         if Direction /= "def" and then Direction /= "ref" then
            return;
         end if;
         declare
            Path   : constant String := Path_Of (To_String (R.Site));
            Owners : constant Name_Lists.Vector :=
              Owners_Of (Path_To_Nodes, To_String (R.Site));
            Name   : constant String            := To_String (R.Name);
            Place  : Occurrence_Maps.Cursor     := By_Name.Find (Name);
         begin
            if Owners.Is_Empty then
               return;
            end if;
            if not Occurrence_Maps.Has_Element (Place) then
               By_Name.Insert (Name, (others => <>));
               Place := By_Name.Find (Name);
            end if;
            for Node of Owners loop
               if Direction = "def" then
                  By_Name.Reference (Place).Defs.Append
                    (Occurrence'
                       (Path => To_Unbounded_String (Path), Node => Node));
               else
                  By_Name.Reference (Place).Refs.Append
                    (Occurrence'
                       (Path => To_Unbounded_String (Path), Node => Node));
               end if;
            end loop;
         end;
      end Take;

      procedure Scan is new Core.Refs.For_Each_Row (Take);

      Pairs  : Set_Outer_Maps.Map;
      Result : Edge_Vectors.Vector;
   begin
      Scan (Refs);

      for Place in By_Name.Iterate loop
         declare
            Seen : Occurrences renames By_Name.Constant_Reference (Place);
            Definer_Nodes : Text_Lists.Set;
         begin
            if not Seen.Defs.Is_Empty and then not Seen.Refs.Is_Empty then
               --  The distinct definer nodes: the condition Compute drops on.
               --  One node with several defining files is Compute's job.
               for D of Seen.Defs loop
                  Definer_Nodes.Include (To_String (D.Node));
               end loop;
               if Natural (Definer_Nodes.Length) > 1 then
                  for R of Seen.Refs loop
                     declare
                        Same_Node  : Boolean                   := False;
                        Deps_Place : constant Path_Sets.Cursor :=
                          Path_To_Deps.Find (To_String (R.Path));
                     begin
                        for D of Seen.Defs loop
                           if D.Node = R.Node then
                              Same_Node := True;
                              exit;
                           end if;
                        end loop;
                        if not Same_Node
                          and then Path_Sets.Has_Element (Deps_Place)
                        then
                           declare
                              Deps      : constant Text_Lists.Set :=
                                Path_Sets.Element (Deps_Place);
                              Resolved  : Unbounded_String;
                              Found     : Boolean                 := False;
                              Ambiguous : Boolean                 := False;
                           begin
                              for D of Seen.Defs loop
                                 declare
                                    Own       : constant Path_Sets.Cursor :=
                                      Path_To_Namespace.Find
                                        (To_String (D.Path));
                                    Qualifies : Boolean := False;
                                 begin
                                    if Path_Sets.Has_Element (Own) then
                                       for Identity of Path_Sets.Element (Own)
                                       loop
                                          if Deps.Contains (Identity) then
                                             Qualifies := True;
                                             exit;
                                          end if;
                                       end loop;
                                       if Qualifies then
                                          if Found then
                                             if Resolved /= D.Node then
                                                Ambiguous := True;
                                             end if;
                                          else
                                             Found    := True;
                                             Resolved := D.Node;
                                          end if;
                                       end if;
                                    end if;
                                 end;
                              end loop;
                              if Found and then not Ambiguous then
                                 declare
                                    From : constant String :=
                                      To_String (R.Node);
                                    To   : constant String :=
                                      To_String (Resolved);
                                 begin
                                    if not Pairs.Contains (From) then
                                       Pairs.Insert
                                         (From, Set_Inner_Maps.Empty_Map);
                                    end if;
                                    declare
                                       Inner :
                                         Set_Inner_Maps.Map renames
                                         Pairs.Reference (From);
                                    begin
                                       if not Inner.Contains (To) then
                                          Inner.Insert
                                            (To, Text_Lists.Sets.Empty_Set);
                                       end if;
                                       Inner.Reference (To).Include
                                         (Occurrence_Maps.Key (Place));
                                    end;
                                 end;
                              end if;
                           end;
                        end if;
                     end;
                  end loop;
               end if;
            end if;
         end;
      end loop;

      for Outer in Pairs.Iterate loop
         for Inner in Set_Outer_Maps.Element (Outer).Iterate loop
            declare
               Names : Text_Lists.Vector;
            begin
               for Name of Set_Inner_Maps.Element (Inner) loop
                  Names.Append (To_Unbounded_String (Name));
               end loop;
               Result.Append
                 (Edge'
                    (From => To_Unbounded_String (Set_Outer_Maps.Key (Outer)),
                     To => To_Unbounded_String (Set_Inner_Maps.Key (Inner)),
                     Weight  => Natural (Names.Length),
                     Symbols => Shown (Names, Opts.Symbols_Shown)));
            end;
         end loop;
      end loop;

      Edge_Sorting.Sort (Result);
      if Opts.Top /= 0 then
         Cap_Per_Node (Result, Opts.Top);
      end if;
      return Result;
   end Resolve_Ambiguous;

   function Merge_Edges
     (Edges, Extra : Edge_Vectors.Vector; Top : Natural)
      return Edge_Vectors.Vector
   is
      Result : Edge_Vectors.Vector := Edges;
   begin
      for E of Extra loop
         Result.Append (E);
      end loop;
      Edge_Sorting.Sort (Result);
      if Top /= 0 then
         Cap_Per_Node (Result, Top);
      end if;
      return Result;
   end Merge_Edges;

   function Image (E : Edge) return String is
      Text : Unbounded_String;
   begin
      Append
        (Text,
         To_String (E.From) & HT & To_String (E.To) & HT &
         Decimal_Image.Image (E.Weight) & HT);
      for I in 1 .. Natural (E.Symbols.Length) loop
         if I > 1 then
            Append (Text, " ");
         end if;
         Append (Text, E.Symbols (I));
      end loop;
      Append (Text, Character'Val (10));
      return To_String (Text);
   end Image;

end Synapse.Core.Links;
