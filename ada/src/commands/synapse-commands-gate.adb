with Ada.Strings.Unbounded;

with Synapse.Commands.Cli_Args;
with Synapse.Commands.Graph_Support;
with Synapse.Core.Gate;

package body Synapse.Commands.Gate is

   use Ada.Strings.Unbounded;
   use type Core.Gate.Status;

   package Support renames Synapse.Commands.Graph_Support;

   Prog : constant String    := "synapse-gate";
   LF   : constant Character := Character'Val (10);
   HT   : constant Character := ASCII.HT;

   Usage_Text : constant String :=
     "usage: synapse gate --vocab <groupwords.tsv> [--parseable " &
     "<parseable.tsv>] [--all] [--top N]" & LF & LF &
     "  --vocab       cluster-keyed vocabulary: `cluster <TAB> word <TAB> " &
     "count`" & LF &
     "  --parseable   synapse vocab's `parseable.tsv`: `cluster <TAB> " &
     "parseable <TAB> total`." & LF &
     "                A cluster with zero rare terms and zero parseable " &
     "files is reported" & LF &
     "                `unparseable` instead of `flagged` -- see " &
     "core/gate.zig." & LF &
     "  --all         print every cluster with its score, not only the " &
     "flagged ones" & LF &
     "  --top         terms per cluster the rule looks at, default 8" & LF;

   --  The clusters of `cluster<TAB>parseable<TAB>total` rows that have files
   --  and none of them parseable. A row with no total, a total of zero or
   --  a count that is not a number says nothing and is left out.
   function Unparseable_In (Text : String) return Core.Text_Lists.Set is
      Result : Core.Text_Lists.Set;
      Start  : Positive := Text'First;

      function Number (S : String) return Integer is
      begin
         if S'Length = 0 or else not (for all C of S => C in '0' .. '9') then
            return -1;
         end if;
         return Integer'Value (S);
      exception
         when Constraint_Error =>
            return -1;
      end Number;
   begin
      for I in Text'First .. Text'Last + 1 loop
         if I > Text'Last or else Text (I) = LF then
            declare
               Last : Natural := I - 1;
            begin
               if Last >= Start and then Text (Last) = ASCII.CR then
                  Last := Last - 1;
               end if;
               if Last >= Start then
                  declare
                     Line : constant String := Text (Start .. Last);
                     Tab1, Tab2, Tab3 : Natural         := 0;
                  begin
                     for K in Line'Range loop
                        if Line (K) = HT then
                           if Tab1 = 0 then
                              Tab1 := K;
                           elsif Tab2 = 0 then
                              Tab2 := K;
                           elsif Tab3 = 0 then
                              Tab3 := K;
                           end if;
                        end if;
                     end loop;
                     if Tab1 > 0 and then Tab2 > 0 then
                        declare
                           Parseable : constant Integer :=
                             Number (Line (Tab1 + 1 .. Tab2 - 1));
                           Total     : constant Integer :=
                             Number
                               (Line
                                  (Tab2 + 1 ..
                                       (if Tab3 > 0 then Tab3 - 1
                                        else Line'Last)));
                        begin
                           if Parseable >= 0 and then Total > 0
                             and then Parseable = 0
                           then
                              Result.Include (Line (Line'First .. Tab1 - 1));
                           end if;
                        end;
                     end if;
                  end;
               end if;
               Start := I + 1;
            end;
         end if;
      end loop;
      return Result;
   end Unparseable_In;

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code is
      Vocab_Path, Parseable_Path               : Unbounded_String;
      Have_Vocab, Have_Parseable, All_Clusters : Boolean  := False;
      Top                                      : Natural  := 8;
      I                                        : Positive := 1;
   begin
      while I <= Natural (Args.Length) loop
         declare
            Arg : constant String := To_String (Args (I));

            function Has_Next return Boolean is (I < Natural (Args.Length));
         begin
            if Cli_Args.Is_Help (Arg) then
               Complain (Env, Usage_Text);
               return 0;
            elsif Arg = "--all" then
               All_Clusters := True;
            elsif Arg = "--vocab" then
               if not Has_Next then
                  return Usage_Error (Env, Usage_Text);
               end if;
               I          := I + 1;
               Vocab_Path := Args (I);
               Have_Vocab := Length (Vocab_Path) > 0;
            elsif Arg = "--parseable" then
               if not Has_Next then
                  return Usage_Error (Env, Usage_Text);
               end if;
               I              := I + 1;
               Parseable_Path := Args (I);
               Have_Parseable := True;
            elsif Arg = "--top" then
               if not Has_Next then
                  return Usage_Error (Env, Usage_Text);
               end if;
               I := I + 1;
               declare
                  Raw : constant String := To_String (Args (I));
               begin
                  if Raw'Length = 0
                    or else not (for all C of Raw => C in '0' .. '9')
                  then
                     return Usage_Error (Env, Usage_Text);
                  end if;
                  Top := Natural'Value (Raw);
                  if Top < 1 then
                     return Usage_Error (Env, Usage_Text);
                  end if;
               exception
                  when Constraint_Error =>
                     return Usage_Error (Env, Usage_Text);
               end;
            else
               return Usage_Error (Env, Usage_Text);
            end if;
         end;
         I := I + 1;
      end loop;
      if not Have_Vocab then
         return Usage_Error (Env, Usage_Text);
      end if;

      declare
         Table : Unbounded_String;
         Read  : Boolean;
      begin
         Support.Read_File (To_String (Vocab_Path), Natural'Last, Table, Read);
         if not Read then
            Complain
              (Env,
               Prog & ": no such vocabulary file: " & To_String (Vocab_Path) &
               LF);
            return 1;
         end if;
         if Length (Table) = 0 then
            Complain
              (Env,
               Prog & ": " & To_String (Vocab_Path) &
               " is empty -- nothing was tagged, so cluster quality " &
               "cannot be judged" & LF);
            return 1;
         end if;
         declare
            Settings : Core.Gate.Options := (Top => Top, others => <>);
            Shares   : Unbounded_String;
            Present  : Boolean;
         begin
            if Have_Parseable then
               Support.Read_File
                 (To_String (Parseable_Path), 64 * 1_024 * 1_024, Shares,
                  Present);
               if not Present then
                  Complain
                    (Env,
                     Prog & ": no such parseable-share file: " &
                     To_String (Parseable_Path) & LF);
                  return 1;
               end if;
               Settings.Unparseable := Unparseable_In (To_String (Shares));
            end if;
            declare
               Verdicts : constant Core.Gate.Verdict_Vectors.Vector :=
                 Core.Gate.Judge (To_String (Table), Settings);
               Out_Text : Unbounded_String;
            begin
               for V of Verdicts loop
                  if V.State = Core.Gate.Flagged or else All_Clusters then
                     Append (Out_Text, Core.Gate.Verdict_Line (V));
                  end if;
               end loop;
               Say (Env, To_String (Out_Text));
               return 0;
            end;
         end;
      end;
   end Run;

end Synapse.Commands.Gate;
