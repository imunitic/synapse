with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.File_Byte_Source;
with Synapse.Commands.Graph_Support;
with Synapse.Commands.Node_Lists;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Links;
with Synapse.Core.Text_Lists;

package body Synapse.Commands.Link_Graph is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;
   package Links renames Synapse.Core.Links;

   Prog : constant String    := "synapse-link-graph";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse link-graph --refs <_refs.tsv> --lists <dir> " &
     "[--deps <f>] [--namespaces <f>]" & LF &
     "                          [--top N] [--out <dir>]" & LF & LF &
     "  --refs        synapse build-refs's index. Default " &
     "$SYNAPSE_WORK_DIR/_refs.tsv." & LF &
     "  --lists       the NN.txt/NN.title path lists synapse build-lists " &
     "wrote." & LF & "  --deps        synapse build-deps's index. Default " &
     "$SYNAPSE_WORK_DIR/_deps.tsv," & LF &
     "                skipped silently if absent." & LF &
     "  --namespaces  synapse build-namespaces's index. Default" & LF &
     "                $SYNAPSE_WORK_DIR/_namespaces.tsv, skipped silently " &
     "if absent." & LF &
     "  --top         edges kept per node, strongest first, default 8. 0 " &
     "means no cap." & LF &
     "  --out         where to write links.tsv. Default $SYNAPSE_WORK_DIR." &
     LF;

   --  `path<TAB>value` rows folded into the set of values of each path: the
   --  shape of both a file's declared dependencies and its declared
   --  namespaces.
   function Path_Sets_Of (Table : String) return Links.Path_Sets.Map is
      Result : Links.Path_Sets.Map;
      Start  : Positive := Table'First;
   begin
      for I in Table'First .. Table'Last + 1 loop
         if I > Table'Last or else Table (I) = LF then
            declare
               Last : Natural := I - 1;
               Tab  : Natural := 0;
               Tab2 : Natural := 0;
            begin
               if Last >= Start and then Table (Last) = ASCII.CR then
                  Last := Last - 1;
               end if;
               for K in Start .. Last loop
                  if Table (K) = HT then
                     if Tab = 0 then
                        Tab := K;
                     elsif Tab2 = 0 then
                        Tab2 := K;
                     end if;
                  end if;
               end loop;
               if Last >= Start and then Tab > 0 then
                  declare
                     Path  : constant String := Table (Start .. Tab - 1);
                     Value : constant String :=
                       Table
                         (Tab + 1 .. (if Tab2 > 0 then Tab2 - 1 else Last));
                  begin
                     if not Result.Contains (Path) then
                        Result.Insert (Path, Core.Text_Lists.Sets.Empty_Set);
                     end if;
                     declare
                        Updated : Core.Text_Lists.Set := Result (Path);
                     begin
                        Updated.Include (Value);
                        Result.Replace (Path, Updated);
                     end;
                  end;
               end if;
               Start := I + 1;
            end;
         end if;
      end loop;
      return Result;
   end Path_Sets_Of;

   function Write
     (Env                                                : Environment;
      Refs_In, Lists_Dir, Deps_In, Namespaces_In, Out_In : String;
      Have_Refs, Have_Deps, Have_Namespaces, Have_Out : Boolean; Top : Natural)
      return Exit_Code
   is
      Refs_Path       : Unbounded_String := To_Unbounded_String (Refs_In);
      Deps_Path       : Unbounded_String := To_Unbounded_String (Deps_In);
      Namespaces_Path : Unbounded_String :=
        To_Unbounded_String (Namespaces_In);
      Out_Dir         : Unbounded_String := To_Unbounded_String (Out_In);
      Use_Deps        : Boolean          := Have_Deps;
      Use_Namespaces  : Boolean          := Have_Namespaces;
   begin
      if not Ada.Directories.Exists (Lists_Dir) then
         Complain (Env, Prog & ": no such lists dir: " & Lists_Dir & LF);
         return 1;
      end if;
      --  The work directory supplies whichever of --refs and --out is
      --  missing, and then the two optional tables beside them.
      if not Have_Refs or else not Have_Out then
         declare
            Work : constant Support.Maybe_Path := Support.Work_Dir (Env, Prog);
         begin
            if not Work.Found then
               return 1;
            end if;
            if not Have_Refs then
               Refs_Path := Work.Value & "/_refs.tsv";
            end if;
            if not Have_Out then
               Out_Dir := Work.Value;
            end if;
            if not Have_Deps then
               Deps_Path := Work.Value & "/_deps.tsv";
               Use_Deps  := True;
            end if;
            if not Have_Namespaces then
               Namespaces_Path := Work.Value & "/_namespaces.tsv";
               Use_Namespaces  := True;
            end if;
         end;
      end if;

      declare
         Index : Adapters.File_Byte_Source.Source;
      begin
         begin
            Adapters.File_Byte_Source.Open (Index, To_String (Refs_Path));
         exception
            when others =>
               Complain
                 (Env,
                  Prog & ": no reference index at " & To_String (Refs_Path) &
                  " -- run `synapse build-refs`" & LF);
               return 1;
         end;
         declare
            Nodes         : constant Node_Lists.Node_Vectors.Vector :=
              Node_Lists.Read (Lists_Dir);
            Path_To_Nodes : Links.Path_Nodes.Map;
            Titles        : Core.Text_Lists.Set;
         begin
            for Node of Nodes loop
               Titles.Include (To_String (Node.Title));
               for Path of Node.Paths loop
                  declare
                     Key : constant String := To_String (Path);
                  begin
                     if not Path_To_Nodes.Contains (Key) then
                        Path_To_Nodes.Insert (Key, Lists.Vectors.Empty_Vector);
                     end if;
                     declare
                        Updated : Lists.Vector := Path_To_Nodes (Key);
                     begin
                        Updated.Append (Node.Title);
                        Path_To_Nodes.Replace (Key, Updated);
                     end;
                  end;
               end loop;
            end loop;
            if Titles.Is_Empty then
               Complain
                 (Env,
                  Prog & ": no NN.txt/NN.title pairs in " & Lists_Dir & LF);
               return 1;
            end if;

            declare
               Count : constant Natural          := Natural (Titles.Length);
               Options                    : constant Links.Options    :=
                 (Top           => Top,
                  Symbols_Shown => Links.Default_Options.Symbols_Shown);
               Edges                      : Links.Edge_Vectors.Vector :=
                 Links.Compute (Index, Path_To_Nodes, Count, Options);
               Resolved                   : Natural                   := 0;
               Deps_Text, Namespaces_Text : Unbounded_String;
               Have_Both                  : Boolean                   := False;
               Read_Deps, Read_Namespaces : Boolean                   := False;
            begin
               if Use_Deps and then Use_Namespaces then
                  Support.Read_File
                    (To_String (Deps_Path), Natural'Last, Deps_Text,
                     Read_Deps);
                  Support.Read_File
                    (To_String (Namespaces_Path), Natural'Last,
                     Namespaces_Text, Read_Namespaces);
                  Have_Both := Read_Deps and then Read_Namespaces;
               end if;
               if Have_Both then
                  declare
                     Extra : constant Links.Edge_Vectors.Vector :=
                       Links.Resolve_Ambiguous
                         (Index, Path_To_Nodes,
                          Path_Sets_Of (To_String (Namespaces_Text)),
                          Path_Sets_Of (To_String (Deps_Text)), Options);
                  begin
                     Resolved := Natural (Extra.Length);
                     Edges    := Links.Merge_Edges (Edges, Extra, Top);
                  end;
               end if;

               declare
                  Target    : constant String :=
                    To_String (Out_Dir) & "/links.tsv";
                  Body_Text : Unbounded_String;
                  Covered   : Core.Text_Lists.Set;
               begin
                  for E of Edges loop
                     Append (Body_Text, Links.Image (E));
                     Covered.Include (To_String (E.From));
                  end loop;
                  Support.Write_File (Target, To_String (Body_Text));
                  Complain
                    (Env,
                     Prog & ": " & Core.Decimal_Image.Image (Count) &
                     " nodes, " &
                     Core.Decimal_Image.Image (Natural (Edges.Length)) &
                     " edges (" & Core.Decimal_Image.Image (Resolved) &
                     " via import-edge resolution), " &
                     Core.Decimal_Image.Image (Natural (Covered.Length)) &
                     " nodes with at least one -> " & Target & LF);
                  return 0;
               end;
            end;
         end;
      end;
   end Write;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Refs_Path, Lists_Dir, Deps_Path, Namespaces_Path,
      Out_Dir : Unbounded_String;
      Have_Refs, Have_Lists, Have_Deps, Have_Namespaces, Have_Out : Boolean  :=
        False;
      Top : Natural  := 8;
      I : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg : constant String := To_String (Args (I));
         begin
            if Arg in "-h" | "--help" then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg in
                "--refs" | "--lists" | "--deps" | "--namespaces" | "--out"
                | "--top"
            then
               if I = Natural (Args.Length) then
                  return Usage_Error (Env, Usage_Text);
               end if;
               I := I + 1;
               if Arg = "--refs" then
                  Refs_Path := Args (I);
                  Have_Refs := True;
               elsif Arg = "--lists" then
                  Lists_Dir  := Args (I);
                  Have_Lists := True;
               elsif Arg = "--deps" then
                  Deps_Path := Args (I);
                  Have_Deps := True;
               elsif Arg = "--namespaces" then
                  Namespaces_Path := Args (I);
                  Have_Namespaces := True;
               elsif Arg = "--out" then
                  Out_Dir  := Args (I);
                  Have_Out := True;
               else
                  declare
                     Raw : constant String := To_String (Args (I));
                  begin
                     if Raw'Length = 0
                       or else not (for all C of Raw => C in '0' .. '9')
                     then
                        return Usage_Error (Env, Usage_Text);
                     end if;
                     Top := Natural'Value (Raw);
                  exception
                     when Constraint_Error =>
                        return Usage_Error (Env, Usage_Text);
                  end;
               end if;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
         I := I + 1;
      end loop;
      if not Have_Lists then
         return Usage_Error (Env, Usage_Text);
      end if;
      return
        Write
          (Env, To_String (Refs_Path), To_String (Lists_Dir),
           To_String (Deps_Path), To_String (Namespaces_Path),
           To_String (Out_Dir), Have_Refs, Have_Deps, Have_Namespaces,
           Have_Out, Top);
   end Run;

end Synapse.Commands.Link_Graph;
