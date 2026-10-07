with Ada.Containers.Ordered_Sets;

with Synapse.Core.Graph_Model;
with Synapse.Core.Text_Lists;

package body Synapse.Adapters.Tree_Sitter.Tagger is

   use Ada.Strings.Unbounded;
   use type Core.Grammar_Registry.Query_Source;
   use type Core.Graph_Model.Role;

   package Graph renames Synapse.Core.Graph_Model;
   package Registry renames Synapse.Core.Grammar_Registry;

   LF : constant Character := Character'Val (10);

   function Classify (Name : String) return Predicate is
     (if Name'Length = 0 then Unevaluable
      elsif Name (Name'Last) = '!' then Directive elsif Name = "eq?" then Equal
      elsif Name = "not-eq?" then Not_Equal elsif Name = "any-of?" then Any_Of
      elsif Name = "not-any-of?" then Not_Any_Of else Unevaluable);

   function Is_Created (T : Tagger) return Boolean is (T.Ready);

   function Starts_With (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   ---------------------------------------------------------------------------
   --  Predicates
   ---------------------------------------------------------------------------

   --  Steps run `name, argument.., Done` and repeat: a step is a name when it
   --  starts a group and is a string.
   function Is_Name_Step
     (Steps : Predicate_Steps; S : Positive) return Boolean is
     ((S = Steps'First or else Steps (S - 1).Kind = Done)
      and then Steps (S).Kind = String_Literal);

   --  Disabled and not ignored: a false tag is worse than a missing one.
   function Is_Unevaluable (Q : Query; Pattern_Index : Natural) return Boolean
   is
      Steps : constant Predicate_Steps := Predicates (Q, Pattern_Index);
   begin
      for S in Steps'Range loop
         if Is_Name_Step (Steps, S)
           and then Classify (String_Value (Q, Steps (S).Value)) = Unevaluable
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Unevaluable;

   --  Disables every pattern with a predicate that cannot be answered, and
   --  tells whether any pattern is left that can match.
   procedure Disable_Unevaluable (Q : in out Query; Any_Left : out Boolean) is
      Total    : constant Natural := Pattern_Count (Q);
      Disabled : Natural          := 0;
   begin
      for I in 0 .. Total - 1 loop
         if Is_Unevaluable (Q, I) then
            Disable_Pattern (Q, I);
            Disabled := Disabled + 1;
         end if;
      end loop;
      Any_Left := Total = 0 or else Disabled < Total;
   end Disable_Unevaluable;

   --  Where a node's bytes sit in Source, or not found when they fall outside
   --  it.
   procedure Locate
     (Source      :     String; N : Node; Found : out Boolean;
      First, Last : out Integer)
   is
      Start  : constant Natural := Start_Byte (N);
      Finish : constant Natural := End_Byte (N);
   begin
      Found := Start <= Finish and then Finish <= Source'Length;
      First := Source'First + Start;
      Last  := Source'First + Finish - 1;
   end Locate;

   --  The text a capture of the match landed on.
   procedure Capture_Text
     (M     :     Match; Id : Natural; Source : String; Found : out Boolean;
      First : out Integer; Last : out Integer)
   is
   begin
      Found := False;
      First := Source'First;
      Last  := Source'First - 1;
      for I in 1 .. Capture_Count (M) loop
         if Capture (M, I).Id = Id then
            Locate (Source, Capture (M, I).Captured, Found, First, Last);
            return;
         end if;
      end loop;
   end Capture_Text;

   function Holds
     (Q      : Query; Kind : Predicate; Args : Predicate_Steps; M : Match;
      Source : String) return Boolean
   is
      Found      : Boolean;
      First_L    : Integer;
      Last_L     : Integer;
      First_R    : Integer;
      Last_R     : Integer;
      Found_Item : Boolean := False;
   begin
      if Args'Length < 2 then
         return True;
      end if;
      --  The first argument is the capture under test; a literal there is
      --  malformed, so it fails and does not let the match through.
      if Args (Args'First).Kind /= Capture then
         return False;
      end if;
      Capture_Text
        (M, Args (Args'First).Value, Source, Found, First_L, Last_L);
      if not Found then
         return False;
      end if;
      declare
         Left : constant String := Source (First_L .. Last_L);
      begin
         case Kind is
            when Equal | Not_Equal =>
               declare
                  Second : constant Predicate_Step := Args (Args'First + 1);
                  Same   : Boolean;
               begin
                  if Second.Kind = Capture then
                     Capture_Text
                       (M, Second.Value, Source, Found, First_R, Last_R);
                     if not Found then
                        return False;
                     end if;
                     Same := Left = Source (First_R .. Last_R);
                  else
                     Same := Left = String_Value (Q, Second.Value);
                  end if;
                  return (Kind = Equal) = Same;
               end;

            when Any_Of | Not_Any_Of =>
               for I in Args'First + 1 .. Args'Last loop
                  if Args (I).Kind = String_Literal
                    and then Left = String_Value (Q, Args (I).Value)
                  then
                     Found_Item := True;
                  end if;
               end loop;
               return (Kind = Any_Of) = Found_Item;

            when others =>
               return True;
         end case;
      end;
   end Holds;

   --  Per match and not per pattern: the answer depends on the text the
   --  captures landed on. A pattern that gets here passed at creation.
   function Predicates_Hold
     (Q : Query; M : Match; Source : String) return Boolean
   is
      Steps : constant Predicate_Steps := Predicates (Q, Pattern (M));
      S     : Natural                  := Steps'First;
      Last  : Natural;
   begin
      while S <= Steps'Last loop
         if not Is_Name_Step (Steps, S) then
            S := S + 1;
         else
            declare
               Kind : constant Predicate :=
                 Classify (String_Value (Q, Steps (S).Value));
            begin
               Last := S + 1;
               while Last <= Steps'Last and then Steps (Last).Kind /= Done loop
                  Last := Last + 1;
               end loop;
               if Kind /= Directive
                 and then not Holds
                   (Q, Kind, Steps (S + 1 .. Last - 1), M, Source)
               then
                  return False;
               end if;
               S := Last + 1;
            end;
         end if;
      end loop;
      return True;
   end Predicates_Hold;

   ---------------------------------------------------------------------------
   --  Tags
   ---------------------------------------------------------------------------

   --  The whole line containing a byte offset, trimmed: what a tag echoes of
   --  where it was found.
   function Line_At (Source : String; Offset : Natural) return String is
      Start  : Integer := Source'First + Offset;
      Finish : Integer := Source'First + Offset;
   begin
      while Start > Source'First and then Source (Start - 1) /= LF loop
         Start := Start - 1;
      end loop;
      while Finish <= Source'Last and then Source (Finish) /= LF loop
         Finish := Finish + 1;
      end loop;
      while Start < Finish
        and then Source (Start) in ' ' | Character'Val (9) | Character'Val (13)
      loop
         Start := Start + 1;
      end loop;
      while Finish > Start
        and then Source (Finish - 1) in
          ' ' | Character'Val (9) | Character'Val (13)
      loop
         Finish := Finish - 1;
      end loop;
      return Source (Start .. Finish - 1);
   end Line_At;

   procedure Add_Tag
     (Into  : in out Located_Vectors.Vector; Source : String; Where : Node;
      Which :        Graph.Role; Kind : String)
   is
      Found       : Boolean;
      First, Last : Integer;
   begin
      Locate (Source, Where, Found, First, Last);
      if not Found then
         return;
      end if;
      Into.Append
        (Synapse.Ports.Extractor.Located_Tag'
           (Item  =>
              Graph.Tag'
                (Name       => To_Unbounded_String (Source (First .. Last)),
                 Kind       => To_Unbounded_String (Kind), Which => Which,
                 Line       => Start_Point (Where).Row,
                 Expression =>
                   To_Unbounded_String (Line_At (Source, Start_Byte (Where)))),
            Where =>
              (Start_Row => Start_Point (Where).Row,
               Start_Col => Start_Point (Where).Column,
               End_Row   => End_Point (Where).Row,
               End_Col   => End_Point (Where).Column)));
   end Add_Tag;

   --  tags.scm: `@name` and a sibling `@definition.<kind>` or
   --  `@reference.<kind>`. Neither a name nor a role is not a tag, which is
   --  legitimate in a tags query.
   function Tags_From_Tags_Query
     (T : Tagger; Root_Node : Node; Source : String)
      return Located_Vectors.Vector
   is
      Result : Located_Vectors.Vector;
      C      : Cursor;
      M      : Match;
      Found  : Boolean;
   begin
      Exec (C, T.Main, Root_Node);
      loop
         Next_Match (C, Found, M);
         exit when not Found;
         if Predicates_Hold (T.Main, M, Source) then
            declare
               Name_Node : Node       := No_Node;
               Which     : Graph.Role := Graph.Def;
               Has_Role  : Boolean    := False;
               Kind      : Unbounded_String;
            begin
               for I in 1 .. Capture_Count (M) loop
                  declare
                     Item : constant Match_Capture := Capture (M, I);
                     Name : constant String := Capture_Name (T.Main, Item.Id);
                  begin
                     if Name = "name" then
                        Name_Node := Item.Captured;
                     elsif Starts_With (Name, "definition.") then
                        Which    := Graph.Def;
                        Has_Role := True;
                        Kind     :=
                          To_Unbounded_String
                            (Name (Name'First + 11 .. Name'Last));
                     elsif Starts_With (Name, "reference.") then
                        Which    := Graph.Ref;
                        Has_Role := True;
                        Kind     :=
                          To_Unbounded_String
                            (Name (Name'First + 10 .. Name'Last));
                     end if;
                  end;
               end loop;
               if not Is_Null (Name_Node) and then Has_Role then
                  Add_Tag (Result, Source, Name_Node, Which, To_String (Kind));
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Tags_From_Tags_Query;

   Definition_Prefix : constant String := "local.definition";

   function Tags_From_Locals_Query
     (T : Tagger; Root_Node : Node; Source : String)
      return Located_Vectors.Vector
   is
      Result : Located_Vectors.Vector;
      C      : Cursor;
      M      : Match;
      Found  : Boolean;
   begin
      Exec (C, T.Main, Root_Node);
      loop
         Next_Match (C, Found, M);
         exit when not Found;
         if Predicates_Hold (T.Main, M, Source) then
            for I in 1 .. Capture_Count (M) loop
               declare
                  Item : constant Match_Capture := Capture (M, I);
                  Name : constant String := Capture_Name (T.Main, Item.Id);
               begin
                  if Starts_With (Name, Definition_Prefix) then
                     declare
                        Rest : constant String :=
                          Name
                            (Name'First + Definition_Prefix'Length ..
                                 Name'Last);
                     begin
                        if Rest'Length = 0 or else Rest (Rest'First) = '.' then
                           declare
                              Raw   : constant String                        :=
                                (if Rest'Length = 0 then ""
                                 else Rest (Rest'First + 1 .. Rest'Last));
                              Ruled : constant Core.Kind_Synonyms.Maybe_Kind :=
                                Core.Kind_Synonyms.Kind_For
                                  (T.Rules, Raw, To_String (T.Scope));
                           begin
                              if Ruled.Found then
                                 Add_Tag
                                   (Result, Source, Item.Captured, Graph.Def,
                                    To_String (Ruled.Value));
                              end if;
                           end;
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end if;
      end loop;
      return Result;
   end Tags_From_Locals_Query;

   ---------------------------------------------------------------------------
   --  The bounded walk
   ---------------------------------------------------------------------------

   function Lower (C : Character) return Character is
     (if C in 'A' .. 'Z' then Character'Val (Character'Pos (C) + 32) else C);

   function Is_Name_Type (Type_Name : String) return Boolean is
      function Equals (Word : String) return Boolean is
      begin
         if Type_Name'Length /= Word'Length then
            return False;
         end if;
         for I in 0 .. Word'Length - 1 loop
            if Lower (Type_Name (Type_Name'First + I)) /= Word (Word'First + I)
            then
               return False;
            end if;
         end loop;
         return True;
      end Equals;
   begin
      return Equals ("identifier") or else Equals ("name");
   end Is_Name_Type;

   type Queued is record
      Item  : Node;
      Depth : Natural;
   end record;

   package Queues is new Ada.Containers.Vectors (Positive, Queued);

   --  Breadth first, depth capped at 3, for the nearest identifier or name
   --  descendant on a single line: a queue, so depth 1 is looked at before
   --  depth 2. The node itself is never a candidate.
   procedure Find_Name_Descendant
     (Start : Node; Source : String; Found : out Boolean; Name : out Node)
   is
      Queue : Queues.Vector;
      Head  : Positive := 1;
   begin
      Found := False;
      Name  := No_Node;
      Queue.Append (Queued'(Item => Start, Depth => 0));
      while Head <= Natural (Queue.Length) loop
         declare
            Current : constant Queued := Queue (Head);
         begin
            Head := Head + 1;
            if Current.Depth > 0 and then Is_Name_Type (Kind (Current.Item))
            then
               declare
                  Located     : Boolean;
                  First, Last : Integer;
               begin
                  Locate (Source, Current.Item, Located, First, Last);
                  if Located then
                     declare
                        One_Line : Boolean := True;
                     begin
                        for I in First .. Last loop
                           if Source (I) = LF then
                              One_Line := False;
                           end if;
                        end loop;
                        if One_Line then
                           Found := True;
                           Name  := Current.Item;
                           return;
                        end if;
                     end;
                  end if;
               end;
            end if;
            if Current.Depth < 3 then
               for I in 1 .. Named_Child_Count (Current.Item) loop
                  Queue.Append
                    (Queued'
                       (Item  => Named_Child (Current.Item, I),
                        Depth => Current.Depth + 1));
               end loop;
            end if;
         end;
      end loop;
   end Find_Name_Descendant;

   package Seen_Sets is new Ada.Containers.Ordered_Sets (Long_Long_Integer);

   package Node_Stacks is new Ada.Containers.Vectors (Positive, Node);

   --  Every node of a type guessed to have no name field becomes a tag named
   --  by the nearest identifier. Depth first over the whole tree, in source
   --  order, into a matched node's children too: a declaration can nest in
   --  another, and one match must not hide the ones below it. A stack stands
   --  in for recursion, so a deeply nested file cannot exhaust the call stack.
   function Tags_From_Walk
     (T : Tagger; Root_Node : Node; Source : String)
      return Located_Vectors.Vector
   is
      Result   : Located_Vectors.Vector;
      Stack    : Node_Stacks.Vector;
      Seen     : Seen_Sets.Set;
      Walkable : Boolean := False;
   begin
      for G of T.Guesses loop
         if not G.Has_Name_Field then
            Walkable := True;
         end if;
      end loop;
      if not Walkable then
         return Result;
      end if;

      Stack.Append (Root_Node);
      while not Stack.Is_Empty loop
         declare
            Current   : constant Node   := Stack.Last_Element;
            Type_Name : constant String := Kind (Current);
         begin
            Stack.Delete_Last;
            for G of T.Guesses loop
               if not G.Has_Name_Field
                 and then To_String (G.Type_Name) = Type_Name
               then
                  declare
                     Found       : Boolean;
                     Name        : Node;
                     Located     : Boolean;
                     First, Last : Integer;
                  begin
                     Find_Name_Descendant (Current, Source, Found, Name);
                     if Found then
                        Locate (Source, Name, Located, First, Last);
                        --  Two guessed ancestors landing on one identifier
                        --  are one definition and not two.
                        if Located
                          and then not Seen.Contains
                            (Long_Long_Integer (Start_Byte (Name)) * 2**32 +
                             Long_Long_Integer (End_Byte (Name)))
                        then
                           Seen.Insert
                             (Long_Long_Integer (Start_Byte (Name)) * 2**32 +
                              Long_Long_Integer (End_Byte (Name)));
                           Add_Tag
                             (Result, Source, Name, Graph.Def,
                              To_String (G.Kind));
                        end if;
                     end if;
                  end;
                  exit;  --  a type matches at most one guess
               end if;
            end loop;
            for I in reverse 1 .. Named_Child_Count (Current) loop
               Stack.Append (Named_Child (Current, I));
            end loop;
         end;
      end loop;
      return Result;
   end Tags_From_Walk;

   ---------------------------------------------------------------------------
   --  Local references
   ---------------------------------------------------------------------------

   --  Every name with a local definition capture anywhere in the file.
   --  Predicates are not consulted: this is a set of names and not a tag.
   function Locally_Defined_Names
     (T : Tagger; Root_Node : Node; Source : String) return Core.Text_Lists.Set
   is
      Names : Core.Text_Lists.Set;
      C     : Cursor;
      M     : Match;
      Found : Boolean;
   begin
      Exec (C, T.Locals, Root_Node);
      loop
         Next_Match (C, Found, M);
         exit when not Found;
         for I in 1 .. Capture_Count (M) loop
            declare
               Item : constant Match_Capture := Capture (M, I);
               Name : constant String := Capture_Name (T.Locals, Item.Id);
            begin
               if Starts_With (Name, Definition_Prefix) then
                  declare
                     Rest : constant String :=
                       Name
                         (Name'First + Definition_Prefix'Length .. Name'Last);
                  begin
                     if Rest'Length = 0 or else Rest (Rest'First) = '.' then
                        declare
                           Located     : Boolean;
                           First, Last : Integer;
                        begin
                           Locate
                             (Source, Item.Captured, Located, First, Last);
                           if Located then
                              Names.Include (Source (First .. Last));
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end loop;
      return Names;
   end Locally_Defined_Names;

   --  A reference whose name is a same-file local binding is answered and
   --  dropped here, and never reaches the cross-file join it was not a
   --  candidate for.
   function Without_Local_References
     (T    : Tagger; Root_Node : Node; Source : String;
      Tags : Located_Vectors.Vector) return Located_Vectors.Vector
   is
      Locals : constant Core.Text_Lists.Set :=
        Locally_Defined_Names (T, Root_Node, Source);
      Kept   : Located_Vectors.Vector;
   begin
      if Locals.Is_Empty then
         return Tags;
      end if;
      for Item of Tags loop
         if Item.Item.Which = Graph.Ref
           and then Locals.Contains (To_String (Item.Item.Name))
         then
            null;
         else
            Kept.Append (Item);
         end if;
      end loop;
      return Kept;
   end Without_Local_References;

   ---------------------------------------------------------------------------
   --  Creating and tagging
   ---------------------------------------------------------------------------

   procedure Create
     (T              : in out Tagger; Lang : Language; Query_Text : String;
      Source         :        Core.Grammar_Registry.Query_Source;
      Rules          :        Core.Kind_Synonyms.Rule_List; Scope : String;
      Classification :        Core.Node_Types.Guess_Vectors.Vector;
      Locals_Text    :        Core.Grammar_Registry.Maybe_Text;
      Status         :    out Create_Status)
   is
      Query_Status : Tree_Sitter.Query_Status;
      Error_Offset : Natural;
      Any_Left     : Boolean;
      Ready_Locals : Boolean := False;
      Parser_Ready : Boolean;
   begin
      Compile (T.Main, Lang, Query_Text, Query_Status, Error_Offset);
      if Query_Status /= Compiled then
         Status := Query_Invalid;
         return;
      end if;
      Disable_Unevaluable (T.Main, Any_Left);
      if not Any_Left then
         Status := Predicate_Unsupported;
         return;
      end if;

      --  Best effort: a locals.scm that cannot be used only means no
      --  filtering of local references for this grammar.
      if Locals_Text.Found then
         Compile
           (T.Locals, Lang, To_String (Locals_Text.Value), Query_Status,
            Error_Offset);
         if Query_Status = Compiled then
            Disable_Unevaluable (T.Locals, Any_Left);
            Ready_Locals := Any_Left;
         end if;
      end if;

      Set_Language (T.Reader, Lang, Parser_Ready);
      if not Parser_Ready then
         Status := Language_Rejected;
         return;
      end if;

      T.Has_Locals := Ready_Locals;
      T.Source     := Source;
      T.Rules      := Rules;
      T.Scope      := To_Unbounded_String (Scope);
      T.Guesses    := Classification;
      T.Ready      := True;
      Status       := Created;
   end Create;

   function Tag_File_Located
     (T : in out Tagger; Source : String) return Located_Results.Result
   is
   begin
      if not T.Ready then
         return Located_Results.Failure (Not_Created);
      end if;
      declare
         Parsed : constant Tree := Parse (T.Reader, Source);
      begin
         if Is_Null (Parsed) then
            return Located_Results.Failure (Not_Parsed);
         end if;
         declare
            Root_Node : constant Node := Root (Parsed);
            Tags      : Located_Vectors.Vector;
         begin
            case T.Source is
               when Registry.Tags | Registry.Override =>
                  Tags := Tags_From_Tags_Query (T, Root_Node, Source);

               when Registry.Locals =>
                  Tags := Tags_From_Locals_Query (T, Root_Node, Source);

               when Registry.Generated =>
                  --  Two sources at once: the query covers every guess with
                  --  a name field and the walk the rest.
                  Tags := Tags_From_Tags_Query (T, Root_Node, Source);
                  Tags.Append_Vector (Tags_From_Walk (T, Root_Node, Source));
            end case;
            if T.Has_Locals then
               Tags := Without_Local_References (T, Root_Node, Source, Tags);
            end if;
            return Located_Results.Success (Tags);
         end;
      end;
   end Tag_File_Located;

   function Tag_File
     (T : in out Tagger; Source : String) return Tag_Results.Result
   is
      Got : constant Located_Results.Result := Tag_File_Located (T, Source);
   begin
      if not Located_Results.Is_Success (Got) then
         return Tag_Results.Failure (Located_Results.Error (Got));
      end if;
      declare
         Plain : Tag_Vectors.Vector;
      begin
         for Item of Located_Results.Value (Got) loop
            Plain.Append (Item.Item);
         end loop;
         return Tag_Results.Success (Plain);
      end;
   end Tag_File;

end Synapse.Adapters.Tree_Sitter.Tagger;
