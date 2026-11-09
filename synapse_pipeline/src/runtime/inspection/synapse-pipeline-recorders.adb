with Synapse.Pipeline.Inspection;

package body Synapse.Pipeline.Recorders is

   use Ada.Strings.Unbounded;
   use type States.Run_Status;

   package JSON renames Synapse.Core.JSON;

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function Summary
     (Id, Started, Ended : String; Item : States.State) return JSON.Value
   is
     (JSON.Make_Object
        ([Member ("format", JSON.Make_String (Format)),
          Member ("id", JSON.Make_String (Id)),
          Member
            ("pipeline", JSON.Make_String (To_String (Item.Pipeline))),
          Member ("started", JSON.Make_String (Started)),
          Member
            ("ended",
             (if Ended = "" then JSON.Null_Value
              else JSON.Make_String (Ended))),
          Member
            ("status",
             JSON.Make_String
               (case Item.Status is
                  when States.Running   => "running",
                  when States.Completed => "completed",
                  when States.Failed    => "failed")),
          Member
            ("current_step",
             (if Item.Status = States.Running
              then JSON.Make_String (To_String (Item.Current_Step))
              else JSON.Null_Value)),
          Member ("state", States.To_JSON (Item))]));

   --  Writes the summary of the run in state Item.
   procedure Write_Summary
     (R : in out Recorder; Item : States.State)
   is
      Ended   : constant String :=
        (if States.Is_Terminal (Item) then R.Clock.Timestamp else "");
      Written : constant Boolean :=
        R.Store.Replace_Summary
          (To_String (R.Id),
           JSON.To_String
             (Summary (To_String (R.Id), To_String (R.Started), Ended, Item)));
      pragma Unreferenced (Written);
   begin
      null;
   end Write_Summary;

   procedure Start
     (R           : in out Recorder;
      Id          : String;
      Registered  : Boolean;
      Description : JSON.Value;
      Initial     : States.State) is
   begin
      R.Id := To_Unbounded_String (Id);
      R.Registered := Registered;
      R.Started := To_Unbounded_String (R.Clock.Timestamp);
      R.Context.Start (Id, Description, Initial);
      if R.Registered then
         Write_Summary (R, Initial);
         declare
            Written : constant Boolean :=
              R.Store.Write_Description (Id, JSON.To_String (Description));
            pragma Unreferenced (Written);
         begin
            null;
         end;
      end if;
   end Start;

   procedure Record_Definition (R : in out Recorder; Path, Content : String) is
   begin
      if R.Registered then
         declare
            Written : constant Boolean :=
              R.Store.Write_Definition (To_String (R.Id), Path, Content);
            pragma Unreferenced (Written);
         begin
            null;
         end;
      end if;
   end Record_Definition;

   procedure Publish (R : in out Recorder; Item : States.State) is
   begin
      R.Context.Publish (Item);
      if R.Registered then
         Write_Summary (R, Item);
      end if;
   end Publish;

   procedure Record_Event
     (R      : in out Recorder;
      Kind   : String;
      Step   : String;
      Detail : JSON.Value) is
   begin
      R.Context.Record_Event (Kind, Step, Detail);
      if R.Registered then
         declare
            Events  : constant Inspection.Event_Vectors.Vector :=
              R.Context.Current.Events;
            Written : constant Boolean :=
              (Events.Is_Empty
               or else R.Store.Append_Event
                         (To_String (R.Id),
                          JSON.To_String
                            (Inspection.Event_JSON (Events.Last_Element))));
            pragma Unreferenced (Written);
         begin
            null;
         end;
      end if;
   end Record_Event;

end Synapse.Pipeline.Recorders;
