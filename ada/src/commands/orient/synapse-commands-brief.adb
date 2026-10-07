with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Commands.Cli_Args;
with Synapse.Commands.Graph_Support;
with Synapse.Commands.Node_Lists;
with Synapse.Core.Decimal_Image;

package body Synapse.Commands.Brief is

   use Ada.Strings.Unbounded;

   package Support renames Synapse.Commands.Graph_Support;

   Prog : constant String    := "synapse-brief";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse brief --lists <dir> [--rank <dir>] [--links <file>] " &
     "[--repo <path>] [--out <dir>]" & LF & LF &
     "  --lists  the NN.txt/NN.title path lists synapse build-lists wrote." &
     LF & "  --rank   where synapse rank --lists wrote " &
     "NN.summary.tsv/NN.crux.tsv." & LF &
     "           Default $SYNAPSE_WORK_DIR/rank." & LF &
     "  --links  synapse link-graph's output. Default " &
     "$SYNAPSE_WORK_DIR/links.tsv." & LF &
     "           A missing file warns and leaves every node's edges empty." &
     LF & "  --out    where to write brief/NN.md. Default $SYNAPSE_WORK_DIR." &
     LF;

   function Trimmed (Text : String) return String is
      First : Positive := Text'First;
      Last  : Natural  := Text'Last;
   begin
      while First <= Last and then Text (First) in ' ' | HT | ASCII.CR | LF
      loop
         First := First + 1;
      end loop;
      while Last >= First and then Text (Last) in ' ' | HT | ASCII.CR | LF loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trimmed;

   --  Rows of a ranked pool in a fence, or `(none)`.
   function Tsv_Block (Text : String) return String is
      Body_Text : constant String := Trimmed (Text);
   begin
      if Body_Text'Length = 0 then
         return "(none)" & LF;
      end if;
      return "```" & LF & Body_Text & LF & "```" & LF;
   end Tsv_Block;

   --  The rows of the link graph that start at this node. The file is
   --  strongest first for each node, and that order is kept.
   function Links_For (Links_Text, Title : String) return String is
      Rows  : Unbounded_String;
      Start : Positive := Links_Text'First;
   begin
      for I in Links_Text'First .. Links_Text'Last + 1 loop
         if I > Links_Text'Last or else Links_Text (I) = LF then
            if I > Start then
               declare
                  Line : constant String := Links_Text (Start .. I - 1);
                  Tab  : Natural         := 0;
               begin
                  for K in Line'Range loop
                     if Line (K) = HT then
                        Tab := K;
                        exit;
                     end if;
                  end loop;
                  if Tab > 0 and then Line (Line'First .. Tab - 1) = Title then
                     Append (Rows, Line & LF);
                  end if;
               end;
            end if;
            Start := I + 1;
         end if;
      end loop;
      if Length (Rows) = 0 then
         return "(none)" & LF;
      end if;
      return "```" & LF & To_String (Rows) & "```" & LF;
   end Links_For;

   function Build
     (Env : Environment; Lists_Dir : String;
      Rank_In, Links_In, Repo, Out_In            : String;
      Have_Rank, Have_Links, Have_Repo, Have_Out : Boolean) return Exit_Code
   is
      Rank_Dir   : Unbounded_String := To_Unbounded_String (Rank_In);
      Links_Path : Unbounded_String := To_Unbounded_String (Links_In);
      Out_Dir    : Unbounded_String := To_Unbounded_String (Out_In);
   begin
      if not Ada.Directories.Exists (Lists_Dir) then
         Complain (Env, Prog & ": no such lists dir: " & Lists_Dir & LF);
         return 1;
      end if;
      if not (Have_Rank and then Have_Links and then Have_Out) then
         declare
            Work : constant Support.Maybe_Path :=
              Support.Work_Dir (Env, Prog, (if Have_Repo then Repo else "."));
         begin
            if not Work.Found then
               return 1;
            end if;
            if not Have_Out then
               Out_Dir := Work.Value;
            end if;
            if not Have_Rank then
               Rank_Dir := Work.Value & "/rank";
            end if;
            if not Have_Links then
               Links_Path := Work.Value & "/links.tsv";
            end if;
         end;
      end if;

      declare
         Root : constant String :=
           Support.Repo_Root (Env, (if Have_Repo then Repo else ""));
      begin
         if Root = "" then
            Complain
              (Env,
               Prog & ": not inside a git repo: " &
               (if Have_Repo then Repo else ".") & LF);
            return 1;
         end if;
         declare
            Nodes : constant Node_Lists.Node_Vectors.Vector :=
              Node_Lists.Read (Lists_Dir);
         begin
            if Nodes.Is_Empty then
               Complain
                 (Env,
                  Prog & ": no NN.txt/NN.title pairs in " & Lists_Dir & LF);
               return 1;
            end if;
            declare
               Links_Text : Unbounded_String;
               Have       : Boolean;
               Brief_Dir  : constant String := To_String (Out_Dir) & "/brief";
               Missing    : Natural         := 0;
            begin
               Support.Read_File
                 (To_String (Links_Path), Natural'Last, Links_Text, Have);
               if not Have then
                  Complain
                    (Env,
                     Prog & ": no link graph at " & To_String (Links_Path) &
                     " -- every brief's candidate links will be empty; " &
                     "run synapse build-refs and synapse link-graph first" &
                     LF);
               end if;
               for Node of Nodes loop
                  declare
                     Slug : constant String := Node_Lists.Slug (Node.Number);
                     Summary : Unbounded_String;
                     Crux    : Unbounded_String;
                     Got     : Boolean;
                     Page    : Unbounded_String;
                  begin
                     Support.Read_File
                       (To_String (Rank_Dir) & "/" & Slug & ".summary.tsv",
                        16 * 1_024 * 1_024, Summary, Got);
                     if not Got then
                        Missing := Missing + 1;
                     end if;
                     Support.Read_File
                       (To_String (Rank_Dir) & "/" & Slug & ".crux.tsv",
                        16 * 1_024 * 1_024, Crux, Got);
                     Append (Page, "# " & Node.Title & LF & LF);
                     Append (Page, "Repo root: " & Root & LF);
                     Append
                       (Page,
                        "Sources list: " & To_String (Node.Txt_Path) & " (" &
                        Core.Decimal_Image.Image (Node.Files) &
                        " files, exhaustive -- do not re-enumerate; " &
                        "`write-node` reads this list directly)" & LF & LF);
                     Append
                       (Page,
                        "## Summary pool (ranked, read the top few)" & LF);
                     Append (Page, Tsv_Block (To_String (Summary)));
                     Append
                       (Page,
                        LF & "## Crux pool (ranked, tests excluded)" & LF);
                     Append (Page, Tsv_Block (To_String (Crux)));
                     Append
                       (Page,
                        LF &
                        "## Candidate links (from the link graph; weight " &
                        "= distinct rare shared symbols)" & LF);
                     Append
                       (Page,
                        Links_For
                          (To_String (Links_Text), To_String (Node.Title)));
                     Append
                       (Page,
                        LF & "## Every node in this namespace (for judging " &
                        "part_of)" & LF);
                     for Other of Nodes loop
                        Append (Page, "- " & Other.Title & LF);
                     end loop;
                     Support.Write_File
                       (Brief_Dir & "/" & Slug & ".md", To_String (Page));
                  end;
               end loop;
               if Missing /= 0 then
                  Complain
                    (Env,
                     Prog & ": " & Core.Decimal_Image.Image (Missing) & "/" &
                     Core.Decimal_Image.Image (Natural (Nodes.Length)) &
                     " nodes had no rank output at " & To_String (Rank_Dir) &
                     " -- their pool sections are empty; run synapse rank " &
                     "--lists first" & LF);
               end if;
               Complain
                 (Env,
                  Prog & ": " &
                  Core.Decimal_Image.Image (Natural (Nodes.Length)) &
                  " briefs -> " & Brief_Dir & LF);
               return 0;
            end;
         end;
      end;
   end Build;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Lists_Dir, Rank_Dir, Links_Path, Repo, Out_Dir : Unbounded_String;
      Have_Lists, Have_Rank, Have_Links, Have_Repo, Have_Out : Boolean  :=
        False;
      I                                                      : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg   : constant String := To_String (Args (I));
            Value : Unbounded_String;
            Found : Boolean;
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg in "--lists" | "--rank" | "--links" | "--repo" | "--out"
            then
               Cli_Args.Take_Value (Args, I, Value, Found);
               if not Found then
                  return Usage_Error (Env, Usage_Text);
               end if;
               if Arg = "--lists" then
                  Lists_Dir  := Value;
                  Have_Lists := True;
               elsif Arg = "--rank" then
                  Rank_Dir  := Value;
                  Have_Rank := True;
               elsif Arg = "--links" then
                  Links_Path := Value;
                  Have_Links := True;
               elsif Arg = "--repo" then
                  Repo      := Value;
                  Have_Repo := True;
               else
                  Out_Dir  := Value;
                  Have_Out := True;
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
        Build
          (Env, To_String (Lists_Dir), To_String (Rank_Dir),
           To_String (Links_Path), To_String (Repo), To_String (Out_Dir),
           Have_Rank, Have_Links, Have_Repo, Have_Out);
   end Run;

end Synapse.Commands.Brief;
