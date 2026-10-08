with Ada.Directories;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Index_Map;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Context;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Emit;
with Synapse.Core.Fault_Names;
with Synapse.Core.Index_Map;
with Synapse.Core.Index_Map_Format;

package body Synapse.Commands.Index is

   use Ada.Strings.Unbounded;
   use type Adapters.Index_Map.Issue;
   use type Ada.Directories.File_Kind;

   package Support renames Synapse.Commands.Graph_Support;
   package Map_Adapter renames Synapse.Adapters.Index_Map;
   package Names renames Synapse.Core.Fault_Names;

   Prog : constant String    := "synapse-index";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse index build --unassigned <file> [--out <file>] " &
     "[--lists <dir>]" & LF &
     "       (pairs on stdin unless --lists names the lists directory)" & LF &
     "       synapse index unassigned [--file <file>|--namespace " &
     "<repo>@<branch>]" & LF &
     "       synapse index lookup <path> [--file <file>|--namespace " &
     "<repo>@<branch>]" & LF &
     "       synapse index nodes [--file <file>|--namespace " &
     "<repo>@<branch>]" & LF &
     "       synapse index paths [--file <file>|--namespace " &
     "<repo>@<branch>]" & LF &
     "       synapse index add-unassigned <path> [--file <file>]" & LF & LF &
     "  --namespace  read forms only -- another checkout's already-built " &
     "index," & LF &
     "               not the cwd's; read-only, no checkout of it needs to " &
     "exist" & LF;

   function Usage (Env : Environment) return Exit_Code is
   begin
      Complain (Env, Usage_Text);
      Cli_Args.Print_Map_For (Env, "index");
      return 2;
   end Usage;

   function No_Work_Dir (Env : Environment) return Exit_Code is
   begin
      Complain (Env, Prog & ": no SYNAPSE_WORK_DIR and no --out/--file" & LF);
      return 1;
   end No_Work_Dir;

   --  The names under which an index that would not read back is reported.
   function Issue_Name (Why : Map_Adapter.Issue) return String is
     (Names.Camel (Map_Adapter.Issue'Image (Why)));

   --  `path<TAB>node.md` for every path of every `lists/NNN.txt` that has a
   --  `NNN.title`. A list with no title is an unfinished build and not a node
   --  claiming nothing. The extension is part of the value: the staleness
   --  hook uses it as a vault path.
   procedure Pairs_From_Lists
     (Env   :        Environment; Lists_Dir : String;
      Pairs : in out Core.Index_Map.Pair_Vectors.Vector; Count : out Natural)
   is
      Stems  : Lists.Vector;
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      package Sorting is new Lists.Vectors.Generic_Sorting
        ("<" => Ada.Strings.Unbounded."<");
   begin
      Count := 0;
      begin
         Ada.Directories.Start_Search
           (Search, Lists_Dir, "*.txt",
            [Ada.Directories.Ordinary_File => True, others => False]);
      exception
         when others =>
            Complain (Env, Prog & ": cannot read --lists " & Lists_Dir & LF);
            return;
      end;
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name'Length > 4 then
               Stems.Append
                 (To_Unbounded_String (Name (Name'First .. Name'Last - 4)));
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      Sorting.Sort (Stems);   --  the same lists give the same bytes

      for Stem of Stems loop
         declare
            Title : Unbounded_String;
            Text  : Unbounded_String;
            Read  : Boolean;
         begin
            Support.Read_File
              (Lists_Dir & "/" & To_String (Stem) & ".title", 1_048_576, Title,
               Read);
            if Read then
               Support.Read_File
                 (Lists_Dir & "/" & To_String (Stem) & ".txt",
                  256 * 1_024 * 1_024, Text, Read);
               if Read then
                  declare
                     Whole : constant String := To_String (Title);
                     Last  : Natural         := Whole'Last;
                  begin
                     while Last >= Whole'First and then Whole (Last) = LF loop
                        Last := Last - 1;
                     end loop;
                     declare
                        Node      : constant String :=
                          Core.Emit.File_Title (Whole (Whole'First .. Last)) &
                          ".md";
                        Body_Text : constant String := To_String (Text);
                        Start     : Positive        := Body_Text'First;
                     begin
                        for I in Body_Text'First .. Body_Text'Last + 1 loop
                           if I > Body_Text'Last or else Body_Text (I) = LF
                           then
                              declare
                                 First : Positive := Start;
                                 Last2 : Natural  := I - 1;
                              begin
                                 while First <= Last2
                                   and then Body_Text (First) in
                                     ' ' | HT | ASCII.CR
                                 loop
                                    First := First + 1;
                                 end loop;
                                 while Last2 >= First
                                   and then Body_Text (Last2) in
                                     ' ' | HT | ASCII.CR
                                 loop
                                    Last2 := Last2 - 1;
                                 end loop;
                                 if Last2 >= First then
                                    Pairs.Append
                                      (Core.Index_Map.Pair'
                                         (Path =>
                                            To_Unbounded_String
                                              (Body_Text (First .. Last2)),
                                          Node => To_Unbounded_String (Node)));
                                    Count := Count + 1;
                                 end if;
                              end;
                              Start := I + 1;
                           end if;
                        end loop;
                     end;
                  end;
               end if;
            end if;
         end;
      end loop;
   end Pairs_From_Lists;

   --  Reads `path<TAB>node` pairs, groups them, and replaces the index.
   function Build_Index
     (Env : Environment; Path : String; Unassigned_File, Lists_Dir : String;
      Has_Unassigned, Has_Lists : Boolean) return Exit_Code
   is
      Pairs : Core.Index_Map.Pair_Vectors.Vector;
      Count : Natural := 0;
   begin
      if Has_Lists then
         Pairs_From_Lists (Env, Lists_Dir, Pairs, Count);
         if Count = 0 then
            Complain (Env, Prog & ": no (path, node) pairs" & LF);
            return 1;
         end if;
      else
         declare
            Text  : constant String := Env.Console.Read_Stdin;
            Start : Positive        := Text'First;
         begin
            for I in Text'First .. Text'Last + 1 loop
               if I > Text'Last or else Text (I) = LF then
                  declare
                     Last : Natural := I - 1;
                     Tab  : Natural := 0;
                  begin
                     if Last >= Start and then Text (Last) = ASCII.CR then
                        Last := Last - 1;
                     end if;
                     --  The last tab and not the first: a path may contain
                     --  one, and the node's file name follows the last.
                     for K in reverse Start .. Last loop
                        if Text (K) = HT then
                           Tab := K;
                           exit;
                        end if;
                     end loop;
                     if Tab > Start and then Tab < Last then
                        Pairs.Append
                          (Core.Index_Map.Pair'
                             (Path =>
                                To_Unbounded_String (Text (Start .. Tab - 1)),
                              Node =>
                                To_Unbounded_String (Text (Tab + 1 .. Last))));
                     end if;
                     Start := I + 1;
                  end;
               end if;
            end loop;
         end;
      end if;

      --  Absent is empty and not an error: a namespace with every file
      --  claimed has no unassigned list.
      declare
         Unassigned : Lists.Vector;
         Text       : Unbounded_String;
         Read       : Boolean := True;
      begin
         if Has_Unassigned then
            Support.Read_File
              (Unassigned_File, 64 * 1_024 * 1_024, Text, Read);
            if not Read then
               Complain
                 (Env,
                  Prog & ": cannot read --unassigned " & Unassigned_File & LF);
               return 1;
            end if;
         end if;
         declare
            Whole : constant String := To_String (Text);
            Start : Positive        := Whole'First;
         begin
            for I in Whole'First .. Whole'Last + 1 loop
               if I > Whole'Last or else Whole (I) = LF then
                  declare
                     Last : Natural := I - 1;
                  begin
                     if Last >= Start and then Whole (Last) = ASCII.CR then
                        Last := Last - 1;
                     end if;
                     if Last >= Start then
                        Unassigned.Append
                          (To_Unbounded_String (Whole (Start .. Last)));
                     end if;
                     Start := I + 1;
                  end;
               end if;
            end loop;
         end;

         declare
            Bytes : Unbounded_String;
         begin
            begin
               Bytes :=
                 To_Unbounded_String
                   (Core.Index_Map.Build (Pairs, Unassigned));
            exception
               when E : others =>
                  Complain
                    (Env,
                     Prog & ": cannot build index (" & Names.Of_Exception (E) &
                     ")" & LF);
                  return 1;
            end;
            begin
               Map_Adapter.Write_File (Path, To_String (Bytes));
            exception
               when others =>
                  Complain (Env, Prog & ": cannot write " & Path & LF);
                  return 1;
            end;
            declare
               Map : Map_Adapter.Map;
            begin
               Map_Adapter.Open (Map, Path);   --  what a reader will find
               if Map_Adapter.Discarded (Map) /= Map_Adapter.None then
                  Complain
                    (Env,
                     Prog & ": wrote an index that will not read back (" &
                     Issue_Name (Map_Adapter.Discarded (Map)) & ")" & LF);
                  return 1;
               end if;
               Say
                 (Env,
                  "keys=" &
                  Core.Decimal_Image.Image (Map_Adapter.Count (Map)) &
                  " unassigned=" &
                  Core.Decimal_Image.Image
                    (Map_Adapter.Unassigned_Count (Map)) &
                  " bytes=" & Core.Decimal_Image.Image (Length (Bytes)) & LF);
               return 0;
            end;
         end;
      end;
   end Build_Index;

   --  The index at Path, opened for a read form, or false after saying that
   --  it will not read.
   procedure Open_For_Read
     (Env :     Environment; Map : in out Map_Adapter.Map; Path : String;
      Ok  : out Boolean)
   is
   begin
      Map_Adapter.Open (Map, Path);
      Ok := Map_Adapter.Discarded (Map) = Map_Adapter.None;
      if not Ok then
         Complain
           (Env,
            Prog & ": unreadable index (" &
            Issue_Name (Map_Adapter.Discarded (Map)) & "): " & Path & LF);
      end if;
   end Open_For_Read;

   function Print_Each
     (Env : Environment; Items : Lists.Vector) return Exit_Code
   is
      Out_Text : Unbounded_String;
   begin
      for Item of Items loop
         Append (Out_Text, Item);
         Append (Out_Text, LF);
      end loop;
      Say (Env, To_String (Out_Text));
      return 0;
   end Print_Each;

   function Add_Unassigned
     (Env : Environment; Path, Extra : String) return Exit_Code
   is
      Map : Map_Adapter.Map;
   begin
      Map_Adapter.Open (Map, Path);
      if Map_Adapter.Discarded (Map) /= Map_Adapter.None
        or else not Map_Adapter.Is_Open (Map)
      then
         return 0;
      end if;
      begin
         declare
            Changed : constant Boolean :=
              Map_Adapter.Add_Unassigned (Map, Extra);
            pragma Unreferenced (Changed);
         begin
            return 0;
         end;
      exception
         when E : Core.Index_Map_Format.Path_Too_Long
           | Core.Index_Map_Format.Path_Contains_Newline
           | Core.Index_Map_Format.Unsorted
           | Core.Index_Map_Format.Unsorted_Nodes
           | Core.Index_Map_Format.No_Nodes
           | Core.Index_Map_Format.Node_Name_Too_Long
           | Core.Index_Map_Format.Too_Many_Nodes_For_Path =>
            Complain
              (Env,
               Prog & ": cannot re-encode index (" & Names.Of_Exception (E) &
               ")" & LF);
            return 1;
         when others                                       =>
            Complain (Env, Prog & ": cannot write " & Path & LF);
            return 1;
      end;
   end Add_Unassigned;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      File, Unassigned_File, Lists_Dir, Positional,
      Namespace     : Unbounded_String;
      Has_File, Has_Unassigned, Has_Lists, Has_Positional,
      Has_Namespace : Boolean  := False;
      I             : Positive := 2;
   begin
      if Args.Is_Empty then
         return Usage (Env);
      end if;
      declare
         Form : constant String := To_String (Args (1));
      begin
         --  Before anything resolves: help must work outside a repository.
         if Cli_Args.Is_Help (Form) then
            Complain (Env, Usage_Text);
            Cli_Args.Print_Map_For (Env, "index");
            return 0;
         end if;
         while I <= Natural (Args.Length) loop
            declare
               Arg : constant String := To_String (Args (I));

               function Next_Is_Value return Boolean is
                 (I < Natural (Args.Length));
            begin
               if Arg in "--out" | "--file" then
                  if not Next_Is_Value then
                     return Usage (Env);
                  end if;
                  I        := I + 1;
                  File     := Args (I);
                  Has_File := True;
               elsif Arg = "--unassigned" then
                  if not Next_Is_Value then
                     return Usage (Env);
                  end if;
                  I               := I + 1;
                  Unassigned_File := Args (I);
                  Has_Unassigned  := True;
               elsif Arg = "--lists" then
                  if not Next_Is_Value then
                     return Usage (Env);
                  end if;
                  I         := I + 1;
                  Lists_Dir := Args (I);
                  Has_Lists := True;
               elsif Arg = "--namespace" then
                  if not Next_Is_Value then
                     return Usage (Env);
                  end if;
                  I             := I + 1;
                  Namespace     := Args (I);
                  Has_Namespace := True;
               elsif Arg'Length >= 2
                 and then Arg (Arg'First .. Arg'First + 1) = "--"
               then
                  return Usage (Env);
               elsif not Has_Positional then
                  Positional     := Args (I);
                  Has_Positional := True;
               else
                  return Usage (Env);
               end if;
            end;
            I := I + 1;
         end loop;

         --  A write lands in the namespace the checkout's own identity names,
         --  never one picked by hand.
         if Has_Namespace and then Form in "build" | "add-unassigned" then
            Complain
              (Env,
               Prog & ": --namespace only applies to a read form " &
               "(unassigned/lookup/nodes/paths)" & LF);
            return 2;
         end if;
         if Has_Namespace and then Has_File then
            Complain
              (Env,
               Prog & ": --file/--out already names the index directly -- " &
               "--namespace has nothing to do" & LF);
            return 2;
         end if;

         declare
            Path : Unbounded_String;
         begin
            if Has_File then
               Path := File;
            else
               declare
                  Work : constant Support.Maybe_Path :=
                    (if Has_Namespace then
                       Support.Work_Dir_For_Namespace
                         (Env, To_String (Namespace), Prog)
                     else Support.Work_Dir (Env, Prog));
               begin
                  if not Work.Found then
                     return No_Work_Dir (Env);
                  end if;
                  Path := Work.Value & "/_index.bin";
               end;
            end if;

            declare
               Where : constant String := To_String (Path);
               Map   : Map_Adapter.Map;
               Ok    : Boolean;
            begin
               if Form = "build" then
                  return
                    Build_Index
                      (Env, Where, To_String (Unassigned_File),
                       To_String (Lists_Dir), Has_Unassigned, Has_Lists);
               elsif Form = "unassigned" then
                  Open_For_Read (Env, Map, Where, Ok);
                  return
                    (if Ok then Print_Each (Env, Map_Adapter.Unassigned (Map))
                     else 1);
               elsif Form = "lookup" then
                  if not Has_Positional then
                     return Usage (Env);
                  end if;
                  Open_For_Read (Env, Map, Where, Ok);
                  if not Ok then
                     return 1;
                  end if;
                  declare
                     Found : constant Map_Adapter.Maybe_Nodes :=
                       Map_Adapter.Nodes_For (Map, To_String (Positional));
                  begin
                     return
                       (if Found.Found then Print_Each (Env, Found.Value)
                        else 1);
                  end;
               elsif Form = "nodes" then
                  Open_For_Read (Env, Map, Where, Ok);
                  return
                    (if Ok then Print_Each (Env, Map_Adapter.Node_Names (Map))
                     else 1);
               elsif Form = "paths" then
                  Open_For_Read (Env, Map, Where, Ok);
                  return
                    (if Ok then Print_Each (Env, Map_Adapter.Paths (Map))
                     else 1);
               elsif Form = "add-unassigned" then
                  if not Has_Positional then
                     return Usage (Env);
                  end if;
                  return Add_Unassigned (Env, Where, To_String (Positional));
               end if;
               return Usage (Env);
            end;
         end;
      end;
   end Run;

   function Build_Index_At
     (Env : Environment; Work_Dir : String) return Exit_Code
   is
      Lists_Dir  : constant String := Work_Dir & "/lists";
      Unassigned : constant String := Work_Dir & "/unassigned.txt";
   begin
      if not Ada.Directories.Exists (Lists_Dir) then
         Complain (Env, "synapse-build-index: no lists/ in " & Work_Dir & LF);
         return 1;
      end if;
      if not Ada.Directories.Exists (Unassigned) then
         Complain
           (Env, "synapse-build-index: no unassigned.txt in " & Work_Dir & LF);
         return 1;
      end if;
      Say (Env, "_index.bin written: ");
      return
        Build_Index
          (Env, Work_Dir & "/_index.bin", Unassigned, Lists_Dir, True, True);
   end Build_Index_At;

   function Run_Build_Index
     (Env : Environment; Args : Lists.Vector) return Exit_Code
   is
   begin
      for Arg_Item of Args loop
         Complain (Env, "usage: synapse build-index" & LF);
         return (if Cli_Args.Is_Help (To_String (Arg_Item)) then 0 else 2);
      end loop;
      declare
         Ctx : constant Context.Maybe_Context :=
           Context.Resolve (Env, "synapse-build-index");
      begin
         if not Ctx.Found then
            return 1;
         end if;
         return Build_Index_At (Env, To_String (Ctx.Value.Work_Dir));
      end;
   end Run_Build_Index;

end Synapse.Commands.Index;
