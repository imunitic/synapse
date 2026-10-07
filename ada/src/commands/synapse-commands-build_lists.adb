with Ada.Directories;
with Synapse.Adapters.Git_Identity;
with Synapse.Commands.Cli_Args;
with Synapse.Commands.Enumerate;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Decimal_Image;
with Synapse.Core.Identity;
with Synapse.Core.Node_Format;

package body Synapse.Commands.Build_Lists is

   use Ada.Strings.Unbounded;
   use type Synapse.Commands.Graph_Support.Grep_Outcome;

   package Support renames Synapse.Commands.Graph_Support;

   Prog : constant String    := "synapse-build-lists";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse build-lists [--reenumerate]" & LF;

   function Parse_Row (Raw : String) return Maybe_Row is
      Last : constant Natural          :=
        (if Raw'Length > 0 and then Raw (Raw'Last) = ASCII.CR then Raw'Last - 1
         else Raw'Last);
      Line : constant String           := Raw (Raw'First .. Last);
      Tabs : array (1 .. 2) of Natural := [others => 0];
      N    : Natural                   := 0;
   begin
      for I in Line'Range loop
         if Line (I) = HT and then N < 2 then
            N        := N + 1;
            Tabs (N) := I;
         end if;
      end loop;
      if Line'Length = 0 or else Line (Line'First) = HT or else N = 0 then
         return (Found => False);
      end if;
      declare
         Include_End : constant Natural :=
           (if N >= 2 then Tabs (2) - 1 else Line'Last);
         Exclude     : constant String  :=
           (if N >= 2 then Line (Tabs (2) + 1 .. Line'Last) else "");
      begin
         return
           (Found   => True,
            Title   => To_Unbounded_String (Line (Line'First .. Tabs (1) - 1)),
            Include =>
              To_Unbounded_String (Line (Tabs (1) + 1 .. Include_End)),
            Exclude => To_Unbounded_String (Exclude));
      end;
   end Parse_Row;

   --  `grep -E Include` then `grep -vE Exclude` over the paths. False when
   --  grep itself failed, as it does for a pattern it cannot read.
   procedure Select_Paths
     (Env     :     Environment; All_Paths, Include, Exclude : String;
      Matched : out Unbounded_String; Ok : out Boolean)
   is
      Included : Unbounded_String;
      Outcome  : Support.Grep_Outcome;
   begin
      Matched := Null_Unbounded_String;
      Support.Grep (Env, "-E", Include, All_Paths, Included, Outcome);
      Ok := Outcome /= Support.Failed;
      if not Ok or else Length (Included) = 0 then
         return;
      end if;
      Support.Grep
        (Env, "-vE", (if Exclude = "" then "^$" else Exclude),
         To_String (Included), Matched, Outcome);
      Ok := Outcome /= Support.Failed;
   end Select_Paths;

   package Sorting is new Lists.Vectors.Generic_Sorting
     ("<" => Ada.Strings.Unbounded."<");

   procedure Write_Lines (Work_Dir, Name : String; Items : Lists.Vector) is
      Body_Text : Unbounded_String;
   begin
      for Item of Items loop
         Append (Body_Text, Item);
         Append (Body_Text, LF);
      end loop;
      Support.Write_File (Work_Dir & "/" & Name, To_String (Body_Text));
   end Write_Lines;

   --  `covered.txt`, `all-sorted.txt` and `unassigned.txt`, and the two
   --  counts. Byte order throughout: the same comparisons the sorts and
   --  `comm` of a shell make under the C locale.
   procedure Write_Coverage
     (Env : Environment; Work_Dir, All_Paths : String; Covered : Lists.Vector)
   is
      Claimed : Lists.Vector := Covered;
      Unique  : Lists.Vector;
      Every   : Lists.Vector;
      Free    : Lists.Vector;
      Start   : Positive     := All_Paths'First;
   begin
      Sorting.Sort (Claimed);
      for Item of Claimed loop
         if Unique.Is_Empty or else Unique.Last_Element /= Item then
            Unique.Append (Item);
         end if;
      end loop;

      for I in All_Paths'First .. All_Paths'Last + 1 loop
         if I > All_Paths'Last or else All_Paths (I) = LF then
            if I > Start then
               Every.Append (To_Unbounded_String (All_Paths (Start .. I - 1)));
            end if;
            Start := I + 1;
         end if;
      end loop;
      Sorting.Sort (Every);

      Write_Lines (Work_Dir, "covered.txt", Unique);
      Write_Lines (Work_Dir, "all-sorted.txt", Every);

      --  `comm -23`: in all-sorted and not in covered, one merge pass.
      declare
         I : Positive := 1;
         J : Positive := 1;
      begin
         while I <= Natural (Every.Length) loop
            if J > Natural (Unique.Length) or else Every (I) < Unique (J) then
               Free.Append (Every (I));
               I := I + 1;
            elsif Every (I) = Unique (J) then
               I := I + 1;
            else
               J := J + 1;
            end if;
         end loop;
      end;
      Write_Lines (Work_Dir, "unassigned.txt", Free);
      Say
        (Env,
         "covered:    " & Core.Decimal_Image.Image (Natural (Unique.Length)) &
         LF & "unassigned: " &
         Core.Decimal_Image.Image (Natural (Free.Length)) & LF);
   end Write_Coverage;

   function Build
     (Env : Environment; Identity_Path : String; Reenumerate : Boolean)
      return Exit_Code
   is
      Resolved : Core.Identity.Resolved;
   begin
      begin
         Resolved := Adapters.Git_Identity.Resolve (Identity_Path);
      exception
         when others =>
            Complain (Env, Prog & ": not inside a git repo" & LF);
            return 1;
      end;
      declare
         Work : constant Support.Maybe_Path := Support.Work_Dir (Env, Prog);
      begin
         if not Work.Found then
            return 1;
         end if;
         declare
            Work_Dir : constant String := To_String (Work.Value);
            Manifest : Unbounded_String;
            Read     : Boolean;
            All_Text : Unbounded_String;
            Covered  : Lists.Vector;
            Count    : Natural         := 0;
         begin
            Ada.Directories.Create_Path (Work_Dir);
            --  Before enumerating: a missing manifest should not cost minutes
            --  of work on a big repository before it is reported.
            Support.Read_File
              (Work_Dir & "/manifest.tsv",
               Support.Max_Listing_Bytes (Env, 16 * 1_024 * 1_024), Manifest,
               Read);
            if not Read then
               Complain (Env, Prog & ": no manifest.tsv in " & Work_Dir & LF);
               return 1;
            end if;
            if not Enumerate.Ensure
                (Env, To_String (Resolved.Where.Repo_Root), Work_Dir,
                 Reenumerate)
            then
               return 1;
            end if;
            Support.Read_File
              (Work_Dir & "/all.txt",
               Support.Max_Listing_Bytes (Env, 256 * 1_024 * 1_024), All_Text,
               Read);
            if not Read then
               Complain (Env, Prog & ": cannot read all.txt" & LF);
               return 1;
            end if;

            --  Rebuilt from nothing, so a removed row leaves no stale list.
            declare
               Lists_Dir : constant String := Work_Dir & "/lists";
            begin
               if Ada.Directories.Exists (Lists_Dir) then
                  Ada.Directories.Delete_Tree (Lists_Dir);
               end if;
               Ada.Directories.Create_Path (Lists_Dir);
            exception
               when others =>
                  null;
            end;

            declare
               Whole : constant String := To_String (Manifest);
               Start : Positive        := Whole'First;
            begin
               for I in Whole'First .. Whole'Last + 1 loop
                  if I > Whole'Last or else Whole (I) = LF then
                     declare
                        Item : constant Maybe_Row :=
                          Parse_Row (Whole (Start .. I - 1));
                     begin
                        Start := I + 1;
                        if Item.Found then
                           Count := Count + 1;
                           --  Every reader of the lists goes through
                           --  `001` to the maximum, so a slug past it
                           --  would vanish from every brief.
                           if Count > Core.Node_Format.Max_Nodes then
                              Complain
                                (Env,
                                 Prog & ": manifest has more than " &
                                 Core.Decimal_Image.Image
                                   (Integer'(Core.Node_Format.Max_Nodes)) &
                                 " nodes -- raise Max_Nodes" & LF);
                              return 1;
                           end if;
                           declare
                              Slug    : constant String :=
                                [1 ..
                                    3 -
                                    Core.Decimal_Image.Image (Count)'Length =>
                                  '0'] &
                                Core.Decimal_Image.Image (Count);
                              Matched : Unbounded_String;
                              Ok      : Boolean;
                              Paths   : Natural         := 0;
                           begin
                              Support.Write_File
                                (Work_Dir & "/lists/" & Slug & ".title",
                                 To_String (Item.Title) & LF);
                              Select_Paths
                                (Env, To_String (All_Text),
                                 To_String (Item.Include),
                                 To_String (Item.Exclude), Matched, Ok);
                              if not Ok then
                                 Complain (Env, Prog & ": grep failed" & LF);
                                 return 1;
                              end if;
                              Support.Write_File
                                (Work_Dir & "/lists/" & Slug & ".txt",
                                 To_String (Matched));
                              declare
                                 Text : constant String := To_String (Matched);
                                 First : Positive        := Text'First;
                              begin
                                 for K in Text'First .. Text'Last + 1 loop
                                    if K > Text'Last or else Text (K) = LF then
                                       if K > First then
                                          Paths := Paths + 1;
                                          Covered.Append
                                            (To_Unbounded_String
                                               (Text (First .. K - 1)));
                                       end if;
                                       First := K + 1;
                                    end if;
                                 end loop;
                              end;
                              Say
                                (Env,
                                 Slug & HT & Core.Decimal_Image.Image (Paths) &
                                 HT & To_String (Item.Title) & LF);
                           end;
                        end if;
                     end;
                  end if;
               end loop;
            end;

            Say (Env, "--- coverage" & LF);
            Write_Coverage (Env, Work_Dir, To_String (All_Text), Covered);
            return 0;
         end;
      end;
   end Build;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Reenumerate : Boolean := False;
   begin
      for Arg_Item of Args loop
         declare
            Arg : constant String := To_String (Arg_Item);
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg = "--reenumerate" then
               Reenumerate := True;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
      end loop;
      return Build (Env, ".", Reenumerate);
   end Run;

end Synapse.Commands.Build_Lists;
