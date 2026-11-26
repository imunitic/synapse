package body Synapse.Pipeline.Recorders is

   use Ada.Strings.Unbounded;
   use type States.Run_Status;

   package JSON renames Synapse.Core.JSON;

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function Summary
     (Id, Started, Ended : String;
      Item               : States.State;
      Attention          : Inspection.Attention := (others => <>);
      Directory          : String := "";
      Interactive        : Boolean := False)
      return JSON.Value
   is
      use type Inspection.Attention_State;
      use type JSON.Member_Array;
      Head    : constant JSON.Member_Array :=
        [Member ("format", JSON.Make_String (Format)),
         Member ("id", JSON.Make_String (Id)),
         Member ("pipeline", JSON.Make_String (To_String (Item.Pipeline)))];
      Where   : constant JSON.Member_Array :=
        (if Directory = ""
         then JSON.Member_Array'(1 .. 0 => <>)
         else [Member ("directory", JSON.Make_String (Directory))]);
      Tail    : constant JSON.Member_Array :=
        [Member ("started", JSON.Make_String (Started)),
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
         Member ("state", States.To_JSON (Item)),
         Member ("interactive", JSON.Make_Boolean (Interactive)),
         Member ("attention", Inspection.Attention_JSON (Attention))];
      Members : constant JSON.Member_Array := Head & Where & Tail;
   begin
      return JSON.Make_Object
        (if Attention.State = Inspection.Absent
         then Members (Members'First .. Members'Last - 1) else Members);
   end Summary;

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
             (Summary
                (To_String (R.Id), To_String (R.Started), Ended, Item,
                 R.Context.Current.Attention, To_String (R.Directory),
                 R.Interactive)));
      pragma Unreferenced (Written);
   begin
      null;
   end Write_Summary;

   procedure Start
     (R           : in out Recorder;
      Id          : String;
      Registered  : Boolean;
      Description : JSON.Value;
      Initial     : States.State;
      Directory   : String := "";
      Interactive : Boolean := False) is
   begin
      R.Interactive := Interactive;
      R.Id := To_Unbounded_String (Id);
      R.Directory := To_Unbounded_String (Directory);
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

   procedure Record_Patch (R : in out Recorder; Name, Content : String) is
   begin
      if R.Registered then
         declare
            Written : constant Boolean :=
              R.Store.Write_Patch (To_String (R.Id), Name, Content);
            pragma Unreferenced (Written);
         begin
            null;
         end;
      end if;
   end Record_Patch;

   procedure Record_Output (R : in out Recorder; Name, Content : String) is
   begin
      if R.Registered then
         declare
            Written : constant Boolean :=
              R.Store.Write_Output (To_String (R.Id), Name, Content);
            pragma Unreferenced (Written);
         begin
            null;
         end;
      end if;
   end Record_Output;

   procedure Publish (R : in out Recorder; Item : States.State) is
   begin
      R.Context.Publish (Item);
      if R.Registered then
         Write_Summary (R, Item);
      end if;
   end Publish;

   procedure Attend
     (R      : in out Recorder;
      Step   : String;
      State  : Inspection.Attention_State;
      Reason : String := "")
   is
      use type Inspection.Attention_State;
      Before : constant Inspection.Attention_State :=
        R.Context.Current.Attention.State;
   begin
      R.Context.Set_Attention
        ((State  => State,
          Reason => To_Unbounded_String (Reason),
          Since  => To_Unbounded_String (R.Clock.Timestamp)));
      if State = Inspection.Waiting then
         R.Record_Event
           ("session.waiting", Step,
            JSON.Make_Object
              ([Member ("reason", JSON.Make_String (Reason))]));
      elsif Before = Inspection.Waiting then
         R.Record_Event ("session.resumed", Step, JSON.Null_Value);
      end if;
      if R.Registered then
         Write_Summary (R, R.Context.Current.Run);
      end if;
   end Attend;

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
