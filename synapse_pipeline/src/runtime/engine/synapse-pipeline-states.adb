with Synapse.Core.Optional_Text;

package body Synapse.Pipeline.States is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   function Initial
     (Item : Resolved.Pipeline; Input : JSON.Value) return State
   is
      Result : State;
   begin
      Result.Pipeline := Item.Name;
      Result.Current_Step := Item.Steps.First_Element.Name;
      Result.Initial_Input := Input;
      for Ignored of Item.Edges loop
         Result.Fired.Append (0);
      end loop;
      return Result;
   end Initial;

   function Status_Name (Item : Run_Status) return String is
     (case Item is
        when Running   => "running",
        when Completed => "completed",
        when Failed    => "failed");

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function Optional_JSON (Item : Synapse.Core.Optional_Text.Option)
      return JSON.Value is
     (if Item.Found then JSON.Make_String (To_String (Item.Value))
      else JSON.Null_Value);

   function Failure_JSON (Item : State) return JSON.Value is
   begin
      if Item.Status /= Failed then
         return JSON.Null_Value;
      end if;
      return JSON.Make_Object
        ([Member
            ("kind", JSON.Make_String (Failures.Name_Of (Item.Failure.Kind))),
         Member ("step", JSON.Make_String (To_String (Item.Failure.Step))),
         Member
           ("message", JSON.Make_String (To_String (Item.Failure.Message))),
         Member ("reset", Optional_JSON (Item.Failure.Reset))]);
   end Failure_JSON;

   function To_JSON (Item : State) return JSON.Value is
      Fired : JSON.Value_Array (1 .. Natural (Item.Fired.Length));
   begin
      for I in Fired'Range loop
         Fired (I) := JSON.Make_Integer (Long_Long_Integer (Item.Fired (I)));
      end loop;
      return JSON.Make_Object
        ([Member ("format", JSON.Make_String (Format)),
          Member ("pipeline", JSON.Make_String (To_String (Item.Pipeline))),
          Member ("status", JSON.Make_String (Status_Name (Item.Status))),
          Member
            ("current_step",
             JSON.Make_String (To_String (Item.Current_Step))),
          Member ("initial_input", Item.Initial_Input),
          Member ("previous_output", Item.Previous_Output),
          Member ("fired", JSON.Make_Array (Fired)),
          Member
            ("steps_run",
             JSON.Make_Integer (Long_Long_Integer (Item.Steps_Run))),
          Member ("failure", Failure_JSON (Item))]);
   end To_JSON;

   function To_Text (Item : State) return String is
     (JSON.To_String (To_JSON (Item)));

   function From_JSON (Document : JSON.Value) return State_Results.Result is
      Result  : State;
      Failed_Read : Boolean := False;
      Problem : Unbounded_String;

      procedure Fail (Where, What : String) is
      begin
         if not Failed_Read then
            Failed_Read := True;
            Problem := To_Unbounded_String (Where & ": " & What);
         end if;
      end Fail;

      function Image (N : Natural) return String is
         Text : constant String := Natural'Image (N);
      begin
         return Text (Text'First + 1 .. Text'Last);
      end Image;

      function Field
        (Object : JSON.Value; Key, Where : String) return JSON.Value is
      begin
         if JSON.Kind_Of (Object) /= JSON.JSON_Object then
            Fail (Where, "expected an object");
         elsif not JSON.Has_Member (Object, Key) then
            Fail (Where, "'" & Key & "' is missing");
         else
            return JSON.Member_Value (Object, Key);
         end if;
         return JSON.Null_Value;
      end Field;

      function String_Field
        (Object : JSON.Value; Key, Where : String) return String
      is
         Item : constant JSON.Value := Field (Object, Key, Where);
      begin
         if Failed_Read then
            return "";
         elsif JSON.Kind_Of (Item) /= JSON.JSON_String then
            Fail (Where & "." & Key, "expected a string");
            return "";
         end if;
         return JSON.As_String (Item);
      end String_Field;

      function Count_Of (Item : JSON.Value; Where : String) return Natural is
      begin
         if JSON.Kind_Of (Item) /= JSON.JSON_Integer
           or else JSON.As_Integer (Item) not in 0 .. 2_000_000_000
         then
            Fail (Where, "expected a whole number, 0 or more");
            return 0;
         end if;
         return Natural (JSON.As_Integer (Item));
      end Count_Of;

      Status_Text : Unbounded_String;
   begin
      if String_Field (Document, "format", "document") /= Format
        and then not Failed_Read
      then
         Fail ("format", "expected '" & Format & "'");
      end if;
      Result.Pipeline :=
        To_Unbounded_String (String_Field (Document, "pipeline", "document"));
      Status_Text :=
        To_Unbounded_String (String_Field (Document, "status", "document"));
      if not Failed_Read then
         if To_String (Status_Text) = "running" then
            Result.Status := Running;
         elsif To_String (Status_Text) = "completed" then
            Result.Status := Completed;
         elsif To_String (Status_Text) = "failed" then
            Result.Status := Failed;
         else
            Fail
              ("document.status",
               "expected 'running', 'completed' or 'failed'");
         end if;
      end if;
      Result.Current_Step :=
        To_Unbounded_String
          (String_Field (Document, "current_step", "document"));
      Result.Initial_Input := Field (Document, "initial_input", "document");
      Result.Previous_Output :=
        Field (Document, "previous_output", "document");
      Result.Steps_Run :=
        Count_Of (Field (Document, "steps_run", "document"),
                  "document.steps_run");
      declare
         Fired : constant JSON.Value := Field (Document, "fired", "document");
      begin
         if not Failed_Read and then JSON.Kind_Of (Fired) /= JSON.JSON_Array
         then
            Fail ("document.fired", "expected a list");
         elsif not Failed_Read then
            for I in 1 .. JSON.Length (Fired) loop
               Result.Fired.Append
                 (Count_Of
                    (JSON.Element (Fired, I),
                     "document.fired[" & Image (I) & "]"));
               exit when Failed_Read;
            end loop;
         end if;
      end;
      declare
         Cause : constant JSON.Value :=
           Field (Document, "failure", "document");
      begin
         if Failed_Read then
            null;
         elsif Result.Status = Failed then
            declare
               Kind_Text : constant String :=
                 String_Field (Cause, "kind", "document.failure");
               Kind      : constant Failures.Kind_Options.Option :=
                 Failures.Find (Kind_Text);
            begin
               if not Failed_Read and then not Kind.Found then
                  Fail
                    ("document.failure.kind",
                     "'" & Kind_Text & "' is not a kind of failure");
               elsif Kind.Found then
                  Result.Failure.Kind := Kind.Value;
                  Result.Failure.Step :=
                    To_Unbounded_String
                      (String_Field (Cause, "step", "document.failure"));
                  Result.Failure.Message :=
                    To_Unbounded_String
                      (String_Field (Cause, "message", "document.failure"));
                  declare
                     Reset : constant JSON.Value :=
                       Field (Cause, "reset", "document.failure");
                  begin
                     if not Failed_Read
                       and then JSON.Kind_Of (Reset) = JSON.JSON_String
                     then
                        Result.Failure.Reset :=
                          Synapse.Core.Optional_Text.Of_Value
                            (To_Unbounded_String (JSON.As_String (Reset)));
                     elsif not Failed_Read
                       and then JSON.Kind_Of (Reset) /= JSON.JSON_Null
                     then
                        Fail
                          ("document.failure.reset",
                           "expected a string or null");
                     end if;
                  end;
               end if;
            end;
         elsif JSON.Kind_Of (Cause) /= JSON.JSON_Null then
            Fail ("document.failure", "a run that has not failed has none");
         end if;
      end;
      if Failed_Read then
         return State_Results.Failure (Problem);
      end if;
      return State_Results.Success (Result);
   end From_JSON;

   function Parse (Text : String) return State_Results.Result is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      if not Parsed.Ok then
         return State_Results.Failure
           (To_Unbounded_String
              ("not JSON: " & JSON.Parse_Error_Kind'Image (Parsed.Error)
               & " at byte" & Natural'Image (Parsed.Offset)));
      end if;
      return From_JSON (Parsed.Item);
   end Parse;

end Synapse.Pipeline.States;
