with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Synapse.Core.Line_Slice;
with Synapse.Core.Decimal_Image;

package body Synapse.Core.Drift is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   package Sorting is new Text_Lists.Vectors.Generic_Sorting;

   function Parse_Name_Status (Raw : String) return Diff is
      Result : Diff;
      Start  : Integer := Raw'First;
   begin
      loop
         declare
            Stop : constant Natural := Line_Slice.Next_Line_Feed (Raw, Start);
            Last : Integer := (if Stop = 0 then Raw'Last else Stop - 1);
         begin
            if Last >= Start and then Raw (Last) = Character'Val (13) then
               Last := Last - 1;
            end if;
            if Last >= Start then
               declare
                  Line : constant String  := Raw (Start .. Last);
                  Tab  : constant Natural :=
                    Ada.Strings.Fixed.Index (Line, "" & HT);
               begin
                  if Tab > Line'First then
                     declare
                        Status : constant Character := Line (Line'First);
                        Rest : constant String := Line (Tab + 1 .. Line'Last);
                        Second : constant Natural   :=
                          Ada.Strings.Fixed.Index (Rest, "" & HT);
                        Path   : constant String    :=
                          (if Status in 'R' | 'C' and then Second > 0 then
                             Rest (Rest'First .. Second - 1)
                           else Rest);
                     begin
                        case Status is
                           when 'M' =>
                              Result.Modified.Append
                                (To_Unbounded_String (Path));

                           when 'D' =>
                              Result.Deleted.Append
                                (To_Unbounded_String (Path));

                           when 'R' =>
                              Result.Renamed_From.Append
                                (To_Unbounded_String (Path));

                           when 'A' =>
                              Result.Added.Append (To_Unbounded_String (Path));

                           when others =>
                              null;
                        end case;
                     end;
                  end if;
               end;
            end if;
            exit when Stop = 0;
            Start := Stop + 1;
         end;
      end loop;
      Sorting.Sort (Result.Modified);
      Sorting.Sort (Result.Deleted);
      Sorting.Sort (Result.Renamed_From);
      Sorting.Sort (Result.Added);
      return Result;
   end Parse_Name_Status;

   function Count_Intersect (A, B : Text_Lists.Vector) return Natural is
      Shared : Natural  := 0;
      I      : Positive := 1;
      J      : Positive := 1;
   begin
      while I <= Natural (A.Length) and then J <= Natural (B.Length) loop
         if A (I) < B (J) then
            I := I + 1;
         elsif A (I) > B (J) then
            J := J + 1;
         else
            Shared := Shared + 1;
            I      := I + 1;
            J      := J + 1;
         end if;
      end loop;
      return Shared;
   end Count_Intersect;

   function Of_Node
     (Paths : Text_Lists.Vector; Changes : Diff) return Node_Drift is
     (Modified => Count_Intersect (Paths, Changes.Modified),
      Renamed  => Count_Intersect (Paths, Changes.Renamed_From),
      Deleted  => Count_Intersect (Paths, Changes.Deleted));

   function Findings (Node_Without_Md : String; D : Node_Drift) return String
   is
      Text : Unbounded_String;
   begin
      if D.Modified > 0 then
         Append
           (Text,
            Node_Without_Md & HT & "content changed in " &
            Decimal_Image.Image (D.Modified) & " of its files" & LF);
      end if;
      if D.Renamed > 0 then
         Append
           (Text,
            Node_Without_Md & HT & Decimal_Image.Image (D.Renamed) &
            " of its files were renamed -- reseat sources, prose may still " &
            "hold" & LF);
      end if;
      if D.Deleted > 0 then
         Append
           (Text,
            Node_Without_Md & HT & Decimal_Image.Image (D.Deleted) &
            " of its files are gone" & LF);
      end if;
      return To_String (Text);
   end Findings;

   function Short_Commit (Commit : String) return String is
     (if Commit'Length <= 12 then Commit
      else Commit (Commit'First .. Commit'First + 11));

   function Undiffable_Line
     (Node_Without_Md : String; Kind : Undiffable_Kind; Commit : String := "")
      return String is
     (case Kind is
        when Node_File_Missing =>
          Node_Without_Md & HT & "node file missing from the vault" & LF,
        when No_Commit_Recorded =>
          Node_Without_Md & HT &
          "no commit recorded, so nothing to diff against -- verify with " &
          "`stale`" & LF,
        when Baseline_Absent =>
          Node_Without_Md & HT & "baseline " & Short_Commit (Commit) &
          " not in local history -- verify with `stale`" & LF);

end Synapse.Core.Drift;
