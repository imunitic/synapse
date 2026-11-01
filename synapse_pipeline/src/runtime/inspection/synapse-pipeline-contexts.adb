with Ada.Strings.Unbounded;

package body Synapse.Pipeline.Contexts is

   use Ada.Strings.Unbounded;

   protected body Execution_Context is

      procedure Start
        (Id          : String;
         Description : Synapse.Core.JSON.Value;
         Initial     : States.State) is
      begin
         Data.Execution_Id := To_Unbounded_String (Id);
         Data.Description := Description;
         Data.Run := Initial;
         Data.Events.Clear;
         Next := 1;
      end Start;

      procedure Publish (Item : States.State) is
      begin
         Data.Run := Item;
      end Publish;

      procedure Record_Event
        (Kind, Step : String; Detail : Synapse.Core.JSON.Value) is
      begin
         Data.Events.Append
           (Inspection.Event'
              (Sequence => Next, Kind => To_Unbounded_String (Kind),
               Step => To_Unbounded_String (Step), Detail => Detail));
         Next := Next + 1;
         if Natural (Data.Events.Length) > Inspection.Max_Events then
            Data.Events.Delete_First;
         end if;
      end Record_Event;

      function Current return Inspection.Snapshot is (Data);

   end Execution_Context;

end Synapse.Pipeline.Contexts;
