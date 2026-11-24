with Ada.Strings.Fixed;

with Synapse.Core.JSON;
with Synapse.Pipeline.Session_Support;

package body Synapse.Pipeline.Recording_Runners is

   use Ada.Strings.Unbounded;

   package JSON renames Synapse.Core.JSON;

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function Image (Item : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Item), Ada.Strings.Left));

   function Label (Id : String; Request : Sessions.Session_Request)
      return String
   is
      Text : String :=
        Id & "-" & Image (Request.Visit) & "-" & Image (Request.Attempt);
   begin
      for C of Text loop
         if C not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' then
            C := '_';
         end if;
      end loop;
      return Text;
   end Label;

   --  Keeps what the session changed, when there is something to keep.
   procedure Keep_Changes
     (R         : in out Recording_Runner;
      Request   : Sessions.Session_Request;
      Directory : String;
      Name      : String;
      Before    : Working_Trees.Maybe_Text)
   is
   begin
      if R.Trees = null or else not Before.Found then
         return;
      end if;
      declare
         After : constant Working_Trees.Maybe_Text :=
           R.Trees.Snapshot (Directory, Name & "-after");
      begin
         if not After.Found or else After.Value = Before.Value then
            return;
         end if;
         declare
            Diff : constant Working_Trees.Maybe_Text :=
              R.Trees.Changes
                (Directory, To_String (Before.Value), To_String (After.Value));
         begin
            if Diff.Found and then Length (Diff.Value) > 0 then
               R.Recorder.Record_Patch
                 (Image (Request.Visit) & "-" & To_String (Request.Step.Name)
                  & "-" & Image (Request.Attempt) & ".patch",
                  Patches.Capped (To_String (Diff.Value), R.Largest));
            end if;
         end;
      end;
   end Keep_Changes;

   overriding
   function Run_Session
     (R       : in out Recording_Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result
   is
      Stamped   : Sessions.Session_Request := Request;
      Directory : constant String :=
        To_String (Request.Settings.Working_Directory);
      Name      : constant String := Label (To_String (R.Id), Request);
      Before    : constant Working_Trees.Maybe_Text :=
        (if R.Trees = null then Working_Trees.Maybe_Text'(Found => False)
         else R.Trees.Snapshot (Directory, Name & "-before"));
   begin
      Stamped.Execution_Id := R.Id;
      R.Recorder.Record_Event
        ("session.started", To_String (Request.Step.Name),
         JSON.Make_Object
           ([Member
               ("attempt",
                JSON.Make_Integer (Long_Long_Integer (Request.Attempt))),
            Member
              ("visit",
               JSON.Make_Integer (Long_Long_Integer (Request.Visit))),
            Member
              ("transcript",
               JSON.Make_String
                 (R.Recorder.Store.Transcript_Path
                    (To_String (R.Id),
                     Session_Support.Transcript_Name (Request)))),
            Member
              ("before",
               (if Before.Found
                then JSON.Make_String (To_String (Before.Value))
                else JSON.Null_Value))]));
      declare
         Answer : constant Sessions.Session_Result :=
           R.Inner.Run_Session (Stamped);
      begin
         Keep_Changes (R, Request, Directory, Name, Before);
         R.Recorder.Record_Event
           ("session.finished", To_String (Request.Step.Name),
            JSON.Make_Object
              ([Member
                  ("attempt",
                   JSON.Make_Integer (Long_Long_Integer (Request.Attempt))),
               Member ("succeeded", JSON.Make_Boolean (Answer.Succeeded)),
               Member
                 ("transcript",
                  (if Answer.Transcript.Found
                   then JSON.Make_String (To_String (Answer.Transcript.Value))
                   else JSON.Null_Value))]));
         return Answer;
      end;
   end Run_Session;

end Synapse.Pipeline.Recording_Runners;
