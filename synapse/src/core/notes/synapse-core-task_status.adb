package body Synapse.Core.Task_Status is

   LF : constant Character := Character'Val (10);

   function Image (S : Status) return String is
     (case S is when Todo => "TODO", when In_Progress => "IN-PROGRESS",
        when Review => "REVIEW", when Done => "DONE",
        when Canceled => "CANCELED", when Cancelled => "CANCELLED");

   function Parse (Text : String) return Maybe_Status is
   begin
      for S in Status loop
         if Text = Image (S) then
            return (Found => True, Value => S);
         end if;
      end loop;
      return (Found => False);
   end Parse;

   function Count_Checklist (Text : String) return Checklist_Count is
      Result : Checklist_Count;
      Start  : Integer := Text'First;
   begin
      while Start <= Text'Last + 1 loop
         declare
            Stop : Integer := Start;
         begin
            while Stop <= Text'Last and then Text (Stop) /= LF loop
               Stop := Stop + 1;
            end loop;
            declare
               First : Integer := Start;
               Last  : Integer := Stop - 1;
            begin
               if Last >= First and then Text (Last) = Character'Val (13) then
                  Last := Last - 1;
               end if;
               while First <= Last
                 and then Text (First) in ' ' | Character'Val (9)
               loop
                  First := First + 1;
               end loop;
               --  `- [`, a mark, `]`
               if Last - First + 1 >= 5
                 and then Text (First .. First + 2) = "- ["
                 and then Text (First + 4) = ']'
                 and then Text (First + 3) in ' ' | 'x' | 'X'
               then
                  Result.Total := Result.Total + 1;
                  if Text (First + 3) /= ' ' then
                     Result.Checked := Result.Checked + 1;
                  end if;
               end if;
            end;
            Start := Stop + 1;
         end;
      end loop;
      return Result;
   end Count_Checklist;

end Synapse.Core.Task_Status;
