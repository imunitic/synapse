--  The `status:` transition of a task note, as one tested rule and not a table
--  repeated in the prose of two skills with nothing to keep them in agreement.
--
--  Pure: it takes the counts of a checklist and not a note or a path. Reading
--  a task note out of a store is the caller's.

package Synapse.Core.Task_Status is

   type Status is (Todo, In_Progress, Review, Done, Canceled, Cancelled);

   --  The status as a note spells it: `TODO`, `IN-PROGRESS`, `REVIEW`, `DONE`,
   --  `CANCELED` or `CANCELLED`.
   function Image (S : Status) return String;

   type Maybe_Status (Found : Boolean := False) is record
      case Found is
         when True =>
            Value : Status;

         when False =>
            null;
      end case;
   end record;

   --  The status a note's text names, in its exact spelling.
   function Parse (Text : String) return Maybe_Status;

   type Checklist_Count is record
      Total   : Natural := 0;
      Checked : Natural := 0;
   end record;

   --  Whether work remains. A note with no checklist items is the ambiguous
   --  case and counts as unfinished: no checklist means that nothing has been
   --  verified done, not that everything has.
   function Any_Unchecked (C : Checklist_Count) return Boolean is
     (C.Total = 0 or else C.Checked < C.Total);

   --  The `- [ ]` and `- [x]` lines of Body (the `x` in either case), with
   --  leading blanks allowed so that a nested item counts. Any other bullet,
   --  such as a source row or a link edge, is not a checklist line.
   function Count_Checklist (Text : String) return Checklist_Count;

   --  What a checklist implies: `IN-PROGRESS` while anything is unchecked or
   --  there is no checklist, else `REVIEW`. Never `DONE`.
   function Next_Status (C : Checklist_Count) return Status is
     (if Any_Unchecked (C) then In_Progress else Review);

   --  Whether this workflow may ever write To. Done and the two spellings of
   --  canceled are real states, but only a person sets them.
   function Is_Automatic_Target (To : Status) return Boolean is
     (To in In_Progress | Review);

end Synapse.Core.Task_Status;
